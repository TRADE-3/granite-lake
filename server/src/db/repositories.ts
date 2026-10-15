import { randomBytes, randomInt, randomUUID, createHash } from "node:crypto";
import { verifyPersonalMessageSignature } from "@mysten/sui/verify";
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
  // Server-issued nonce the claimed wallet must sign before completeOtpSession
  // binds it to this session. Null only for sessions created before
  // this column existed.
  walletNonce: string | null;
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
  userWallet: string;
  ttlMs: number;
}): Promise<OtpSessionRecord> {
  assertConfiguredDomain(input.domain);
  assertConfiguredEmailDomain(input.userEmail);
  assertSuiAddress(input.userWallet, "userWallet");

  const userEmail = normalizeEmail(input.userEmail);
  const userWallet = normalizeWallet(input.userWallet);
  const existingUser = await findUserByEmail(userEmail);

  if (existingUser) {
    throw new Error(`User email ${userEmail} is already registered.`);
  }

  // otp_sessions_pending_email_unique only excludes rows whose status is not
  // 'pending_verification'. A session past its TTL keeps that status until
  // something loads it, so without this it still blocks the insert below
  // with a duplicate key error instead of the friendly "in progress" one.
  await expireStalePendingOtpSessionsByEmail(userEmail);

  const pendingSession = await findActivePendingOtpSessionByEmail(userEmail);

  if (pendingSession) {
    throw new Error(`User email ${userEmail} already has a registration in progress.`);
  }

  const userId = randomUUID();
  const otp = String(randomInt(0, 1_000_000)).padStart(6, "0");
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + input.ttlMs);

  const session: OtpSessionRecord = {
    userId,
    domain: configuredDomainForEmail(userEmail),
    userEmail,
    userWallet,
    adminWallet: configuredAdminWallet(),
    otpHash: sha256(otp),
    walletNonce: randomBytes(32).toString("base64"),
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
        wallet_nonce,
        status,
        created_at,
        expires_at,
        verified_at,
        tx_digest,
        user_cap_id,
        error
      ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
    `,
    [
      session.userId,
      session.userEmail,
      session.userWallet,
      session.otpHash,
      session.walletNonce,
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
      userWallet,
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
        wallet_nonce as "walletNonce",
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

async function expireStalePendingOtpSessionsByEmail(userEmail: string): Promise<void> {
  await pool.query(
    `
      update otp_sessions
      set status = 'expired', error = 'OTP expired.'
      where user_email = $1
        and status = 'pending_verification'
        and expires_at <= now()
    `,
    [userEmail]
  );
}

async function findActivePendingOtpSessionByEmail(userEmail: string): Promise<OtpSessionRecord | null> {
  const result = await pool.query<OtpSessionRecord>(
    `
      select
        user_id as "userId",
        user_email as "userEmail",
        user_wallet as "userWallet",
        otp_hash as "otpHash",
        wallet_nonce as "walletNonce",
        status,
        created_at as "createdAt",
        expires_at as "expiresAt",
        verified_at as "verifiedAt",
        tx_digest as "txDigest",
        user_cap_id as "userCapId",
        error
      from otp_sessions
      where user_email = $1
        and status = 'pending_verification'
        and expires_at > now()
      limit 1
    `,
    [userEmail]
  );

  return result.rows[0] ? withConfiguredOtpFields(result.rows[0]) : null;
}

export type OrphanedOtpSessionRecord = {
  userId: string;
  userEmail: string;
  userWallet: string | null;
  verifiedAt: string | null;
  txDigest: string | null;
  userCapId: string | null;
};

/**
 * Completed otp_sessions rows with no corresponding users row: sessions that
 * minted an on-chain capability but whose users insert never landed, most
 * commonly because a second concurrent session for the same email lost the
 * race against the users.user_email uniqueness constraint. These
 * capabilities are live on chain and unrevocable through /admin/users, which
 * only reads the users table.
 */
export async function findOrphanedCompletedOtpSessions(): Promise<OrphanedOtpSessionRecord[]> {
  const result = await pool.query<OrphanedOtpSessionRecord>(
    `
      select
        s.user_id as "userId",
        s.user_email as "userEmail",
        s.user_wallet as "userWallet",
        s.verified_at as "verifiedAt",
        s.tx_digest as "txDigest",
        s.user_cap_id as "userCapId"
      from otp_sessions s
      left join users u on u.user_id = s.user_id
      where s.status = 'completed'
        and u.user_id is null
      order by s.verified_at desc
    `
  );

  return result.rows;
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

export type UserLookupField = "email" | "employeeId" | "wallet";

/**
 * Finds a single user by email, employee ID (users.user_id) or wallet address.
 * Email and wallet are normalized (trimmed, lower-cased) the same way they are
 * on write, so lookups are case-insensitive.
 */
export async function findUserBy(field: UserLookupField, value: string): Promise<UserRecord | null> {
  switch (field) {
    case "email":
      return findUserByEmail(value);
    case "wallet":
      return findUserByWallet(value);
    case "employeeId":
      return findUser(value.trim());
  }
}

async function findUserByWallet(userWallet: string): Promise<UserRecord | null> {
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
      where user_wallet = $1
    `,
    [normalizeWallet(userWallet)]
  );

  return result.rows[0] ? withConfiguredUserFields(result.rows[0]) : null;
}

export async function disableUser(userId: string): Promise<UserRecord | null> {
  const existing = await findUser(userId);

  if (!existing) {
    return null;
  }

  const disableUserTxDigest = await suiService.disableUser({
    domain: configuredDomainForEmail(existing.userEmail),
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
    domain: configuredDomainForEmail(existing.userEmail),
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
  userWalletSignature: string;
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

  // The wallet claimed at /otp/verify must be the same one bound to the
  // session at /otp/request; anything else means the session is being
  // completed for a wallet other than the one that started it.
  if (!session.userWallet || normalizeWallet(session.userWallet) !== normalizeWallet(input.userWallet)) {
    throw new Error("userWallet does not match the OTP session.");
  }

  // The wallet address alone proves nothing about key possession, so also
  // require a signature over this session's server-issued nonce, verified
  // against the claimed address, before minting a capability for it.
  await assertWalletSignature({
    userWallet: normalizeWallet(input.userWallet),
    nonce: session.walletNonce,
    signature: input.userWalletSignature,
  });

  const existingUser = await findUserByEmail(session.userEmail);

  if (existingUser) {
    await pool.query(
      `update otp_sessions set status = 'expired', error = 'User email already registered by another session.' where user_id = $1`,
      [input.userId]
    );

    throw new Error(`User email ${session.userEmail} is already registered.`);
  }

  const addUserResult = await suiService.addUser({
    domain: configuredDomainForEmail(session.userEmail),
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
        wallet_nonce as "walletNonce",
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

function configuredDomains(): string[] {
  return env.DOMAINS.map(normalizeDomain);
}

function configuredEmailDomainAliases(): Record<string, string> {
  return env.EMAIL_DOMAIN_ALIASES;
}

// Resolves an email domain to its registry domain via EMAIL_DOMAIN_ALIASES,
// falling back to itself. Null if the result isn't a configured domain.
function registeredDomainForEmailDomain(emailDomain: string): string | null {
  const normalized = normalizeDomain(emailDomain);
  const aliasTarget = configuredEmailDomainAliases()[normalized];
  const registeredDomain = normalizeDomain(aliasTarget ?? normalized);

  return configuredDomains().includes(registeredDomain) ? registeredDomain : null;
}

function acceptedEmailDomains(): string[] {
  return Array.from(new Set([...configuredDomains(), ...Object.keys(configuredEmailDomainAliases())]));
}

export function isAcceptedEmailDomain(email: string): boolean {
  const normalized = normalizeEmail(email);
  const atIndex = normalized.lastIndexOf("@");
  const emailDomain = atIndex === -1 ? "" : normalized.slice(atIndex + 1);

  return registeredDomainForEmailDomain(emailDomain) !== null;
}

export function listAcceptedEmailDomains(): string[] {
  return acceptedEmailDomains();
}

function configuredDomainForEmail(email: string): string {
  const atIndex = email.lastIndexOf("@");
  const emailDomain = atIndex === -1 ? "" : email.slice(atIndex + 1);
  const registeredDomain = registeredDomainForEmailDomain(emailDomain);

  if (!registeredDomain) {
    throw new Error(`user_email must belong to ${acceptedEmailDomains().join(", ")}.`);
  }

  return registeredDomain;
}

function configuredAdminWallet(): string {
  return normalizeWallet(env.ADMIN_WALLET);
}

function assertConfiguredDomain(domain: string): void {
  const configuredDomainsLst = configuredDomains();

  if (!configuredDomainsLst.includes(normalizeDomain(domain))) {
    throw new Error(`This container is configured for ${configuredDomainsLst.join(", ")}, not ${domain}.`);
  }
}

function assertConfiguredEmailDomain(email: string): void {
  if (!isAcceptedEmailDomain(email)) {
    throw new Error(`user_email must belong to ${acceptedEmailDomains().join(", ")}.`);
  }
}

function withConfiguredOtpFields(session: Omit<OtpSessionRecord, "domain" | "adminWallet">): OtpSessionRecord {
  return {
    ...session,
    domain: configuredDomainForEmail(session.userEmail),
    adminWallet: configuredAdminWallet(),
  };
}

function withConfiguredUserFields(user: Omit<UserRecord, "domain" | "adminWallet">): UserRecord {
  return {
    ...user,
    domain: configuredDomainForEmail(user.userEmail),
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

// Proves the caller holds userWallet's private key by requiring a signature
// over this session's server-issued nonce. The wallet never
// existed on chain until this check passes, so there is nothing to look up
// on chain here - only the signature over the nonce establishes possession.
async function assertWalletSignature(params: {
  userWallet: string;
  nonce: string | null;
  signature: string;
}): Promise<void> {
  if (!params.nonce) {
    throw new Error("userWallet does not match the OTP session.");
  }

  try {
    await verifyPersonalMessageSignature(Buffer.from(params.nonce, "base64"), params.signature, {
      address: params.userWallet,
    });
  } catch {
    throw new Error("userWallet does not match the OTP session.");
  }
}

const DEACTIVATION_CHALLENGE_TTL_MS = 5 * 60 * 1000;

function deactivationMessage(userId: string, nonce: string): Buffer {
  return Buffer.from(`deactivate:${userId}:${nonce}`, "utf8");
}

/**
 * Issues a single-use challenge the registered wallet must sign to deactivate
 * its own account. Returns null if the user does not exist.
 */
export async function createDeactivationChallenge(
  userId: string
): Promise<{ nonce: string; expiresAt: string } | null> {
  const nonce = randomBytes(32).toString("base64");
  const expiresAt = new Date(Date.now() + DEACTIVATION_CHALLENGE_TTL_MS).toISOString();
  const result = await pool.query(
    `update users set deactivate_nonce = $2, deactivate_nonce_expires_at = $3 where user_id = $1`,
    [userId, nonce, expiresAt]
  );

  return result.rowCount ? { nonce, expiresAt } : null;
}

/**
 * Disables a user after verifying the registered wallet signed the pending
 * deactivation challenge. Returns null if the user does not exist; throws
 * "Deactivation signature is invalid." for a missing/expired challenge or bad
 * signature. The challenge is consumed atomically so it cannot be replayed.
 */
export async function disableUserWithSignature(input: {
  userId: string;
  userWalletSignature: string;
}): Promise<UserRecord | null> {
  const row = await pool.query<{
    userWallet: string;
    status: string;
    nonce: string | null;
    expiresAt: string | null;
  }>(
    `
      select
        user_wallet as "userWallet",
        status,
        deactivate_nonce as nonce,
        deactivate_nonce_expires_at as "expiresAt"
      from users
      where user_id = $1
    `,
    [input.userId]
  );
  const user = row.rows[0];

  if (!user) {
    return null;
  }

  if (!user.nonce || !user.expiresAt || Date.now() > Date.parse(user.expiresAt)) {
    throw new Error("Deactivation signature is invalid.");
  }

  try {
    await verifyPersonalMessageSignature(deactivationMessage(input.userId, user.nonce), input.userWalletSignature, {
      address: user.userWallet,
    });
  } catch {
    throw new Error("Deactivation signature is invalid.");
  }

  const consumed = await pool.query(
    `
      update users
      set deactivate_nonce = null, deactivate_nonce_expires_at = null
      where user_id = $1 and deactivate_nonce = $2
    `,
    [input.userId, user.nonce]
  );

  if (!consumed.rowCount) {
    throw new Error("Deactivation signature is invalid.");
  }

  // Already disabled (e.g. a retry after a failed client-side step): report
  // success without a second on-chain disable_user.
  if (user.status === "disabled") {
    return findUser(input.userId);
  }

  return disableUser(input.userId);
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
