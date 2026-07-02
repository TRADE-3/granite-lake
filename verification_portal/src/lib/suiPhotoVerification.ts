import {
  FILE_ATTESTED_EVENT_TYPES,
  DOMAIN_ADDED_EVENT_TYPE,
  GRANITE_LAKE_PACKAGE_ID,
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  PHOTO_ATTESTED_EVENT_TYPES,
  SUI_RPC_URL,
  USER_CAP_TYPE,
  USER_CAP_TYPE_ORIGINAL,
  USER_DISABLED_EVENT_TYPE,
  USER_ENABLED_EVENT_TYPE,
} from "../constants";

type SuiEventCursor = {
  txDigest: string;
  eventSeq: string;
};

type SuiEvent = {
  id: SuiEventCursor;
  packageId: string;
  sender: string;
  timestampMs?: string;
  parsedJson?: Record<string, unknown>;
};

type SuiEventPage = {
  data?: SuiEvent[];
  hasNextPage?: boolean;
  nextCursor?: SuiEventCursor | null;
};

type OwnedObjectContent = {
  dataType?: string;
  type?: string;
  fields?: Record<string, unknown>;
};

type OwnedObjectResponse = {
  data?: {
    content?: OwnedObjectContent;
  };
};

type SuiRpcError = {
  message?: string;
};

type SuiRpcResponse<T> = {
  result?: T;
  error?: SuiRpcError;
};

export type ScanProgress = {
  pagesScanned: number;
  eventsScanned: number;
};

export type PhotoAttestationRecord = {
  txDigest: string;
  eventSeq: string;
  timestampMs: string | null;
  checkpointTime: string;
  photoHashHex: string;
  gpsRawHex: string;
  gpsDecoded: string;
  altitudeRawHex: string;
  altitudeDecoded: string;
  projectIdRawHex: string;
  projectIdDecoded: string;
  userWallet: string;
  domain: string | null;
  domainAdminWallet: string | null;
  userEnabledAtAttestation: boolean | null;
};

export type FileAttestationRecord = {
  txDigest: string;
  eventSeq: string;
  timestampMs: string | null;
  checkpointTime: string;
  fileHashHex: string;
  fileIdRawHex: string;
  fileIdDecoded: string;
  projectIdRawHex: string;
  projectIdDecoded: string;
  userWallet: string;
  domain: string | null;
  domainAdminWallet: string | null;
  userEnabledAtAttestation: boolean | null;
};

export type VerificationResult =
  | {
      hasMatch: false;
      progress: ScanProgress;
    }
  | {
      hasMatch: true;
      progress: ScanProgress;
      record: PhotoAttestationRecord;
    };

export type FileVerificationResult =
  | {
      hasMatch: false;
      progress: ScanProgress;
    }
  | {
      hasMatch: true;
      progress: ScanProgress;
      record: FileAttestationRecord;
    };

function normalizeHex(value: string): string {
  return value.toLowerCase().replace(/^0x/, "");
}

function isByteArray(value: unknown): value is number[] {
  return Array.isArray(value) && value.every((item) => Number.isInteger(item) && item >= 0 && item <= 255);
}

function parseVectorU8(value: unknown): Uint8Array | null {
  if (value instanceof Uint8Array) return value;

  if (isByteArray(value)) {
    return new Uint8Array(value);
  }

  if (typeof value === "string") {
    const normalized = normalizeHex(value);
    if (/^[a-f0-9]+$/i.test(normalized) && normalized.length % 2 === 0) {
      const bytes = normalized.match(/.{1,2}/g)?.map((byte) => parseInt(byte, 16)) ?? [];
      return new Uint8Array(bytes);
    }

    return new TextEncoder().encode(value);
  }

  if (typeof value === "object" && value && "bytes" in value) {
    const bytes = (value as { bytes?: unknown }).bytes;
    if (isByteArray(bytes)) {
      return new Uint8Array(bytes);
    }
  }

  return null;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

function tryDecodeUtf8(bytes: Uint8Array): string {
  if (bytes.length === 0) return "";
  try {
    const decoded = new TextDecoder().decode(bytes);
    return decoded.trim();
  } catch {
    return "";
  }
}

function decodeVector(value: unknown): { hex: string; decoded: string } {
  const bytes = parseVectorU8(value);
  if (!bytes) return { hex: "", decoded: "" };

  const hex = bytesToHex(bytes);
  const decoded = tryDecodeUtf8(bytes);
  return { hex, decoded };
}

function decodePhotoHash(value: unknown): string {
  const decoded = decodeVector(value);

  if (decoded.decoded) {
    const candidate = normalizeHex(decoded.decoded);
    if (/^[a-f0-9]{64}$/i.test(candidate)) {
      return candidate;
    }
  }

  const candidate = normalizeHex(decoded.hex);
  if (/^[a-f0-9]{64}$/i.test(candidate)) {
    return candidate;
  }

  return "";
}

function safeAddress(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function isAllowedPackageId(packageId: string): boolean {
  const normalized = normalizeHex(packageId);
  return (
    normalized === normalizeHex(GRANITE_LAKE_PACKAGE_ID) ||
    normalized === normalizeHex(GRANITE_LAKE_ORIGINAL_PACKAGE_ID)
  );
}

async function suiRpcCall<T>(method: string, params: unknown[]): Promise<T> {
  const response = await fetch(SUI_RPC_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method,
      params,
    }),
  });

  if (!response.ok) {
    throw new Error(`Sui RPC request failed: ${response.status} ${response.statusText}`);
  }

  const payload = (await response.json()) as SuiRpcResponse<T>;

  if (payload.error) {
    throw new Error(payload.error.message ?? "Sui RPC returned an error");
  }

  if (!payload.result) {
    throw new Error("Sui RPC returned no result payload");
  }

  return payload.result;
}

async function getDomainFromUserCap(userWallet: string): Promise<string | null> {
  const attempts = [USER_CAP_TYPE, USER_CAP_TYPE_ORIGINAL];

  for (const structType of attempts) {
    const owned = await suiRpcCall<{ data?: OwnedObjectResponse[] }>("suix_getOwnedObjects", [
      userWallet,
      {
        filter: {
          StructType: structType,
        },
        options: {
          showContent: true,
        },
      },
      null,
      10,
    ]);

    const first = owned.data?.[0]?.data?.content;
    const fields = first?.fields;
    if (!fields) {
      continue;
    }

    const domain = decodeVector(fields.domain).decoded;
    if (domain) {
      return domain;
    }
  }

  return null;
}

async function getDomainAdminWallet(domain: string | null): Promise<string | null> {
  if (!domain) {
    return null;
  }

  let cursor: SuiEventCursor | null = null;

  do {
    const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
      {
        MoveEventType: DOMAIN_ADDED_EVENT_TYPE,
      },
      cursor,
      50,
      true,
    ]);

    for (const event of page.data ?? []) {
      const parsed = event.parsedJson;
      if (!parsed) {
        continue;
      }

      const eventDomain = decodeVector(parsed.domain).decoded;
      if (eventDomain === domain) {
        const adminWallet = safeAddress(parsed.admin_wallet);
        return adminWallet || null;
      }
    }

    cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
  } while (cursor);

  return null;
}

type StatusPoint = {
  enabled: boolean;
  timestampMs: number;
};

function sameDomain(eventDomainValue: unknown, domain: string | null): boolean {
  if (!domain) return false;
  const fromEvent = decodeVector(eventDomainValue).decoded;
  return fromEvent === domain;
}

async function findLatestStatusPoint(params: {
  eventType: string;
  userWallet: string;
  domain: string | null;
  attestationTimestampMs: number;
  enabled: boolean;
}): Promise<StatusPoint | null> {
  let cursor: SuiEventCursor | null = null;

  do {
    const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
      {
        MoveEventType: params.eventType,
      },
      cursor,
      50,
      true,
    ]);

    for (const event of page.data ?? []) {
      const parsed = event.parsedJson;
      const timestamp = Number(event.timestampMs ?? 0);
      if (!parsed || !Number.isFinite(timestamp) || timestamp <= 0) {
        continue;
      }

      if (timestamp > params.attestationTimestampMs) {
        continue;
      }

      const userWallet = safeAddress(parsed.user_wallet);
      if (userWallet.toLowerCase() !== params.userWallet.toLowerCase()) {
        continue;
      }

      if (!sameDomain(parsed.domain, params.domain)) {
        continue;
      }

      return {
        enabled: params.enabled,
        timestampMs: timestamp,
      };
    }

    cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
  } while (cursor);

  return null;
}

async function getEnabledAtAttestation(params: {
  userWallet: string;
  domain: string | null;
  attestationTimestampMs: number;
}): Promise<boolean | null> {
  if (!params.domain || !Number.isFinite(params.attestationTimestampMs) || params.attestationTimestampMs <= 0) {
    return null;
  }

  const [enabledPoint, disabledPoint] = await Promise.all([
    findLatestStatusPoint({
      eventType: USER_ENABLED_EVENT_TYPE,
      userWallet: params.userWallet,
      domain: params.domain,
      attestationTimestampMs: params.attestationTimestampMs,
      enabled: true,
    }),
    findLatestStatusPoint({
      eventType: USER_DISABLED_EVENT_TYPE,
      userWallet: params.userWallet,
      domain: params.domain,
      attestationTimestampMs: params.attestationTimestampMs,
      enabled: false,
    }),
  ]);

  if (!enabledPoint && !disabledPoint) {
    return null;
  }
  if (enabledPoint && !disabledPoint) {
    return true;
  }
  if (!enabledPoint && disabledPoint) {
    return false;
  }

  return (enabledPoint?.timestampMs ?? 0) >= (disabledPoint?.timestampMs ?? 0);
}

function toRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): PhotoAttestationRecord | null {
  const parsed = event.parsedJson;
  if (!parsed) return null;

  const hash = decodePhotoHash(parsed.photo_hash);
  const gps = decodeVector(parsed.gps);
  const altitude = decodeVector(parsed.altitude);
  const projectId = decodeVector(parsed.project_id);
  const userWallet = safeAddress(parsed.user_wallet);

  if (!hash || !userWallet) {
    return null;
  }

  const timestampMs = event.timestampMs ?? null;

  return {
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    photoHashHex: hash,
    gpsRawHex: gps.hex,
    gpsDecoded: gps.decoded,
    altitudeRawHex: altitude.hex,
    altitudeDecoded: altitude.decoded,
    projectIdRawHex: projectId.hex,
    projectIdDecoded: projectId.decoded,
    userWallet,
    domain,
    domainAdminWallet,
    userEnabledAtAttestation: enabled,
  };
}

function toFileRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): FileAttestationRecord | null {
  const parsed = event.parsedJson;
  if (!parsed) return null;

  const hash = decodePhotoHash(parsed.file_hash);
  const fileId = decodeVector(parsed.file_id);
  const projectId = decodeVector(parsed.project_id);
  const userWallet = safeAddress(parsed.user_wallet);

  if (!hash || !userWallet) {
    return null;
  }

  const timestampMs = event.timestampMs ?? null;

  return {
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    fileHashHex: hash,
    fileIdRawHex: fileId.hex,
    fileIdDecoded: fileId.decoded,
    projectIdRawHex: projectId.hex,
    projectIdDecoded: projectId.decoded,
    userWallet,
    domain,
    domainAdminWallet,
    userEnabledAtAttestation: enabled,
  };
}

export async function verifyPhotoHash(options: {
  photoHashHex: string;
  onProgress?: (progress: ScanProgress) => void;
}): Promise<VerificationResult> {
  const targetHash = normalizeHex(options.photoHashHex);
  let pagesScanned = 0;
  let eventsScanned = 0;

  for (const eventType of PHOTO_ATTESTED_EVENT_TYPES) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
        {
          MoveEventType: eventType,
        },
        cursor,
        50,
        true,
      ]);

      pagesScanned += 1;
      eventsScanned += page.data?.length ?? 0;
      options.onProgress?.({ pagesScanned, eventsScanned });

      for (const event of page.data ?? []) {
        if (!isAllowedPackageId(event.packageId)) {
          continue;
        }

        const parsed = event.parsedJson;
        const eventPhotoHash = decodePhotoHash(parsed?.photo_hash);
        if (!eventPhotoHash || normalizeHex(eventPhotoHash) !== targetHash) {
          continue;
        }

        const userWallet = safeAddress(parsed?.user_wallet);
        if (!userWallet) {
          continue;
        }

        const domain = await getDomainFromUserCap(userWallet);
        const domainAdminWallet = await getDomainAdminWallet(domain);
        const enabled = await getEnabledAtAttestation({
          userWallet,
          domain,
          attestationTimestampMs: Number(event.timestampMs ?? 0),
        });

        const record = toRecord(event, domain, domainAdminWallet, enabled);
        if (!record) {
          continue;
        }

        return {
          hasMatch: true,
          progress: { pagesScanned, eventsScanned },
          record,
        };
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  return {
    hasMatch: false,
    progress: { pagesScanned, eventsScanned },
  };
}

export async function verifyFileHash(options: {
  fileHashHex: string;
  onProgress?: (progress: ScanProgress) => void;
}): Promise<FileVerificationResult> {
  const targetHash = normalizeHex(options.fileHashHex);
  let pagesScanned = 0;
  let eventsScanned = 0;

  for (const eventType of FILE_ATTESTED_EVENT_TYPES) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>("suix_queryEvents", [
        {
          MoveEventType: eventType,
        },
        cursor,
        50,
        true,
      ]);

      pagesScanned += 1;
      eventsScanned += page.data?.length ?? 0;
      options.onProgress?.({ pagesScanned, eventsScanned });

      for (const event of page.data ?? []) {
        if (!isAllowedPackageId(event.packageId)) {
          continue;
        }

        const parsed = event.parsedJson;
        const eventFileHash = decodePhotoHash(parsed?.file_hash);
        if (!eventFileHash || normalizeHex(eventFileHash) !== targetHash) {
          continue;
        }

        const userWallet = safeAddress(parsed?.user_wallet);
        if (!userWallet) {
          continue;
        }

        const domain = await getDomainFromUserCap(userWallet);
        const domainAdminWallet = await getDomainAdminWallet(domain);
        const enabled = await getEnabledAtAttestation({
          userWallet,
          domain,
          attestationTimestampMs: Number(event.timestampMs ?? 0),
        });

        const record = toFileRecord(event, domain, domainAdminWallet, enabled);
        if (!record) {
          continue;
        }

        return {
          hasMatch: true,
          progress: { pagesScanned, eventsScanned },
          record,
        };
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  return {
    hasMatch: false,
    progress: { pagesScanned, eventsScanned },
  };
}
