import { env } from "./config/env.js";
import { closePool } from "./db/pool.js";
import { buildApp } from "./app.js";
import { sponsorService } from "./routes/sponsor.js";

// Fail fast on sponsor misconfiguration (missing key, key/wallet mismatch,
// sponsor wallet equal to the admin wallet) rather than on first attestation.
if (env.SPONSOR_ENABLED) {
  await sponsorService.initialize();
}

const app = await buildApp();

const shutdown = async (signal: string) => {
  app.log.info({ signal }, "shutting down");
  sponsorService.stopMaintenance();
  await app.close();
  await closePool();
  process.exit(0);
};

process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));

await app.listen({
  host: env.HOST,
  port: env.PORT,
});

sponsorService.startMaintenance();
