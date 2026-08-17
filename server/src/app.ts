import { randomUUID } from "node:crypto";
import Fastify, { type FastifyError } from "fastify";
import rateLimit from "@fastify/rate-limit";
import { adminRoutes } from "./routes/admin.js";
import { healthRoutes } from "./routes/health.js";
import { otpRoutes } from "./routes/otp.js";

export async function buildApp() {
  const app = Fastify({
    logger: true,
  });

  // Every route handles its own expected error cases and responds directly;
  // anything that reaches this handler is an unmapped condition (a bug, an
  // unexpected dependency failure, a framework-level parsing error). Without
  // this, Fastify's default handler serializes the raw error — including
  // internal messages and, for framework-level failures, the framework's own
  // error codes — straight to an unauthenticated caller.
  app.setErrorHandler((error: FastifyError, request, reply) => {
    const correlationId = randomUUID();
    request.log.error({ err: error, correlationId }, "Unhandled request error");

    const statusCode =
      typeof error.statusCode === "number" && error.statusCode >= 400 && error.statusCode < 600
        ? error.statusCode
        : 500;
    const isClientError = statusCode < 500;

    return reply.status(statusCode).send({
      error: isClientError ? "bad_request" : "internal_error",
      message: isClientError ? "The request could not be processed." : "An unexpected error occurred.",
      correlationId,
    });
  });

  await app.register(rateLimit, {
    max: 100,
    timeWindow: "1 minute",
  });

  await app.register(healthRoutes);
  await app.register(adminRoutes);
  await app.register(otpRoutes);

  return app;
}
