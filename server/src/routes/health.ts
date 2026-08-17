import type { FastifyPluginAsync } from "fastify";
import { pool } from "../db/pool.js";
import { requireAppApiKey } from "../utils/auth.js";

export const healthRoutes: FastifyPluginAsync = async (app) => {
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

  app.get(
    "/utc",
    {
      preHandler: async (request, reply) => {
        requireAppApiKey(request, reply);
      },
    },
    async () => ({
      utc: new Date().toISOString(),
    })
  );
};
