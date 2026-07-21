import type { FastifyPluginAsync } from "fastify";
import { pool } from "../db/pool.js";
import { requireAppApiKey } from "../utils/auth.js";

export const healthRoutes: FastifyPluginAsync = async (app) => {
  app.addHook("onRequest", async (request, reply) => {
    if (!request.url.startsWith("/utc")) {
      return;
    }

    if (!requireAppApiKey(request, reply)) {
      return;
    }
  });

  app.get("/health", async (_request, reply) => {
    try {
      await pool.query("select 1");

      return reply.send({
        ok: true,
        service: "granite-lake-api",
        database: "up",
      });
    } catch {
      return reply.status(503).send({
        ok: false,
        service: "granite-lake-api",
        database: "down",
      });
    }
  });

  app.get("/utc", async () => ({
    utc: new Date().toISOString(),
  }));
};
