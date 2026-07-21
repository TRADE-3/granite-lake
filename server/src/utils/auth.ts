import type { FastifyReply, FastifyRequest } from "fastify";
import { env } from "../config/env.js";

export function requireAppApiKey(request: FastifyRequest, reply: FastifyReply): boolean {
  const apiKey = request.headers["x-app-api-key"];

  if (apiKey !== env.APP_API_KEY) {
    reply.status(401).send({
      error: "unauthorized",
      message: "Invalid app API key.",
    });

    return false;
  }

  return true;
}
