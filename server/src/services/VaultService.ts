import type { AppEnv } from "../config/env.js";

type VaultRef = {
  mount: string;
  path: string;
  key: string;
};

type VaultReadResponse = {
  data?: {
    data?: Record<string, unknown>;
  };
};

type VaultLoginResponse = {
  auth?: {
    client_token?: string;
  };
};

let cachedToken: string | undefined;

export function isVaultConfigured(env: AppEnv): boolean {
  return env.VAULT_ENABLED && Boolean(env.VAULT_ADDR);
}

export function isVaultReference(value: string | undefined): boolean {
  return Boolean(value?.startsWith("vault://"));
}

export function buildSecretPath(env: AppEnv, ...parts: string[]): string {
  const prefix = env.VAULT_SECRET_PREFIX ?? `${env.NODE_ENV}/${env.CLIENT_ID}`;
  return [...prefix.split("/"), ...parts].map(toVaultPathPart).join("/");
}

export function buildVaultReference(env: AppEnv, secretPath: string, key: string): string {
  return `vault://${env.VAULT_KV_MOUNT}/${secretPath}#${key}`;
}

export async function resolveSecretValue(env: AppEnv, value: string | undefined): Promise<string | undefined> {
  if (!value || !isVaultReference(value)) return value;
  return readVaultReference(env, value);
}

async function readVaultReference(env: AppEnv, reference: string): Promise<string | undefined> {
  assertVaultReady(env);
  const ref = parseVaultReference(reference);
  const secret = await readKvSecret(env, ref.mount, ref.path);
  const value = secret[ref.key];
  return typeof value === "string" ? value : undefined;
}

async function readKvSecret(env: AppEnv, mount: string, secretPath: string): Promise<Record<string, unknown>> {
  let json: VaultReadResponse;

  try {
    json = await vaultFetch<VaultReadResponse>(env, kvDataPath(mount, secretPath), { method: "GET" });
  } catch (error) {
    if (error instanceof VaultHttpError && error.status === 404) return {};
    throw error;
  }

  return json.data?.data ?? {};
}

async function vaultFetch<T = unknown>(env: AppEnv, path: string, init: RequestInit): Promise<T> {
  const token = await getVaultToken(env);
  const headers = new Headers(init.headers);
  headers.set("X-Vault-Token", token);
  headers.set("Content-Type", "application/json");

  if (env.VAULT_NAMESPACE) {
    headers.set("X-Vault-Namespace", env.VAULT_NAMESPACE);
  }

  let res: Response;

  try {
    res = await fetch(`${env.VAULT_ADDR}/v1/${path}`, {
      ...init,
      headers,
    });
  } catch (error) {
    throw new VaultConnectionError(env.VAULT_ADDR, error);
  }

  if (!res.ok) {
    throw new VaultHttpError(path, res.status);
  }

  const text = await res.text();
  if (!text) return undefined as T;
  return JSON.parse(text) as T;
}

async function getVaultToken(env: AppEnv): Promise<string> {
  if (env.VAULT_TOKEN) return env.VAULT_TOKEN;
  if (cachedToken) return cachedToken;

  if (env.VAULT_AUTH_METHOD !== "approle") {
    throw new Error("Vault token is required when VAULT_AUTH_METHOD=token");
  }

  if (!env.VAULT_ROLE_ID || !env.VAULT_SECRET_ID) {
    throw new Error("VAULT_ROLE_ID and VAULT_SECRET_ID are required for AppRole");
  }

  const headers = new Headers({ "Content-Type": "application/json" });

  if (env.VAULT_NAMESPACE) {
    headers.set("X-Vault-Namespace", env.VAULT_NAMESPACE);
  }

  let res: Response;

  try {
    res = await fetch(`${env.VAULT_ADDR}/v1/auth/approle/login`, {
      method: "POST",
      headers,
      body: JSON.stringify({
        role_id: env.VAULT_ROLE_ID,
        secret_id: env.VAULT_SECRET_ID,
      }),
    });
  } catch (error) {
    throw new VaultConnectionError(env.VAULT_ADDR, error);
  }

  if (!res.ok) {
    throw new Error(`Vault AppRole login failed with HTTP ${res.status}`);
  }

  const json = (await res.json()) as VaultLoginResponse;
  const token = json.auth?.client_token;

  if (!token) {
    throw new Error("Vault AppRole login did not return a client token");
  }

  cachedToken = token;
  return token;
}

function parseVaultReference(reference: string): VaultRef {
  const parsed = new URL(reference);
  const mount = parsed.hostname;
  const path = parsed.pathname.replace(/^\/+/, "");
  const key = parsed.hash.replace(/^#/, "");

  if (!mount || !path || !key) {
    throw new Error(`Invalid Vault reference: ${reference}`);
  }

  return { mount, path, key };
}

function kvDataPath(mount: string, secretPath: string): string {
  return `${encodeURIComponent(mount)}/data/${secretPath.split("/").map(encodeURIComponent).join("/")}`;
}

function toVaultPathPart(value: string): string {
  return value.trim().replace(/[^a-zA-Z0-9_.=-]+/g, "_");
}

function assertVaultReady(env: AppEnv): void {
  if (!isVaultConfigured(env)) {
    throw new Error("Vault is not enabled. Set VAULT_ENABLED=true and VAULT_ADDR.");
  }
}

export class VaultConnectionError extends Error {
  constructor(
    readonly address: string | undefined,
    readonly cause: unknown
  ) {
    super(`Vault is unavailable at ${address ?? "<unset>"}.`);
  }
}

class VaultHttpError extends Error {
  constructor(
    path: string,
    readonly status: number
  ) {
    super(`Vault request failed: ${path} returned HTTP ${status}`);
  }
}
