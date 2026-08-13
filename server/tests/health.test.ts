import { describe, expect, it, vi } from "vitest";

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

vi.mock("../src/db/pool.js", () => ({
  pool: {
    query: vi.fn(async () => ({ rows: [{ ok: 1 }] })),
  },
}));

const { buildApp } = await import("../src/app.js");

describe("health routes", () => {
  it("serves /health without any credential", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/health",
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      ok: true,
      service: "granite-lake-api",
      database: "up",
    });

    await app.close();
  });

  it("rejects /utc without an app API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/utc",
    });

    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({
      error: "unauthorized",
      message: "Invalid app API key.",
    });

    await app.close();
  });

  it("rejects /utc with an invalid app API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/utc",
      headers: { "x-app-api-key": "wrong-key" },
    });

    expect(response.statusCode).toBe(401);

    await app.close();
  });

  it("rejects a percent-encoded /utc path without an app API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/%75tc",
    });

    expect(response.statusCode).toBe(401);

    await app.close();
  });

  it("serves /utc with a valid app API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/utc",
      headers: { "x-app-api-key": "app-key" },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toHaveProperty("utc");

    await app.close();
  });
});
