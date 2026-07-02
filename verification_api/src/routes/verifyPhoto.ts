import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import {
  FILE_ATTESTED_EVENT_TYPE,
  FILE_ATTESTED_EVENT_TYPES,
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_PACKAGE_ID,
  GRANITE_LAKE_REGISTRY_ID,
  PHOTO_ATTESTED_EVENT_TYPE,
  PHOTO_ATTESTED_EVENT_TYPES,
  SUI_RPC_URL,
} from "../constants.js";
import { lookupGraniteTxtConsensus } from "../services/dnsLookup.js";
import { verifyAttestationHashDetailed } from "../services/photoVerification.js";
import { AttestType, VerificationResponse } from "../types.js";

function normalizeAttestType(value: string): AttestType | null {
  if (value === "attest_photo" || value === "attest_file") {
    return value;
  }

  return null;
}

export async function registerVerifyPhotoRoute(app: FastifyInstance): Promise<void> {
  async function verifyAttestationHandler(request: FastifyRequest, reply: FastifyReply) {
    const startedAt = Date.now();

    let attestType: AttestType | null = null;
    let upload: {
      fileName: string;
      mimeType: string;
      buffer: Buffer;
    } | null = null;

    for await (const part of request.parts()) {
      if (part.type === "file") {
        upload = {
          fileName: part.filename,
          mimeType: part.mimetype,
          buffer: await part.toBuffer(),
        };
        continue;
      }

      if (part.fieldname === "attest_type") {
        attestType = normalizeAttestType(String(part.value ?? ""));
      }
    }

    if (!upload) {
      return reply.code(400).send({ error: "Missing multipart file field." });
    }
    if (!attestType) {
      return reply.code(400).send({
        error: "Missing or invalid attest_type. Expected attest_photo or attest_file.",
      });
    }

    const { buffer } = upload;
    if (buffer.length === 0) {
      return reply.code(400).send({ error: "Uploaded file is empty." });
    }

    const hashHex = createHash("sha256").update(buffer).digest("hex");
    const scan = await verifyAttestationHashDetailed(attestType, hashHex, SUI_RPC_URL);
    const eventType = attestType === "attest_photo" ? PHOTO_ATTESTED_EVENT_TYPE : FILE_ATTESTED_EVENT_TYPE;
    const scannedEventTypes = attestType === "attest_photo" ? PHOTO_ATTESTED_EVENT_TYPES : FILE_ATTESTED_EVENT_TYPES;
    const attestationLabel = attestType === "attest_photo" ? "PhotoAttested" : "FileAttested";
    const requestHash = attestType === "attest_photo" ? { photoHashHex: hashHex } : { fileHashHex: hashHex };

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
        ? `${attestationLabel} hash matched and metadata was resolved.`
        : `No ${attestationLabel} event matched the provided file hash.`,
      request: {
        attestType,
        fileName: upload.fileName,
        mimeType: upload.mimeType,
        sizeBytes: buffer.length,
        hashHex,
        ...requestHash,
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
        eventType: scan.eventType ?? eventType,
        eventTypes: scannedEventTypes,
      },
      attestation: scan.record,
      userEnabledAtAttestation: scan.statusAtAttestation,
      dnsVerification,
      warnings,
      durationMs: Date.now() - startedAt,
    };

    return reply.code(200).send(response);
  }

  app.post("/verify-attestation", verifyAttestationHandler);
}
