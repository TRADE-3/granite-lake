import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { env } from "../config/env.js";
import { disableUser, enableUser, listUsers } from "../db/repositories.js";

export const adminRoutes: FastifyPluginAsync = async (app) => {
  app.addHook("onRequest", async (request, reply) => {
    if (!request.url.startsWith("/admin")) {
      return;
    }

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
