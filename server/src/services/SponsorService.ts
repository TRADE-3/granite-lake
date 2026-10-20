import { randomInt } from "node:crypto";
import { bcs } from "@mysten/sui/bcs";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import type { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Inputs, Transaction, TransactionDataBuilder } from "@mysten/sui/transactions";
import { normalizeSuiAddress, SUI_CLOCK_OBJECT_ID, toBase64 } from "@mysten/sui/utils";
import { verifyTransactionSignature } from "@mysten/sui/verify";
import type { AppEnv } from "../config/env.js";
import { findUserBy, type UserRecord } from "../db/repositories.js";
import {
  findSponsorTransaction,
  getSponsorLedgerSpend,
  getSponsorState,
  getSponsorUsage,
  insertSponsorTransaction,
  listRecentSponsorTransactions,
  listSponsorUsageByUser,
  listUnresolvedSponsorTransactions,
  resolveSponsorTransaction,
  setSponsorPaused,
  type SponsorState,
  type SponsorTransactionKind,
  type SponsorTransactionRecord,
} from "../db/sponsorRepositories.js";
import { GoogleChatService } from "./GoogleChatService.js";
import { createSuiClient } from "./SuiService.js";
import { resolveSecretValue } from "./VaultService.js";

export type PhotoAttestationArgs = {
  hash: string;
  gps: string;
  altitude: string;
  projectId: string;
  capturedAtMs: number;
  isOnline: boolean;
  isForcedOffline: boolean;
  internetNullReasonHash: string;
  hasGps: boolean;
  isGpsForcedNull: boolean;
  gpsNullReasonHash: string;
};

export type FileAttestationArgs = {
  hash: string;
  fileId: string;
  projectId: string;
  capturedAtMs: number;
  isOnline: boolean;
  isForcedOffline: boolean;
  internetNullReasonHash: string;
};

export type AttestationRequest =
  | { kind: "photo"; args: PhotoAttestationArgs }
  | { kind: "file"; args: FileAttestationArgs };

export type OwnedObjectRef = { objectId: string; version: string; digest: string };
export type SharedObjectRef = { objectId: string; initialSharedVersion: string; mutable: false };

export type ValidDuring = {
  minEpoch: string;
  maxEpoch: string;
  chain: string;
  nonce: number;
};

export type PreparedSponsorTransaction = {
  digest: string;
  txBytes: string;
  sender: string;
  gasData: { owner: string; price: string; budget: string; payment: [] };
  objectRefs: { userCap: OwnedObjectRef; registry: SharedObjectRef; clock: SharedObjectRef };
  validDuring: ValidDuring;
  expiresAt: string;
};

export type SponsorSubmitResult =
  | { digest: string; status: "executed"; gasUsedMist: string }
  | { digest: string; status: "failed"; gasUsedMist: string | null; error: string }
  | { digest: string; status: "pending" }
  | { digest: string; status: "dropped" };

export class SponsorError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "SponsorError";
  }
}

type SponsorSuiClient = Pick<SuiGrpcClient, "core">;

type PreparedEntry = {
  bytes: Uint8Array;
  userWallet: string;
  userId: string;
  kind: SponsorTransactionKind;
  gasBudget: bigint;
  maxEpoch: bigint;
  expiresAt: number;
};

type HealthSnapshot = {
  addressBalance: bigint;
  coinBalance: bigint;
  referenceGasPrice: bigint;
  state: SponsorState;
  fetchedAt: number;
};

// Mirrors the app's _dryRun: computation + gross storage + 1000 * price. The
// rebate is only refunded after execution, so it must not be subtracted.
const GAS_SAFE_OVERHEAD = 1000n;
const HEALTH_CACHE_MS = 30_000;
const MAX_PREPARED_PER_WALLET = 5;
// Unresolved rows younger than this are left to the submit that created them.
const SWEEP_MIN_AGE_MS = 60_000;
const ALERT_COOLDOWN_MS = 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Domain-sponsored attestation gas. The sponsor key only ever signs a
 * transaction this service built itself (a single allowlisted attest_photo /
 * attest_file call) after an active registered user has signed exactly those
 * bytes. See design/granite-lake-sponsored-transactions-design.md.
 */
export class SponsorService {
  private readonly client: SponsorSuiClient;
  private readonly googleChat: GoogleChatService;
  private keypair: Ed25519Keypair | null = null;
  private readonly prepared = new Map<string, PreparedEntry>();
  private health: HealthSnapshot | null = null;
  private sharedObjectVersions = new Map<string, string>();
  private chainIdentifier: string | null = null;
  private readonly alertSentAt = new Map<string, number>();
  private leakSnapshot: { totalBalance: bigint; at: Date } | null = null;
  private maintenanceTimer: NodeJS.Timeout | null = null;
  private submitLock: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly appEnv: AppEnv,
    deps: { client?: SponsorSuiClient; googleChat?: GoogleChatService } = {}
  ) {
    this.client = deps.client ?? createSuiClient(appEnv);
    this.googleChat = deps.googleChat ?? new GoogleChatService(appEnv);
  }

  get enabled(): boolean {
    return this.appEnv.SPONSOR_ENABLED;
  }

  get sponsorWallet(): string {
    return normalizeSuiAddress(this.appEnv.SPONSOR_WALLET);
  }

  /**
   * Resolves and checks the sponsor key. Called at boot when sponsorship is
   * enabled so misconfiguration fails fast, and lazily before first use.
   */
  async initialize(): Promise<Ed25519Keypair> {
    if (this.keypair) return this.keypair;

    if (!this.enabled) {
      throw new SponsorError(503, "sponsor_disabled", "Sponsored attestations are not enabled for this domain.");
    }

    const { SPONSOR_PRIVATE_KEY, SPONSOR_WALLET, ADMIN_WALLET, SUI_PACKAGE_ID, SUI_REGISTRY_ID } = this.appEnv;
    if (!SPONSOR_PRIVATE_KEY || !SPONSOR_WALLET || !SUI_PACKAGE_ID || !SUI_REGISTRY_ID) {
      throw new Error(
        "Sponsor configuration is incomplete. Set SPONSOR_PRIVATE_KEY, SPONSOR_WALLET, SUI_PACKAGE_ID, and SUI_REGISTRY_ID."
      );
    }

    // The sponsor path is reachable by every app install; it must never hold
    // the domain admin key. There is deliberately no fallback to SUI_PRIVATE_KEY.
    if (normalizeSuiAddress(SPONSOR_WALLET.trim()) === normalizeSuiAddress(ADMIN_WALLET.trim())) {
      throw new Error("SPONSOR_WALLET must differ from ADMIN_WALLET.");
    }

    const privateKey = await resolveSecretValue(this.appEnv, SPONSOR_PRIVATE_KEY);
    if (!privateKey) {
      throw new Error("Sponsor private key could not be resolved from configuration.");
    }

    const decoded = decodeSuiPrivateKey(privateKey.trim());
    if (decoded.scheme !== "ED25519") {
      throw new Error(`Unsupported sponsor private key scheme: ${decoded.scheme}. Expected ED25519.`);
    }

    const keypair = Ed25519Keypair.fromSecretKey(decoded.secretKey);
    const signerAddress = normalizeSuiAddress(keypair.toSuiAddress());
    if (signerAddress !== this.sponsorWallet) {
      throw new Error(`Sponsor signer ${signerAddress} does not match SPONSOR_WALLET ${this.sponsorWallet}.`);
    }

    this.keypair = keypair;
    return keypair;
  }

  status():
    | { enabled: false }
    | { enabled: true; sponsorWallet: string; maxGasBudgetMist: string; maxGasPriceMist: string } {
    if (!this.enabled) return { enabled: false };

    return {
      enabled: true,
      sponsorWallet: this.sponsorWallet,
      maxGasBudgetMist: this.appEnv.SPONSOR_MAX_GAS_BUDGET_MIST.toString(),
      maxGasPriceMist: this.appEnv.SPONSOR_MAX_GAS_PRICE_MIST.toString(),
    };
  }

  async prepare(input: { userWallet: string; request: AttestationRequest }): Promise<PreparedSponsorTransaction> {
    await this.initialize();
    const userWallet = normalizeSuiAddress(input.userWallet);

    const user = await this.requireActiveUser(userWallet);
    await this.assertWithinQuota(user, 0n);
    const health = await this.assertHealthy();

    const userCap = await this.resolveUserCap(user, userWallet);
    const registry = await this.resolveSharedObject(this.appEnv.SUI_REGISTRY_ID);
    const clock = await this.resolveSharedObject(SUI_CLOCK_OBJECT_ID);

    const [{ systemState }, chain] = await Promise.all([
      this.client.core.getCurrentSystemState(),
      this.getChainIdentifier(),
    ]);
    const minEpoch = BigInt(systemState.epoch);
    const validDuring: ValidDuring = {
      minEpoch: minEpoch.toString(),
      maxEpoch: (minEpoch + 1n).toString(),
      chain,
      nonce: randomInt(0, 2 ** 32),
    };

    const build = (gasBudget: bigint) =>
      buildAttestationTransaction({
        packageId: this.appEnv.SUI_PACKAGE_ID,
        moduleName: this.appEnv.SUI_MODULE,
        request: input.request,
        userWallet,
        sponsorWallet: this.sponsorWallet,
        userCap,
        registry,
        clock,
        gasPrice: health.referenceGasPrice,
        gasBudget,
        validDuring,
      }).build();

    // Simulation is the semantic check: it catches E_NOT_USER,
    // E_USER_DISABLED, the null-reason invariants and UserCap problems
    // before any gas is at risk.
    const simulation = await this.client.core.simulateTransaction({
      transaction: await build(this.appEnv.SPONSOR_MAX_GAS_BUDGET_MIST),
      include: { effects: true },
    });
    if (simulation.$kind === "FailedTransaction") {
      throw new SponsorError(
        422,
        "simulation_failed",
        simulation.FailedTransaction.status.error?.message ?? "The attestation would fail on-chain."
      );
    }

    const gasUsed = simulation.Transaction.effects.gasUsed;
    const gasBudget =
      BigInt(gasUsed.computationCost) + BigInt(gasUsed.storageCost) + GAS_SAFE_OVERHEAD * health.referenceGasPrice;
    if (gasBudget > this.appEnv.SPONSOR_MAX_GAS_BUDGET_MIST) {
      throw new SponsorError(
        422,
        "simulation_failed",
        `Attestation needs ${gasBudget} MIST of gas, above the sponsor cap of ${this.appEnv.SPONSOR_MAX_GAS_BUDGET_MIST}.`
      );
    }

    const bytes = await build(gasBudget);
    const digest = TransactionDataBuilder.getDigestFromBytes(bytes);
    const expiresAt = Date.now() + this.appEnv.SPONSOR_PREPARE_TTL_MS;

    this.cachePrepared(digest, {
      bytes,
      userWallet,
      userId: user.userId,
      kind: input.request.kind,
      gasBudget,
      maxEpoch: BigInt(validDuring.maxEpoch),
      expiresAt,
    });

    return {
      digest,
      txBytes: toBase64(bytes),
      sender: userWallet,
      gasData: {
        owner: this.sponsorWallet,
        price: health.referenceGasPrice.toString(),
        budget: gasBudget.toString(),
        payment: [],
      },
      objectRefs: { userCap, registry, clock },
      validDuring,
      expiresAt: new Date(expiresAt).toISOString(),
    };
  }

  async submit(input: { userWallet: string; digest: string; userSignature: string }): Promise<SponsorSubmitResult> {
    const keypair = await this.initialize();
    const userWallet = normalizeSuiAddress(input.userWallet);

    // A repeat of a digest we already sponsor-signed (e.g. the response was
    // lost on a flaky connection) returns the recorded outcome.
    const existing = await findSponsorTransaction(input.digest);
    if (existing) {
      return this.repeatSubmitResult(existing, userWallet);
    }

    const entry = this.prepared.get(input.digest);
    if (!entry || entry.expiresAt <= Date.now() || entry.userWallet !== userWallet) {
      throw new SponsorError(404, "prepared_tx_not_found", "Prepared transaction not found or expired.");
    }

    // An admin may have disabled the user between prepare and submit.
    const user = await this.requireActiveUser(userWallet);

    // The property the whole design rests on: the sponsor key only signs
    // bytes this server built and an active registered user has signed.
    try {
      await verifyTransactionSignature(entry.bytes, input.userSignature, { address: userWallet });
    } catch {
      throw new SponsorError(400, "invalid_user_signature", "User signature does not match the prepared transaction.");
    }

    const inserted = await this.withSubmitLock(async () => {
      await this.assertWithinQuota(user, entry.gasBudget);
      return insertSponsorTransaction({
        txDigest: input.digest,
        userId: user.userId,
        kind: entry.kind,
        gasBudget: entry.gasBudget,
        maxEpoch: entry.maxEpoch,
      });
    });

    // A concurrent submit for the same digest won the insert; it owns signing.
    if (!inserted) {
      const row = await findSponsorTransaction(input.digest);
      if (!row) throw new SponsorError(404, "prepared_tx_not_found", "Prepared transaction not found or expired.");
      return this.repeatSubmitResult(row, userWallet);
    }

    // Evict before signing so a digest can be sponsor-signed at most once.
    this.prepared.delete(input.digest);

    const { signature: sponsorSignature } = await keypair.signTransaction(entry.bytes);

    let result;
    try {
      result = await this.client.core.executeTransaction({
        transaction: entry.bytes,
        signatures: [input.userSignature, sponsorSignature],
        include: { effects: true },
      });
    } catch (error) {
      // Outcome unknown: the row stays `signed` with its budget reserved. A
      // repeated submit or the maintenance sweep resolves it from chain.
      console.error("Sponsored execute failed; leaving row unresolved", {
        digest: input.digest,
        error: error instanceof Error ? error.message : String(error),
      });
      throw new SponsorError(502, "sui_rpc_failed", "Could not confirm the sponsored transaction. Try again.");
    }

    const tx = result.$kind === "Transaction" ? result.Transaction : result.FailedTransaction;
    const row = await this.resolveFromEffects(input.digest, tx.effects);
    this.health = null;

    return toSubmitResult(row ?? (await findSponsorTransaction(input.digest)), input.digest);
  }

  /** Resolves stale `signed` rows from chain state. */
  async sweepUnresolved(): Promise<void> {
    const rows = await listUnresolvedSponsorTransactions({ createdBefore: new Date(Date.now() - SWEEP_MIN_AGE_MS) });
    if (rows.length === 0) return;

    const { systemState } = await this.client.core.getCurrentSystemState();
    const currentEpoch = BigInt(systemState.epoch);

    for (const row of rows) {
      await this.resolveFromChain(row, currentEpoch);
    }
  }

  /**
   * Compares the drop in the sponsor balance since the last run with the gas
   * the ledger explains over the same window. A larger drop means something
   * other than this server is spending from the sponsor wallet, so
   * sponsorship pauses until an admin resumes it.
   */
  async checkUnexpectedSpend(): Promise<void> {
    const { balance } = await this.client.core.getBalance({ owner: this.sponsorWallet });
    const totalBalance = BigInt(balance.balance);
    const now = new Date();
    const previous = this.leakSnapshot;
    this.leakSnapshot = { totalBalance, at: now };

    // A top-up only raises the balance, so it can mask a drain within one
    // window; the next window still catches it.
    if (!previous || totalBalance >= previous.totalBalance) return;

    const drop = previous.totalBalance - totalBalance;
    const explained = await getSponsorLedgerSpend({ since: previous.at, until: now });
    // One transaction's budget of slack for rows resolving across the window edge.
    const tolerance = this.appEnv.SPONSOR_MAX_GAS_BUDGET_MIST;

    if (drop <= explained + tolerance) return;

    const reason = `Sponsor balance fell by ${drop} MIST but the ledger explains ${explained} MIST.`;
    await setSponsorPaused({ paused: true, reason });
    this.health = null;
    this.alert(
      "unexpected_spend",
      [
        `Granite Lake sponsor PAUSED for ${this.appEnv.CLIENT_ID}`,
        "",
        reason,
        `Sponsor wallet: ${this.sponsorWallet}`,
        "Something other than this server may be spending from the sponsor wallet.",
        "Investigate, then resume with POST /admin/sponsor/resume.",
      ].join("\n"),
      0
    );
  }

  async runMaintenance(): Promise<void> {
    try {
      await this.sweepUnresolved();
    } catch (error) {
      console.error("Sponsor sweep failed", { error: error instanceof Error ? error.message : String(error) });
    }

    try {
      await this.checkUnexpectedSpend();
    } catch (error) {
      console.error("Sponsor spend check failed", { error: error instanceof Error ? error.message : String(error) });
    }
  }

  startMaintenance(): void {
    if (!this.enabled || this.maintenanceTimer) return;

    void this.runMaintenance();
    this.maintenanceTimer = setInterval(() => void this.runMaintenance(), this.appEnv.SPONSOR_LEAK_CHECK_INTERVAL_MS);
    this.maintenanceTimer.unref();
  }

  stopMaintenance(): void {
    if (this.maintenanceTimer) clearInterval(this.maintenanceTimer);
    this.maintenanceTimer = null;
  }

  async resume(): Promise<SponsorState> {
    const state = await setSponsorPaused({ paused: false });
    this.health = null;
    // Start a fresh window so the drop that caused the pause isn't re-flagged.
    this.leakSnapshot = null;
    return state;
  }

  async summary() {
    const now = Date.now();
    const today = startOfUtcDay(new Date(now));
    const weekAgo = new Date(today.getTime() - 6 * DAY_MS);

    const [state, balance, domainToday, domainWeek, usersToday, usersWeek, unresolved, recentFailures] =
      await Promise.all([
        getSponsorState(),
        this.enabled
          ? this.client.core
              .getBalance({ owner: this.sponsorWallet })
              .then(({ balance }) => balance)
              .catch(() => null)
          : Promise.resolve(null),
        getSponsorUsage({ since: today }),
        getSponsorUsage({ since: weekAgo }),
        listSponsorUsageByUser(today),
        listSponsorUsageByUser(weekAgo),
        listRecentSponsorTransactions({ statuses: ["signed"], limit: 50 }),
        listRecentSponsorTransactions({ statuses: ["failed", "dropped"], limit: 20 }),
      ]);

    return {
      enabled: this.enabled,
      paused: state.paused,
      pausedReason: state.pausedReason,
      pausedAt: state.pausedAt,
      sponsorWallet: this.enabled ? this.sponsorWallet : null,
      balance: balance
        ? {
            totalMist: balance.balance,
            coinBalanceMist: balance.coinBalance,
            addressBalanceMist: balance.addressBalance,
          }
        : null,
      caps: {
        txPerUserPerDay: this.appEnv.SPONSOR_TX_PER_USER_PER_DAY,
        gasPerUserPerDayMist: this.appEnv.SPONSOR_GAS_PER_USER_PER_DAY_MIST.toString(),
        txPerDomainPerDay: this.appEnv.SPONSOR_TX_PER_DOMAIN_PER_DAY,
        gasPerDomainPerDayMist: this.appEnv.SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST.toString(),
        minBalanceMist: this.appEnv.SPONSOR_MIN_BALANCE_MIST.toString(),
      },
      usage: {
        today: { domain: serializeUsage(domainToday), users: usersToday },
        last7Days: { domain: serializeUsage(domainWeek), users: usersWeek },
      },
      unresolved,
      recentFailures,
    };
  }

  // Test hook.
  resetForTesting(): void {
    this.prepared.clear();
    this.health = null;
    this.alertSentAt.clear();
    this.leakSnapshot = null;
    this.sharedObjectVersions.clear();
    this.chainIdentifier = null;
  }

  private async requireActiveUser(userWallet: string): Promise<UserRecord> {
    const user = await findUserBy("wallet", userWallet);
    if (!user || user.status !== "active" || !user.userCapId) {
      throw new SponsorError(403, "user_not_active", "This wallet is not an active registered user.");
    }
    return user;
  }

  private async assertWithinQuota(user: UserRecord, additionalGas: bigint): Promise<void> {
    const since = startOfUtcDay(new Date());
    const [userUsage, domainUsage] = await Promise.all([
      getSponsorUsage({ userId: user.userId, since }),
      getSponsorUsage({ since }),
    ]);

    const {
      SPONSOR_TX_PER_USER_PER_DAY,
      SPONSOR_GAS_PER_USER_PER_DAY_MIST,
      SPONSOR_TX_PER_DOMAIN_PER_DAY,
      SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST,
    } = this.appEnv;
    const day = since.toISOString().slice(0, 10);

    if (domainUsage.gasMist * 5n >= SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST * 4n) {
      this.alert(
        `domain_80:${day}`,
        `Granite Lake sponsor for ${this.appEnv.CLIENT_ID}: domain gas today is ${domainUsage.gasMist} MIST, ` +
          `over 80% of the ${SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST} MIST daily cap.`,
        DAY_MS
      );
    }

    // The new transaction must fit: count + 1 and gas + its budget.
    const userOver =
      userUsage.txCount + 1 > SPONSOR_TX_PER_USER_PER_DAY ||
      userUsage.gasMist + additionalGas > SPONSOR_GAS_PER_USER_PER_DAY_MIST;
    const domainOver =
      domainUsage.txCount + 1 > SPONSOR_TX_PER_DOMAIN_PER_DAY ||
      domainUsage.gasMist + additionalGas > SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST;

    if (userOver) {
      this.alert(
        `user_quota:${user.userId}:${day}`,
        `Granite Lake sponsor for ${this.appEnv.CLIENT_ID}: user ${user.userEmail} (${user.userId}) ` +
          `reached their daily sponsored attestation quota.`,
        DAY_MS
      );
    }

    if (userOver || domainOver) {
      throw new SponsorError(409, "quota_exceeded", "Daily sponsored attestation quota reached. Try again later.");
    }
  }

  private async assertHealthy(): Promise<HealthSnapshot> {
    const health = await this.getHealth();

    if (health.state.paused) {
      throw new SponsorError(503, "sponsor_unavailable", "Sponsored attestations are paused for this domain.");
    }

    if (health.addressBalance < this.appEnv.SPONSOR_MIN_BALANCE_MIST) {
      this.alert(
        "low_balance",
        `Granite Lake sponsor for ${this.appEnv.CLIENT_ID} is low: address balance ${health.addressBalance} MIST ` +
          `(coin balance ${health.coinBalance} MIST) is below ${this.appEnv.SPONSOR_MIN_BALANCE_MIST} MIST. ` +
          `Fund the address balance of ${this.sponsorWallet}.`,
        ALERT_COOLDOWN_MS
      );
      throw new SponsorError(503, "sponsor_unavailable", "Sponsored attestations are temporarily unavailable.");
    }

    if (health.referenceGasPrice > this.appEnv.SPONSOR_MAX_GAS_PRICE_MIST) {
      throw new SponsorError(503, "sponsor_unavailable", "Network fees are above the sponsor's limit.");
    }

    return health;
  }

  private async getHealth(): Promise<HealthSnapshot> {
    if (this.health && Date.now() - this.health.fetchedAt < HEALTH_CACHE_MS) {
      return this.health;
    }

    const [{ balance }, { referenceGasPrice }, state] = await Promise.all([
      this.client.core.getBalance({ owner: this.sponsorWallet }),
      this.client.core.getReferenceGasPrice(),
      getSponsorState(),
    ]);

    this.health = {
      // Gas with an empty payment is paid from the address balance only;
      // SUI held in coin objects can't cover it.
      addressBalance: BigInt(balance.addressBalance),
      coinBalance: BigInt(balance.coinBalance),
      referenceGasPrice: BigInt(referenceGasPrice),
      state,
      fetchedAt: Date.now(),
    };
    return this.health;
  }

  private async resolveUserCap(user: UserRecord, userWallet: string): Promise<OwnedObjectRef> {
    const { object } = await this.client.core.getObject({ objectId: user.userCapId, include: { content: true } });
    const expectedType = `${normalizeSuiAddress(this.appEnv.SUI_PACKAGE_ID)}::${this.appEnv.SUI_MODULE}::UserCap`;
    const invalid = () => new SponsorError(403, "user_not_active", "This wallet's UserCap is missing or invalid.");

    const ownerMatches =
      object.owner.$kind === "AddressOwner" && normalizeSuiAddress(object.owner.AddressOwner) === userWallet;
    if (!ownerMatches || normalizeType(object.type) !== expectedType) {
      throw invalid();
    }

    // The cap must be for this stack's domain: the one add_user minted it
    // with (configuredDomainForEmail, i.e. user.domain) and one this stack
    // serves. A cap for another domain would pass assert_user_enabled for
    // *that* domain on-chain, so check it here rather than rely on one
    // stack per domain.
    let cap;
    try {
      cap = UserCapBcs.parse(object.content);
    } catch {
      throw invalid();
    }
    const capDomain = normalizeDomain(Buffer.from(cap.domain).toString("utf8"));
    const servedDomains = this.appEnv.DOMAINS.map(normalizeDomain);
    if (
      capDomain !== normalizeDomain(user.domain) ||
      !servedDomains.includes(capDomain) ||
      normalizeSuiAddress(cap.user_wallet) !== userWallet
    ) {
      throw invalid();
    }

    return { objectId: normalizeSuiAddress(object.objectId), version: object.version, digest: object.digest };
  }

  /**
   * Shared objects are passed immutably: attest_* take `&Registry` and
   * `&Clock`, and a mutable reference to the hot Registry would needlessly
   * serialize every attestation through consensus.
   */
  private async resolveSharedObject(objectId: string): Promise<SharedObjectRef> {
    const normalizedId = normalizeSuiAddress(objectId);
    let initialSharedVersion = this.sharedObjectVersions.get(normalizedId);

    if (!initialSharedVersion) {
      const { object } = await this.client.core.getObject({ objectId: normalizedId });
      if (object.owner.$kind !== "Shared") {
        throw new Error(`Object ${normalizedId} is not a shared object.`);
      }
      initialSharedVersion = object.owner.Shared.initialSharedVersion;
      this.sharedObjectVersions.set(normalizedId, initialSharedVersion);
    }

    return { objectId: normalizedId, initialSharedVersion, mutable: false };
  }

  private async getChainIdentifier(): Promise<string> {
    if (!this.chainIdentifier) {
      const { chainIdentifier } = await this.client.core.getChainIdentifier();
      this.chainIdentifier = chainIdentifier;
    }
    return this.chainIdentifier;
  }

  private cachePrepared(digest: string, entry: PreparedEntry): void {
    const now = Date.now();
    const forWallet: Array<[string, PreparedEntry]> = [];

    for (const [key, value] of this.prepared) {
      if (value.expiresAt <= now) {
        this.prepared.delete(key);
      } else if (value.userWallet === entry.userWallet) {
        forWallet.push([key, value]);
      }
    }

    // Bound memory: keep only the newest few outstanding per wallet.
    forWallet.sort((a, b) => a[1].expiresAt - b[1].expiresAt);
    while (forWallet.length >= MAX_PREPARED_PER_WALLET) {
      const [oldest] = forWallet.shift()!;
      this.prepared.delete(oldest);
    }

    this.prepared.set(digest, entry);
  }

  private async repeatSubmitResult(row: SponsorTransactionRecord, userWallet: string): Promise<SponsorSubmitResult> {
    const user = await findUserBy("wallet", userWallet);
    if (!user || user.userId !== row.userId) {
      throw new SponsorError(404, "prepared_tx_not_found", "Prepared transaction not found or expired.");
    }

    if (row.status !== "signed") return toSubmitResult(row, row.txDigest);

    const { systemState } = await this.client.core.getCurrentSystemState();
    const resolved = await this.resolveFromChain(row, BigInt(systemState.epoch));
    return toSubmitResult(resolved, row.txDigest);
  }

  private async resolveFromChain(
    row: SponsorTransactionRecord,
    currentEpoch: bigint
  ): Promise<SponsorTransactionRecord> {
    let tx;
    try {
      const result = await this.client.core.getTransaction({ digest: row.txDigest, include: { effects: true } });
      tx = result.$kind === "Transaction" ? result.Transaction : result.FailedTransaction;
    } catch {
      tx = null;
    }

    if (tx) {
      return (await this.resolveFromEffects(row.txDigest, tx.effects)) ?? row;
    }

    // ValidDuring bounds when the bytes can land; past max_epoch they never will.
    if (currentEpoch > BigInt(row.maxEpoch)) {
      return (await resolveSponsorTransaction({ txDigest: row.txDigest, status: "dropped", gasUsed: null })) ?? row;
    }

    return row;
  }

  private async resolveFromEffects(
    digest: string,
    effects: {
      status: { success: boolean; error: { message?: string } | null };
      gasUsed: { computationCost: string; storageCost: string; storageRebate: string };
    }
  ): Promise<SponsorTransactionRecord | null> {
    const gasUsed =
      BigInt(effects.gasUsed.computationCost) +
      BigInt(effects.gasUsed.storageCost) -
      BigInt(effects.gasUsed.storageRebate);

    return resolveSponsorTransaction({
      txDigest: digest,
      status: effects.status.success ? "executed" : "failed",
      gasUsed,
      error: effects.status.success ? null : (effects.status.error?.message ?? "Transaction failed on-chain."),
    });
  }

  private withSubmitLock<T>(fn: () => Promise<T>): Promise<T> {
    // Serializes quota check + ledger insert within this container (one per
    // domain stack) so concurrent submits can't both squeeze under a cap.
    const run = this.submitLock.then(fn, fn);
    this.submitLock = run.catch(() => undefined);
    return run;
  }

  private alert(key: string, text: string, cooldownMs: number): void {
    const last = this.alertSentAt.get(key);
    if (cooldownMs > 0 && last !== undefined && Date.now() - last < cooldownMs) return;
    this.alertSentAt.set(key, Date.now());

    console.error(JSON.stringify({ level: 40, time: Date.now(), msg: "Sponsor alert", key, text }));
    // An alert that fails to send must never fail a user request.
    this.googleChat.sendText(text).catch((error: unknown) => {
      console.error("Sponsor alert delivery failed", {
        key,
        error: error instanceof Error ? error.message : String(error),
      });
    });
  }
}

/**
 * Builds the one transaction the sponsor will ever sign: a single
 * attest_photo / attest_file call. Arguments are encoded exactly as the app's
 * builder encodes them (photo_attestation_service.dart), so events are
 * unchanged and the app can verify the bytes by rebuilding them.
 */
export function buildAttestationTransaction(params: {
  packageId: string;
  moduleName: string;
  request: AttestationRequest;
  userWallet: string;
  sponsorWallet: string;
  userCap: OwnedObjectRef;
  registry: SharedObjectRef;
  clock: SharedObjectRef;
  gasPrice: bigint;
  gasBudget: bigint;
  validDuring: ValidDuring;
}): Transaction {
  const tx = new Transaction();
  // hash/gps/altitude/projectId/fileId are the UTF-8 bytes of the string
  // (for the hash that is the 64-char hex text, not 32 decoded bytes).
  const utf8 = (value: string) => tx.pure.vector("u8", Array.from(Buffer.from(value, "utf8")));
  // Null-reason hashes are hex-decoded to 32 raw bytes, or an empty vector.
  const hexBytes = (value: string) => tx.pure.vector("u8", Array.from(Buffer.from(value, "hex")));

  // Inputs are appended in call order, which must match the contract
  // signature (UserCap, Registry, values..., Clock) - hence clock is a thunk
  // evaluated last in each argument list.
  const userCap = tx.object(Inputs.ObjectRef(params.userCap));
  const registry = tx.object(Inputs.SharedObjectRef(params.registry));
  const clock = () => tx.object(Inputs.SharedObjectRef(params.clock));
  const target = `${params.packageId}::${params.moduleName}::attest_${params.request.kind}` as const;

  if (params.request.kind === "photo") {
    const args = params.request.args;
    tx.moveCall({
      target,
      arguments: [
        userCap,
        registry,
        utf8(args.hash),
        utf8(args.gps),
        utf8(args.altitude),
        utf8(args.projectId),
        tx.pure.u64(args.capturedAtMs),
        tx.pure.bool(args.isOnline),
        tx.pure.bool(args.isForcedOffline),
        hexBytes(args.internetNullReasonHash),
        tx.pure.bool(args.hasGps),
        tx.pure.bool(args.isGpsForcedNull),
        hexBytes(args.gpsNullReasonHash),
        clock(),
      ],
    });
  } else {
    const args = params.request.args;
    tx.moveCall({
      target,
      arguments: [
        userCap,
        registry,
        utf8(args.hash),
        utf8(args.fileId),
        utf8(args.projectId),
        tx.pure.u64(args.capturedAtMs),
        tx.pure.bool(args.isOnline),
        tx.pure.bool(args.isForcedOffline),
        hexBytes(args.internetNullReasonHash),
        clock(),
      ],
    });
  }

  tx.setSender(params.userWallet);
  tx.setGasOwner(params.sponsorWallet);
  // Empty payment: gas comes from the sponsor's address balance, so no gas
  // coin is referenced and concurrent sponsorships can't equivocate.
  tx.setGasPayment([]);
  tx.setGasPrice(params.gasPrice);
  tx.setGasBudget(params.gasBudget);
  tx.setExpiration({
    ValidDuring: {
      minEpoch: params.validDuring.minEpoch,
      maxEpoch: params.validDuring.maxEpoch,
      minTimestamp: null,
      maxTimestamp: null,
      chain: params.validDuring.chain,
      nonce: params.validDuring.nonce,
    },
  });

  return tx;
}

function toSubmitResult(row: SponsorTransactionRecord | null, digest: string): SponsorSubmitResult {
  switch (row?.status) {
    case "executed":
      return { digest, status: "executed", gasUsedMist: row.gasUsed ?? "0" };
    case "failed":
      return { digest, status: "failed", gasUsedMist: row.gasUsed, error: row.error ?? "Transaction failed on-chain." };
    case "dropped":
      return { digest, status: "dropped" };
    default:
      return { digest, status: "pending" };
  }
}

// Field layout of photo_attestation::UserCap: UID, then domain, then
// user_wallet (contracts/sources/granite_lake.move).
const UserCapBcs = bcs.struct("UserCap", {
  id: bcs.Address,
  domain: bcs.vector(bcs.u8()),
  user_wallet: bcs.Address,
});

function normalizeDomain(domain: string): string {
  return domain.trim().toLowerCase();
}

function normalizeType(type: string): string {
  const [address, ...rest] = type.split("::");
  return [normalizeSuiAddress(address), ...rest].join("::");
}

function startOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
}

function serializeUsage(usage: { txCount: number; gasMist: bigint }) {
  return { txCount: usage.txCount, gasMist: usage.gasMist.toString() };
}
