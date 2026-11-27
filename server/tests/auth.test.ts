import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

process.env.DOMAINS = "acme.com";
process.env.REGISTRY_DOMAIN = "acme.com";
process.env.EMAIL_DOMAIN_ALIASES = "";
process.env.CLIENT_ID = "acme";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
process.env.APP_API_KEY = "app-key";
process.env.SUI_NETWORK = "testnet";
process.env.SUI_RPC_URL = "https://fullnode.testnet.sui.io:443";
process.env.TRADE3_API_URL = "https://trade3.test";
process.env.GL_JWT_SECRET = "test-secret-that-is-at-least-32-characters";
process.env.GL_ACCESS_TOKEN_TTL = "900";
process.env.GL_REFRESH_TOKEN_TTL = "15552000";
process.env.AUTH_REQUIRE_USER_TOKEN = "true";
process.env.OTP_ENABLED = "false";
process.env.VAULT_ENABLED = "false";

type User = Record<string, string | null>;
type Token = { userId: string; familyId: string; expiresAt: Date; usedAt: Date | null; revoked: boolean };

const db = vi.hoisted(() => ({
  users: [] as Array<Record<string, string | null>>,
  challenges: new Map<string, { wallet: string; used: boolean }>(),
  tokens: new Map<string, unknown>(),
  lock: Promise.resolve() as Promise<unknown>,
}));
const tokens = db.tokens as Map<string, Token>;
const chain = vi.hoisted(() => ({ addUser: vi.fn(), findUserCap: vi.fn() }));

vi.mock("../src/services/SuiService.js", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/services/SuiService.js")>()),
  createSuiClient: vi.fn(() => ({})),
  SuiService: vi.fn().mockImplementation(() => chain),
}));

vi.mock("../src/db/authRepositories.js", () => ({
  // Serialises callers, as the advisory locks do.
  withAdvisoryLocks: (_keys: string[], fn: (c: unknown) => Promise<unknown>) => {
    const run = db.lock.then(() => fn({}));
    db.lock = run.catch(() => undefined);
    return run;
  },
  findExchangeCandidates: async (_c: unknown, i: { trade3UserId: number; userWallet: string; userEmail: string }) =>
    db.users.filter(
      (u) => u.trade3UserId === String(i.trade3UserId) || u.userWallet === i.userWallet || u.userEmail === i.userEmail
    ),
  linkTrade3User: async (_c: unknown, i: { userId: string; trade3UserId: number; registryDomain: string }) => {
    const user = db.users.find((u) => u.userId === i.userId)!;
    user.trade3UserId = String(i.trade3UserId);
    user.registryDomain ??= i.registryDomain;
  },
  insertTrade3User: async (_c: unknown, i: User & { trade3UserId: unknown }) => {
    db.users.push({ ...i, status: "active", trade3UserId: String(i.trade3UserId) });
  },
  insertChallenge: async (i: { nonceHash: string; userWallet: string }) => {
    db.challenges.set(i.nonceHash, { wallet: i.userWallet, used: false });
  },
  consumeChallenge: async (hash: string, wallet: string) => {
    const challenge = db.challenges.get(hash);
    if (!challenge || challenge.used || challenge.wallet !== wallet) return false;
    challenge.used = true;
    return true;
  },
  insertRefreshToken: async (i: { tokenHash: string; userId: string; familyId: string; expiresAt: Date }) => {
    tokens.set(i.tokenHash, { ...i, usedAt: null, revoked: false });
  },
  useRefreshToken: async (hash: string) => {
    const token = tokens.get(hash);
    if (!token) return null;
    token.usedAt ??= new Date();
    return { ...token };
  },
  revokeFamily: async (familyId: string) => revoke(familyId),
  revokeFamilyOfToken: async (hash: string) => {
    const token = tokens.get(hash);
    if (token) revoke(token.familyId);
  },
  findSessionState: async (userId: string, familyId: string) => {
    const user = db.users.find((u) => u.userId === userId);
    const family = [...tokens.values()].filter((t) => t.familyId === familyId && t.userId === userId);
    if (!user || !family.length) return null;
    return { status: user.status, userWallet: user.userWallet, revoked: family.some((t) => t.revoked) };
  },
}));

function revoke(familyId: string) {
  for (const token of tokens.values()) if (token.familyId === familyId) token.revoked = true;
}

const { buildApp } = await import("../src/app.js");
const { resetAllRateLimiters } = await import("../src/utils/rateLimit.js");

const APP = { "x-app-api-key": "app-key" };
const wallet = Ed25519Keypair.generate();
const otherWallet = Ed25519Keypair.generate();

let t3User: Record<string, unknown>;
let t3Status: number;

function companyMe(overrides: Record<string, unknown> = {}, company: Record<string, unknown> = {}) {
  return {
    id: 1,
    company_id: 3007,
    email: "Owner@Example.com",
    is_active: true,
    name: "User One",
    position: "Position",
    role: "OWNER",
    permissions: { can_deposit_documents: false },
    company: { name: "Test Company", is_whitelisted: true, bank_accounts: ["secret"], ...company },
    ...overrides,
  };
}

let app: Awaited<ReturnType<typeof buildApp>>;

beforeEach(async () => {
  db.users.length = 0;
  db.challenges.clear();
  tokens.clear();
  resetAllRateLimiters();
  chain.addUser.mockReset().mockResolvedValue({ txDigest: "digest", userCapId: "0xcap" });
  chain.findUserCap.mockReset().mockResolvedValue(null);
  t3User = companyMe();
  t3Status = 200;
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(JSON.stringify({ success: true, user: t3User }), { status: t3Status }))
  );
  app = await buildApp();
});

afterEach(async () => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
  await app.close();
});

async function signedChallenge(keypair = wallet) {
  const userWallet = keypair.toSuiAddress();
  const challenge = await app.inject({
    method: "POST",
    url: "/auth/challenge",
    headers: APP,
    payload: { userWallet },
  });
  const { nonce } = challenge.json();
  const { signature } = await keypair.signPersonalMessage(Buffer.from(`auth:${userWallet}:${nonce}`, "utf8"));
  return { userWallet, nonce, signature };
}

function postExchange(payload: object) {
  return app.inject({
    method: "POST",
    url: "/auth/exchange",
    headers: { ...APP, authorization: "Bearer t3-token" },
    payload,
  });
}

const signIn = async (keypair = wallet) => postExchange(await signedChallenge(keypair));
const post = (url: string, refreshToken: string) =>
  app.inject({ method: "POST", url, headers: APP, payload: { refreshToken } });

function otpUser(overrides: User = {}): User {
  return {
    userId: "otp-user",
    userEmail: "owner@example.com",
    userWallet: wallet.toSuiAddress(),
    status: "active",
    userCapId: "0xoldcap",
    addUserTxDigest: "old-digest",
    registryDomain: "acme.com",
    trade3UserId: null,
    ...overrides,
  };
}

describe("/auth/exchange", () => {
  it("registers a new user and returns tokens and profile", async () => {
    const response = await signIn();

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      domain: "acme.com",
      userCapId: "0xcap",
      userEmail: "owner@example.com",
      profile: { trade3UserId: 1, companyId: 3007, companyName: "Test Company", role: "OWNER" },
    });
    expect(response.body).not.toContain("secret");
    expect(chain.addUser).toHaveBeenCalledWith({ domain: "acme.com", userWallet: wallet.toSuiAddress() });
    expect(fetch).toHaveBeenCalledWith("https://trade3.test/api/company/me", expect.anything());
  });

  it("does not call add_user again for a known user", async () => {
    await signIn();
    const again = await signIn();

    expect(again.statusCode).toBe(200);
    expect(chain.addUser).toHaveBeenCalledTimes(1);
  });

  it("calls add_user once for concurrent exchanges", async () => {
    const payloads = [await signedChallenge(), await signedChallenge()];
    const responses = await Promise.all(payloads.map(postExchange));

    expect(responses.map((r) => r.statusCode)).toEqual([200, 200]);
    expect(chain.addUser).toHaveBeenCalledTimes(1);
  });

  it("rejects a different wallet for a known user", async () => {
    await signIn();
    const response = await signIn(otherWallet);

    expect(response.statusCode).toBe(409);
    expect(response.json().error).toBe("wallet_mismatch");
  });

  it("rejects a disabled user", async () => {
    db.users.push(otpUser({ status: "disabled", trade3UserId: "1" }));
    const response = await signIn();

    expect(response.statusCode).toBe(403);
    expect(response.json().error).toBe("user_disabled");
  });

  it("links an OTP user whose email and wallet both match", async () => {
    db.users.push(otpUser());
    const response = await signIn();

    expect(response.json()).toMatchObject({ userId: "otp-user", userCapId: "0xoldcap" });
    expect(db.users[0].trade3UserId).toBe("1");
    expect(chain.addUser).not.toHaveBeenCalled();
  });

  it.each([
    ["email only", { userWallet: otherWallet.toSuiAddress() }],
    ["wallet only", { userEmail: "someone@else.com" }],
    ["already linked to another Trade3 id", { trade3UserId: "2" }],
  ])("does not link on %s", async (_name, overrides) => {
    db.users.push(otpUser(overrides));
    const response = await signIn();

    expect(response.statusCode).toBe(409);
    expect(response.json().error).toBe("account_conflict");
    expect(chain.addUser).not.toHaveBeenCalled();
  });

  it.each([
    ["inactive user", () => companyMe({ is_active: false })],
    ["company not whitelisted", () => companyMe({}, { is_whitelisted: false })],
  ])("rejects an %s before any chain call", async (_name, user) => {
    t3User = user();
    const response = await signIn();

    expect(response.statusCode).toBe(403);
    expect(response.json().error).toBe("not_eligible");
    expect(chain.addUser).not.toHaveBeenCalled();
  });

  it("fails closed on a Trade3 401 or a malformed response", async () => {
    t3Status = 401;
    expect((await signIn()).json().error).toBe("trade3_unauthorized");

    t3Status = 200;
    t3User = companyMe({ id: "1" });
    expect((await signIn()).json().error).toBe("trade3_unavailable");
    expect(chain.addUser).not.toHaveBeenCalled();
  });

  it("rejects a reused challenge and another wallet's signature", async () => {
    const payload = await signedChallenge();
    await postExchange(payload);
    expect((await postExchange(payload)).json().error).toBe("invalid_signature");

    const other = await signedChallenge(otherWallet);
    const forged = { ...(await signedChallenge()), signature: other.signature };
    expect((await postExchange(forged)).statusCode).toBe(401);
  });

  it("recovers the UserCap when add_user already landed", async () => {
    chain.addUser.mockRejectedValue(new Error("MoveAbort E_USER_EXISTS"));
    chain.findUserCap.mockResolvedValue({ txDigest: "earlier", userCapId: "0xfound" });
    const response = await signIn();

    expect(response.json()).toMatchObject({ userCapId: "0xfound", txDigest: "earlier" });
  });
});

describe("company whitelist", () => {
  it("is checked again for an already registered user", async () => {
    await signIn();
    const issued = tokens.size;
    t3User = companyMe({}, { is_whitelisted: false });
    const response = await signIn();

    expect(response.statusCode).toBe(403);
    expect(response.json().error).toBe("not_eligible");
    expect(tokens.size).toBe(issued);
  });

  it("does not link an OTP user of a company that is not whitelisted", async () => {
    db.users.push(otpUser());
    t3User = companyMe({}, { is_whitelisted: false });

    expect((await signIn()).statusCode).toBe(403);
    expect(db.users[0].trade3UserId).toBeNull();
  });

  it.each([
    ["missing", undefined],
    ["null", null],
    ["the string 'true'", "true"],
    ["the number 1", 1],
  ])("fails closed when is_whitelisted is %s", async (_name, value) => {
    t3User = companyMe({}, { is_whitelisted: value });
    const response = await signIn();

    expect(response.statusCode).toBe(502);
    expect(chain.addUser).not.toHaveBeenCalled();
    expect(tokens.size).toBe(0);
  });

  it("fails closed when the company is missing", async () => {
    t3User = companyMe({ company: undefined });

    expect((await signIn()).statusCode).toBe(502);
    expect(chain.addUser).not.toHaveBeenCalled();
  });

  it("has no per-server company allowlist: any whitelisted company registers", async () => {
    t3User = companyMe({ company_id: 999999 });

    expect((await signIn()).statusCode).toBe(200);
  });
});

describe("user permissions", () => {
  const noRights = {
    can_sign_documents: false,
    can_view_documents: false,
    is_multisig_member: false,
    can_deposit_documents: false,
    can_view_transactions: false,
  };

  // The deposit right limits payment schedule selection in the app, not registration.
  it.each([
    ["every permission is false", noRights],
    ["permissions are missing", undefined],
  ])("registers a user when %s", async (_name, permissions) => {
    t3User = companyMe({ permissions });

    expect((await signIn()).statusCode).toBe(200);
  });

  it.each(["OWNER", "MEMBER", "ANYTHING_ELSE"])("does not restrict by role (%s)", async (role) => {
    t3User = companyMe({ role });
    const response = await signIn();

    expect(response.statusCode).toBe(200);
    expect(response.json().profile.role).toBe(role);
  });

  it("is_active is required to be a real boolean true", async () => {
    t3User = companyMe({ is_active: "true" });

    expect((await signIn()).statusCode).toBe(502);
    expect(chain.addUser).not.toHaveBeenCalled();
  });
});

describe("sessions", () => {
  it("rotates the refresh token without extending the session", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const first = (await signIn()).json();
    vi.setSystemTime(Date.now() + 60 * 24 * 60 * 60 * 1000);

    const second = (await post("/auth/refresh", first.refreshToken)).json();

    expect(second.refreshToken).not.toBe(first.refreshToken);
    expect(second.refreshTokenExpiresAt).toBe(first.refreshTokenExpiresAt);
  });

  it("ends the session once the fixed lifetime has passed", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const session = (await signIn()).json();
    vi.setSystemTime(Date.now() + 181 * 24 * 60 * 60 * 1000);

    expect((await post("/auth/refresh", session.refreshToken)).statusCode).toBe(401);
  });

  it("allows a retry within the grace window and revokes on later reuse", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const first = (await signIn()).json();
    const second = (await post("/auth/refresh", first.refreshToken)).json();
    expect((await post("/auth/refresh", first.refreshToken)).statusCode).toBe(200);

    vi.setSystemTime(Date.now() + 31 * 1000);
    expect((await post("/auth/refresh", first.refreshToken)).statusCode).toBe(401);
    expect((await post("/auth/refresh", second.refreshToken)).statusCode).toBe(401);
  });

  it("logout ends refresh and access, and can be repeated", async () => {
    const session = (await signIn()).json();

    expect((await post("/auth/logout", session.refreshToken)).statusCode).toBe(204);
    expect((await post("/auth/logout", session.refreshToken)).statusCode).toBe(204);
    expect((await post("/auth/refresh", session.refreshToken)).statusCode).toBe(401);
    expect((await sponsor(session.accessToken, wallet.toSuiAddress())).json().error).toBe("invalid_token");
  });

  it("stops a disabled user at once", async () => {
    const session = (await signIn()).json();
    db.users[0].status = "disabled";

    expect((await sponsor(session.accessToken, wallet.toSuiAddress())).statusCode).toBe(401);
    expect((await post("/auth/refresh", session.refreshToken)).json().error).toBe("user_disabled");
  });
});

function sponsor(accessToken: string | null, userWallet: string) {
  return app.inject({
    method: "POST",
    url: "/sponsor/submit",
    headers: accessToken ? { ...APP, authorization: `Bearer ${accessToken}` } : APP,
    payload: { userWallet },
  });
}

describe("existing routes", () => {
  it("require a token that matches the wallet and user", async () => {
    const session = (await signIn()).json();

    expect((await sponsor(null, wallet.toSuiAddress())).statusCode).toBe(401);
    expect((await sponsor(`${session.accessToken}x`, wallet.toSuiAddress())).statusCode).toBe(401);
    expect((await sponsor(session.accessToken, otherWallet.toSuiAddress())).statusCode).toBe(403);

    const otherUser = await app.inject({
      method: "POST",
      url: "/otp/someone-else/deactivate/challenge",
      headers: { ...APP, authorization: `Bearer ${session.accessToken}` },
    });
    expect(otherUser.statusCode).toBe(403);
  });

  it("refuses OTP registration when it is turned off", async () => {
    const response = await app.inject({ method: "POST", url: "/otp/request", headers: APP, payload: {} });

    expect(response.json().error).toBe("otp_disabled");
  });

  it("keeps the app key on /auth routes", async () => {
    const response = await app.inject({ method: "POST", url: "/auth/challenge", payload: {} });

    expect(response.statusCode).toBe(401);
  });
});
