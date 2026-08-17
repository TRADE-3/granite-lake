import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { env } from "../config/env.js";
import { disableUser, enableUser, findOrphanedCompletedOtpSessions, listUsers } from "../db/repositories.js";

export const adminRoutes: FastifyPluginAsync = async (app) => {
  // This hook is scoped to adminRoutes by Fastify's plugin encapsulation:
  // it only runs for requests routed to one of the endpoints registered
  // below, never for sibling plugins (health, otp). It must not re-check
  // the URL itself — request.url is the raw, possibly percent-encoded
  // request line, while routing (which already ran) matches on the
  // decoded path. A request to /%61dmin/users routes here correctly but
  // fails a raw-string "startsWith('/admin')" check, which previously
  // skipped the key check entirely for exactly the requests that needed it.
  app.addHook("onRequest", async (request, reply) => {
    const apiKey = request.headers["x-admin-api-key"];

    if (apiKey !== env.ADMIN_API_KEY) {
      return reply.status(401).send({
        error: "unauthorized",
        message: "Invalid admin API key.",
      });
    }
  });

  app.get("/admin/users", async () => ({
    users: await listUsers(),
  }));

  app.get("/admin/orphaned-sessions", async () => ({
    orphanedSessions: await findOrphanedCompletedOtpSessions(),
  }));

  app.patch("/admin/users/:userId/disable", async (request, reply) => {
    const userId = z
      .string()
      .min(1)
      .parse((request.params as { userId: string }).userId);
    const user = await disableUser(userId);

    if (!user) {
      return reply.status(404).send({
        error: "not_found",
        message: "No user found.",
      });
    }

    return reply.send({
      message: "User disabled successfully.",
      user,
    });
  });

  app.patch("/admin/users/:userId/enable", async (request, reply) => {
    const userId = z
      .string()
      .min(1)
      .parse((request.params as { userId: string }).userId);
    const user = await enableUser(userId);

    if (!user) {
      return reply.status(404).send({
        error: "not_found",
        message: "No user found.",
      });
    }

    return reply.send({
      message: "User enabled successfully.",
      user,
    });
  });
};
