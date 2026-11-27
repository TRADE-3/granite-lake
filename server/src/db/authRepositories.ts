import { pool } from "./pool.js";

type Queryable = Pick<typeof pool, "query">;

export type AuthUserRow = {
  userId: string;
  userEmail: string;
  userWallet: string;
  status: "active" | "disabled";
  userCapId: string;
  addUserTxDigest: string;
  registryDomain: string | null;
  // bigint: pg returns it as a string; compare numerically.
  trade3UserId: string | null;
};

const AUTH_USER_COLUMNS = `
  user_id as "userId",
  user_email as "userEmail",
  user_wallet as "userWallet",
  status,
  user_cap_id as "userCapId",
  add_user_tx_digest as "addUserTxDigest",
  registry_domain as "registryDomain",
  trade3_user_id as "trade3UserId"
`;

/**
 * Runs fn while holding Postgres advisory locks on every key, so two exchanges
 * for the same Trade3 user or wallet cannot both call add_user. fn must use the
 * connection it is given: taking another from the pool while holding this one
 * could exhaust it.
 */
export async function withAdvisoryLocks<T>(keys: string[], fn: (db: Queryable) => Promise<T>): Promise<T> {
  const client = await pool.connect();

  try {
    // Sorted, so two callers can never wait on each other.
    for (const key of [...keys].sort()) {
      await client.query(`select pg_advisory_lock(hashtextextended($1, 0))`, [key]);
    }
    return await fn(client);
  } finally {
    try {
      await client.query(`select pg_advisory_unlock_all()`);
      client.release();
    } catch {
      // A connection that cannot unlock must not go back into the pool.
      client.release(true);
    }
  }
}

export async function findExchangeCandidates(
  db: Queryable,
  input: { trade3UserId: number; userWallet: string; userEmail: string }
): Promise<AuthUserRow[]> {
  const result = await db.query<AuthUserRow>(
    `
      select ${AUTH_USER_COLUMNS}
      from users
      where trade3_user_id = $1 or user_wallet = $2 or user_email = $3
    `,
    [input.trade3UserId, input.userWallet, input.userEmail]
  );

  return result.rows;
}

export async function linkTrade3User(
  db: Queryable,
  input: { userId: string; trade3UserId: number; trade3CompanyId: number; registryDomain: string }
): Promise<void> {
  await db.query(
    `
      update users
      set
        trade3_user_id = $2,
        trade3_company_id = $3,
        registry_domain = coalesce(registry_domain, $4),
        updated_at = now()
      where user_id = $1
    `,
    [input.userId, input.trade3UserId, input.trade3CompanyId, input.registryDomain]
  );
}

export async function insertTrade3User(
  db: Queryable,
  input: {
    userId: string;
    userEmail: string;
    userWallet: string;
    userCapId: string;
    addUserTxDigest: string;
    registryDomain: string;
    trade3UserId: number;
    trade3CompanyId: number;
  }
): Promise<void> {
  await db.query(
    `
      insert into users (
        user_id, user_email, user_wallet, status, user_cap_id, add_user_tx_digest,
        last_verified_at, registry_domain, trade3_user_id, trade3_company_id
      )
      values ($1, $2, $3, 'active', $4, $5, now(), $6, $7, $8)
    `,
    [
      input.userId,
      input.userEmail,
      input.userWallet,
      input.userCapId,
      input.addUserTxDigest,
      input.registryDomain,
      input.trade3UserId,
      input.trade3CompanyId,
    ]
  );
}

export async function insertChallenge(input: {
  nonceHash: string;
  userWallet: string;
  expiresAt: Date;
}): Promise<void> {
  await pool.query(`delete from auth_challenges where expires_at < now()`);
  await pool.query(`insert into auth_challenges (nonce_hash, user_wallet, expires_at) values ($1, $2, $3)`, [
    input.nonceHash,
    input.userWallet,
    input.expiresAt.toISOString(),
  ]);
}

/** Marks a live challenge used. False if it is unknown, expired or already used. */
export async function consumeChallenge(nonceHash: string, userWallet: string): Promise<boolean> {
  const result = await pool.query(
    `
      update auth_challenges
      set used_at = now()
      where nonce_hash = $1 and user_wallet = $2 and used_at is null and expires_at > now()
    `,
    [nonceHash, userWallet]
  );

  return Boolean(result.rowCount);
}

export async function insertRefreshToken(input: {
  tokenHash: string;
  userId: string;
  familyId: string;
  expiresAt: Date;
}): Promise<void> {
  await pool.query(
    `insert into auth_refresh_tokens (token_hash, user_id, family_id, expires_at) values ($1, $2, $3, $4)`,
    [input.tokenHash, input.userId, input.familyId, input.expiresAt.toISOString()]
  );
}

export type RefreshTokenRow = {
  userId: string;
  familyId: string;
  expiresAt: string | Date;
  usedAt: string | Date;
};

/** Atomically records a use; usedAt is the time of the FIRST use. */
export async function useRefreshToken(tokenHash: string): Promise<RefreshTokenRow | null> {
  const result = await pool.query<RefreshTokenRow>(
    `
      update auth_refresh_tokens
      set used_at = coalesce(used_at, now())
      where token_hash = $1
      returning user_id as "userId", family_id as "familyId", expires_at as "expiresAt", used_at as "usedAt"
    `,
    [tokenHash]
  );

  return result.rows[0] ?? null;
}

export async function revokeFamily(familyId: string): Promise<void> {
  await pool.query(`update auth_refresh_tokens set revoked_at = now() where family_id = $1 and revoked_at is null`, [
    familyId,
  ]);
}

export async function revokeFamilyOfToken(tokenHash: string): Promise<void> {
  await pool.query(
    `
      update auth_refresh_tokens
      set revoked_at = now()
      where family_id = (select family_id from auth_refresh_tokens where token_hash = $1)
        and revoked_at is null
    `,
    [tokenHash]
  );
}

/**
 * The state every token check needs. A family counts as revoked if any of its
 * tokens is, which also covers a token issued while a logout was in flight.
 */
export async function findSessionState(
  userId: string,
  familyId: string
): Promise<{ status: "active" | "disabled"; userWallet: string; revoked: boolean } | null> {
  const result = await pool.query<{ status: "active" | "disabled"; userWallet: string; revoked: boolean }>(
    `
      select
        u.status,
        u.user_wallet as "userWallet",
        bool_or(t.revoked_at is not null) as revoked
      from users u
      join auth_refresh_tokens t on t.user_id = u.user_id
      where u.user_id = $1 and t.family_id = $2
      group by u.user_id
    `,
    [userId, familyId]
  );

  return result.rows[0] ?? null;
}
