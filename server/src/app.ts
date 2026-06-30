import Fastify from "fastify";
import rateLimit from "@fastify/rate-limit";
import { adminRoutes } from "./routes/admin.js";
import { healthRoutes } from "./routes/health.js";
import { otpRoutes } from "./routes/otp.js";

export async function buildApp() {
  const app = Fastify({
    logger: true,
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
