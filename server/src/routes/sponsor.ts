import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from "fastify";
import { isValidSuiAddress, isValidTransactionDigest, normalizeSuiAddress } from "@mysten/sui/utils";
import { z } from "zod";
import { env } from "../config/env.js";
import { SponsorError, SponsorService } from "../services/SponsorService.js";
import { isTransientNetworkError } from "../services/SuiService.js";
import { requireAppApiKey } from "../utils/auth.js";
import { sponsorIpLimiter, sponsorWalletLimiter } from "../utils/rateLimit.js";

export const sponsorService = new SponsorService(env);

const CAPTURED_AT_MAX_FUTURE_SKEW_MS = 5 * 60 * 1000;

const utf8Max = (maxBytes: number) =>
  z.string().refine((value) => Buffer.byteLength(value, "utf8") <= maxBytes, `must be at most ${maxBytes} UTF-8 bytes`);

const suiAddress = z
  .string()
  .trim()
  .refine((value) => isValidSuiAddress(normalizeSuiAddress(value)) && /^0x[0-9a-fA-F]{1,64}$/.test(value));

const contentHash = z.string().regex(/^[0-9a-f]{64}$/);
const nullReasonHash = z.string().regex(/^([0-9a-fA-F]{64})?$/);

// Device clocks drift, so allow a little future skew; offline captures can
// be arbitrarily old, so there is no lower bound.
const capturedAtMs = z
  .number()
  .int()
  .nonnegative()
  .refine((value) => Number.isSafeInteger(value) && value <= Date.now() + CAPTURED_AT_MAX_FUTURE_SKEW_MS);

const prepareSchema = z.discriminatedUnion("kind", [
  z.object({
    userWallet: suiAddress,
    kind: z.literal("photo"),
    args: z
      .object({
        hash: contentHash,
        gps: utf8Max(64),
        altitude: utf8Max(64),
        projectId: utf8Max(128),
        capturedAtMs,
        isOnline: z.boolean(),
        isForcedOffline: z.boolean(),
        internetNullReasonHash: nullReasonHash,
        hasGps: z.boolean(),
        isGpsForcedNull: z.boolean(),
        gpsNullReasonHash: nullReasonHash,
      })
      .strict(),
  }),
  z.object({
    userWallet: suiAddress,
    kind: z.literal("file"),
    args: z
      .object({
        hash: contentHash,
        fileId: utf8Max(128),
        projectId: utf8Max(128),
        capturedAtMs,
        isOnline: z.boolean(),
        isForcedOffline: z.boolean(),
        internetNullReasonHash: nullReasonHash,
      })
      .strict(),
  }),
]);

const submitSchema = z.object({
  userWallet: suiAddress,
  digest: z.string().refine(isValidTransactionDigest),
  userSignature: z.string().min(1).max(1024),
});

export const sponsorRoutes: FastifyPluginAsync = async (app) => {
  app.addHook("onRequest", async (request, reply) => {
    if (!requireAppApiKey(request, reply)) {
      return;
    }
  });

  app.get("/sponsor/status", async () => sponsorService.status());

  app.post("/sponsor/prepare", { bodyLimit: 16 * 1024 }, async (request, reply) => {
    if (rejectIfRateLimited(request, reply, "prepare")) return reply;

    const parsed = prepareSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({
        error: "invalid_request",
        message: "Request body must contain a valid userWallet, kind, and attestation args.",
      });
    }

    const { userWallet, ...attestation } = parsed.data;
    return handleSponsorErrors(request, reply, async () => {
      const prepared = await sponsorService.prepare({ userWallet, request: attestation });
      return reply.status(201).send(prepared);
    });
  });

  app.post("/sponsor/submit", { bodyLimit: 16 * 1024 }, async (request, reply) => {
    if (rejectIfRateLimited(request, reply, "submit")) return reply;

    const parsed = submitSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.status(400).send({
        error: "invalid_request",
        message: "Request body must contain userWallet, digest, and userSignature.",
      });
    }

    return handleSponsorErrors(request, reply, async () => {
      const result = await sponsorService.submit(parsed.data);
      return reply.status(result.status === "pending" ? 202 : 200).send(result);
    });
  });
};

function rejectIfRateLimited(request: FastifyRequest, reply: FastifyReply, route: "prepare" | "submit"): boolean {
  const ip = request.ip || (request.headers["x-forwarded-for"] as string) || "unknown";
  const body = request.body as { userWallet?: unknown } | undefined;
  const wallet = typeof body?.userWallet === "string" ? body.userWallet.trim().toLowerCase() : null;

  const checks: Array<[typeof sponsorIpLimiter, string]> = [[sponsorIpLimiter, `sponsor_${route}_ip:${ip}`]];
  if (wallet) checks.push([sponsorWalletLimiter, `sponsor_${route}_wallet:${wallet}`]);

  for (const [limiter, key] of checks) {
    if (!limiter.isAllowed(key)) {
      const retryAfter = limiter.getRetryAfter(key);
      reply.header("Retry-After", retryAfter);
      reply.status(429).send({
        error: "rate_limit_exceeded",
        message: `Too many sponsored attestation requests. Try again in ${retryAfter} seconds.`,
      });
      return true;
    }
  }

  return false;
}

async function handleSponsorErrors(
  request: FastifyRequest,
  reply: FastifyReply,
  fn: () => Promise<FastifyReply>
): Promise<FastifyReply> {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof SponsorError) {
      return reply.status(error.statusCode).send({ error: error.code, message: error.message });
    }

    if (isTransientNetworkError(error)) {
      request.log.error({ err: error }, "Sui RPC failed during sponsorship");
      return reply.status(502).send({ error: "sui_rpc_failed", message: "Network error. Try again." });
    }

    throw error;
  }
}
