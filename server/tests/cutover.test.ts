import { describe, expect, it } from "vitest";

process.env.DOMAINS = "acme.com";
process.env.CLIENT_ID = "acme";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
process.env.APP_API_KEY = "app-key";
process.env.SUI_NETWORK = "testnet";
process.env.SUI_RPC_URL = "https://fullnode.testnet.sui.io:443";
// Blank, not deleted: dotenv would refill a deleted key from a developer's .env,
// and a blank value must fall back to the default.
process.env.OTP_ENABLED = "";
process.env.AUTH_REQUIRE_USER_TOKEN = "";

const { env } = await import("../src/config/env.js");
const { buildApp } = await import("../src/app.js");

const APP = { "x-app-api-key": "app-key" };

describe("cutover defaults", () => {
  it("turns OTP off and requires access tokens", () => {
    expect(env.OTP_ENABLED).toBe(false);
    expect(env.AUTH_REQUIRE_USER_TOKEN).toBe(true);
  });

  it.each([
    ["POST", "/otp/request", 403, "otp_disabled"],
    ["POST", "/otp/verify", 403, "otp_disabled"],
    ["GET", "/otp/some-user", 401, "invalid_token"],
    ["PATCH", "/otp/some-user/deactivate", 401, "invalid_token"],
    ["GET", "/sponsor/status", 401, "invalid_token"],
  ] as const)("%s %s answers %i with only the app key", async (method, url, status, error) => {
    const app = await buildApp();
    const response = await app.inject({ method, url, headers: APP });

    expect(response.statusCode).toBe(status);
    expect(response.json().error).toBe(error);
    await app.close();
  });

  it("leaves /utc on the app key", async () => {
    const app = await buildApp();
    const response = await app.inject({ method: "GET", url: "/utc", headers: APP });

    expect(response.statusCode).toBe(200);
    await app.close();
  });
});
