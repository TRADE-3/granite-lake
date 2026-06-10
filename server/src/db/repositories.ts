import { randomInt, randomUUID, createHash } from "node:crypto";
import { env } from "../config/env.js";
import { GoogleChatService } from "../services/GoogleChatService.js";
import { SuiService, type AddUserResult } from "../services/SuiService.js";
import { pool } from "./pool.js";

const googleChatService = new GoogleChatService(env);
const suiService = new SuiService(env);

export type OtpSessionRecord = {
  userId: string;
  domain: string;
  userEmail: string;
  userWallet: string | null;
  adminWallet: string;
  otpHash: string;
  status: "pending_verification" | "completed" | "expired";
  createdAt: string;
  expiresAt: string;
  verifiedAt: string | null;
  txDigest: string | null;
  userCapId: string | null;
  error: string | null;
};

export type UserRecord = {
  userId: string;
  domain: string;
  userEmail: string;
  userWallet: string;
  adminWallet: string;
  status: "active" | "disabled";
  userCapId: string;
  addUserTxDigest: string;
  disableUserTxDigest: string | null;
  enableUserTxDigest: string | null;
  createdAt: string;
  updatedAt: string;
  lastVerifiedAt: string;
  disabledAt: string | null;
};

export async function createOtpSession(input: {
  domain: string;
  userEmail: string;
  ttlMs: number;
}): Promise<OtpSessionRecord> {
  assertConfiguredDomain(input.domain);
  assertConfiguredEmailDomain(input.userEmail);

  const userId = randomUUID();
  const userEmail = normalizeEmail(input.userEmail);
  const existingUser = await findUserByEmail(userEmail);

  if (existingUser) {
    throw new Error(`User email ${userEmail} is already registered.`);
  }

  const otp = String(randomInt(0, 1_000_000)).padStart(6, "0");
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + input.ttlMs);

  const session: OtpSessionRecord = {
    userId,
    domain: configuredDomain(),
    userEmail,
    userWallet: null,
    adminWallet: configuredAdminWallet(),
    otpHash: sha256(otp),
    status: "pending_verification",
    createdAt: createdAt.toISOString(),
    expiresAt: expiresAt.toISOString(),
    verifiedAt: null,
    txDigest: null,
    userCapId: null,
    error: null,
  };

  await pool.query(
    `
      insert into otp_sessions (
        user_id,
        user_email,
        user_wallet,
        otp_hash,
        status,
        created_at,
        expires_at,
        verified_at,
        tx_digest,
        user_cap_id,
        error
      ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
    `,
    [
      session.userId,
      session.userEmail,
      session.userWallet,
      session.otpHash,
      session.status,
      session.createdAt,
      session.expiresAt,
      session.verifiedAt,
      session.txDigest,
      session.userCapId,
      session.error,
    ]
  );

  try {
    await googleChatService.sendOtp({
      userEmail: session.userEmail,
      userId: session.userId,
      otp,
      expiresAt: session.expiresAt,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Failed to send OTP message to Google Chat.";

    await pool.query(`update otp_sessions set error = $2 where user_id = $1`, [session.userId, message]);

    throw error;
  }

  return session;
}

export async function findOtpSession(userId: string): Promise<OtpSessionRecord | null> {
  const result = await pool.query<OtpSessionRecord>(
    `
      select
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        otp_hash as "otpHash",
        status,
        created_at as "createdAt",
        expires_at as "expiresAt",
        verified_at as "verifiedAt",
        tx_digest as "txDigest",
        user_cap_id as "userCapId",
        error
      from otp_sessions
      where user_id = $1
    `,
    [userId]
  );

  return result.rows[0] ? withConfiguredOtpFields(result.rows[0]) : null;
}

export async function listUsers(): Promise<UserRecord[]> {
  const result = await pool.query<UserRecord>(
    `
      select
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        status,
        user_cap_id as "userCapId",
        add_user_tx_digest as "addUserTxDigest",
        disable_user_tx_digest as "disableUserTxDigest",
        enable_user_tx_digest as "enableUserTxDigest",
        created_at as "createdAt",
        updated_at as "updatedAt",
        last_verified_at as "lastVerifiedAt",
        disabled_at as "disabledAt"
      from users
      order by updated_at desc
    `
  );

  return result.rows.map(withConfiguredUserFields);
}

export async function disableUser(userId: string): Promise<UserRecord | null> {
  const existing = await findUser(userId);

  if (!existing) {
    return null;
  }

  const disableUserTxDigest = await suiService.disableUser({
    domain: configuredDomain(),
    userWallet: existing.userWallet,
  });

  const result = await pool.query<UserRecord>(
    `
      update users
      set
        status = 'disabled',
        disable_user_tx_digest = $2,
        disabled_at = coalesce(disabled_at, now()),
        updated_at = now()
      where user_id = $1
      returning
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        status,
        user_cap_id as "userCapId",
        add_user_tx_digest as "addUserTxDigest",
        disable_user_tx_digest as "disableUserTxDigest",
        enable_user_tx_digest as "enableUserTxDigest",
        created_at as "createdAt",
        updated_at as "updatedAt",
        last_verified_at as "lastVerifiedAt",
        disabled_at as "disabledAt"
    `,
    [userId, disableUserTxDigest]
  );

  return result.rows[0] ? withConfiguredUserFields(result.rows[0]) : null;
}

export async function enableUser(userId: string): Promise<UserRecord | null> {
  const existing = await findUser(userId);

  if (!existing) {
    return null;
  }

  const enableUserTxDigest = await suiService.enableUser({
    domain: configuredDomain(),
    userWallet: existing.userWallet,
  });

  const result = await pool.query<UserRecord>(
    `
      update users
      set
        status = 'active',
        enable_user_tx_digest = $2,
        disabled_at = null,
        updated_at = now()
      where user_id = $1
      returning
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        status,
        user_cap_id as "userCapId",
        add_user_tx_digest as "addUserTxDigest",
        disable_user_tx_digest as "disableUserTxDigest",
        enable_user_tx_digest as "enableUserTxDigest",
        created_at as "createdAt",
        updated_at as "updatedAt",
        last_verified_at as "lastVerifiedAt",
        disabled_at as "disabledAt"
    `,
    [userId, enableUserTxDigest]
  );

  return result.rows[0] ? withConfiguredUserFields(result.rows[0]) : null;
}

export async function completeOtpSession(input: {
  userId: string;
  domain: string;
  otp: string;
  userWallet: string;
}): Promise<OtpSessionRecord> {
  const session = await findOtpSession(input.userId);

  if (!session) {
    throw new Error(`No OTP session for ${input.userId}.`);
  }

  if (session.status === "completed") {
    throw new Error("OTP already used.");
  }

  if (Date.now() > Date.parse(session.expiresAt)) {
    await pool.query(`update otp_sessions set status = 'expired', error = 'OTP expired.' where user_id = $1`, [
      input.userId,
    ]);

    throw new Error("OTP expired.");
  }

  if (sha256(input.otp) !== session.otpHash) {
    throw new Error("OTP is invalid.");
  }

  assertConfiguredDomain(input.domain);

  assertSuiAddress(input.userWallet, "userWallet");

  const addUserResult = await suiService.addUser({
    domain: configuredDomain(),
    userWallet: normalizeWallet(input.userWallet),
  });

  const verifiedAt = new Date().toISOString();
  const updated = await pool.query<OtpSessionRecord>(
    `
      update otp_sessions
      set
        user_wallet = $2,
        status = 'completed',
        verified_at = $3,
        tx_digest = $4,
        user_cap_id = $5,
        error = null
      where user_id = $1
      returning
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        otp_hash as "otpHash",
        status,
        created_at as "createdAt",
        expires_at as "expiresAt",
        verified_at as "verifiedAt",
        tx_digest as "txDigest",
        user_cap_id as "userCapId",
        error
    `,
    [input.userId, normalizeWallet(input.userWallet), verifiedAt, addUserResult.txDigest, addUserResult.userCapId]
  );

  const completedSession = withConfiguredOtpFields(updated.rows[0]);
  await upsertActiveUserFromSession(completedSession, addUserResult);

  return completedSession;
}

function normalizeDomain(value: string): string {
  return value.trim().toLowerCase();
}

function normalizeWallet(value: string): string {
  return value.trim().toLowerCase();
}

function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}

function configuredDomain(): string {
  return normalizeDomain(env.DOMAIN);
}

function configuredAdminWallet(): string {
  return normalizeWallet(env.ADMIN_WALLET);
}

function assertConfiguredDomain(domain: string): void {
  if (normalizeDomain(domain) !== configuredDomain()) {
    throw new Error(`This container is configured for ${configuredDomain()}, not ${domain}.`);
  }
}

function assertConfiguredEmailDomain(email: string): void {
  const normalized = normalizeEmail(email);
  const atIndex = normalized.lastIndexOf("@");
  const emailDomain = atIndex === -1 ? "" : normalized.slice(atIndex + 1);

  if (emailDomain !== configuredDomain()) {
    throw new Error(`user_email must belong to ${configuredDomain()}.`);
  }
}

function withConfiguredOtpFields(session: Omit<OtpSessionRecord, "domain" | "adminWallet">): OtpSessionRecord {
  return {
    ...session,
    domain: configuredDomain(),
    adminWallet: configuredAdminWallet(),
  };
}

function withConfiguredUserFields(user: Omit<UserRecord, "domain" | "adminWallet">): UserRecord {
  return {
    ...user,
    domain: configuredDomain(),
    adminWallet: configuredAdminWallet(),
  };
}

async function findUser(userId: string): Promise<UserRecord | null> {
  const result = await pool.query<UserRecord>(
    `
      select
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        status,
        user_cap_id as "userCapId",
        add_user_tx_digest as "addUserTxDigest",
        disable_user_tx_digest as "disableUserTxDigest",
        enable_user_tx_digest as "enableUserTxDigest",
        created_at as "createdAt",
        updated_at as "updatedAt",
        last_verified_at as "lastVerifiedAt",
        disabled_at as "disabledAt"
      from users
      where user_id = $1
    `,
    [userId]
  );

  return result.rows[0] ? withConfiguredUserFields(result.rows[0]) : null;
}

async function findUserByEmail(userEmail: string): Promise<UserRecord | null> {
  const result = await pool.query<UserRecord>(
    `
      select
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        status,
        user_cap_id as "userCapId",
        add_user_tx_digest as "addUserTxDigest",
        disable_user_tx_digest as "disableUserTxDigest",
        enable_user_tx_digest as "enableUserTxDigest",
        created_at as "createdAt",
        updated_at as "updatedAt",
        last_verified_at as "lastVerifiedAt",
        disabled_at as "disabledAt"
      from users
      where user_email = $1
    `,
    [normalizeEmail(userEmail)]
  );

  return result.rows[0] ? withConfiguredUserFields(result.rows[0]) : null;
}

async function upsertActiveUserFromSession(session: OtpSessionRecord, addUserResult: AddUserResult): Promise<void> {
  if (!session.userWallet || !session.verifiedAt) {
    return;
  }

  await pool.query(
    `
      insert into users (
        user_id,
        user_email,
        user_wallet,
        status,
        user_cap_id,
        add_user_tx_digest,
        last_verified_at
      )
      values ($1, $2, $3, 'active', $4, $5, $6)
      on conflict (user_id)
      do update set
        user_email = excluded.user_email,
        user_wallet = excluded.user_wallet,
        status = 'active',
        user_cap_id = excluded.user_cap_id,
        add_user_tx_digest = excluded.add_user_tx_digest,
        last_verified_at = excluded.last_verified_at,
        disabled_at = null,
        disable_user_tx_digest = null,
        enable_user_tx_digest = null,
        updated_at = now()
    `,
    [
      session.userId,
      normalizeEmail(session.userEmail),
      normalizeWallet(session.userWallet),
      addUserResult.userCapId,
      addUserResult.txDigest,
      session.verifiedAt,
    ]
  );
}

function assertSuiAddress(value: string, key: string): void {
  if (!/^0x[a-f0-9]{64}$/i.test(value.trim())) {
    throw new Error(`${key} must be a Sui address.`);
  }
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
