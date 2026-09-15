import { beforeEach, describe, expect, it, vi } from "vitest";

process.env.DOMAINS = "acme.com";
process.env.CLIENT_ID = "acme";
process.env.ADMIN_WALLET = "0xabc";
process.env.ADMIN_API_KEY = "admin-key";
process.env.APP_API_KEY = "app-key";
process.env.SUI_NETWORK = "testnet";
process.env.SUI_RPC_URL = "https://fullnode.testnet.sui.io:443";
process.env.SUI_PRIVATE_KEY = "suiprivkey-test";
process.env.SUI_PACKAGE_ID = "0xpackage";
process.env.SUI_REGISTRY_ID = "0xregistry";

vi.mock("../src/db/repositories.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/db/repositories.js")>();

  return {
    ...actual,
    listUsers: vi.fn(async () => [
      {
        userId: "user-id-1",
        domain: "acme.com",
        userEmail: "alice@acme.com",
        userWallet: "0xuser",
        adminWallet: "0xabc",
        status: "active",
        userCapId: "0xcap",
        addUserTxDigest: "add-digest",
        disableUserTxDigest: null,
        enableUserTxDigest: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        lastVerifiedAt: new Date().toISOString(),
        disabledAt: null,
      },
    ]),
    disableUser: vi.fn(async (userId) => {
      if (userId !== "user-id-1") {
        return null;
      }

      return {
        userId,
        domain: "acme.com",
        userEmail: "alice@acme.com",
        userWallet: "0xuser",
        adminWallet: "0xabc",
        status: "disabled",
        userCapId: "0xcap",
        addUserTxDigest: "add-digest",
        disableUserTxDigest: "disable-digest",
        enableUserTxDigest: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        lastVerifiedAt: new Date().toISOString(),
        disabledAt: new Date().toISOString(),
      };
    }),
    enableUser: vi.fn(async (userId) => {
      if (userId !== "user-id-1") {
        return null;
      }

      return {
        userId,
        domain: "acme.com",
        userEmail: "alice@acme.com",
        userWallet: "0xuser",
        adminWallet: "0xabc",
        status: "active",
        userCapId: "0xcap",
        addUserTxDigest: "add-digest",
        disableUserTxDigest: "disable-digest",
        enableUserTxDigest: "enable-digest",
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        lastVerifiedAt: new Date().toISOString(),
        disabledAt: null,
      };
    }),
  };
});

const { buildApp } = await import("../src/app.js");

describe("admin routes", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("requires the admin API key", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/admin/users",
    });

    expect(response.statusCode).toBe(401);
    await app.close();
  });

  it("requires the admin API key on a percent-encoded path", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/%61dmin/users",
    });

    expect(response.statusCode).toBe(401);
    await app.close();
  });

  it("lists users when authorized", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "GET",
      url: "/admin/users",
      headers: {
        "x-admin-api-key": "admin-key",
      },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      users: [
        {
          userId: "user-id-1",
          domain: "acme.com",
          userEmail: "alice@acme.com",
          userWallet: "0xuser",
          adminWallet: "0xabc",
          status: "active",
          userCapId: "0xcap",
          addUserTxDigest: "add-digest",
          disableUserTxDigest: null,
          enableUserTxDigest: null,
          createdAt: expect.any(String),
          updatedAt: expect.any(String),
          lastVerifiedAt: expect.any(String),
          disabledAt: null,
        },
      ],
    });

    await app.close();
  });

  it("disables a user when authorized", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/admin/users/user-id-1/disable",
      headers: {
        "x-admin-api-key": "admin-key",
      },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      message: "User disabled successfully.",
      user: {
        userId: "user-id-1",
        domain: "acme.com",
        userEmail: "alice@acme.com",
        userWallet: "0xuser",
        adminWallet: "0xabc",
        status: "disabled",
        userCapId: "0xcap",
        addUserTxDigest: "add-digest",
        disableUserTxDigest: "disable-digest",
        enableUserTxDigest: null,
        createdAt: expect.any(String),
        updatedAt: expect.any(String),
        lastVerifiedAt: expect.any(String),
        disabledAt: expect.any(String),
      },
    });

    await app.close();
  });

  it("returns 404 when disabling a missing user", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/admin/users/missing-user/disable",
      headers: {
        "x-admin-api-key": "admin-key",
      },
    });

    expect(response.statusCode).toBe(404);
    expect(response.json()).toEqual({
      error: "not_found",
      message: "No user found.",
    });

    await app.close();
  });

  it("enables a user when authorized", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/admin/users/user-id-1/enable",
      headers: {
        "x-admin-api-key": "admin-key",
      },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      message: "User enabled successfully.",
      user: {
        userId: "user-id-1",
        domain: "acme.com",
        userEmail: "alice@acme.com",
        userWallet: "0xuser",
        adminWallet: "0xabc",
        status: "active",
        userCapId: "0xcap",
        addUserTxDigest: "add-digest",
        disableUserTxDigest: "disable-digest",
        enableUserTxDigest: "enable-digest",
        createdAt: expect.any(String),
        updatedAt: expect.any(String),
        lastVerifiedAt: expect.any(String),
        disabledAt: null,
      },
    });

    await app.close();
  });

  it("returns 404 when enabling a missing user", async () => {
    const app = await buildApp();

    const response = await app.inject({
      method: "PATCH",
      url: "/admin/users/missing-user/enable",
      headers: {
        "x-admin-api-key": "admin-key",
      },
    });

    expect(response.statusCode).toBe(404);
    expect(response.json()).toEqual({
      error: "not_found",
      message: "No user found.",
    });

    await app.close();
  });
});
