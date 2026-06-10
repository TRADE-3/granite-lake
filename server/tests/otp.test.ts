import { beforeEach, describe, expect, it, vi } from "vitest";

process.env.DOMAIN = "acme.com";
process.env.CLIENT_ID = "acme";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
process.env.SUI_NETWORK = "testnet";
process.env.SUI_RPC_URL = "https://fullnode.testnet.sui.io:443";
process.env.SUI_PRIVATE_KEY = "suiprivkey-test";
process.env.SUI_PACKAGE_ID = "0xpackage";
process.env.SUI_REGISTRY_ID = "0xregistry";

const createOtpSession = vi.fn(async (input) => ({
  userId: "user-id-1",
  domain: input.domain,
  userEmail: input.userEmail,
  userWallet: null,
  adminWallet: "0xabc",
  otpHash: "otp-hash",
  status: "pending_verification",
  createdAt: new Date().toISOString(),
  expiresAt: new Date().toISOString(),
  verifiedAt: null,
  txDigest: null,
  userCapId: null,
  error: null,
}));

const completeOtpSession = vi.fn();

vi.mock("../src/db/repositories.js", () => ({
  completeOtpSession,
  createOtpSession,
  disableUser: vi.fn(),
  enableUser: vi.fn(),
  findOtpSession: vi.fn(),
  listUsers: vi.fn(async () => []),
}));

const { buildApp } = await import("../src/app.js");

describe("otp routes", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("requests an OTP for a domain email without returning the OTP", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      payload: {
        domain: "acme.com",
        user_email: "alice@acme.com",
      },
    });

    expect(response.statusCode).toBe(201);
    expect(createOtpSession).toHaveBeenCalledWith({
      domain: "acme.com",
      userEmail: "alice@acme.com",
      ttlMs: 300000,
    });
    expect(response.json()).toEqual({
      userId: "user-id-1",
      expiresAt: expect.any(String),
      domain: "acme.com",
      userEmail: "alice@acme.com",
    });
    expect(response.json()).not.toHaveProperty("otp");

    await app.close();
  });

  it("accepts an OTP request sent as a JSON string body", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: {
        "content-type": "text/plain",
      },
      payload: JSON.stringify({
        domain: "acme.com",
        user_email: "alice@acme.com",
      }),
    });

    expect(response.statusCode).toBe(201);
    expect(createOtpSession).toHaveBeenCalledWith({
      domain: "acme.com",
      userEmail: "alice@acme.com",
      ttlMs: 300000,
    });

    await app.close();
  });

  it("rejects a malformed OTP request body", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      headers: {
        "content-type": "text/plain",
      },
      payload: "not json",
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_request",
      message: "Request body must be a JSON object with domain and user_email.",
    });
    expect(createOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("rejects an OTP request for a different email domain", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      payload: {
        domain: "acme.com",
        user_email: "alice@example.com",
      },
    });

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({
      error: "invalid_email_domain",
      message: "user_email must belong to acme.com.",
    });
    expect(createOtpSession).not.toHaveBeenCalled();

    await app.close();
  });

  it("rejects an OTP request for an already registered email", async () => {
    createOtpSession.mockRejectedValueOnce(
      new Error("User email alice@acme.com is already registered."),
    );

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/request",
      payload: {
        domain: "acme.com",
        user_email: "alice@acme.com",
      },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json()).toEqual({
      error: "user_email_exists",
      message: "User email alice@acme.com is already registered.",
    });

    await app.close();
  });

  it("rejects OTP verification when the OTP was already used", async () => {
    completeOtpSession.mockRejectedValueOnce(new Error("OTP already used."));

    const app = await buildApp();

    const response = await app.inject({
      method: "POST",
      url: "/otp/verify",
      payload: {
        userId: "user-id-1",
        otp: "123456",
        domain: "acme.com",
        userWallet:
          "0x1111111111111111111111111111111111111111111111111111111111111111",
      },
    });

    expect(response.statusCode).toBe(409);
    expect(response.json()).toEqual({
      error: "otp_already_used",
      message: "OTP already used.",
    });

    await app.close();
  });
});
