import {
  DOMAIN_ADDED_EVENT_TYPE,
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_PACKAGE_ID,
  PHOTO_ATTESTED_EVENT_TYPE,
  SUI_RPC_URL,
  USER_CAP_TYPE,
  USER_CAP_TYPE_ORIGINAL,
  USER_DISABLED_EVENT_TYPE,
  USER_ENABLED_EVENT_TYPE,
} from "../constants.js";
import { AttestationRecord } from "../types.js";

type SuiEventCursor = {
  txDigest: string;
  eventSeq: string;
};

type SuiEvent = {
  id: SuiEventCursor;
  packageId: string;
  timestampMs?: string;
  parsedJson?: Record<string, unknown>;
};

type SuiEventPage = {
  data?: SuiEvent[];
  hasNextPage?: boolean;
  nextCursor?: SuiEventCursor | null;
};

type SuiRpcResponse<T> = {
  result?: T;
  error?: { message?: string };
};

type OwnedObjectsResult = {
  data?: Array<{
    data?: {
      objectId?: string;
      content?: {
        fields?: Record<string, unknown>;
      };
    };
  }>;
};

export type VerificationScanResult = {
  pagesScanned: number;
  eventsScanned: number;
  record: AttestationRecord | null;
  statusAtAttestation: {
    value: boolean | null;
    latestEnabledTimestampMs: number | null;
    latestDisabledTimestampMs: number | null;
  };
};

function normalizeHex(value: string): string {
  return value.toLowerCase().replace(/^0x/, "");
}

function isByteArray(value: unknown): value is number[] {
  return Array.isArray(value) && value.every((item) => Number.isInteger(item) && item >= 0 && item <= 255);
}

function parseVectorU8(value: unknown): Uint8Array | null {
  if (value instanceof Uint8Array) return value;
  if (isByteArray(value)) return new Uint8Array(value);

  if (typeof value === "string") {
    const normalized = normalizeHex(value);
    if (/^[a-f0-9]+$/i.test(normalized) && normalized.length % 2 === 0) {
      const bytes = normalized.match(/.{1,2}/g)?.map((byte) => parseInt(byte, 16)) ?? [];
      return new Uint8Array(bytes);
    }
    return new TextEncoder().encode(value);
  }

  return null;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

function decodeVector(value: unknown): { hex: string; decoded: string } {
  const bytes = parseVectorU8(value);
  if (!bytes) return { hex: "", decoded: "" };

  const hex = bytesToHex(bytes);
  let decoded = "";
  try {
    decoded = new TextDecoder().decode(bytes).trim();
  } catch {
    decoded = "";
  }

  return { hex, decoded };
}

function decodePhotoHash(value: unknown): string {
  const decoded = decodeVector(value);

  if (decoded.decoded) {
    const candidate = normalizeHex(decoded.decoded);
    if (/^[a-f0-9]{64}$/i.test(candidate)) return candidate;
  }

  const candidate = normalizeHex(decoded.hex);
  if (/^[a-f0-9]{64}$/i.test(candidate)) return candidate;

  return "";
}

function safeAddress(value: unknown): string {
  return typeof value === "string" ? value : "";
}

async function suiRpcCall<T>(method: string, params: unknown[], rpcUrl: string): Promise<T> {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });

  if (!response.ok) {
    throw new Error(`Sui RPC request failed: ${response.status} ${response.statusText}`);
  }

  const payload = (await response.json()) as SuiRpcResponse<T>;
  if (payload.error) {
    throw new Error(payload.error.message ?? "Sui RPC returned an error");
  }
  if (!payload.result) {
    throw new Error("Sui RPC returned no result");
  }

  return payload.result;
}

async function getUserCapInfo(
  userWallet: string,
  rpcUrl: string
): Promise<{ domain: string | null; userCapObjectId: string | null }> {
  for (const structType of [USER_CAP_TYPE, USER_CAP_TYPE_ORIGINAL]) {
    const owned = await suiRpcCall<OwnedObjectsResult>(
      "suix_getOwnedObjects",
      [
        userWallet,
        {
          filter: { StructType: structType },
          options: { showContent: true },
        },
        null,
        10,
      ],
      rpcUrl
    );

    for (const item of owned.data ?? []) {
      const fields = item.data?.content?.fields;
      if (!fields) continue;

      const domain = decodeVector(fields.domain).decoded;
      const userCapObjectId = item.data?.objectId ?? null;
      if (domain) {
        return {
          domain,
          userCapObjectId,
        };
      }
    }
  }

  return {
    domain: null,
    userCapObjectId: null,
  };
}

async function getDomainAdminWallet(domain: string | null, rpcUrl: string): Promise<string | null> {
  if (!domain) return null;

  let cursor: SuiEventCursor | null = null;

  do {
    const page: SuiEventPage = await suiRpcCall<SuiEventPage>(
      "suix_queryEvents",
      [{ MoveEventType: DOMAIN_ADDED_EVENT_TYPE }, cursor, 50, true],
      rpcUrl
    );

    for (const event of page.data ?? []) {
      const parsed = event.parsedJson;
      if (!parsed) continue;

      if (decodeVector(parsed.domain).decoded === domain) {
        const adminWallet = safeAddress(parsed.admin_wallet);
        return adminWallet || null;
      }
    }

    cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
  } while (cursor);

  return null;
}

async function latestStatusTimestamp(params: {
  eventType: string;
  userWallet: string;
  domain: string;
  attestationTimestampMs: number;
  rpcUrl: string;
}): Promise<number | null> {
  let cursor: SuiEventCursor | null = null;
  let latest: number | null = null;

  do {
    const page: SuiEventPage = await suiRpcCall<SuiEventPage>(
      "suix_queryEvents",
      [{ MoveEventType: params.eventType }, cursor, 50, true],
      params.rpcUrl
    );

    for (const event of page.data ?? []) {
      const parsed = event.parsedJson;
      if (!parsed) continue;

      const timestamp = Number(event.timestampMs ?? 0);
      if (!Number.isFinite(timestamp) || timestamp <= 0 || timestamp > params.attestationTimestampMs) {
        continue;
      }

      const wallet = safeAddress(parsed.user_wallet).toLowerCase();
      if (wallet !== params.userWallet.toLowerCase()) {
        continue;
      }

      const eventDomain = decodeVector(parsed.domain).decoded;
      if (eventDomain !== params.domain) {
        continue;
      }

      latest = latest === null ? timestamp : Math.max(latest, timestamp);
    }

    cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
  } while (cursor);

  return latest;
}

async function getEnabledAtAttestation(params: {
  userWallet: string;
  domain: string | null;
  attestationTimestampMs: number;
  rpcUrl: string;
}): Promise<{
  value: boolean | null;
  latestEnabledTimestampMs: number | null;
  latestDisabledTimestampMs: number | null;
}> {
  if (!params.domain || params.attestationTimestampMs <= 0) {
    return {
      value: null,
      latestEnabledTimestampMs: null,
      latestDisabledTimestampMs: null,
    };
  }

  const [latestEnabledTimestampMs, latestDisabledTimestampMs] = await Promise.all([
    latestStatusTimestamp({
      eventType: USER_ENABLED_EVENT_TYPE,
      userWallet: params.userWallet,
      domain: params.domain,
      attestationTimestampMs: params.attestationTimestampMs,
      rpcUrl: params.rpcUrl,
    }),
    latestStatusTimestamp({
      eventType: USER_DISABLED_EVENT_TYPE,
      userWallet: params.userWallet,
      domain: params.domain,
      attestationTimestampMs: params.attestationTimestampMs,
      rpcUrl: params.rpcUrl,
    }),
  ]);

  if (latestEnabledTimestampMs === null && latestDisabledTimestampMs === null) {
    return {
      value: null,
      latestEnabledTimestampMs,
      latestDisabledTimestampMs,
    };
  }

  if (latestDisabledTimestampMs === null) {
    return {
      value: true,
      latestEnabledTimestampMs,
      latestDisabledTimestampMs,
    };
  }

  if (latestEnabledTimestampMs === null) {
    return {
      value: false,
      latestEnabledTimestampMs,
      latestDisabledTimestampMs,
    };
  }

  return {
    value: latestEnabledTimestampMs >= latestDisabledTimestampMs,
    latestEnabledTimestampMs,
    latestDisabledTimestampMs,
  };
}

export async function verifyPhotoHashDetailed(
  photoHashHex: string,
  rpcUrl = SUI_RPC_URL
): Promise<VerificationScanResult> {
  const targetHash = normalizeHex(photoHashHex);
  let cursor: SuiEventCursor | null = null;
  let pagesScanned = 0;
  let eventsScanned = 0;

  do {
    const page: SuiEventPage = await suiRpcCall<SuiEventPage>(
      "suix_queryEvents",
      [{ MoveEventType: PHOTO_ATTESTED_EVENT_TYPE }, cursor, 50, true],
      rpcUrl
    );

    pagesScanned += 1;
    eventsScanned += page.data?.length ?? 0;

    for (const event of page.data ?? []) {
      const packageId = event.packageId.toLowerCase();
      const allowedPackageIds = new Set([
        GRANITE_LAKE_PACKAGE_ID.toLowerCase(),
        GRANITE_LAKE_ORIGINAL_PACKAGE_ID.toLowerCase(),
      ]);
      if (!allowedPackageIds.has(packageId)) continue;

      const parsed = event.parsedJson;
      if (!parsed) continue;

      const eventPhotoHash = decodePhotoHash(parsed.photo_hash);
      if (!eventPhotoHash || normalizeHex(eventPhotoHash) !== targetHash) {
        continue;
      }

      const userWallet = safeAddress(parsed.user_wallet);
      if (!userWallet) continue;

      const userCapInfo = await getUserCapInfo(userWallet, rpcUrl);
      const domain = userCapInfo.domain;
      const domainAdminWallet = await getDomainAdminWallet(domain, rpcUrl);
      const statusAtAttestation = await getEnabledAtAttestation({
        userWallet,
        domain,
        attestationTimestampMs: Number(event.timestampMs ?? 0),
        rpcUrl,
      });

      const gps = decodeVector(parsed.gps);
      const altitude = decodeVector(parsed.altitude);
      const projectId = decodeVector(parsed.project_id);

      const record: AttestationRecord = {
        txDigest: event.id.txDigest,
        eventSeq: event.id.eventSeq,
        packageId: event.packageId,
        eventTimestampMs: event.timestampMs ?? null,
        checkpointTimeIso: event.timestampMs ? new Date(Number(event.timestampMs)).toISOString() : null,
        userCapObjectId: userCapInfo.userCapObjectId,
        photoHashHex: eventPhotoHash,
        gpsRawHex: gps.hex,
        gpsDecoded: gps.decoded,
        altitudeRawHex: altitude.hex,
        altitudeDecoded: altitude.decoded,
        projectIdRawHex: projectId.hex,
        projectIdDecoded: projectId.decoded,
        userWallet,
        domain,
        domainAdminWallet,
      };

      return {
        pagesScanned,
        eventsScanned,
        record,
        statusAtAttestation,
      };
    }

    cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
  } while (cursor);

  return {
    pagesScanned,
    eventsScanned,
    record: null,
    statusAtAttestation: {
      value: null,
      latestEnabledTimestampMs: null,
      latestDisabledTimestampMs: null,
    },
  };
}
