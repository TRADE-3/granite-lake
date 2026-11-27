import type { FastifyReply, FastifyRequest } from "fastify";
import { env } from "../config/env.js";
import { authenticate, type AuthenticatedUser } from "../services/AuthService.js";

declare module "fastify" {
  interface FastifyRequest {
    glUser?: AuthenticatedUser;
  }
}

/**
 * Checks the GL access token on a route that already requires the app key.
 * A presented token must be valid. A missing one is allowed until
 * AUTH_REQUIRE_USER_TOKEN is on, so installed apps keep working.
 */
export async function checkUserToken(request: FastifyRequest, reply: FastifyReply) {
  const token = readBearerToken(request);

  if (!token) {
    return env.AUTH_REQUIRE_USER_TOKEN ? rejectToken(reply) : undefined;
  }

  const user = await authenticate(token);
  if (!user) return rejectToken(reply);
  request.glUser = user;
  return undefined;
}

/** For /otp/:userId routes: a token may only act on its own user. */
export async function checkOwnUserToken(request: FastifyRequest, reply: FastifyReply) {
  const rejected = await checkUserToken(request, reply);
  if (rejected) return rejected;

  const { userId } = request.params as { userId: string };
  if (request.glUser && request.glUser.userId !== userId) {
    return reply.status(403).send({ error: "forbidden", message: "This token belongs to another user." });
  }
  return undefined;
}

export function readBearerToken(request: FastifyRequest): string | null {
  const match = /^Bearer\s+(\S+)$/i.exec(request.headers.authorization ?? "");
  return match?.[1] ?? null;
}

function rejectToken(reply: FastifyReply) {
  return reply.status(401).send({ error: "invalid_token", message: "Missing or invalid access token." });
}
