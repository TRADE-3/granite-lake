import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import * as authService from "../services/AuthService.js";
import { AuthError } from "../services/AuthService.js";
import { isTransientNetworkError } from "../services/SuiService.js";
import { Trade3Error } from "../services/Trade3Service.js";
import { VaultConnectionError } from "../services/VaultService.js";
import { requireAppApiKey } from "../utils/auth.js";
import { authRefreshLimiter, authSignInLimiter, type RateLimiter } from "../utils/rateLimit.js";
import { readBearerToken } from "../utils/userAuth.js";

const userWallet = z.string().regex(/^0x[0-9a-fA-F]{64}$/);
const challengeSchema = z.object({ userWallet });
const exchangeSchema = z.object({
  userWallet,
  nonce: z.string().min(1).max(128),
  signature: z.string().min(1).max(1024),
});
const refreshSchema = z.object({ refreshToken: z.string().min(1).max(256) });

export const authRoutes: FastifyPluginAsync = async (app) => {
  app.addHook("onRequest", async (request, reply) => {
    if (!requireAppApiKey(request, reply)) {
      return reply;
    }
  });

  const options = { bodyLimit: 16 * 1024 };

  app.post("/auth/challenge", options, async (request, reply) => {
    if (rateLimited(request, reply, authSignInLimiter, "challenge")) return reply;
    const body = challengeSchema.safeParse(request.body);
    if (!body.success) return invalidRequest(reply, "Body must contain a Sui userWallet.");

    return reply.status(201).send(await authService.createChallenge(body.data.userWallet));
  });

  app.post("/auth/exchange", options, async (request, reply) => {
    if (rateLimited(request, reply, authSignInLimiter, "exchange")) return reply;
    const body = exchangeSchema.safeParse(request.body);
    const trade3AccessToken = readBearerToken(request);
    if (!body.success || !trade3AccessToken) {
      return invalidRequest(reply, "Send a Trade3 bearer token with userWallet, nonce, and signature.");
    }

    return handleAuthErrors(request, reply, async () =>
      reply.send(await authService.exchange({ ...body.data, trade3AccessToken }))
    );
  });

  app.post("/auth/refresh", options, async (request, reply) => {
    if (rateLimited(request, reply, authRefreshLimiter, "refresh")) return reply;
    const body = refreshSchema.safeParse(request.body);
    if (!body.success) return invalidRequest(reply, "Body must contain refreshToken.");

    return handleAuthErrors(request, reply, async () => reply.send(await authService.refresh(body.data.refreshToken)));
  });

  // Succeeds for unknown tokens too, so retrying an unlink is always safe.
  app.post("/auth/logout", options, async (request, reply) => {
    if (rateLimited(request, reply, authRefreshLimiter, "logout")) return reply;
    const body = refreshSchema.safeParse(request.body);
    if (!body.success) return invalidRequest(reply, "Body must contain refreshToken.");

    await authService.logout(body.data.refreshToken);
    return reply.status(204).send();
  });
};

function invalidRequest(reply: FastifyReply, message: string) {
  return reply.status(400).send({ error: "invalid_request", message });
}

function rateLimited(request: FastifyRequest, reply: FastifyReply, limiter: RateLimiter, route: string): boolean {
  const key = `auth_${route}:${request.ip || "unknown"}`;
  if (limiter.isAllowed(key)) return false;

  const retryAfter = limiter.getRetryAfter(key);
  reply.header("Retry-After", retryAfter);
  reply.status(429).send({
    error: "rate_limit_exceeded",
    message: `Too many requests. Try again in ${retryAfter} seconds.`,
  });
  return true;
}

async function handleAuthErrors(
  request: FastifyRequest,
  reply: FastifyReply,
  fn: () => Promise<FastifyReply>
): Promise<FastifyReply> {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof AuthError) {
      return reply.status(error.statusCode).send({ error: error.code, message: error.message });
    }
    if (error instanceof Trade3Error) {
      return error.kind === "unauthorized"
        ? reply.status(401).send({ error: "trade3_unauthorized", message: error.message })
        : reply.status(502).send({ error: "trade3_unavailable", message: error.message });
    }
    if (error instanceof VaultConnectionError) {
      request.log.error({ err: error }, "Vault failed during sign-in");
      return reply.status(502).send({ error: "vault_unavailable", message: "Vault is unavailable." });
    }
    if (isTransientNetworkError(error)) {
      request.log.error({ err: error }, "Sui RPC failed during sign-in");
      return reply.status(502).send({ error: "sui_rpc_failed", message: "Network error. Try again." });
    }
    throw error;
  }
}
