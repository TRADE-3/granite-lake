import { beforeEach, describe, expect, it, vi } from "vitest";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

// Simulates a deployment whose registered/on-chain domain (and DNS trust
// anchor) is trade3.io, but whose staff email domain is the different
// tr3.io. EMAIL_DOMAIN_ALIASES routes tr3.io email addresses to register
// under trade3.io instead of registering (and failing on-chain) under the
// literal email domain.
process.env.DOMAINS = "trade3.io";
process.env.EMAIL_DOMAIN_ALIASES = "tr3.io:trade3.io";
process.env.CLIENT_ID = "trade3";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
process.env.APP_API_KEY = "app-key";
process.env.SUI_NETWORK = "testnet";
process.env.SUI_RPC_URL = "https://fullnode.testnet.sui.io:443";
process.env.SUI_PRIVATE_KEY = "suiprivkey-test";
process.env.SUI_PACKAGE_ID = "0xpackage";
process.env.SUI_REGISTRY_ID = "0xregistry";

const addUserMock = vi.fn(async () => ({ txDigest: "0xdigest", userCapId: "0xcap" }));

vi.mock("../src/services/SuiService.js", () => ({
  SuiService: vi.fn().mockImplementation(() => ({
    addUser: addUserMock,
    disableUser: vi.fn(),
    enableUser: vi.fn(),
  })),
}));

vi.mock("../src/services/GoogleChatService.js", () => ({
  GoogleChatService: vi.fn().mockImplementation(() => ({
    sendOtp: vi.fn(),
  })),
}));

const queryMock = vi.fn(async (sql: string) => {
  const normalized = sql.trim().toLowerCase();

  if (normalized.startsWith("select") && normalized.includes("from otp_sessions")) {
    return { rows: [currentSession], rowCount: 1 };
  }
  if (normalized.startsWith("select") && normalized.includes("from users")) {
    return { rows: [], rowCount: 0 };
  }
  if (normalized.startsWith("update otp_sessions")) {
    currentSession = { ...currentSession, status: "completed" };
    return { rows: [currentSession], rowCount: 1 };
  }
  if (normalized.startsWith("insert into users")) {
    return { rows: [], rowCount: 1 };
  }

  throw new Error(`Unexpected query in test: ${sql}`);
});

vi.mock("../src/db/pool.js", () => ({
  pool: { query: (sql: string) => queryMock(sql) },
}));

const { completeOtpSession, isAcceptedEmailDomain, listAcceptedEmailDomains } =
  await import("../src/db/repositories.js");

const NONCE = Buffer.from("test-nonce-32-bytes-of-entropy!!").toString("base64");

let currentSession: Record<string, unknown>;

const OTP = "123456";
const OTP_HASH = "8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92";

function pendingSession(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    userId: "user-id-1",
    userEmail: "alice@tr3.io",
    userWallet: null,
    otpHash: OTP_HASH,
    walletNonce: NONCE,
    status: "pending_verification",
    createdAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    verifiedAt: null,
    txDigest: null,
    userCapId: null,
    error: null,
    ...overrides,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  currentSession = pendingSession();
});

describe("EMAIL_DOMAIN_ALIASES", () => {
  it("registers a tr3.io email under the aliased trade3.io registry domain", async () => {
    const keypair = new Ed25519Keypair();
    const { signature } = await keypair.signPersonalMessage(Buffer.from(NONCE, "base64"));

    const result = await completeOtpSession({
      userId: "user-id-1",
      domain: "trade3.io",
      otp: OTP,
      userWallet: keypair.toSuiAddress(),
      userWalletSignature: signature,
    });

    expect(result.status).toBe("completed");
    expect(result.domain).toBe("trade3.io");
    // The alias target - not the literal tr3.io email domain - is what must
    // reach the chain, since only trade3.io is registered on-chain.
    expect(addUserMock).toHaveBeenCalledWith({
      domain: "trade3.io",
      userWallet: keypair.toSuiAddress().toLowerCase(),
    });
  });

  it("accepts an aliased email domain as a valid registration email", () => {
    expect(isAcceptedEmailDomain("alice@tr3.io")).toBe(true);
    expect(isAcceptedEmailDomain("alice@TR3.IO")).toBe(true);
  });

  it("rejects an email domain with no alias and no direct match", () => {
    expect(isAcceptedEmailDomain("alice@unrelated.io")).toBe(false);
  });

  it("lists both the registered domain and its email aliases as accepted", () => {
    expect(listAcceptedEmailDomains().sort()).toEqual(["tr3.io", "trade3.io"]);
  });
});
