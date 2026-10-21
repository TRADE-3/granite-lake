import "dotenv/config";
import { z } from "zod";

const booleanFromEnv = z.preprocess((value) => {
  if (typeof value !== "string") return value;
  if (value.toLowerCase() === "true") return true;
  if (value.toLowerCase() === "false") return false;
  return value;
}, z.boolean());

const blankStringToUndefined = (value: unknown) => {
  if (value === "") return undefined;
  return value;
};

const optionalUrlFromEnv = z.preprocess(blankStringToUndefined, z.string().url().optional());

const optionalStringFromEnv = z.preprocess(blankStringToUndefined, z.string().optional());

const vaultAuthMethodFromEnv = z.preprocess(blankStringToUndefined, z.enum(["token", "approle"]).default("token"));

const domainSchema = z
  .string()
  .regex(/^[a-zA-Z0-9.-]+$/)
  .optional();

// emailDomain -> registeredDomain, e.g. "tr3.io:trade3.io".
const emailDomainAliasesSchema = z
  .string()
  .default("")
  .refine((val) => {
    if (!val) return true;

    return val
      .split(",")
      .map((pair) => pair.trim())
      .filter(Boolean)
      .every((pair) => {
        const parts = pair.split(":").map((part) => part.trim());
        return parts.length === 2 && parts.every((d) => domainSchema.safeParse(d).success);
      });
  }, "EMAIL_DOMAIN_ALIASES must be a comma-separated list of emailDomain:registeredDomain pairs")
  .transform((val) => {
    const aliases: Record<string, string> = {};

    for (const pair of val
      .split(",")
      .map((p) => p.trim())
      .filter(Boolean)) {
      const [emailDomain, registeredDomain] = pair.split(":").map((p) => p.trim().toLowerCase());
      aliases[emailDomain] = registeredDomain;
    }

    return aliases;
  });

const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "staging", "production"]).default("development"),
  PORT: z.coerce.number().int().positive().default(8080),
  HOST: z.string().default("0.0.0.0"),
  CLIENT_ID: z.string().min(1),
  DOMAINS: z
    .string()
    .min(1)
    .refine((val) => {
      const domains = val.split(",").map((d) => d.trim());
      return domains.every((d) => domainSchema.safeParse(d).success);
    })
    .transform((val) => val.split(",").map((d) => d.trim())),
  EMAIL_DOMAIN_ALIASES: emailDomainAliasesSchema,
  ADMIN_WALLET: z.string().min(1),
  ADMIN_API_KEY: z.string().min(1),
  APP_API_KEY: z.string().min(1),
  POSTGRES_USER: z.string().min(1).default("postgres"),
  POSTGRES_PASSWORD: z.string().min(1).default("postgres"),
  POSTGRES_HOST: z.string().min(1).default("db"),
  POSTGRES_PORT: z.coerce.number().int().positive().default(5432),
  POSTGRES_DB: z.string().min(1).optional(),
  GOOGLE_CHAT_WEBHOOK_URL: z.string().default(""),
  SUI_NETWORK: z.enum(["mainnet", "testnet", "devnet", "localnet"]).default("testnet"),
  SUI_RPC_URL: z.string().url(),
  SUI_PRIVATE_KEY: z.string().default(""),
  SUI_PACKAGE_ID: z.string().default(""),
  SUI_MODULE: z.string().default("photo_attestation"),
  SUI_REGISTRY_ID: z.string().default(""),
  SUI_GAS_BUDGET: z.coerce.number().int().positive().default(10_000_000),
  VAULT_ENABLED: booleanFromEnv.default(false),
  VAULT_ADDR: optionalUrlFromEnv,
  VAULT_TOKEN: optionalStringFromEnv,
  VAULT_NAMESPACE: optionalStringFromEnv,
  VAULT_AUTH_METHOD: vaultAuthMethodFromEnv,
  VAULT_ROLE_ID: optionalStringFromEnv,
  VAULT_SECRET_ID: optionalStringFromEnv,
  VAULT_KV_MOUNT: z.string().default("secret"),
  VAULT_SECRET_PREFIX: optionalStringFromEnv,
  OTP_TTL_MS: z.coerce
    .number()
    .int()
    .positive()
    .default(5 * 60 * 1000),
  // Domain-sponsored attestation gas; see design/granite-lake-sponsored-transactions-design.md.
  SPONSOR_ENABLED: booleanFromEnv.default(false),
  SPONSOR_PRIVATE_KEY: z.string().default(""),
  SPONSOR_WALLET: z.string().default(""),
  SPONSOR_MAX_GAS_BUDGET_MIST: z.coerce.bigint().positive().default(50_000_000n),
  SPONSOR_MAX_GAS_PRICE_MIST: z.coerce.bigint().positive().default(1_000n),
  SPONSOR_TX_PER_USER_PER_DAY: z.coerce.number().int().nonnegative().default(200),
  SPONSOR_GAS_PER_USER_PER_DAY_MIST: z.coerce.bigint().nonnegative().default(1_000_000_000n),
  SPONSOR_TX_PER_DOMAIN_PER_DAY: z.coerce.number().int().nonnegative().default(5_000),
  SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST: z.coerce.bigint().nonnegative().default(50_000_000_000n),
  SPONSOR_PREPARE_TTL_MS: z.coerce
    .number()
    .int()
    .positive()
    .default(5 * 60 * 1000),
  SPONSOR_MIN_BALANCE_MIST: z.coerce.bigint().nonnegative().default(1_000_000_000n),
  SPONSOR_LEAK_CHECK_INTERVAL_MS: z.coerce
    .number()
    .int()
    .positive()
    .default(15 * 60 * 1000),
  // Coins held by the sponsor above this are swept into its address balance
  // (the only place sponsored gas is paid from).
  SPONSOR_COIN_SWEEP_MIN_MIST: z.coerce.bigint().positive().default(100_000_000n),
  // Daily ceiling on admin-wallet -> sponsor top-ups via POST /admin/sponsor/top-up.
  SPONSOR_TOPUP_MAX_PER_DAY_MIST: z.coerce.bigint().nonnegative().default(10_000_000_000n),
});

const parsedEnv = envSchema.parse(process.env);
const postgresDb =
  parsedEnv.POSTGRES_DB ?? `${parsedEnv.NODE_ENV}_${toIdentifierPart(parsedEnv.CLIENT_ID)}_granite_lake`;

export const env = {
  ...parsedEnv,
  POSTGRES_DB: postgresDb,
  DATABASE_URL: `postgres://${encodeURIComponent(parsedEnv.POSTGRES_USER)}:${encodeURIComponent(parsedEnv.POSTGRES_PASSWORD)}@${parsedEnv.POSTGRES_HOST}:${parsedEnv.POSTGRES_PORT}/${postgresDb}`,
};
console.log(env.DOMAINS);

export type AppEnv = typeof env;

function toIdentifierPart(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9_]/g, "_");
}
