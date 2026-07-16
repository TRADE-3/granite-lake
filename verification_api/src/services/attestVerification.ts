import {
  DOMAIN_ADDED_EVENT_TYPES,
  FILE_ATTESTED_EVENT_TYPES,
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_PACKAGE_ID,
  PHOTO_ATTESTED_EVENT_TYPES,
  SUI_RPC_URL,
  USER_CAP_TYPE,
  USER_CAP_TYPE_ORIGINAL,
  USER_ADDED_EVENT_TYPES,
  USER_DISABLED_EVENT_TYPES,
  USER_ENABLED_EVENT_TYPES,
} from "../constants.js";
import { AttestationRecord, AttestType } from "../types.js";

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
  typeRepr?: string;
};

type SuiEventPage = {
  data?: SuiEvent[];
  hasNextPage?: boolean;
  nextCursor?: SuiEventCursor | null;
};

type GraphQlResponse<T> = {
  data?: T;
  errors?: Array<{ message?: string }>;
};

function getEventTypeSuffix(eventType: string): string {
  return eventType.split("::").pop()?.toLowerCase() ?? "";
}

function matchesExpectedEventType(event: SuiEvent, eventType: string): boolean {
  const expected = getEventTypeSuffix(eventType);
  if (!expected) return false;
  return event.typeRepr?.toLowerCase().endsWith(`::${expected}`) ?? false;
}

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
  eventType: string | null;
  record: AttestationRecord | null;
  statusAtAttestation: {
    value: boolean | null;
    latestEnabledTimestampMs: number | null;
    latestDisabledTimestampMs: number | null;
  };
};

export type WalletAttestationsScanResult = {
  pagesScanned: number;
  eventsScanned: number;
  photoCount: number;
  fileCount: number;
  events: AttestationRecord[];
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
    const normalizedBase64 = value.trim().replace(/\s+/g, "");
    if (
      normalizedBase64.length > 0 &&
      normalizedBase64.length % 4 === 0 &&
      /^[A-Za-z0-9+/]+={0,2}$/.test(normalizedBase64)
    ) {
      try {
        return Uint8Array.from(Buffer.from(normalizedBase64, "base64"));
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
  const response = await fetch(normalizeGraphQlUrl(rpcUrl), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(buildGraphQlRequest(method, params)),
  });

  if (!response.ok) {
    throw new Error(`Sui GraphQL request failed: ${response.status} ${response.statusText}`);
  }

  const payload = (await response.json()) as GraphQlResponse<Record<string, unknown>>;
  if (payload.errors?.length) {
    const message = payload.errors
      .map((entry) => entry.message?.trim())
      .filter((entry): entry is string => Boolean(entry))
      .join("\n");
    throw new Error(message || "Sui GraphQL returned an error");
  }
  if (!payload.data) {
    throw new Error("Sui GraphQL returned no data");
  }

  return extractGraphQlResult<T>(method, payload.data);
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
      const moveEventType = filter.MoveEventType ?? "";
      const moduleFilter = moveEventType.includes("::")
        ? moveEventType.substring(0, moveEventType.lastIndexOf("::"))
        : moveEventType;
      return {
        query: `query($module:String!,$first:Int!,$after:String){
          events(first:$first, after:$after, filter:{ module:$module }){
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
          module: moduleFilter,
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

function mapOwnedObjectsGraphQlResult(data: Record<string, unknown>): OwnedObjectsResult {
  const address = asRecord(data.address);
  const objects = asRecord(address?.objects);
  const nodes = asArray(objects?.nodes);
  return {
    data: nodes.map((node) => {
      const entry = asRecord(node);
      const contents = asRecord(entry?.contents);
      return {
        data: {
          objectId: asString(entry?.address),
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
      const contentType = asRecord(contents?.type);
      return {
        id: {
          txDigest: asString(transaction?.digest),
          eventSeq: String(entry?.sequenceNumber ?? ""),
        },
        packageId: asString(modulePackage?.address),
        sender: asString(sender?.address),
        timestampMs: toTimestampMs(asString(entry?.timestamp) || undefined),
        parsedJson: asRecord(contents?.json) ?? undefined,
        typeRepr: asString(contentType?.repr),
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

  const domainAdminEventTypes = [...DOMAIN_ADDED_EVENT_TYPES, ...USER_ADDED_EVENT_TYPES];

  for (const eventType of domainAdminEventTypes) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>(
        "suix_queryEvents",
        [{ MoveEventType: eventType }, cursor, 50, true],
        rpcUrl
      );

      for (const event of page.data ?? []) {
        const packageId = event.packageId.toLowerCase();
        const allowedPackageIds = new Set([
          GRANITE_LAKE_PACKAGE_ID.toLowerCase(),
          GRANITE_LAKE_ORIGINAL_PACKAGE_ID.toLowerCase(),
        ]);
        if (!allowedPackageIds.has(packageId) || !matchesExpectedEventType(event, eventType)) continue;

        const parsed = event.parsedJson;
        if (!parsed) continue;

        if (decodeVector(parsed.domain).decoded.toLowerCase() === domain.toLowerCase()) {
          const adminWallet = safeAddress(parsed.admin_wallet);
          return adminWallet || null;
        }
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  return null;
}

async function latestStatusTimestamp(params: {
  eventTypes: string[];
  userWallet: string;
  domain: string;
  attestationTimestampMs: number;
  rpcUrl: string;
}): Promise<number | null> {
  let latest: number | null = null;
  const allowedPackageIds = new Set([
    GRANITE_LAKE_PACKAGE_ID.toLowerCase(),
    GRANITE_LAKE_ORIGINAL_PACKAGE_ID.toLowerCase(),
  ]);

  for (const eventType of params.eventTypes) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>(
        "suix_queryEvents",
        [{ MoveEventType: eventType }, cursor, 50, true],
        params.rpcUrl
      );

      for (const event of page.data ?? []) {
        const packageId = event.packageId.toLowerCase();
        if (!allowedPackageIds.has(packageId) || !matchesExpectedEventType(event, eventType)) {
          continue;
        }

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
        if (eventDomain.toLowerCase() !== params.domain.toLowerCase()) {
          continue;
        }

        latest = latest === null ? timestamp : Math.max(latest, timestamp);
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

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
      eventTypes: USER_ENABLED_EVENT_TYPES,
      userWallet: params.userWallet,
      domain: params.domain,
      attestationTimestampMs: params.attestationTimestampMs,
      rpcUrl: params.rpcUrl,
    }),
    latestStatusTimestamp({
      eventTypes: USER_DISABLED_EVENT_TYPES,
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
  return verifyAttestationHashDetailed("attest_photo", photoHashHex, rpcUrl);
}

export async function verifyFileHashDetailed(
  fileHashHex: string,
  rpcUrl = SUI_RPC_URL
): Promise<VerificationScanResult> {
  return verifyAttestationHashDetailed("attest_file", fileHashHex, rpcUrl);
}

export async function verifyAttestationHashDetailed(
  attestType: AttestType,
  hashHex: string,
  rpcUrl = SUI_RPC_URL
): Promise<VerificationScanResult> {
  const targetHash = normalizeHex(hashHex);
  const eventTypes = attestType === "attest_photo" ? PHOTO_ATTESTED_EVENT_TYPES : FILE_ATTESTED_EVENT_TYPES;
  const hashField = attestType === "attest_photo" ? "photo_hash" : "file_hash";
  let pagesScanned = 0;
  let eventsScanned = 0;

  for (const eventType of eventTypes) {
    let cursor: SuiEventCursor | null = null;

    do {
      const page: SuiEventPage = await suiRpcCall<SuiEventPage>(
        "suix_queryEvents",
        [{ MoveEventType: eventType }, cursor, 50, true],
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

        if (!matchesExpectedEventType(event, eventType)) continue;

        const parsed = event.parsedJson;
        if (!parsed) continue;

        const eventHash = decodePhotoHash(parsed[hashField]);
        if (!eventHash || normalizeHex(eventHash) !== targetHash) {
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

        const gps = attestType === "attest_photo" ? decodeVector(parsed.gps) : null;
        const altitude = attestType === "attest_photo" ? decodeVector(parsed.altitude) : null;
        const fileId = attestType === "attest_file" ? decodeVector(parsed.file_id) : null;
        const projectId = decodeVector(parsed.project_id);

        const record: AttestationRecord = {
          attestType,
          txDigest: event.id.txDigest,
          eventSeq: event.id.eventSeq,
          packageId: event.packageId,
          eventTimestampMs: event.timestampMs ?? null,
          checkpointTimeIso: event.timestampMs ? new Date(Number(event.timestampMs)).toISOString() : null,
          userCapObjectId: userCapInfo.userCapObjectId,
          hashHex: eventHash,
          ...(attestType === "attest_photo"
            ? {
                photoHashHex: eventHash,
                gpsRawHex: gps?.hex ?? "",
                gpsDecoded: gps?.decoded ?? "",
                altitudeRawHex: altitude?.hex ?? "",
                altitudeDecoded: altitude?.decoded ?? "",
              }
            : {
                fileHashHex: eventHash,
                fileIdRawHex: fileId?.hex ?? "",
                fileIdDecoded: fileId?.decoded ?? "",
              }),
          projectIdRawHex: projectId.hex,
          projectIdDecoded: projectId.decoded,
          userWallet,
          domain,
          domainAdminWallet,
        };

        return {
          pagesScanned,
          eventsScanned,
          eventType,
          record,
          statusAtAttestation,
        };
      }

      cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
    } while (cursor);
  }

  return {
    pagesScanned,
    eventsScanned,
    eventType: null,
    record: null,
    statusAtAttestation: {
      value: null,
      latestEnabledTimestampMs: null,
      latestDisabledTimestampMs: null,
    },
  };
}

/**
 * Scans all PhotoAttested and/or FileAttested events on-chain and returns
 * every event emitted by the given wallet address.
 *
 * @param walletAddress - The user_wallet address to filter events by.
 * @param rpcUrl - Sui RPC endpoint.
 * @param attestTypeFilter - Optional. Pass "attest_photo" or "attest_file" to
 *   scan only that event type. Omit to scan both (default).
 */
export async function getAttestationsByWallet(
  walletAddress: string,
  rpcUrl = SUI_RPC_URL,
  attestTypeFilter?: AttestType
): Promise<WalletAttestationsScanResult> {
  const targetWallet = walletAddress.toLowerCase();
  const events: AttestationRecord[] = [];
  let pagesScanned = 0;
  let eventsScanned = 0;

  const userCapInfo = await getUserCapInfo(walletAddress, rpcUrl);
  const domain = userCapInfo.domain;
  const domainAdminWallet = await getDomainAdminWallet(domain, rpcUrl);

  const allowedPackageIds = new Set([
    GRANITE_LAKE_PACKAGE_ID.toLowerCase(),
    GRANITE_LAKE_ORIGINAL_PACKAGE_ID.toLowerCase(),
  ]);

  const allEventGroups: Array<{ types: string[]; attestType: AttestType; hashField: string }> = [
    { types: PHOTO_ATTESTED_EVENT_TYPES, attestType: "attest_photo", hashField: "photo_hash" },
    { types: FILE_ATTESTED_EVENT_TYPES, attestType: "attest_file", hashField: "file_hash" },
  ];

  const eventGroups = attestTypeFilter
    ? allEventGroups.filter((group) => group.attestType === attestTypeFilter)
    : allEventGroups;

  for (const group of eventGroups) {
    for (const eventType of group.types) {
      let cursor: SuiEventCursor | null = null;

      do {
        const page: SuiEventPage = await suiRpcCall<SuiEventPage>(
          "suix_queryEvents",
          [{ MoveEventType: eventType }, cursor, 50, true],
          rpcUrl
        );

        pagesScanned += 1;
        eventsScanned += page.data?.length ?? 0;

        for (const event of page.data ?? []) {
          const packageId = event.packageId.toLowerCase();
          if (!allowedPackageIds.has(packageId)) continue;

          if (!matchesExpectedEventType(event, eventType)) continue;

          const parsed = event.parsedJson;
          if (!parsed) continue;

          const eventWallet = safeAddress(parsed.user_wallet).toLowerCase();
          if (eventWallet !== targetWallet) continue;

          const eventHash = decodePhotoHash(parsed[group.hashField]);
          const gps = group.attestType === "attest_photo" ? decodeVector(parsed.gps) : null;
          const altitude = group.attestType === "attest_photo" ? decodeVector(parsed.altitude) : null;
          const fileId = group.attestType === "attest_file" ? decodeVector(parsed.file_id) : null;
          const projectId = decodeVector(parsed.project_id);

          const record: AttestationRecord = {
            attestType: group.attestType,
            txDigest: event.id.txDigest,
            eventSeq: event.id.eventSeq,
            packageId: event.packageId,
            eventTimestampMs: event.timestampMs ?? null,
            checkpointTimeIso: event.timestampMs ? new Date(Number(event.timestampMs)).toISOString() : null,
            userCapObjectId: userCapInfo.userCapObjectId,
            hashHex: eventHash,
            ...(group.attestType === "attest_photo"
              ? {
                  photoHashHex: eventHash,
                  gpsRawHex: gps?.hex ?? "",
                  gpsDecoded: gps?.decoded ?? "",
                  altitudeRawHex: altitude?.hex ?? "",
                  altitudeDecoded: altitude?.decoded ?? "",
                }
              : {
                  fileHashHex: eventHash,
                  fileIdRawHex: fileId?.hex ?? "",
                  fileIdDecoded: fileId?.decoded ?? "",
                }),
            projectIdRawHex: projectId.hex,
            projectIdDecoded: projectId.decoded,
            userWallet: safeAddress(parsed.user_wallet),
            domain,
            domainAdminWallet,
          };

          events.push(record);
        }

        cursor = page.hasNextPage ? (page.nextCursor ?? null) : null;
      } while (cursor);
    }
  }

  events.sort((a, b) => Number(b.eventTimestampMs ?? 0) - Number(a.eventTimestampMs ?? 0));

  return {
    pagesScanned,
    eventsScanned,
    photoCount: events.filter((e) => e.attestType === "attest_photo").length,
    fileCount: events.filter((e) => e.attestType === "attest_file").length,
    events,
  };
}
