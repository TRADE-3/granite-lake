import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { env } from "../config/env.js";
import {
  disableUser,
  enableUser,
  findOrphanedCompletedOtpSessions,
  findUserBy,
  listUsers,
} from "../db/repositories.js";
import { SponsorError } from "../services/SponsorService.js";
import { SponsorFundingService } from "../services/SponsorFundingService.js";
import { sponsorService } from "./sponsor.js";

export const sponsorFundingService = new SponsorFundingService(env, sponsorService);

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

  // GET /admin/users/lookup?by=email|employeeId|wallet&value=...
  // `by` says which identifier `value` is. "employeeId" is the user's
  // userId; no separate employee-ID column exists.
  app.get("/admin/users/lookup", async (request, reply) => {
    const query = z
      .object({
        by: z.enum(["email", "employeeId", "wallet"]),
        value: z.string().trim().min(1),
      })
      .safeParse(request.query);

    if (!query.success) {
      return reply.status(400).send({
        error: "bad_request",
        message: "Query must include by (email | employeeId | wallet) and a non-empty value.",
      });
    }

    const user = await findUserBy(query.data.by, query.data.value);

    if (!user) {
      return reply.status(404).send({
        error: "not_found",
        message: "No user found.",
      });
    }

    return reply.send({ user });
  });

  app.get("/admin/sponsor/summary", async () => sponsorService.summary());

  // Moves SUI from the admin wallet into the sponsor's address balance,
  // within SPONSOR_TOPUP_MAX_PER_DAY_MIST. Amount is a decimal MIST string
  // (1 SUI = 1000000000) so large values don't lose precision.
  app.post("/admin/sponsor/top-up", async (request, reply) => {
    const body = z.object({ amountMist: z.string().regex(/^[1-9][0-9]{0,19}$/) }).safeParse(request.body);

    if (!body.success) {
      return reply.status(400).send({
        error: "bad_request",
        message: 'Body must be { amountMist: "<positive integer MIST>" }.',
      });
    }

    try {
      return reply.send(await sponsorFundingService.topUp(BigInt(body.data.amountMist)));
    } catch (error) {
      if (error instanceof SponsorError) {
        return reply.status(error.statusCode).send({ error: error.code, message: error.message });
      }
      throw error;
    }
  });

  // Sweeps the sponsor's coin objects into its address balance now, rather
  // than waiting for the next maintenance run.
  app.post("/admin/sponsor/sweep", async (_request, reply) => {
    try {
      return reply.send(await sponsorService.sweepCoinsIntoAddressBalance());
    } catch (error) {
      if (error instanceof SponsorError) {
        return reply.status(error.statusCode).send({ error: error.code, message: error.message });
      }
      throw error;
    }
  });

  // Lifts a pause set by the unexpected-spend check. Deliberately manual.
  app.post("/admin/sponsor/resume", async () => ({
    message: "Sponsorship resumed.",
    state: await sponsorService.resume(),
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
