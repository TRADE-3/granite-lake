import { HOST, PORT } from "./constants.js";
import { buildApp } from "./app.js";

const app = await buildApp();

try {
  await app.listen({ host: HOST, port: PORT });
  app.log.info(`Verification API listening on http://${HOST}:${PORT}`);
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
