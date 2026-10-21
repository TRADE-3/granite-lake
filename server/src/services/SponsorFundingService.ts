import { randomUUID } from "node:crypto";
import type { AppEnv } from "../config/env.js";
import {
  getSponsorTopUpTotal,
  insertSponsorTopUp,
  listPendingSponsorTopUps,
  resolveSponsorTopUp,
  setSponsorTopUpDigest,
} from "../db/sponsorRepositories.js";
import { SponsorError, type SponsorService } from "./SponsorService.js";
import { createSuiClient, isTransientNetworkError, SuiService } from "./SuiService.js";

export type SponsorTopUpResult = {
  digest: string;
  status: "executed" | "failed";
  amountMist: string;
  gasUsedMist: string;
  error: string | null;
  toppedUpTodayMist: string;
  dailyCeilingMist: string;
};

/**
 * Funds the domain's sponsor wallet from the domain admin wallet: SUI goes
 * into the sponsor's address balance, the only place sponsored gas is paid
 * from. Admin-signed, so it lives apart from SponsorService, which must
 * never load the admin key. Bounded by SPONSOR_TOPUP_MAX_PER_DAY_MIST.
 */
export class SponsorFundingService {
  private readonly adminSui: Pick<SuiService, "depositSuiToAddressBalance">;
  private readonly client: Pick<ReturnType<typeof createSuiClient>, "core">;
  private lock: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly appEnv: AppEnv,
    private readonly sponsor: SponsorService,
    deps: {
      adminSui?: Pick<SuiService, "depositSuiToAddressBalance">;
      client?: Pick<ReturnType<typeof createSuiClient>, "core">;
    } = {}
  ) {
    const client = createSuiClient(appEnv);
    this.client = deps.client ?? client;
    this.adminSui = deps.adminSui ?? new SuiService(appEnv, client);
  }

  async topUp(amountMist: bigint): Promise<SponsorTopUpResult> {
    // Validates sponsor config, including SPONSOR_WALLET != ADMIN_WALLET.
    await this.sponsor.initialize();
    if (amountMist <= 0n) {
      throw new SponsorError(400, "invalid_request", "amountMist must be a positive integer.");
    }

    const ceiling = this.appEnv.SPONSOR_TOPUP_MAX_PER_DAY_MIST;
    const since = startOfUtcDay(new Date());
    const id = randomUUID();

    // Serialize ceiling check + reservation so concurrent calls can't both
    // fit under the ceiling.
    const toppedUpBefore = await this.withLock(async () => {
      await this.resolvePending();
      const used = await getSponsorTopUpTotal(since);
      if (used + amountMist > ceiling) {
        throw new SponsorError(
          409,
          "top_up_ceiling_exceeded",
          `Top-up would exceed today's ceiling: ${used} of ${ceiling} MIST already topped up.`
        );
      }
      await insertSponsorTopUp({ id, amountMist });
      return used;
    });

    let result;
    try {
      result = await this.adminSui.depositSuiToAddressBalance({
        recipient: this.sponsor.sponsorWallet,
        amountMist,
        onDigest: (txDigest) => setSponsorTopUpDigest({ id, txDigest }),
      });
    } catch (error) {
      // The outcome may be unknown (e.g. a timeout after submission), so the
      // row stays `pending` and keeps counting toward the ceiling until it
      // is resolved from chain by its digest.
      console.error("Sponsor top-up failed", {
        id,
        error: error instanceof Error ? error.message : String(error),
      });
      throw new SponsorError(
        isTransientNetworkError(error) ? 502 : 500,
        "top_up_failed",
        "The top-up could not be confirmed. Check GET /admin/sponsor/summary before retrying."
      );
    }

    await resolveSponsorTopUp({
      id,
      status: result.success ? "executed" : "failed",
      gasUsed: result.gasUsedMist,
      error: result.error,
    });
    this.sponsor.invalidateHealth();

    return {
      digest: result.digest,
      status: result.success ? "executed" : "failed",
      amountMist: amountMist.toString(),
      gasUsedMist: result.gasUsedMist.toString(),
      error: result.error,
      toppedUpTodayMist: (toppedUpBefore + (result.success ? amountMist : 0n)).toString(),
      dailyCeilingMist: ceiling.toString(),
    };
  }

  /** Resolves top-ups whose outcome wasn't known when they were sent. */
  async resolvePending(): Promise<void> {
    for (const row of await listPendingSponsorTopUps()) {
      if (!row.txDigest) {
        // Never got as far as building a transaction: nothing was sent.
        if (Date.now() - new Date(row.createdAt).getTime() > 10 * 60 * 1000) {
          await resolveSponsorTopUp({ id: row.id, status: "failed", error: "Never submitted." });
        }
        continue;
      }

      try {
        const tx = await this.client.core.getTransaction({ digest: row.txDigest, include: { effects: true } });
        const executed = tx.$kind === "Transaction" ? tx.Transaction : tx.FailedTransaction;
        const gasUsed = executed.effects.gasUsed;
        await resolveSponsorTopUp({
          id: row.id,
          status: executed.effects.status.success ? "executed" : "failed",
          gasUsed: BigInt(gasUsed.computationCost) + BigInt(gasUsed.storageCost) - BigInt(gasUsed.storageRebate),
          error: executed.effects.status.success ? null : (executed.effects.status.error?.message ?? null),
        });
      } catch {
        // Not found (yet). Left pending: it keeps counting toward the
        // ceiling, which errs on the side of moving less money.
      }
    }
  }

  private withLock<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.lock.then(fn, fn);
    this.lock = run.catch(() => undefined);
    return run;
  }
}

function startOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
}
