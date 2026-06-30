import Fastify from "fastify";
import multipart from "@fastify/multipart";
import rateLimit from "@fastify/rate-limit";
import { registerVerifyPhotoRoute } from "./routes/verifyPhoto.js";

export async function buildApp() {
  const app = Fastify({ logger: true });

  await app.register(rateLimit, {
    max: 100,
    timeWindow: "1 minute",
  });

  await app.register(multipart, {
    limits: {
      fileSize: 25 * 1024 * 1024,
      files: 1,
    },
  });

  app.get("/health", async () => ({ ok: true }));

  await registerVerifyPhotoRoute(app);

  return app;
}
