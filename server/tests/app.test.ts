import { describe, expect, it, vi } from "vitest";

process.env.DOMAIN = "acme.com";
process.env.CLIENT_ID = "acme";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
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

describe("app routes", () => {
  it("returns health and utc responses", async () => {
    const app = await buildApp();

    const healthResponse = await app.inject({
      method: "GET",
      url: "/health",
    });

    expect(healthResponse.statusCode).toBe(200);
    expect(healthResponse.json()).toEqual({
      ok: true,
      service: "granite-lake-api",
      database: "up",
    });

    const utcResponse = await app.inject({
      method: "GET",
      url: "/utc",
    });

    expect(utcResponse.statusCode).toBe(200);
    expect(utcResponse.json()).toHaveProperty("utc");

    await app.close();
  });
});
