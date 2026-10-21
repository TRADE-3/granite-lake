import { pool } from "./pool.js";

export type SponsorTransactionKind = "photo" | "file";
export type SponsorTransactionStatus = "signed" | "executed" | "failed" | "dropped";

export type SponsorTransactionRecord = {
  txDigest: string;
  userId: string;
  kind: SponsorTransactionKind;
  status: SponsorTransactionStatus;
  gasBudget: string;
  gasUsed: string | null;
  maxEpoch: string;
  error: string | null;
  createdAt: string;
  resolvedAt: string | null;
};

export type SponsorUsage = {
  txCount: number;
  // gas_used for resolved rows plus gas_budget still reserved by unresolved
  // (`signed`) rows, in MIST.
  gasMist: bigint;
};

export type SponsorState = {
  paused: boolean;
  pausedReason: string | null;
  pausedAt: string | null;
};

const sponsorTransactionColumns = `
  tx_digest as "txDigest",
  user_id as "userId",
  kind,
  status,
  gas_budget::text as "gasBudget",
  gas_used::text as "gasUsed",
  max_epoch::text as "maxEpoch",
  error,
  created_at as "createdAt",
  resolved_at as "resolvedAt"
`;

/**
 * Records a transaction the sponsor is about to sign, reserving its budget
 * against the daily caps. Returns false if a row for this digest already
 * exists (a concurrent or repeated submit), in which case nothing is written.
 */
export async function insertSponsorTransaction(input: {
  txDigest: string;
  userId: string;
  kind: SponsorTransactionKind;
  gasBudget: bigint;
  maxEpoch: bigint;
}): Promise<boolean> {
  const result = await pool.query(
    `
      insert into sponsor_transactions (tx_digest, user_id, kind, status, gas_budget, max_epoch)
      values ($1, $2, $3, 'signed', $4, $5)
      on conflict (tx_digest) do nothing
    `,
    [input.txDigest, input.userId, input.kind, input.gasBudget.toString(), input.maxEpoch.toString()]
  );

  return result.rowCount === 1;
}

export async function findSponsorTransaction(txDigest: string): Promise<SponsorTransactionRecord | null> {
  const result = await pool.query<SponsorTransactionRecord>(
    `select ${sponsorTransactionColumns} from sponsor_transactions where tx_digest = $1`,
    [txDigest]
  );

  return result.rows[0] ?? null;
}

/**
 * Moves a `signed` row to its final state. Resolved rows are never changed
 * again, so a late sweep can't overwrite the result recorded at submit.
 */
export async function resolveSponsorTransaction(input: {
  txDigest: string;
  status: Exclude<SponsorTransactionStatus, "signed">;
  gasUsed: bigint | null;
  error?: string | null;
}): Promise<SponsorTransactionRecord | null> {
  const result = await pool.query<SponsorTransactionRecord>(
    `
      update sponsor_transactions
      set status = $2, gas_used = $3, error = $4, resolved_at = now()
      where tx_digest = $1 and status = 'signed'
      returning ${sponsorTransactionColumns}
    `,
    [input.txDigest, input.status, input.gasUsed?.toString() ?? null, input.error ?? null]
  );

  return result.rows[0] ?? null;
}

/**
 * Usage since `since` for one user, or for the whole domain stack when
 * `userId` is omitted (one stack serves exactly one domain). Dropped rows
 * never landed, so they count toward neither cap.
 */
export async function getSponsorUsage(input: { userId?: string; since: Date }): Promise<SponsorUsage> {
  const result = await pool.query<{ txCount: string; gasMist: string }>(
    `
      select
        count(*)::text as "txCount",
        coalesce(sum(case when status = 'signed' then gas_budget else coalesce(gas_used, 0) end), 0)::text as "gasMist"
      from sponsor_transactions
      where created_at >= $1
        and status <> 'dropped'
        and ($2::text is null or user_id = $2)
    `,
    [input.since.toISOString(), input.userId ?? null]
  );

  const row = result.rows[0];
  return {
    txCount: Number(row?.txCount ?? 0),
    gasMist: BigInt(row?.gasMist ?? 0),
  };
}

export async function listUnresolvedSponsorTransactions(input: {
  createdBefore: Date;
  limit?: number;
}): Promise<SponsorTransactionRecord[]> {
  const result = await pool.query<SponsorTransactionRecord>(
    `
      select ${sponsorTransactionColumns}
      from sponsor_transactions
      where status = 'signed' and created_at < $1
      order by created_at asc
      limit $2
    `,
    [input.createdBefore.toISOString(), input.limit ?? 100]
  );

  return result.rows;
}

/**
 * Gas the ledger can account for in a window: gas recorded on rows resolved
 * inside it, plus the full budget of rows still unresolved (their gas may
 * already have left the sponsor wallet).
 */
export async function getSponsorLedgerSpend(input: { since: Date; until: Date }): Promise<bigint> {
  const result = await pool.query<{ gasMist: string }>(
    `
      select (
        coalesce((
          select sum(gas_used) from sponsor_transactions
          where status in ('executed', 'failed') and resolved_at > $1 and resolved_at <= $2
        ), 0)
        +
        coalesce((select sum(gas_budget) from sponsor_transactions where status = 'signed'), 0)
      )::text as "gasMist"
    `,
    [input.since.toISOString(), input.until.toISOString()]
  );

  return BigInt(result.rows[0]?.gasMist ?? 0);
}

export type SponsorUserUsageRow = {
  userId: string;
  userEmail: string | null;
  txCount: number;
  gasMist: string;
};

export async function listSponsorUsageByUser(since: Date): Promise<SponsorUserUsageRow[]> {
  const result = await pool.query<{ userId: string; userEmail: string | null; txCount: string; gasMist: string }>(
    `
      select
        st.user_id as "userId",
        u.user_email as "userEmail",
        count(*)::text as "txCount",
        coalesce(sum(case when st.status = 'signed' then st.gas_budget else coalesce(st.gas_used, 0) end), 0)::text
          as "gasMist"
      from sponsor_transactions st
      left join users u on u.user_id = st.user_id
      where st.created_at >= $1 and st.status <> 'dropped'
      group by st.user_id, u.user_email
      order by sum(coalesce(st.gas_used, st.gas_budget)) desc
    `,
    [since.toISOString()]
  );

  return result.rows.map((row) => ({ ...row, txCount: Number(row.txCount) }));
}

export async function listRecentSponsorTransactions(input: {
  statuses: SponsorTransactionStatus[];
  limit: number;
}): Promise<SponsorTransactionRecord[]> {
  const result = await pool.query<SponsorTransactionRecord>(
    `
      select ${sponsorTransactionColumns}
      from sponsor_transactions
      where status = any($1::text[])
      order by created_at desc
      limit $2
    `,
    [input.statuses, input.limit]
  );

  return result.rows;
}

export async function getSponsorState(): Promise<SponsorState> {
  const result = await pool.query<SponsorState>(
    `
      select paused, paused_reason as "pausedReason", paused_at as "pausedAt"
      from sponsor_state
      where id = true
    `
  );

  return result.rows[0] ?? { paused: false, pausedReason: null, pausedAt: null };
}

export async function setSponsorPaused(input: { paused: boolean; reason?: string | null }): Promise<SponsorState> {
  const result = await pool.query<SponsorState>(
    `
      insert into sponsor_state (id, paused, paused_reason, paused_at)
      values (true, $1, $2, case when $1 then now() else null end)
      on conflict (id) do update
      set paused = excluded.paused, paused_reason = excluded.paused_reason, paused_at = excluded.paused_at
      returning paused, paused_reason as "pausedReason", paused_at as "pausedAt"
    `,
    [input.paused, input.paused ? (input.reason ?? null) : null]
  );

  return result.rows[0];
}

export type SponsorTopUpStatus = "pending" | "executed" | "failed";

export type SponsorTopUpRecord = {
  id: string;
  amountMist: string;
  status: SponsorTopUpStatus;
  txDigest: string | null;
  gasUsed: string | null;
  error: string | null;
  createdAt: string;
  resolvedAt: string | null;
};

const sponsorTopUpColumns = `
  id,
  amount_mist::text as "amountMist",
  status,
  tx_digest as "txDigest",
  gas_used::text as "gasUsed",
  error,
  created_at as "createdAt",
  resolved_at as "resolvedAt"
`;

export async function insertSponsorTopUp(input: { id: string; amountMist: bigint }): Promise<void> {
  await pool.query(`insert into sponsor_topups (id, amount_mist, status) values ($1, $2, 'pending')`, [
    input.id,
    input.amountMist.toString(),
  ]);
}

export async function setSponsorTopUpDigest(input: { id: string; txDigest: string }): Promise<void> {
  await pool.query(`update sponsor_topups set tx_digest = $2 where id = $1`, [input.id, input.txDigest]);
}

export async function resolveSponsorTopUp(input: {
  id: string;
  status: Exclude<SponsorTopUpStatus, "pending">;
  gasUsed?: bigint | null;
  error?: string | null;
}): Promise<void> {
  await pool.query(
    `
      update sponsor_topups
      set status = $2, gas_used = $3, error = $4, resolved_at = now()
      where id = $1 and status = 'pending'
    `,
    [input.id, input.status, input.gasUsed?.toString() ?? null, input.error ?? null]
  );
}

/** Topped up since `since`, counting in-flight (`pending`) rows. */
export async function getSponsorTopUpTotal(since: Date): Promise<bigint> {
  const result = await pool.query<{ total: string }>(
    `
      select coalesce(sum(amount_mist), 0)::text as total
      from sponsor_topups
      where created_at >= $1 and status <> 'failed'
    `,
    [since.toISOString()]
  );

  return BigInt(result.rows[0]?.total ?? 0);
}

export async function listPendingSponsorTopUps(): Promise<SponsorTopUpRecord[]> {
  const result = await pool.query<SponsorTopUpRecord>(
    `select ${sponsorTopUpColumns} from sponsor_topups where status = 'pending' order by created_at asc limit 50`
  );

  return result.rows;
}

export async function listRecentSponsorTopUps(limit: number): Promise<SponsorTopUpRecord[]> {
  const result = await pool.query<SponsorTopUpRecord>(
    `select ${sponsorTopUpColumns} from sponsor_topups order by created_at desc limit $1`,
    [limit]
  );

  return result.rows;
}
