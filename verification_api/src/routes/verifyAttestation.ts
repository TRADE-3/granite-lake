import { createHash } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import {
  FILE_ATTESTED_EVENT_TYPES,
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_PACKAGE_ID,
  GRANITE_LAKE_REGISTRY_ID,
  PHOTO_ATTESTED_EVENT_TYPES,
  SUI_RPC_URL,
} from "../constants.js";
import { lookupGraniteTxtConsensus } from "../services/dnsLookup.js";
import { verifyAttestationHashDetailed } from "../services/attestVerification.js";
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
    const scannedEventTypes = attestType === "attest_photo" ? PHOTO_ATTESTED_EVENT_TYPES : FILE_ATTESTED_EVENT_TYPES;
    const attestationLabel = attestType === "attest_photo" ? "PhotoAttested" : "FileAttested";
    const requestHash = attestType === "attest_photo" ? { photoHashHex: hashHex } : { fileHashHex: hashHex };

    const warnings: string[] = [];
    const distinctWallets = new Set(scan.records.map((record) => record.userWallet.toLowerCase()));
    // The contract accepts this hash from any enabled capability with no
    // link to file ownership, so more than one distinct wallet attesting the
    // same hash is a genuine collision: there is no way to tell which one is
    // "right", so every candidate is returned instead of picking a winner.
    const collision = distinctWallets.size > 1;

    let dnsVerification: VerificationResponse["dnsVerification"] = null;
    let trustFailed = false;
    const resolvedRecord = collision ? null : (scan.records[0] ?? null);

    if (collision) {
      warnings.push(
        `${distinctWallets.size} distinct wallets have attested this hash: ${Array.from(distinctWallets).join(", ")}. See attestations for every candidate; none has been picked automatically.`
      );
    } else if (resolvedRecord?.domain) {
      dnsVerification = {
        attempted: true,
        domain: resolvedRecord.domain,
        lookupHost: null,
        consensusMatched: null,
        dnssecValidated: null,
        providerResults: [],
        record: null,
        attesterMatchesDomainAdminWallet: null,
        error: null,
      };

      try {
        const dnsResult = await lookupGraniteTxtConsensus(resolvedRecord.domain);

        dnsVerification.lookupHost = dnsResult.lookupHost;
        dnsVerification.consensusMatched = dnsResult.consensusMatched;
        dnsVerification.dnssecValidated = dnsResult.dnssecValidated;
        dnsVerification.providerResults = dnsResult.providerResults;
        dnsVerification.record = dnsResult.record;

        if (!dnsResult.consensusMatched) {
          trustFailed = true;
          warnings.push("DNS TXT responses were not identical across all providers; treating verification as failed.");
        }

        const providerErrors = dnsResult.providerResults.filter((provider) => provider.error);
        if (providerErrors.length > 0) {
          trustFailed = true;
          warnings.push(
            `DNS provider errors observed: ${providerErrors.map((provider) => `${provider.provider}: ${provider.error}`).join("; ")}`
          );
        }

        if (resolvedRecord.domainAdminWallet) {
          dnsVerification.attesterMatchesDomainAdminWallet =
            dnsResult.record.attester.toLowerCase() === resolvedRecord.domainAdminWallet.toLowerCase();

          if (!dnsVerification.attesterMatchesDomainAdminWallet) {
            trustFailed = true;
            warnings.push("DNS attester wallet does not match on-chain domain admin wallet.");
          }
        } else {
          trustFailed = true;
          warnings.push("No on-chain domain admin wallet was resolved for comparison.");
        }

        if (dnsResult.record.revoked) {
          trustFailed = true;
          warnings.push("DNS record indicates this attester is revoked.");
        }
      } catch (error) {
        trustFailed = true;
        dnsVerification.error = error instanceof Error ? error.message : String(error);
        warnings.push(`DNS verification unavailable: ${dnsVerification.error}`);
      }
    } else if (scan.records.length > 0) {
      warnings.push("Domain could not be resolved from UserCap; DNS verification skipped.");
    }

    const hasMatch = scan.records.length > 0 && !collision && !trustFailed;

    const response: VerificationResponse = {
      hasMatch,
      collision,
      summary:
        scan.records.length === 0
          ? `No ${attestationLabel} event matched the provided file hash.`
          : collision
            ? `${distinctWallets.size} conflicting ${attestationLabel} attestations matched this hash. See attestations.`
            : trustFailed
              ? `${attestationLabel} hash matched, but the trust check failed. See warnings.`
              : `${attestationLabel} hash matched and metadata was resolved.`,
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
        eventTypes: scannedEventTypes,
      },
      attestations: scan.records,
      dnsVerification,
      warnings,
      durationMs: Date.now() - startedAt,
    };

    return reply.code(200).send(response);
  }

  app.post("/verify-attestation", verifyAttestationHandler);
}
