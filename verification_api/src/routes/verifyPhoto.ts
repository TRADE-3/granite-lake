import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import {
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_PACKAGE_ID,
  GRANITE_LAKE_REGISTRY_ID,
  PHOTO_ATTESTED_EVENT_TYPE,
  SUI_RPC_URL,
} from "../constants.js";
import { lookupGraniteTxtConsensus } from "../services/dnsLookup.js";
import { verifyPhotoHashDetailed } from "../services/photoVerification.js";
import { VerificationResponse } from "../types.js";

export async function registerVerifyPhotoRoute(app: FastifyInstance): Promise<void> {
  app.post("/verify-photo", async (request, reply) => {
    const startedAt = Date.now();

    const part = await request.file();
    if (!part) {
      return reply.code(400).send({ error: "Missing multipart file field." });
    }

    const buffer = await part.toBuffer();
    if (buffer.length === 0) {
      return reply.code(400).send({ error: "Uploaded file is empty." });
    }

    const photoHashHex = createHash("sha256").update(buffer).digest("hex");
    const scan = await verifyPhotoHashDetailed(photoHashHex, SUI_RPC_URL);

    const warnings: string[] = [];

    const dnsVerification: VerificationResponse["dnsVerification"] = {
      attempted: Boolean(scan.record?.domain),
      domain: scan.record?.domain ?? null,
      lookupHost: null,
      consensusMatched: null,
      dnssecValidated: null,
      providerResults: [],
      record: null,
      attesterMatchesDomainAdminWallet: null,
      error: null,
    };

    if (scan.record?.domain) {
      try {
        const dnsResult = await lookupGraniteTxtConsensus(scan.record.domain);

        dnsVerification.lookupHost = dnsResult.lookupHost;
        dnsVerification.consensusMatched = dnsResult.consensusMatched;
        dnsVerification.dnssecValidated = dnsResult.dnssecValidated;
        dnsVerification.providerResults = dnsResult.providerResults;
        dnsVerification.record = dnsResult.record;

        if (!dnsResult.consensusMatched) {
          warnings.push(
            "DNS TXT responses were not identical across all providers; using best available attester record."
          );
        }

        const providerErrors = dnsResult.providerResults.filter((provider) => provider.error);
        if (providerErrors.length > 0) {
          warnings.push(
            `DNS provider errors observed: ${providerErrors.map((provider) => `${provider.provider}: ${provider.error}`).join("; ")}`
          );
        }

        if (scan.record.domainAdminWallet) {
          dnsVerification.attesterMatchesDomainAdminWallet =
            dnsResult.record.attester.toLowerCase() === scan.record.domainAdminWallet.toLowerCase();

          if (!dnsVerification.attesterMatchesDomainAdminWallet) {
            warnings.push("DNS attester wallet does not match on-chain domain admin wallet.");
          }
        }

        if (dnsResult.record.revoked) {
          warnings.push("DNS record indicates this attester is revoked.");
        }
      } catch (error) {
        dnsVerification.error = error instanceof Error ? error.message : String(error);
        warnings.push(`DNS verification unavailable: ${dnsVerification.error}`);
      }
    } else {
      warnings.push("Domain could not be resolved from UserCap; DNS verification skipped.");
    }

    const response: VerificationResponse = {
      hasMatch: Boolean(scan.record),
      summary: scan.record
        ? "Photo hash matched a PhotoAttested event and metadata was resolved."
        : "No PhotoAttested event matched the provided file hash.",
      request: {
        fileName: part.filename,
        mimeType: part.mimetype,
        sizeBytes: buffer.length,
        photoHashHex,
      },
      config: {
        rpcUrl: SUI_RPC_URL,
        packageId: GRANITE_LAKE_PACKAGE_ID,
        originalPackageId: GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
        registryId: GRANITE_LAKE_REGISTRY_ID,
      },
      scan: {
        pagesScanned: scan.pagesScanned,
        eventsScanned: scan.eventsScanned,
        eventType: PHOTO_ATTESTED_EVENT_TYPE,
      },
      attestation: scan.record,
      userEnabledAtAttestation: scan.statusAtAttestation,
      dnsVerification,
      warnings,
      durationMs: Date.now() - startedAt,
    };

    return reply.code(200).send(response);
  });
}
