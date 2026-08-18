import { beforeEach, describe, expect, it, vi } from "vitest";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

process.env.DOMAIN = "acme.com";
process.env.CLIENT_ID = "acme";
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

// F-03 requires proving possession of userWallet's private key before it is
// bound to an OTP session. That check calls the real Sui signature-verify
// library end to end, so this suite mocks only the DB and the chain write -
// not the check itself - to prove a real Ed25519 keypair produces a
// signature the server actually accepts, and that a tampered one is
// actually rejected rather than merely mocked as rejected (see otp.test.ts
// for the route-level error-mapping coverage, which mocks completeOtpSession
// entirely and so never exercises this).
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

const { completeOtpSession } = await import("../src/db/repositories.js");

const NONCE = Buffer.from("test-nonce-32-bytes-of-entropy!!").toString("base64");

let currentSession: Record<string, unknown>;

const OTP = "123456";
const OTP_HASH = "8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92"; // sha256("123456")

function pendingSession(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    userId: "user-id-1",
    userEmail: "alice@acme.com",
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

describe("completeOtpSession wallet signature check (F-03)", () => {
  it("accepts a real signature over the session nonce from the claimed wallet", async () => {
    const keypair = new Ed25519Keypair();
    const { signature } = await keypair.signPersonalMessage(Buffer.from(NONCE, "base64"));

    const result = await completeOtpSession({
      userId: "user-id-1",
      domain: "acme.com",
      otp: OTP,
      userWallet: keypair.toSuiAddress(),
      userWalletSignature: signature,
    });

    expect(result.status).toBe("completed");
    expect(addUserMock).toHaveBeenCalledWith({
      domain: "acme.com",
      userWallet: keypair.toSuiAddress().toLowerCase(),
    });
  });

  it("rejects a valid signature that does not match the claimed wallet address", async () => {
    const signer = new Ed25519Keypair();
    const claimedWallet = new Ed25519Keypair().toSuiAddress(); // different wallet than the signer
    const { signature } = await signer.signPersonalMessage(Buffer.from(NONCE, "base64"));

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: claimedWallet,
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });

  it("rejects a valid signature produced over a different session's nonce", async () => {
    const keypair = new Ed25519Keypair();
    const otherNonce = Buffer.from("a-completely-different-nonce!!!!").toString("base64");
    const { signature } = await keypair.signPersonalMessage(Buffer.from(otherNonce, "base64"));

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: keypair.toSuiAddress(),
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });

  it("rejects a malformed signature string", async () => {
    const keypair = new Ed25519Keypair();

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: keypair.toSuiAddress(),
        userWalletSignature: "not-a-real-signature",
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });

  it("rejects when the session predates the wallet_nonce column (null nonce)", async () => {
    currentSession = pendingSession({ walletNonce: null });
    const keypair = new Ed25519Keypair();
    const { signature } = await keypair.signPersonalMessage(Buffer.from(NONCE, "base64"));

    await expect(
      completeOtpSession({
        userId: "user-id-1",
        domain: "acme.com",
        otp: OTP,
        userWallet: keypair.toSuiAddress(),
        userWalletSignature: signature,
      })
    ).rejects.toThrow("userWallet does not match the OTP session.");

    expect(addUserMock).not.toHaveBeenCalled();
  });
});
