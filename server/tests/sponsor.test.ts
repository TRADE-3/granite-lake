import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { bcs } from "@mysten/sui/bcs";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { TransactionDataBuilder } from "@mysten/sui/transactions";
import { fromBase64, normalizeSuiAddress, toBase64 } from "@mysten/sui/utils";

const sponsorKeypair = Ed25519Keypair.generate();
const userKeypair = Ed25519Keypair.generate();
const otherKeypair = Ed25519Keypair.generate();
const USER_WALLET = userKeypair.toSuiAddress();
const SPONSOR_WALLET = sponsorKeypair.toSuiAddress();
const PACKAGE_ID = normalizeSuiAddress("0xaa");
const REGISTRY_ID = normalizeSuiAddress("0xdd");
const USER_CAP_ID = normalizeSuiAddress("0xcc");
const CHAIN_ID = "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S";

process.env.DOMAINS = "acme.com";
process.env.CLIENT_ID = "acme";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
process.env.APP_API_KEY = "app-key";
process.env.SUI_NETWORK = "testnet";
process.env.SUI_RPC_URL = "https://fullnode.testnet.sui.io:443";
process.env.SUI_PRIVATE_KEY = "suiprivkey-test";
process.env.SUI_PACKAGE_ID = PACKAGE_ID;
process.env.SUI_REGISTRY_ID = REGISTRY_ID;
process.env.SPONSOR_ENABLED = "true";
process.env.SPONSOR_PRIVATE_KEY = sponsorKeypair.getSecretKey();
process.env.SPONSOR_WALLET = SPONSOR_WALLET;
process.env.SPONSOR_TX_PER_USER_PER_DAY = "3";
// Pinned so a developer's server/.env (loaded by dotenv/config) can't change
// the limits these tests assert against.
process.env.SPONSOR_MAX_GAS_BUDGET_MIST = "50000000";
process.env.SPONSOR_MAX_GAS_PRICE_MIST = "1000";
process.env.SPONSOR_GAS_PER_USER_PER_DAY_MIST = "1000000000";
process.env.SPONSOR_TX_PER_DOMAIN_PER_DAY = "5000";
process.env.SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST = "50000000000";
process.env.SPONSOR_PREPARE_TTL_MS = "300000";
process.env.SPONSOR_MIN_BALANCE_MIST = "1000000000";
process.env.SPONSOR_LEAK_CHECK_INTERVAL_MS = "900000";

const APP_HEADERS = { "x-app-api-key": "app-key" };
const ADMIN_HEADERS = { "x-admin-api-key": "admin-key" };

const state = vi.hoisted(() => ({
  users: new Map<string, Record<string, unknown>>(),
  ledger: new Map<string, Record<string, unknown>>(),
  paused: { paused: false, pausedReason: null as string | null, pausedAt: null as string | null },
  chain: {} as Record<string, unknown>,
}));

const chain = vi.hoisted(() => ({
  epoch: "812",
  referenceGasPrice: "1000",
  addressBalance: "5000000000",
  coinBalance: "0",
  userCapOwner: "",
  userCapType: "",
  userCapDomain: "acme.com",
  userCapWallet: "",
  simulateFailure: null as string | null,
  gasUsed: {
    computationCost: "1000000",
    storageCost: "2000000",
    storageRebate: "980000",
    nonRefundableStorageFee: "0",
  },
  executeError: null as Error | null,
  executeFailure: null as string | null,
  executed: [] as Array<{ transaction: Uint8Array; signatures: string[] }>,
  onChain: new Map<string, { success: boolean }>(),
}));

function fakeClient() {
  const effects = (success: boolean, message?: string) => ({
    status: success ? { success: true, error: null } : { success: false, error: { message } },
    gasUsed: chain.gasUsed,
  });

  return {
    core: {
      getCurrentSystemState: vi.fn(async () => ({ systemState: { epoch: chain.epoch } })),
      getChainIdentifier: vi.fn(async () => ({ chainIdentifier: CHAIN_ID })),
      getReferenceGasPrice: vi.fn(async () => ({ referenceGasPrice: chain.referenceGasPrice })),
      getBalance: vi.fn(async () => ({
        balance: {
          coinType: "0x2::sui::SUI",
          balance: (BigInt(chain.addressBalance) + BigInt(chain.coinBalance)).toString(),
          addressBalance: chain.addressBalance,
          coinBalance: chain.coinBalance,
        },
      })),
      getObject: vi.fn(async ({ objectId }: { objectId: string }) => {
        if (objectId === USER_CAP_ID) {
          return {
            object: {
              objectId,
              version: "5",
              digest: "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
              owner: { $kind: "AddressOwner", AddressOwner: chain.userCapOwner },
              type: chain.userCapType,
              content: bcs
                .struct("UserCap", {
                  id: bcs.Address,
                  domain: bcs.vector(bcs.u8()),
                  user_wallet: bcs.Address,
                })
                .serialize({
                  id: objectId,
                  domain: Array.from(Buffer.from(chain.userCapDomain, "utf8")),
                  user_wallet: chain.userCapWallet,
                })
                .toBytes(),
            },
          };
        }
        return {
          object: {
            objectId,
            version: "100",
            digest: "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
            owner: { $kind: "Shared", Shared: { initialSharedVersion: objectId === REGISTRY_ID ? "3" : "1" } },
            type: "x",
          },
        };
      }),
      simulateTransaction: vi.fn(async () =>
        chain.simulateFailure
          ? { $kind: "FailedTransaction", FailedTransaction: { status: { error: { message: chain.simulateFailure } } } }
          : { $kind: "Transaction", Transaction: { effects: effects(true) } }
      ),
      executeTransaction: vi.fn(async (input: { transaction: Uint8Array; signatures: string[] }) => {
        chain.executed.push(input);
        if (chain.executeError) throw chain.executeError;
        const digest = TransactionDataBuilder.getDigestFromBytes(input.transaction);
        const success = !chain.executeFailure;
        chain.onChain.set(digest, { success });
        return success
          ? { $kind: "Transaction", Transaction: { digest, effects: effects(true) } }
          : {
              $kind: "FailedTransaction",
              FailedTransaction: { digest, effects: effects(false, chain.executeFailure!) },
            };
      }),
      getTransaction: vi.fn(async ({ digest }: { digest: string }) => {
        const tx = chain.onChain.get(digest);
        if (!tx) throw new Error("not found");
        return tx.success
          ? { $kind: "Transaction", Transaction: { digest, effects: effects(true) } }
          : { $kind: "FailedTransaction", FailedTransaction: { digest, effects: effects(false, "aborted") } };
      }),
    },
  };
}

const client = vi.hoisted(() => ({ current: null as unknown }));

vi.mock("../src/services/SuiService.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/services/SuiService.js")>();
  return { ...actual, createSuiClient: () => client.current };
});

vi.mock("../src/services/GoogleChatService.js", () => ({
  GoogleChatService: class {
    sendText = vi.fn(async () => undefined);
    sendOtp = vi.fn(async () => undefined);
  },
}));

vi.mock("../src/db/repositories.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/db/repositories.js")>();
  return {
    ...actual,
    findUserBy: vi.fn(async (_field: string, value: string) => state.users.get(normalizeSuiAddress(value)) ?? null),
  };
});

vi.mock("../src/db/sponsorRepositories.js", () => {
  const usage = (rows: Array<Record<string, unknown>>) => ({
    txCount: rows.length,
    gasMist: rows.reduce(
      (sum, row) => sum + BigInt(row.status === "signed" ? (row.gasBudget as string) : ((row.gasUsed as string) ?? 0)),
      0n
    ),
  });

  return {
    insertSponsorTransaction: vi.fn(async (input: Record<string, unknown>) => {
      if (state.ledger.has(input.txDigest as string)) return false;
      state.ledger.set(input.txDigest as string, {
        txDigest: input.txDigest,
        userId: input.userId,
        kind: input.kind,
        status: "signed",
        gasBudget: String(input.gasBudget),
        gasUsed: null,
        maxEpoch: String(input.maxEpoch),
        error: null,
        createdAt: new Date().toISOString(),
        resolvedAt: null,
      });
      return true;
    }),
    findSponsorTransaction: vi.fn(async (digest: string) => state.ledger.get(digest) ?? null),
    resolveSponsorTransaction: vi.fn(async (input: Record<string, unknown>) => {
      const row = state.ledger.get(input.txDigest as string);
      if (!row || row.status !== "signed") return null;
      Object.assign(row, {
        status: input.status,
        gasUsed: input.gasUsed === null ? null : String(input.gasUsed),
        error: input.error ?? null,
        resolvedAt: new Date().toISOString(),
      });
      return row;
    }),
    getSponsorUsage: vi.fn(async (input: { userId?: string }) =>
      usage(
        [...state.ledger.values()].filter(
          (row) => row.status !== "dropped" && (!input.userId || row.userId === input.userId)
        )
      )
    ),
    listUnresolvedSponsorTransactions: vi.fn(async () =>
      [...state.ledger.values()].filter((row) => row.status === "signed")
    ),
    getSponsorLedgerSpend: vi.fn(async () =>
      [...state.ledger.values()].reduce(
        (sum, row) =>
          sum + BigInt(row.status === "signed" ? (row.gasBudget as string) : ((row.gasUsed as string) ?? 0)),
        0n
      )
    ),
    listSponsorUsageByUser: vi.fn(async () => []),
    listRecentSponsorTransactions: vi.fn(async () => []),
    getSponsorState: vi.fn(async () => ({ ...state.paused })),
    setSponsorPaused: vi.fn(async (input: { paused: boolean; reason?: string }) => {
      state.paused = {
        paused: input.paused,
        pausedReason: input.paused ? (input.reason ?? null) : null,
        pausedAt: input.paused ? new Date().toISOString() : null,
      };
      return { ...state.paused };
    }),
  };
});

client.current = fakeClient();

const { buildApp } = await import("../src/app.js");
const { sponsorService } = await import("../src/routes/sponsor.js");
const { resetAllRateLimiters } = await import("../src/utils/rateLimit.js");
const { SponsorService, buildAttestationTransaction } = await import("../src/services/SponsorService.js");
const { env } = await import("../src/config/env.js");

function photoArgs(overrides: Record<string, unknown> = {}) {
  return {
    hash: "a".repeat(64),
    gps: "6.9271,79.8612",
    altitude: "12.5",
    projectId: "project-1",
    capturedAtMs: 1760000000000,
    isOnline: true,
    isForcedOffline: false,
    internetNullReasonHash: "",
    hasGps: true,
    isGpsForcedNull: false,
    gpsNullReasonHash: "",
    ...overrides,
  };
}

function fileArgs(overrides: Record<string, unknown> = {}) {
  return {
    hash: "b".repeat(64),
    fileId: "file-1",
    projectId: "project-1",
    capturedAtMs: 1760000000000,
    isOnline: false,
    isForcedOffline: false,
    internetNullReasonHash: "c".repeat(64),
    ...overrides,
  };
}

async function prepare(
  app: Awaited<ReturnType<typeof buildApp>>,
  body: Record<string, unknown> = { userWallet: USER_WALLET, kind: "photo", args: photoArgs() }
) {
  return app.inject({ method: "POST", url: "/sponsor/prepare", headers: APP_HEADERS, payload: body });
}

async function submit(app: Awaited<ReturnType<typeof buildApp>>, body: Record<string, unknown>) {
  return app.inject({ method: "POST", url: "/sponsor/submit", headers: APP_HEADERS, payload: body });
}

async function prepareAndSign(app: Awaited<ReturnType<typeof buildApp>>, signer = userKeypair) {
  const prepared = (await prepare(app)).json();
  const { signature } = await signer.signTransaction(fromBase64(prepared.txBytes));
  return { prepared, signature };
}

describe("sponsor routes", () => {
  let app: Awaited<ReturnType<typeof buildApp>>;

  beforeEach(async () => {
    resetAllRateLimiters();
    sponsorService.resetForTesting();
    state.ledger.clear();
    state.users.clear();
    state.paused = { paused: false, pausedReason: null, pausedAt: null };
    state.users.set(normalizeSuiAddress(USER_WALLET), {
      userId: "user-1",
      userEmail: "alice@acme.com",
      domain: "acme.com",
      userWallet: normalizeSuiAddress(USER_WALLET),
      status: "active",
      userCapId: USER_CAP_ID,
    });
    Object.assign(chain, {
      epoch: "812",
      referenceGasPrice: "1000",
      addressBalance: "5000000000",
      coinBalance: "0",
      userCapOwner: USER_WALLET,
      userCapType: `${PACKAGE_ID}::photo_attestation::UserCap`,
      userCapDomain: "acme.com",
      userCapWallet: USER_WALLET,
      simulateFailure: null,
      executeError: null,
      executeFailure: null,
      executed: [],
    });
    chain.onChain.clear();
    app = await buildApp();
  });

  it("requires the app API key", async () => {
    const response = await app.inject({ method: "GET", url: "/sponsor/status" });
    expect(response.statusCode).toBe(401);
  });

  it("reports status without the sponsor balance", async () => {
    const response = await app.inject({ method: "GET", url: "/sponsor/status", headers: APP_HEADERS });
    expect(response.json()).toEqual({
      enabled: true,
      sponsorWallet: normalizeSuiAddress(SPONSOR_WALLET),
      maxGasBudgetMist: "50000000",
      maxGasPriceMist: "1000",
    });
  });

  it("prepares unsigned bytes with sender = user and gas owner = sponsor", async () => {
    const response = await prepare(app);
    expect(response.statusCode).toBe(201);

    const body = response.json();
    const data = TransactionDataBuilder.fromBytes(fromBase64(body.txBytes));
    expect(normalizeSuiAddress(data.sender!)).toBe(normalizeSuiAddress(USER_WALLET));
    expect(normalizeSuiAddress(data.gasData.owner!)).toBe(normalizeSuiAddress(SPONSOR_WALLET));
    expect(data.gasData.payment).toEqual([]);
    // computation + storage + 1000 * price; the rebate is not subtracted.
    expect(data.gasData.budget).toBe("4000000");
    expect(body.gasData).toEqual({
      owner: normalizeSuiAddress(SPONSOR_WALLET),
      price: "1000",
      budget: "4000000",
      payment: [],
    });
    expect(data.expiration).toMatchObject({ ValidDuring: { minEpoch: "812", maxEpoch: "813", chain: CHAIN_ID } });
    expect(data.commands).toHaveLength(1);
    expect(data.commands[0].MoveCall).toMatchObject({
      package: PACKAGE_ID,
      module: "photo_attestation",
      function: "attest_photo",
    });
    expect(data.inputs).toHaveLength(14);
    expect(body.digest).toBe(TransactionDataBuilder.getDigestFromBytes(fromBase64(body.txBytes)));
    expect(body.objectRefs.registry).toEqual({ objectId: REGISTRY_ID, initialSharedVersion: "3", mutable: false });
    expect(chain.executed).toHaveLength(0);
  });

  it("prepares file attestations", async () => {
    const response = await prepare(app, { userWallet: USER_WALLET, kind: "file", args: fileArgs() });
    expect(response.statusCode).toBe(201);
    const data = TransactionDataBuilder.fromBytes(fromBase64(response.json().txBytes));
    expect(data.commands[0].MoveCall?.function).toBe("attest_file");
    expect(data.inputs).toHaveLength(10);
  });

  it.each([
    ["uppercase hash", photoArgs({ hash: "A".repeat(64) })],
    ["short hash", photoArgs({ hash: "a".repeat(63) })],
    ["long gps", photoArgs({ gps: "x".repeat(65) })],
    ["long altitude (multi-byte)", photoArgs({ altitude: "é".repeat(33) })],
    ["long projectId", photoArgs({ projectId: "p".repeat(129) })],
    ["bad null reason", photoArgs({ gpsNullReasonHash: "abc" })],
    ["negative capturedAt", photoArgs({ capturedAtMs: -1 })],
    ["fractional capturedAt", photoArgs({ capturedAtMs: 1.5 })],
    ["future capturedAt", photoArgs({ capturedAtMs: Date.now() + 10 * 60 * 1000 })],
    ["unknown field", photoArgs({ target: "0x2::coin::split" })],
  ])("rejects %s", async (_name, args) => {
    const response = await prepare(app, { userWallet: USER_WALLET, kind: "photo", args });
    expect(response.statusCode).toBe(400);
    expect(response.json().error).toBe("invalid_request");
  });

  it("rejects a long file id and an invalid wallet", async () => {
    expect(
      (await prepare(app, { userWallet: USER_WALLET, kind: "file", args: fileArgs({ fileId: "f".repeat(129) }) }))
        .statusCode
    ).toBe(400);
    expect((await prepare(app, { userWallet: "not-a-wallet", kind: "photo", args: photoArgs() })).statusCode).toBe(400);
  });

  it("allows old capture timestamps and a small future skew", async () => {
    expect(
      (await prepare(app, { userWallet: USER_WALLET, kind: "photo", args: photoArgs({ capturedAtMs: 0 }) })).statusCode
    ).toBe(201);
    expect(
      (
        await prepare(app, {
          userWallet: USER_WALLET,
          kind: "photo",
          args: photoArgs({ capturedAtMs: Date.now() + 60_000 }),
        })
      ).statusCode
    ).toBe(201);
  });

  it.each([
    ["unknown", () => state.users.clear()],
    ["disabled", () => Object.assign(state.users.get(normalizeSuiAddress(USER_WALLET))!, { status: "disabled" })],
    ["no user_cap_id", () => Object.assign(state.users.get(normalizeSuiAddress(USER_WALLET))!, { userCapId: "" })],
    ["UserCap owned by someone else", () => (chain.userCapOwner = otherKeypair.toSuiAddress())],
    ["UserCap of the wrong type", () => (chain.userCapType = `${PACKAGE_ID}::photo_attestation::Fake`)],
    ["UserCap for another domain", () => (chain.userCapDomain = "other.com")],
    [
      "UserCap for a served domain that isn't the user's",
      () => Object.assign(state.users.get(normalizeSuiAddress(USER_WALLET))!, { domain: "beta.com" }),
    ],
    ["UserCap naming a different wallet", () => (chain.userCapWallet = otherKeypair.toSuiAddress())],
  ])("rejects a %s user with 403", async (_name, setup) => {
    setup();
    const response = await prepare(app);
    expect(response.statusCode).toBe(403);
    expect(response.json().error).toBe("user_not_active");
  });

  it("returns 503 when the balance is below the reserve or gas price is above the cap", async () => {
    chain.addressBalance = "999999999";
    chain.coinBalance = "10000000000"; // coin objects can't pay with payment = []
    expect((await prepare(app)).statusCode).toBe(503);

    sponsorService.resetForTesting();
    chain.addressBalance = "5000000000";
    chain.referenceGasPrice = "1001";
    const response = await prepare(app);
    expect(response.statusCode).toBe(503);
    expect(response.json().error).toBe("sponsor_unavailable");
  });

  it("returns 503 while paused", async () => {
    state.paused = { paused: true, pausedReason: "test", pausedAt: null };
    expect((await prepare(app)).statusCode).toBe(503);
  });

  it("returns 422 when simulation fails or the budget exceeds the cap", async () => {
    chain.simulateFailure = "MoveAbort E_GPS_NULL_REASON_MISMATCH";
    expect((await prepare(app)).json().error).toBe("simulation_failed");

    chain.simulateFailure = null;
    chain.gasUsed = { ...chain.gasUsed, computationCost: "60000000" };
    const response = await prepare(app);
    expect(response.statusCode).toBe(422);
    chain.gasUsed = { ...chain.gasUsed, computationCost: "1000000" };
  });

  it("sponsor-signs and executes after verifying the user's signature", async () => {
    const { prepared, signature } = await prepareAndSign(app);

    const response = await submit(app, { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ digest: prepared.digest, status: "executed", gasUsedMist: "2020000" });

    expect(chain.executed).toHaveLength(1);
    const [executed] = chain.executed;
    expect(toBase64(executed.transaction)).toBe(prepared.txBytes);
    expect(executed.signatures[0]).toBe(signature);
    const { signature: expectedSponsorSig } = await sponsorKeypair.signTransaction(fromBase64(prepared.txBytes));
    expect(executed.signatures[1]).toBe(expectedSponsorSig);

    expect(state.ledger.get(prepared.digest)).toMatchObject({
      status: "executed",
      gasUsed: "2020000",
      userId: "user-1",
    });
  });

  it("returns the recorded result for a repeated submit without signing again", async () => {
    const { prepared, signature } = await prepareAndSign(app);
    const body = { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature };

    await submit(app, body);
    const repeat = await submit(app, body);
    expect(repeat.statusCode).toBe(200);
    expect(repeat.json().status).toBe("executed");
    expect(chain.executed).toHaveLength(1);
  });

  it("rejects a signature from the wrong wallet", async () => {
    const { prepared, signature } = await prepareAndSign(app, otherKeypair);
    const response = await submit(app, { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature });
    expect(response.statusCode).toBe(400);
    expect(response.json().error).toBe("invalid_user_signature");
    expect(chain.executed).toHaveLength(0);
    expect(state.ledger.size).toBe(0);
  });

  it("rejects a signature over different bytes", async () => {
    const first = (await prepare(app)).json();
    const second = (
      await prepare(app, { userWallet: USER_WALLET, kind: "photo", args: photoArgs({ gps: "0,0" }) })
    ).json();
    const { signature } = await userKeypair.signTransaction(fromBase64(second.txBytes));

    const response = await submit(app, { userWallet: USER_WALLET, digest: first.digest, userSignature: signature });
    expect(response.statusCode).toBe(400);
    expect(chain.executed).toHaveLength(0);
  });

  it("returns 404 for an unknown digest or another wallet's prepared transaction", async () => {
    const { prepared, signature } = await prepareAndSign(app);
    const unknown = TransactionDataBuilder.getDigestFromBytes(new Uint8Array([1, 2, 3]));

    expect((await submit(app, { userWallet: USER_WALLET, digest: unknown, userSignature: signature })).statusCode).toBe(
      404
    );
    expect(
      (
        await submit(app, {
          userWallet: otherKeypair.toSuiAddress(),
          digest: prepared.digest,
          userSignature: signature,
        })
      ).statusCode
    ).toBe(404);
  });

  it("returns 404 once the prepared transaction has expired", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      const { prepared, signature } = await prepareAndSign(app);
      vi.setSystemTime(Date.now() + env.SPONSOR_PREPARE_TTL_MS + 1);
      const response = await submit(app, {
        userWallet: USER_WALLET,
        digest: prepared.digest,
        userSignature: signature,
      });
      expect(response.statusCode).toBe(404);
      expect(response.json().error).toBe("prepared_tx_not_found");
    } finally {
      vi.useRealTimers();
    }
  });

  it("returns 403 at submit if the user was disabled after prepare", async () => {
    const { prepared, signature } = await prepareAndSign(app);
    Object.assign(state.users.get(normalizeSuiAddress(USER_WALLET))!, { status: "disabled" });

    const response = await submit(app, { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature });
    expect(response.statusCode).toBe(403);
    expect(chain.executed).toHaveLength(0);
  });

  it("records an on-chain abort as failed with gas counted", async () => {
    chain.executeFailure = "MoveAbort E_USER_DISABLED";
    const { prepared, signature } = await prepareAndSign(app);

    const response = await submit(app, { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature });
    expect(response.json()).toMatchObject({ status: "failed", gasUsedMist: "2020000" });
    expect(state.ledger.get(prepared.digest)).toMatchObject({ status: "failed", gasUsed: "2020000" });
  });

  it("enforces the per-user daily transaction cap, counting reserved rows", async () => {
    for (let i = 0; i < 3; i++) {
      const { prepared, signature } = await prepareAndSign(app);
      expect(
        (await submit(app, { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature })).statusCode
      ).toBe(200);
    }

    const response = await prepare(app);
    expect(response.statusCode).toBe(409);
    expect(response.json().error).toBe("quota_exceeded");
  });

  it("enforces the gas cap at submit using the reserved budget", async () => {
    // 1 SUI per user per day; leave less room than one 4,000,000 MIST budget.
    state.ledger.set("seed", {
      txDigest: "seed",
      userId: "user-1",
      kind: "photo",
      status: "signed",
      gasBudget: String(1_000_000_000 - 3_000_000),
      gasUsed: null,
      maxEpoch: "999",
    });
    const { prepared, signature } = await prepareAndSign(app);

    const response = await submit(app, { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature });
    expect(response.statusCode).toBe(409);
    expect(chain.executed).toHaveLength(0);
  });

  it("leaves the row unresolved when execute times out, then resolves it on repeat", async () => {
    chain.executeError = new Error("fetch failed");
    const { prepared, signature } = await prepareAndSign(app);
    const body = { userWallet: USER_WALLET, digest: prepared.digest, userSignature: signature };

    const first = await submit(app, body);
    expect(first.statusCode).toBe(502);
    expect(state.ledger.get(prepared.digest)?.status).toBe("signed");

    // Not on chain yet and still inside ValidDuring: pending.
    const pending = await submit(app, body);
    expect(pending.statusCode).toBe(202);
    expect(pending.json().status).toBe("pending");

    // It landed after all.
    chain.onChain.set(prepared.digest, { success: true });
    const resolved = await submit(app, body);
    expect(resolved.json()).toMatchObject({ status: "executed", gasUsedMist: "2020000" });
  });

  it("sweeps stale signed rows to executed, failed, or dropped", async () => {
    const seed = (digest: string, maxEpoch: string) =>
      state.ledger.set(digest, {
        txDigest: digest,
        userId: "user-1",
        kind: "photo",
        status: "signed",
        gasBudget: "4000000",
        gasUsed: null,
        maxEpoch,
      });
    seed("landed", "813");
    seed("aborted", "813");
    seed("lost", "813");
    seed("in-window", "900");
    chain.onChain.set("landed", { success: true });
    chain.onChain.set("aborted", { success: false });
    chain.epoch = "814";

    await sponsorService.sweepUnresolved();

    expect(state.ledger.get("landed")).toMatchObject({ status: "executed", gasUsed: "2020000" });
    expect(state.ledger.get("aborted")).toMatchObject({ status: "failed" });
    expect(state.ledger.get("lost")).toMatchObject({ status: "dropped", gasUsed: null });
    expect(state.ledger.get("in-window")).toMatchObject({ status: "signed" });
  });

  it("pauses sponsorship when the balance drops more than the ledger explains", async () => {
    await sponsorService.checkUnexpectedSpend();

    // A top-up is not a drain.
    chain.addressBalance = "6000000000";
    await sponsorService.checkUnexpectedSpend();
    expect(state.paused.paused).toBe(false);

    // Ledger-explained spend is fine.
    state.ledger.set("ok", { txDigest: "ok", userId: "user-1", status: "executed", gasUsed: "100000000" });
    chain.addressBalance = "5900000000";
    await sponsorService.checkUnexpectedSpend();
    expect(state.paused.paused).toBe(false);

    // 1 SUI vanishes.
    chain.addressBalance = "4900000000";
    await sponsorService.checkUnexpectedSpend();
    expect(state.paused.paused).toBe(true);
    expect((await prepare(app)).statusCode).toBe(503);

    const resume = await app.inject({ method: "POST", url: "/admin/sponsor/resume", headers: ADMIN_HEADERS });
    expect(resume.statusCode).toBe(200);
    expect(state.paused.paused).toBe(false);
    expect((await prepare(app)).statusCode).toBe(201);
  });

  it("serves the admin summary behind the admin key", async () => {
    expect((await app.inject({ method: "GET", url: "/admin/sponsor/summary" })).statusCode).toBe(401);

    const response = await app.inject({ method: "GET", url: "/admin/sponsor/summary", headers: ADMIN_HEADERS });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      enabled: true,
      paused: false,
      sponsorWallet: normalizeSuiAddress(SPONSOR_WALLET),
      balance: { addressBalanceMist: "5000000000", coinBalanceMist: "0" },
    });
  });

  it("rate limits prepare per wallet", async () => {
    let last;
    for (let i = 0; i < 31; i++) last = await prepare(app);
    expect(last!.statusCode).toBe(429);
    expect(last!.headers["retry-after"]).toBeDefined();
  });
});

describe("sponsor boot checks", () => {
  const withEnv = (overrides: Partial<typeof env>) =>
    new SponsorService({ ...env, ...overrides }, { client: fakeClient() as never });

  it("refuses a sponsor wallet equal to the admin wallet", async () => {
    await expect(
      withEnv({ ADMIN_WALLET: SPONSOR_WALLET.toUpperCase().replace("0X", "0x") }).initialize()
    ).rejects.toThrow("SPONSOR_WALLET must differ from ADMIN_WALLET.");
  });

  it("refuses a key that doesn't match SPONSOR_WALLET", async () => {
    await expect(withEnv({ SPONSOR_PRIVATE_KEY: otherKeypair.getSecretKey() }).initialize()).rejects.toThrow(
      /does not match SPONSOR_WALLET/
    );
  });

  it("never falls back to SUI_PRIVATE_KEY", async () => {
    await expect(withEnv({ SPONSOR_PRIVATE_KEY: "" }).initialize()).rejects.toThrow(
      /Sponsor configuration is incomplete/
    );
  });

  it("reports disabled", async () => {
    const service = withEnv({ SPONSOR_ENABLED: false });
    expect(service.status()).toEqual({ enabled: false });
    await expect(service.initialize()).rejects.toMatchObject({ statusCode: 503, code: "sponsor_disabled" });
  });
});

describe("cross-SDK fixture", () => {
  // The same bytes are rebuilt by the app's Dart builder in
  // app/test/core/services/sponsor_attestation_test.dart. If this fails, the
  // app's pre-signing verification (§8) will reject every prepared transaction.
  const fixture = JSON.parse(
    readFileSync(new URL("./fixtures/sponsor_attestation_fixture.json", import.meta.url), "utf8")
  ) as {
    common: Record<string, never>;
    cases: Array<{ name: string; request: never; txBytesHex: string; digest: string }>;
  };

  it.each(fixture.cases)("$name matches the fixture bytes", async ({ request, txBytesHex, digest }) => {
    const common = fixture.common as unknown as {
      packageId: string;
      moduleName: string;
      userWallet: string;
      sponsorWallet: string;
      userCap: { objectId: string; version: string; digest: string };
      registry: { objectId: string; initialSharedVersion: string; mutable: false };
      clock: { objectId: string; initialSharedVersion: string; mutable: false };
      gasPrice: string;
      gasBudget: string;
      validDuring: { minEpoch: string; maxEpoch: string; chain: string; nonce: number };
    };

    const bytes = await buildAttestationTransaction({
      ...common,
      request,
      gasPrice: BigInt(common.gasPrice),
      gasBudget: BigInt(common.gasBudget),
    }).build();

    expect(Buffer.from(bytes).toString("hex")).toBe(txBytesHex);
    expect(TransactionDataBuilder.getDigestFromBytes(bytes)).toBe(digest);
  });
});
