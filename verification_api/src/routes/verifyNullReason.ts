import type { FastifyInstance } from "fastify";
import { reasonMatchesHash } from "../services/attestVerification.js";

type VerifyNullReasonBody = {
  reasonText?: unknown;
  onChainHashHex?: unknown;
};

// Checks a disclosed plaintext null-reason (for a missing/overridden
// internet or GPS field, see the offline-capture design doc §4b) against
// the on-chain internetNullReasonHashHex/gpsNullReasonHashHex already
// present on an AttestationRecord from /verify-attestation or
// /wallet-attestations/:wallet. The reason text itself is never stored
// on-chain, so this is the only way to confirm a disclosed reason is
// genuine rather than made up after the fact. Kept as its own endpoint,
// separate from /verify-attestation: the photo/file upload there is always
// compulsory, while a reason disclosure is optional and checked
// independently, on demand, against whichever hash the caller already has.
export async function registerVerifyNullReasonRoute(app: FastifyInstance): Promise<void> {
  app.post<{ Body: VerifyNullReasonBody }>("/verify-null-reason", async (request, reply) => {
    const { reasonText, onChainHashHex } = request.body ?? {};

    if (typeof reasonText !== "string" || reasonText.length === 0) {
      return reply.code(400).send({ error: "Missing or invalid reasonText." });
    }
    if (typeof onChainHashHex !== "string" || onChainHashHex.length === 0) {
      return reply.code(400).send({
        error:
          "Missing or invalid onChainHashHex. Pass internetNullReasonHashHex or gpsNullReasonHashHex from an attestation record.",
      });
    }

    const matches = reasonMatchesHash(reasonText, onChainHashHex);

    return reply.code(200).send({ matches });
  });
}
