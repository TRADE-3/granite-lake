import "dotenv/config";
import { z } from "zod";

const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "staging", "production"]).default("development"),
  PORT: z.coerce.number().int().positive().default(8080),
  HOST: z.string().default("0.0.0.0"),
  CLIENT_ID: z.string().min(1),
  DOMAIN: z.string().min(1),
  ADMIN_WALLET: z.string().min(1),
  ADMIN_API_KEY: z.string().min(1),
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
  OTP_TTL_MS: z.coerce
    .number()
    .int()
    .positive()
    .default(5 * 60 * 1000),
});

const parsedEnv = envSchema.parse(process.env);
const postgresDb =
  parsedEnv.POSTGRES_DB ?? `${parsedEnv.NODE_ENV}_${toIdentifierPart(parsedEnv.CLIENT_ID)}_granite_lake`;

export const env = {
  ...parsedEnv,
  POSTGRES_DB: postgresDb,
  DATABASE_URL: `postgres://${encodeURIComponent(parsedEnv.POSTGRES_USER)}:${encodeURIComponent(parsedEnv.POSTGRES_PASSWORD)}@${parsedEnv.POSTGRES_HOST}:${parsedEnv.POSTGRES_PORT}/${postgresDb}`,
};

export type AppEnv = typeof env;

function toIdentifierPart(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9_]/g, "_");
}
