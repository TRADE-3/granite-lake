import { createHash, randomBytes, randomUUID } from "node:crypto";
import { verifyPersonalMessageSignature } from "@mysten/sui/verify";
import { env } from "../config/env.js";
import {
  consumeChallenge,
  findExchangeCandidates,
  findSessionState,
  insertChallenge,
  insertRefreshToken,
  insertTrade3User,
  linkTrade3User,
  revokeFamily,
  revokeFamilyOfToken,
  useRefreshToken,
  withAdvisoryLocks,
  type AuthUserRow,
} from "../db/authRepositories.js";
import { resolveUserDomain } from "../db/repositories.js";
import { signAccessToken, verifyAccessToken } from "../utils/jwt.js";
import { SuiService, type AddUserResult } from "./SuiService.js";
import { fetchTrade3User, type Trade3User } from "./Trade3Service.js";
import { resolveSecretValue } from "./VaultService.js";

const CHALLENGE_TTL_MS = 5 * 60 * 1000;
// A rotated refresh token may be presented again this long after first use, so
// a response lost on a bad connection does not end the session.
const REFRESH_REUSE_GRACE_MS = 30 * 1000;

export class AuthError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string
  ) {
    super(message);
  }
}

export type SessionTokens = {
  accessToken: string;
  accessTokenExpiresAt: string;
  refreshToken: string;
  refreshTokenExpiresAt: string;
};

export type AuthenticatedUser = { userId: string; userWallet: string };

let suiService: SuiService | null = null;
const sui = () => (suiService ??= new SuiService(env));

/** The UTF-8 message the wallet signs to answer a challenge. */
export function challengeMessage(userWallet: string, nonce: string): Buffer {
  return Buffer.from(`auth:${userWallet}:${nonce}`, "utf8");
}

export async function createChallenge(userWallet: string): Promise<{ nonce: string; expiresAt: string }> {
  const wallet = userWallet.toLowerCase();
  const nonce = randomBytes(32).toString("base64");
  const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MS);

  await insertChallenge({ nonceHash: sha256(nonce), userWallet: wallet, expiresAt });

  return { nonce, expiresAt: expiresAt.toISOString() };
}

export async function exchange(input: {
  userWallet: string;
  nonce: string;
  signature: string;
  trade3AccessToken: string;
}) {
  const { baseUrl, registryDomain } = requireExchangeConfig();
  // Before anything irreversible (add_user), make sure tokens can be issued.
  await jwtSecret();
  const userWallet = input.userWallet.toLowerCase();
  const invalidSignature = () => new AuthError(401, "invalid_signature", "Wallet signature or challenge is invalid.");

  try {
    await verifyPersonalMessageSignature(challengeMessage(userWallet, input.nonce), input.signature, {
      address: userWallet,
    });
  } catch {
    throw invalidSignature();
  }

  if (!(await consumeChallenge(sha256(input.nonce), userWallet))) throw invalidSignature();

  const t3 = await fetchTrade3User(baseUrl, input.trade3AccessToken);

  if (!t3.isActive || !t3.companyWhitelisted) {
    throw new AuthError(403, "not_eligible", "This Trade3 account is not allowed to register.");
  }

  const user = await withAdvisoryLocks([`t3:${t3.id}`, `wallet:${userWallet}`], async (db) => {
    const rows = await findExchangeCandidates(db, { trade3UserId: t3.id, userWallet, userEmail: t3.email });
    const linked = rows.find((row) => row.trade3UserId !== null && Number(row.trade3UserId) === t3.id);

    if (linked) {
      assertActive(linked);
      if (linked.userWallet !== userWallet) {
        throw new AuthError(409, "wallet_mismatch", "This account uses a different wallet. Import your recovery key.");
      }
      await linkTrade3User(db, {
        userId: linked.userId,
        trade3UserId: t3.id,
        trade3CompanyId: t3.companyId,
        registryDomain: domainOf(linked),
      });
      return linked;
    }

    // An OTP user is claimed only when email AND wallet (already proven by
    // signature) point at the same unlinked row.
    const [existing] = rows;
    if (existing) {
      const sameAccount =
        rows.length === 1 &&
        existing.trade3UserId === null &&
        existing.userWallet === userWallet &&
        existing.userEmail === t3.email;

      if (!sameAccount) {
        throw new AuthError(409, "account_conflict", "This email or wallet belongs to another account.");
      }

      assertActive(existing);
      await linkTrade3User(db, {
        userId: existing.userId,
        trade3UserId: t3.id,
        trade3CompanyId: t3.companyId,
        registryDomain: domainOf(existing),
      });
      return existing;
    }

    const added = await addUserOrRecover(registryDomain, userWallet);
    const created: AuthUserRow = {
      userId: randomUUID(),
      userEmail: t3.email,
      userWallet,
      status: "active",
      userCapId: added.userCapId,
      addUserTxDigest: added.txDigest,
      registryDomain,
      trade3UserId: String(t3.id),
    };
    await insertTrade3User(db, { ...created, registryDomain, trade3UserId: t3.id, trade3CompanyId: t3.companyId });
    return created;
  });

  const familyId = randomUUID();
  const refreshExpiresAt = new Date(Date.now() + env.GL_REFRESH_TOKEN_TTL * 1000);
  const tokens = await issueTokens(user.userId, userWallet, familyId, refreshExpiresAt);

  return {
    ...tokens,
    userId: user.userId,
    domain: domainOf(user),
    userWallet,
    userCapId: user.userCapId,
    txDigest: user.addUserTxDigest,
    userEmail: user.userEmail,
    profile: toProfile(t3),
  };
}

/**
 * Rotates a refresh token. The new token keeps the family's expiry: a session
 * lasts a fixed time from the QR scan however often it is refreshed.
 */
export async function refresh(refreshToken: string): Promise<SessionTokens> {
  const invalid = () => new AuthError(401, "invalid_refresh_token", "The session has ended. Scan the QR code again.");
  // Checked before the token is marked used, so a config fault cannot burn it.
  await jwtSecret();
  const row = await useRefreshToken(sha256(refreshToken));

  if (!row) throw invalid();

  const expiresAt = new Date(row.expiresAt);
  if (expiresAt.getTime() <= Date.now()) throw invalid();

  if (Date.now() - new Date(row.usedAt).getTime() > REFRESH_REUSE_GRACE_MS) {
    await revokeFamily(row.familyId);
    throw invalid();
  }

  const state = await findSessionState(row.userId, row.familyId);
  if (!state || state.revoked) throw invalid();
  if (state.status !== "active") throw new AuthError(403, "user_disabled", "This account is disabled.");

  return issueTokens(row.userId, state.userWallet, row.familyId, expiresAt);
}

export async function logout(refreshToken: string): Promise<void> {
  await revokeFamilyOfToken(sha256(refreshToken));
}

/** Null unless the token is genuine, unexpired, not logged out and its user is active. */
export async function authenticate(accessToken: string): Promise<AuthenticatedUser | null> {
  if (!env.GL_JWT_SECRET) return null;

  const claims = verifyAccessToken(accessToken, await jwtSecret(), env.CLIENT_ID);
  if (!claims) return null;

  const state = await findSessionState(claims.sub, claims.fid);
  if (!state || state.revoked || state.status !== "active") return null;

  return { userId: claims.sub, userWallet: state.userWallet };
}

async function issueTokens(
  userId: string,
  userWallet: string,
  familyId: string,
  refreshExpiresAt: Date
): Promise<SessionTokens> {
  const secret = await jwtSecret();
  const refreshToken = randomBytes(32).toString("base64url");

  await insertRefreshToken({ tokenHash: sha256(refreshToken), userId, familyId, expiresAt: refreshExpiresAt });

  const iat = Math.floor(Date.now() / 1000);
  // An access token never outlives its session.
  const exp = Math.min(iat + env.GL_ACCESS_TOKEN_TTL, Math.floor(refreshExpiresAt.getTime() / 1000));

  return {
    accessToken: signAccessToken(
      { sub: userId, wallet: userWallet, fid: familyId, aud: env.CLIENT_ID, iat, exp },
      secret
    ),
    accessTokenExpiresAt: new Date(exp * 1000).toISOString(),
    refreshToken,
    refreshTokenExpiresAt: refreshExpiresAt.toISOString(),
  };
}

// add_user aborts if the wallet is already registered on-chain, which happens
// when an earlier attempt landed but its database write did not.
async function addUserOrRecover(domain: string, userWallet: string): Promise<AddUserResult> {
  try {
    return await sui().addUser({ domain, userWallet });
  } catch (error) {
    const existing = await sui()
      .findUserCap({ domain, userWallet })
      .catch(() => null);
    if (existing) return existing;
    throw error;
  }
}

function assertActive(user: AuthUserRow): void {
  if (user.status !== "active") throw new AuthError(403, "user_disabled", "This account is disabled.");
}

function domainOf(user: AuthUserRow): string {
  return resolveUserDomain(user.registryDomain, user.userEmail);
}

function toProfile(t3: Trade3User) {
  return {
    trade3UserId: t3.id,
    name: t3.name,
    email: t3.email,
    position: t3.position,
    companyId: t3.companyId,
    companyName: t3.companyName,
    role: t3.role,
  };
}

function notConfigured(): AuthError {
  return new AuthError(503, "auth_not_configured", "Trade3 sign-in is not configured on this server.");
}

function requireExchangeConfig(): { baseUrl: string; registryDomain: string } {
  const registryDomain = env.REGISTRY_DOMAIN?.trim().toLowerCase();
  if (!env.TRADE3_API_URL || !registryDomain) throw notConfigured();
  return { baseUrl: env.TRADE3_API_URL, registryDomain };
}

async function jwtSecret(): Promise<string> {
  const secret = env.GL_JWT_SECRET ? await resolveSecretValue(env, env.GL_JWT_SECRET) : "";
  if (!secret || secret.trim().length < 32) throw notConfigured();
  return secret.trim();
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
