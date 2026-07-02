import type { FastifyInstance } from "fastify";
import { SUI_RPC_URL } from "../constants.js";
import { getAttestationsByWallet } from "../services/attestVerification.js";
import { AttestType } from "../types.js";

function normalizeAttestTypeQuery(value: unknown): AttestType | null | "invalid" {
  if (value === undefined || value === "") return null; // no filter = all
  if (value === "photo" || value === "attest_photo") return "attest_photo";
  if (value === "file" || value === "attest_file") return "attest_file";
  return "invalid";
}

export async function registerWalletAttestationsRoute(app: FastifyInstance): Promise<void> {
  app.get<{
    Params: { wallet: string };
    Querystring: { attest_type?: string };
  }>("/wallet-attestations/:wallet", async (request, reply) => {
    const startedAt = Date.now();
    const { wallet } = request.params;

    if (!/^0x[a-fA-F0-9]+$/.test(wallet)) {
      return reply.code(400).send({ error: "Invalid wallet address." });
    }

    const attestTypeFilter = normalizeAttestTypeQuery(request.query.attest_type);
    if (attestTypeFilter === "invalid") {
      return reply.code(400).send({
        error: "Invalid attest_type. Expected 'photo' or 'file' (omit for all).",
      });
    }

    const result = await getAttestationsByWallet(wallet, SUI_RPC_URL, attestTypeFilter ?? undefined);

    return reply.code(200).send({
      wallet,
      attestTypeFilter: attestTypeFilter ?? "all",
      pagesScanned: result.pagesScanned,
      eventsScanned: result.eventsScanned,
      photoCount: result.photoCount,
      fileCount: result.fileCount,
      events: result.events,
      durationMs: Date.now() - startedAt,
    });
  });
}
