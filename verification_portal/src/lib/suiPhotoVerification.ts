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
  graphqlCursor?: string;
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
  data?: T;
  errors?: SuiRpcError[];
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

export type WalletAttestType = "attest_photo" | "attest_file";

export type WalletAttestationRecord = {
  attestType: WalletAttestType;
  txDigest: string;
  eventSeq: string;
  packageId: string;
  timestampMs: string | null;
  checkpointTime: string;
  hashHex: string;
  projectIdRawHex: string;
  projectIdDecoded: string;
  userWallet: string;
  domain: string | null;
  domainAdminWallet: string | null;
  userEnabledAtAttestation: boolean | null;
  photoHashHex?: string;
  fileHashHex?: string;
  fileIdRawHex?: string;
  fileIdDecoded?: string;
  gpsRawHex?: string;
  gpsDecoded?: string;
  altitudeRawHex?: string;
  altitudeDecoded?: string;
};

export type WalletAttestationsResult = {
  wallet: string;
  pagesScanned: number;
  eventsScanned: number;
  photoCount: number;
  fileCount: number;
  events: WalletAttestationRecord[];
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
    const normalizedBase64 = value.trim().replace(/\s+/g, "");
    if (
      normalizedBase64.length > 0 &&
      normalizedBase64.length % 4 === 0 &&
      /^[A-Za-z0-9+/]+={0,2}$/.test(normalizedBase64)
    ) {
      try {
        const binary = atob(normalizedBase64);
        return Uint8Array.from(binary, (char) => char.charCodeAt(0));
      } catch {
        // Fall through to the existing hex / text handling.
      }
    }

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
  const response = await fetch(normalizeGraphQlUrl(SUI_RPC_URL), {
    method: "POST",
    headers: {
      "content-type": "application/json",
    },
    body: JSON.stringify(buildGraphQlRequest(method, params)),
  });

  if (!response.ok) {
    throw new Error(`Sui GraphQL request failed: ${response.status} ${response.statusText}`);
  }

  const payload = (await response.json()) as SuiRpcResponse<T>;

  if (payload.errors?.length) {
    const message = payload.errors
      .map((entry) => entry.message?.trim())
      .filter((entry): entry is string => Boolean(entry))
      .join("\n");
    throw new Error(message || "Sui GraphQL returned an error");
  }

  if (!payload.data) {
    throw new Error("Sui GraphQL returned no result payload");
  }

  return extractGraphQlResult<T>(method, payload.data as Record<string, unknown>);
}

function normalizeGraphQlUrl(url: string): string {
  const trimmed = url.trim();
  if (!trimmed) return trimmed;

  try {
    const parsed = new URL(trimmed);
    const host = parsed.host.toLowerCase();
    if (host === "fullnode.testnet.sui.io" || host === "rpc.ankr.com") {
      return "https://graphql.testnet.sui.io/graphql";
    }
    if (host === "fullnode.mainnet.sui.io") {
      return "https://graphql.mainnet.sui.io/graphql";
    }
    if (host === "fullnode.devnet.sui.io") {
      return "https://graphql.devnet.sui.io/graphql";
    }
    if (host.startsWith("graphql.") && !parsed.pathname.endsWith("/graphql")) {
      parsed.pathname = "/graphql";
      return parsed.toString();
    }
    return trimmed;
  } catch {
    return trimmed;
  }
}

function buildGraphQlRequest(method: string, params: unknown[]): { query: string; variables: Record<string, unknown> } {
  switch (method) {
    case "suix_getOwnedObjects": {
      const [ownerAddress, queryOptions, cursor, limit] = params as [
        string,
        { filter?: { StructType?: string } },
        string | null,
        number | undefined,
      ];
      return {
        query: `query($address:SuiAddress!,$type:String!,$first:Int!,$after:String){
          address(address:$address){
            objects(first:$first, after:$after, filter:{ type:$type }){
              pageInfo { hasNextPage endCursor }
              nodes {
                address
                contents {
                  type { repr }
                  json
                }
              }
            }
          }
        }`,
        variables: {
          address: ownerAddress,
          type: queryOptions?.filter?.StructType ?? "",
          first: typeof limit === "number" ? limit : 50,
          after: cursor,
        },
      };
    }
    case "suix_queryEvents": {
      const [filter, cursor, limit] = params as [
        { MoveEventType?: string },
        SuiEventCursor | null,
        number | undefined,
        boolean | undefined,
      ];
      return {
        query: `query($type:String!,$first:Int!,$after:String){
          events(first:$first, after:$after, filter:{ type:$type }){
            pageInfo { hasNextPage endCursor }
            nodes {
              sequenceNumber
              timestamp
              sender { address }
              transaction { digest }
              transactionModule { name package { address } }
              contents {
                type { repr }
                json
              }
            }
          }
        }`,
        variables: {
          type: filter.MoveEventType ?? "",
          first: typeof limit === "number" ? limit : 50,
          after: encodeEventCursor(cursor),
        },
      };
    }
    default:
      throw new Error(`Unsupported GraphQL migration path for method ${method}`);
  }
}

function extractGraphQlResult<T>(method: string, data: Record<string, unknown>): T {
  switch (method) {
    case "suix_getOwnedObjects":
      return mapOwnedObjectsGraphQlResult(data) as T;
    case "suix_queryEvents":
      return mapEventsGraphQlResult(data) as T;
    default:
      throw new Error(`Unsupported GraphQL result mapping for method ${method}`);
  }
}

function mapOwnedObjectsGraphQlResult(data: Record<string, unknown>): { data?: OwnedObjectResponse[] } {
  const address = asRecord(data.address);
  const objects = asRecord(address?.objects);
  const nodes = asArray(objects?.nodes);
  return {
    data: nodes.map((node) => {
      const entry = asRecord(node);
      const contents = asRecord(entry?.contents);
      return {
        data: {
          content: {
            fields: asRecord(contents?.json) ?? undefined,
          },
        },
      };
    }),
  };
}

function mapEventsGraphQlResult(data: Record<string, unknown>): SuiEventPage {
  const events = asRecord(data.events);
  const pageInfo = asRecord(events?.pageInfo);
  const nodes = asArray(events?.nodes);
  return {
    data: nodes.map((node) => {
      const entry = asRecord(node);
      const sender = asRecord(entry?.sender);
      const transaction = asRecord(entry?.transaction);
      const module = asRecord(entry?.transactionModule);
      const modulePackage = asRecord(module?.package);
      const contents = asRecord(entry?.contents);
      return {
        id: {
          txDigest: asString(transaction?.digest),
          eventSeq: String(entry?.sequenceNumber ?? ""),
        },
        packageId: asString(modulePackage?.address),
        sender: asString(sender?.address),
        timestampMs: toTimestampMs(asString(entry?.timestamp) || undefined),
        parsedJson: asRecord(contents?.json) ?? undefined,
      } satisfies SuiEvent;
    }),
    hasNextPage: pageInfo?.hasNextPage === true,
    nextCursor: decodeEventCursor(asString(pageInfo?.endCursor) || null),
  };
}

function encodeEventCursor(cursor: SuiEventCursor | null): string | null {
  if (!cursor) return null;
  return cursor.graphqlCursor ?? null;
}

function decodeEventCursor(cursor: string | null): SuiEventCursor | null {
  if (!cursor) return null;
  return {
    txDigest: "",
    eventSeq: "",
    graphqlCursor: cursor,
  };
}

function toTimestampMs(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? String(timestamp) : undefined;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
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

function normalizeWalletAddress(value: string): string {
  return normalizeHex(value);
}

function matchesWallet(event: SuiEvent, wallet: string): boolean {
  const target = normalizeWalletAddress(wallet);
  const senderMatches = normalizeWalletAddress(event.sender) === target;
  const parsedWallet = safeAddress(event.parsedJson?.user_wallet);
  const parsedMatches = parsedWallet ? normalizeWalletAddress(parsedWallet) === target : false;
  return senderMatches || parsedMatches;
}

function toWalletPhotoRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): WalletAttestationRecord | null {
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
    attestType: "attest_photo",
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    packageId: event.packageId,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    hashHex: hash,
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

function toWalletFileRecord(
  event: SuiEvent,
  domain: string | null,
  domainAdminWallet: string | null,
  enabled: boolean | null
): WalletAttestationRecord | null {
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
    attestType: "attest_file",
    txDigest: event.id.txDigest,
    eventSeq: event.id.eventSeq,
    packageId: event.packageId,
    timestampMs,
    checkpointTime: timestampMs ? new Date(Number(timestampMs)).toLocaleString() : "Unavailable",
    hashHex: hash,
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

export async function getWalletAttestationsByWallet(options: {
  wallet: string;
  onProgress?: (progress: ScanProgress) => void;
}): Promise<WalletAttestationsResult> {
  const wallet = options.wallet.trim();
  const collected: Array<{ attestType: WalletAttestType; event: SuiEvent }> = [];
  const seen = new Set<string>();
  let pagesScanned = 0;
  let eventsScanned = 0;

  const scanTypes: Array<{ eventType: string; attestType: WalletAttestType }> = [
    ...PHOTO_ATTESTED_EVENT_TYPES.map((eventType) => ({ eventType, attestType: "attest_photo" as const })),
    ...FILE_ATTESTED_EVENT_TYPES.map((eventType) => ({ eventType, attestType: "attest_file" as const })),
  ];

  for (const { eventType, attestType } of scanTypes) {
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
        if (!matchesWallet(event, wallet)) {
          continue;
        }

        const key = `${event.id.txDigest}:${event.id.eventSeq}:${attestType}`;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        collected.push({ attestType, event });
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  if (collected.length === 0) {
    return {
      wallet,
      pagesScanned,
      eventsScanned,
      photoCount: 0,
      fileCount: 0,
      events: [],
    };
  }

  const domain = await getDomainFromUserCap(wallet);
  const domainAdminWallet = await getDomainAdminWallet(domain);

  const events: WalletAttestationRecord[] = [];
  for (const item of collected) {
    const enabled = await getEnabledAtAttestation({
      userWallet: wallet,
      domain,
      attestationTimestampMs: Number(item.event.timestampMs ?? 0),
    });

    const record =
      item.attestType === "attest_photo"
        ? toWalletPhotoRecord(item.event, domain, domainAdminWallet, enabled)
        : toWalletFileRecord(item.event, domain, domainAdminWallet, enabled);

    if (record) {
      events.push(record);
    }
  }

  events.sort((left, right) => Number(right.timestampMs ?? 0) - Number(left.timestampMs ?? 0));

  return {
    wallet,
    pagesScanned,
    eventsScanned,
    photoCount: events.filter((event) => event.attestType === "attest_photo").length,
    fileCount: events.filter((event) => event.attestType === "attest_file").length,
    events,
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
