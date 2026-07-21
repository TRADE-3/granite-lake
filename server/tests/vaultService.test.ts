import { afterEach, describe, expect, it, vi } from "vitest";
import { buildSecretPath, buildVaultReference, resolveSecretValue } from "../src/services/VaultService.js";
import type { AppEnv } from "../src/config/env.js";

const env = {
  NODE_ENV: "development",
  PORT: 8080,
  HOST: "0.0.0.0",
  CLIENT_ID: "domain_demo",
  DOMAIN: "domain.com",
  ADMIN_WALLET: "0xadmin",
  ADMIN_API_KEY: "admin-key",
  APP_API_KEY: "app-key",
  POSTGRES_USER: "postgres",
  POSTGRES_PASSWORD: "postgres",
  POSTGRES_HOST: "db",
  POSTGRES_PORT: 5432,
  POSTGRES_DB: "development_domain_demo_granite_lake",
  GOOGLE_CHAT_WEBHOOK_URL: "",
  SUI_NETWORK: "testnet",
  SUI_RPC_URL: "https://fullnode.testnet.sui.io:443",
  SUI_PRIVATE_KEY: "suiprivkey",
  SUI_PACKAGE_ID: "0xpackage",
  SUI_MODULE: "photo_attestation",
  SUI_REGISTRY_ID: "0xregistry",
  SUI_GAS_BUDGET: 10_000_000,
  VAULT_ENABLED: true,
  VAULT_ADDR: "http://vault:8200",
  VAULT_TOKEN: "vault-token",
  VAULT_NAMESPACE: undefined,
  VAULT_AUTH_METHOD: "token",
  VAULT_ROLE_ID: undefined,
  VAULT_SECRET_ID: undefined,
  VAULT_KV_MOUNT: "secret",
  VAULT_SECRET_PREFIX: undefined,
  OTP_TTL_MS: 300_000,
  DATABASE_URL: "postgres://postgres:postgres@db:5432/development_domain_demo_granite_lake",
} satisfies AppEnv;

describe("VaultService", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("builds and resolves fixed static SUI private key references", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ data: { data: { SUI_PRIVATE_KEY: "resolved-suiprivkey" } } }), { status: 200 })
    );

    const secretPath = buildSecretPath(env, "static");
    const reference = buildVaultReference(env, secretPath, "SUI_PRIVATE_KEY");

    await expect(resolveSecretValue(env, reference)).resolves.toBe("resolved-suiprivkey");
    expect(reference).toBe("vault://secret/development/domain_demo/static#SUI_PRIVATE_KEY");
    expect(fetch).toHaveBeenCalledWith(
      "http://vault:8200/v1/secret/data/development/domain_demo/static",
      expect.objectContaining({ method: "GET" })
    );
  });

  it("returns literal secrets without contacting Vault when Vault is disabled", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");

    await expect(
      resolveSecretValue(
        {
          ...env,
          VAULT_ENABLED: false,
          VAULT_ADDR: undefined,
          VAULT_TOKEN: undefined,
          VAULT_ROLE_ID: undefined,
          VAULT_SECRET_ID: undefined,
          VAULT_SECRET_PREFIX: undefined,
        },
        "suiprivkey-literal"
      )
    ).resolves.toBe("suiprivkey-literal");

    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("rejects Vault references when Vault is disabled or missing an address", async () => {
    await expect(
      resolveSecretValue(
        {
          ...env,
          VAULT_ENABLED: false,
          VAULT_ADDR: undefined,
        },
        "vault://secret/development/domain_demo/static#SUI_PRIVATE_KEY"
      )
    ).rejects.toThrow("Vault is not enabled");
  });
});
