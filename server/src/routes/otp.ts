import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { env } from "../config/env.js";
import {
  completeOtpSession,
  createOtpSession,
  findOtpSession,
} from "../db/repositories.js";

const otpRequestSchema = z.object({
  domain: z.string().min(1),
  user_email: z.string().email(),
});

const otpVerifySchema = z.object({
  userId: z.string().min(1),
  otp: z.string().min(1),
  domain: z.string().min(1),
  userWallet: z.string().min(1),
});

export const otpRoutes: FastifyPluginAsync = async (app) => {
  app.post("/otp/request", async (request, reply) => {
    const parsedBody = otpRequestSchema.safeParse(
      parseJsonStringBody(request.body),
    );

    if (!parsedBody.success) {
      return reply.status(400).send({
        error: "invalid_request",
        message:
          "Request body must be a JSON object with domain and user_email.",
      });
    }

    const body = parsedBody.data;

    if (emailDomain(body.user_email) !== env.DOMAIN.trim().toLowerCase()) {
      return reply.status(400).send({
        error: "invalid_email_domain",
        message: `user_email must belong to ${env.DOMAIN}.`,
      });
    }

    let session;

    try {
      session = await createOtpSession({
        domain: body.domain,
        userEmail: body.user_email,
        ttlMs: env.OTP_TTL_MS,
      });
    } catch (error) {
      if (
        error instanceof Error &&
        error.message.includes("is already registered")
      ) {
        return reply.status(409).send({
          error: "user_email_exists",
          message: error.message,
        });
      }

      throw error;
    }

    return reply.status(201).send({
      userId: session.userId,
      expiresAt: session.expiresAt,
      domain: session.domain,
      userEmail: session.userEmail,
    });
  });

  app.get("/otp/:userId", async (request, reply) => {
    const userId = z
      .string()
      .min(1)
      .parse((request.params as { userId: string }).userId);
    const session = await findOtpSession(userId);

    if (!session) {
      return reply.status(404).send({
        error: "not_found",
        message: "No OTP session found.",
      });
    }

    return {
      userId: session.userId,
      domain: session.domain,
      userEmail: session.userEmail,
      userWallet: session.userWallet,
      adminWallet: session.adminWallet,
      txDigest: session.txDigest,
      userCapId: session.userCapId,
      status: session.status,
      createdAt: session.createdAt,
      expiresAt: session.expiresAt,
      verifiedAt: session.verifiedAt,
      error: session.error,
    };
  });

  app.post("/otp/verify", async (request, reply) => {
    const parsedBody = otpVerifySchema.safeParse(
      parseJsonStringBody(request.body),
    );

    if (!parsedBody.success) {
      return reply.status(400).send({
        error: "invalid_request",
        message:
          "Request body must be a JSON object with userId, otp, domain, and userWallet.",
      });
    }

    const body = parsedBody.data;

    let session;

    try {
      session = await completeOtpSession(body);
    } catch (error) {
      if (error instanceof Error) {
        if (error.message === "OTP already used.") {
          return reply.status(409).send({
            error: "otp_already_used",
            message: error.message,
          });
        }

        if (
          error.message === "OTP is invalid." ||
          error.message === "OTP expired." ||
          error.message === "userWallet must be a Sui address." ||
          error.message === "userWallet does not match the OTP session." ||
          error.message.startsWith("This container is configured for")
        ) {
          return reply.status(400).send({
            error: "otp_verification_failed",
            message: error.message,
          });
        }

        if (error.message.startsWith("No OTP session for")) {
          return reply.status(404).send({
            error: "not_found",
            message: error.message,
          });
        }
      }

      throw error;
    }

    return reply.send({
      userId: session.userId,
      domain: session.domain,
      userWallet: session.userWallet,
      txDigest: session.txDigest,
      userCapId: session.userCapId,
      status: session.status,
      verifiedAt: session.verifiedAt,
    });
  });
};

function emailDomain(email: string): string {
  const normalized = email.trim().toLowerCase();
  const atIndex = normalized.lastIndexOf("@");

  return atIndex === -1 ? "" : normalized.slice(atIndex + 1);
}

function parseJsonStringBody(body: unknown): unknown {
  if (typeof body !== "string") {
    return body;
  }

  try {
    return JSON.parse(body);
  } catch {
    return body;
  }
}
