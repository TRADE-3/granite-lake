export type DnsAnswer = {
  name: string;
  type: number;
  TTL: number;
  data: string;
};

export type DnsQuestion = {
  name: string;
  type: number;
};

export type DoHResponse = {
  Status: number;
  TC?: boolean;
  RD?: boolean;
  RA?: boolean;
  AD?: boolean;
  CD?: boolean;
  Question?: DnsQuestion[];
  Answer?: DnsAnswer[];
};

export type DoHEndpoint = {
  url: string;
  format: "json" | "wire";
};

export type DoHProvider = {
  name: string;
  ip: string;
  endpoints: DoHEndpoint[];
};

export type ProviderLookupResult = {
  provider: DoHProvider;
  response: DoHResponse;
};

export type GraniteDnsRecord = {
  domain: string;
  lookupHost: string;
  rawRecord: string;
  chainId: string;
  attester: string;
  revoked: boolean;
};

export type GraniteDnsDiscovery = {
  record: GraniteDnsRecord;
  providers: ProviderLookupResult[];
  dnssecValidated: boolean;
};

const EXPECTED_CHAIN_NAMESPACE = "sui:";

const DNS_CLASS_IN = 1;
const DNS_HEADER_LENGTH = 12;
const TXT_RECORD_TYPE = 16;
const textDecoder = new TextDecoder();

export const GRANITE_DOH_PROVIDERS: DoHProvider[] = [
  {
    name: "AliDNS",
    ip: "223.5.5.5",
    endpoints: [{ url: "https://dns.alidns.com/resolve", format: "json" }],
  },
  {
    name: "Cloudflare",
    ip: "1.1.1.1",
    endpoints: [{ url: "https://cloudflare-dns.com/dns-query", format: "json" }],
  },
  {
    name: "Google",
    ip: "8.8.8.8",
    endpoints: [{ url: "https://dns.google/resolve", format: "json" }],
  },
];

function normalizeDomainName(domain: string): string {
  return domain.trim().replace(/\.+$/, "").toLowerCase();
}

function ensureTrailingDot(name: string): string {
  return name.endsWith(".") ? name : `${name}.`;
}

function encodeDomainName(domain: string): Uint8Array {
  const normalizedDomain = normalizeDomainName(domain);
  if (normalizedDomain.length === 0) {
    return new Uint8Array([0]);
  }

  const labels = normalizedDomain.split(".");
  const bytes: number[] = [];

  for (const label of labels) {
    const labelBytes = new TextEncoder().encode(label);
    if (labelBytes.length === 0 || labelBytes.length > 63) {
      throw new Error(`Invalid DNS label in domain: ${domain}`);
    }

    bytes.push(labelBytes.length, ...labelBytes);
  }

  bytes.push(0);
  return Uint8Array.from(bytes);
}

function buildDnsQuery(domain: string, recordType: number): Uint8Array {
  const qname = encodeDomainName(domain);
  const query = new Uint8Array(DNS_HEADER_LENGTH + qname.length + 4);
  const view = new DataView(query.buffer);

  view.setUint16(0, 0);
  view.setUint16(2, 0x0120);
  view.setUint16(4, 1);
  view.setUint16(6, 0);
  view.setUint16(8, 0);
  view.setUint16(10, 0);

  query.set(qname, DNS_HEADER_LENGTH);

  let offset = DNS_HEADER_LENGTH + qname.length;
  view.setUint16(offset, recordType);
  offset += 2;
  view.setUint16(offset, DNS_CLASS_IN);

  return query;
}

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function decodeDomainName(message: Uint8Array, offset: number): { name: string; nextOffset: number } {
  const labels: string[] = [];
  let currentOffset = offset;
  let nextOffset = offset;
  let jumped = false;
  let jumpCount = 0;

  while (true) {
    if (currentOffset >= message.length) {
      throw new Error("DNS name exceeds response length");
    }

    const length = message[currentOffset];

    if ((length & 0xc0) === 0xc0) {
      if (currentOffset + 1 >= message.length) {
        throw new Error("Incomplete DNS compression pointer");
      }

      const pointer = ((length & 0x3f) << 8) | message[currentOffset + 1];
      if (!jumped) {
        nextOffset = currentOffset + 2;
      }

      currentOffset = pointer;
      jumped = true;
      jumpCount += 1;

      if (jumpCount > message.length) {
        throw new Error("Too many DNS compression jumps");
      }

      continue;
    }

    currentOffset += 1;

    if (length === 0) {
      if (!jumped) {
        nextOffset = currentOffset;
      }
      break;
    }

    const labelEnd = currentOffset + length;
    if (labelEnd > message.length) {
      throw new Error("Incomplete DNS label in response");
    }

    labels.push(textDecoder.decode(message.subarray(currentOffset, labelEnd)));
    currentOffset = labelEnd;

    if (!jumped) {
      nextOffset = currentOffset;
    }
  }

  return {
    name: ensureTrailingDot(labels.join(".")),
    nextOffset,
  };
}

function formatTxtRecord(bytes: Uint8Array): string {
  const chunks: string[] = [];
  let offset = 0;

  while (offset < bytes.length) {
    const chunkLength = bytes[offset];
    offset += 1;

    const chunkEnd = offset + chunkLength;
    if (chunkEnd > bytes.length) {
      throw new Error("Malformed TXT record");
    }

    chunks.push(textDecoder.decode(bytes.subarray(offset, chunkEnd)));
    offset = chunkEnd;
  }

  return chunks.join("");
}

function formatRdata(type: number, rdata: Uint8Array, fullMessage: Uint8Array, rdataOffset: number): string {
  switch (type) {
    case 2:
    case 5:
    case 12:
      return decodeDomainName(fullMessage, rdataOffset).name;
    case 16:
      return formatTxtRecord(rdata);
    default:
      return Array.from(rdata, (value) => value.toString(16).padStart(2, "0")).join("");
  }
}

function parseDnsResponse(message: Uint8Array): DoHResponse {
  if (message.length < DNS_HEADER_LENGTH) {
    throw new Error("DNS response too short");
  }

  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  const flags = view.getUint16(2);
  const questionCount = view.getUint16(4);
  const answerCount = view.getUint16(6);
  const status = flags & 0x000f;

  let offset = DNS_HEADER_LENGTH;
  const questions: DnsQuestion[] = [];
  const answers: DnsAnswer[] = [];

  for (let index = 0; index < questionCount; index += 1) {
    const decodedName = decodeDomainName(message, offset);
    offset = decodedName.nextOffset;

    if (offset + 4 > message.length) {
      throw new Error("Malformed DNS question section");
    }

    const type = view.getUint16(offset);
    offset += 4;

    questions.push({
      name: decodedName.name,
      type,
    });
  }

  for (let index = 0; index < answerCount; index += 1) {
    const decodedName = decodeDomainName(message, offset);
    offset = decodedName.nextOffset;

    if (offset + 10 > message.length) {
      throw new Error("Malformed DNS answer header");
    }

    const type = view.getUint16(offset);
    const ttl = view.getUint32(offset + 4);
    const dataLength = view.getUint16(offset + 8);
    offset += 10;

    const rdataOffset = offset;
    const rdataEnd = rdataOffset + dataLength;
    if (rdataEnd > message.length) {
      throw new Error("Malformed DNS answer payload");
    }

    const rdata = message.subarray(rdataOffset, rdataEnd);
    const data = formatRdata(type, rdata, message, rdataOffset);
    offset = rdataEnd;

    answers.push({
      name: decodedName.name,
      type,
      TTL: ttl,
      data,
    });
  }

  return {
    Status: status,
    TC: Boolean(flags & 0x0200),
    RD: Boolean(flags & 0x0100),
    RA: Boolean(flags & 0x0080),
    AD: Boolean(flags & 0x0020),
    CD: Boolean(flags & 0x0010),
    Question: questions,
    Answer: answers,
  };
}

function buildDoHUrl(endpoint: string, encodedQuery: string): URL {
  const url = new URL(endpoint);
  url.searchParams.set("dns", encodedQuery);
  return url;
}

function buildDnsJsonUrl(endpoint: string, domain: string, recordType: number): URL {
  const url = new URL(endpoint);
  url.searchParams.set("name", domain);
  url.searchParams.set("type", recordType === TXT_RECORD_TYPE ? "TXT" : String(recordType));
  return url;
}

function normalizeJsonTxtData(data: string): string {
  return data.replace(/^"|"$/g, "").replace(/""/g, "");
}

function normalizeDnsJsonList<T>(value: T | T[] | undefined): T[] | undefined {
  if (value === undefined) {
    return undefined;
  }

  return Array.isArray(value) ? value : [value];
}

function parseDnsJsonResponse(
  response: DoHResponse & { Question?: DnsQuestion | DnsQuestion[]; Answer?: DnsAnswer | DnsAnswer[] }
): DoHResponse {
  const questions = normalizeDnsJsonList(response.Question);
  const answers = normalizeDnsJsonList(response.Answer);

  return {
    ...response,
    Question: questions?.map((question) => ({
      ...question,
      name: ensureTrailingDot(question.name),
    })),
    Answer: answers?.map((answer) => ({
      ...answer,
      name: ensureTrailingDot(answer.name),
      data: answer.type === TXT_RECORD_TYPE ? normalizeJsonTxtData(answer.data) : answer.data,
    })),
  };
}

async function fetchDnsMessageGet(url: URL, providerName: string): Promise<Uint8Array> {
  const response = await fetch(url, {
    method: "GET",
    mode: "cors",
    cache: "no-store",
    headers: {
      accept: "application/dns-message",
    },
  });

  if (!response.ok) {
    throw new Error(`${providerName} DoH request failed: ${response.status} ${response.statusText}`);
  }

  return new Uint8Array(await response.arrayBuffer());
}

async function fetchDnsMessagePost(endpoint: string, providerName: string, query: Uint8Array): Promise<Uint8Array> {
  const body = new Blob([new Uint8Array(query)], {
    type: "application/dns-message",
  });
  const response = await fetch(endpoint, {
    method: "POST",
    mode: "cors",
    cache: "no-store",
    headers: {
      accept: "application/dns-message",
      "content-type": "application/dns-message",
    },
    body,
  });

  if (!response.ok) {
    throw new Error(`${providerName} DoH POST failed: ${response.status} ${response.statusText}`);
  }

  return new Uint8Array(await response.arrayBuffer());
}

async function fetchDnsJson(url: URL, providerName: string): Promise<DoHResponse> {
  const response = await fetch(url, {
    method: "GET",
    mode: "cors",
    cache: "no-store",
    headers: {
      accept: "application/dns-json",
    },
  });

  if (!response.ok) {
    throw new Error(`${providerName} DNS JSON request failed: ${response.status} ${response.statusText}`);
  }

  return parseDnsJsonResponse((await response.json()) as DoHResponse);
}

async function lookupDnsOverHttps(
  provider: DoHProvider,
  domain: string,
  recordType = TXT_RECORD_TYPE
): Promise<ProviderLookupResult> {
  const query = buildDnsQuery(domain, recordType);
  const encodedQuery = toBase64Url(query);
  const errors: string[] = [];

  for (const endpoint of provider.endpoints) {
    if (endpoint.format === "json") {
      try {
        const response = await fetchDnsJson(buildDnsJsonUrl(endpoint.url, domain, recordType), provider.name);
        return {
          provider,
          response,
        };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        errors.push(`GET ${endpoint.url} -> ${message}`);
        continue;
      }
    }

    try {
      const responseBytes = await fetchDnsMessageGet(buildDoHUrl(endpoint.url, encodedQuery), provider.name);
      return {
        provider,
        response: parseDnsResponse(responseBytes),
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      errors.push(`GET ${endpoint.url} -> ${message}`);
    }

    try {
      const responseBytes = await fetchDnsMessagePost(endpoint.url, provider.name, query);
      return {
        provider,
        response: parseDnsResponse(responseBytes),
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      errors.push(`POST ${endpoint.url} -> ${message}`);
    }
  }

  throw new Error(`${provider.name} DoH lookup failed across all endpoints.\n${errors.join("\n")}`);
}

function normalizeAnswers(answers: DnsAnswer[] | undefined): string[] {
  return (answers ?? [])
    .filter((answer) => answer.type === TXT_RECORD_TYPE)
    .map((answer) => `${answer.name.toLowerCase()}|TXT|${answer.data.trim()}`)
    .sort();
}

function buildConsensusKey(result: DoHResponse): string {
  return JSON.stringify({
    Status: result.Status,
    Answer: normalizeAnswers(result.Answer),
  });
}

function assertConsensus(results: ProviderLookupResult[]): void {
  const consensusKeys = new Set(results.map((result) => buildConsensusKey(result.response)));
  if (consensusKeys.size === 1) {
    return;
  }

  const mismatchDetails = results
    .map(({ provider, response }) => {
      const answers = normalizeAnswers(response.Answer);
      const renderedAnswers = answers.length > 0 ? answers.join(", ") : "NO_ANSWER";
      return `${provider.name}: Status=${response.Status}; Answers=${renderedAnswers}`;
    })
    .join("\n");

  throw new Error(
    `DNS TXT consensus failed across providers. Treat this as a possible attack or stale resolver path.\n${mismatchDetails}`
  );
}

function parseBoolean(value: string): boolean {
  const normalizedValue = value.trim().toLowerCase();
  if (normalizedValue === "true") {
    return true;
  }
  if (normalizedValue === "false") {
    return false;
  }

  throw new Error(`Invalid revoked flag: ${value}`);
}

function parseGraniteTxtRecord(lookupHost: string, rawRecord: string): GraniteDnsRecord {
  const pairs = rawRecord
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const [rawKey, ...rawValueParts] = part.split("=");
      if (!rawKey || rawValueParts.length === 0) {
        throw new Error(`Malformed TXT token "${part}" for ${lookupHost}`);
      }

      return [rawKey.trim().toLowerCase(), rawValueParts.join("=").trim()] as const;
    });

  const values = new Map<string, string>(pairs);
  const chainId = values.get("chain_id");
  const attester = values.get("attester");
  const revokedValue = values.get("revoked");

  if (!chainId || !attester || revokedValue === undefined) {
    throw new Error(
      `TXT record for ${lookupHost} must include chain_id, attester, and revoked. Received: ${rawRecord}`
    );
  }

  if (!chainId.toLowerCase().startsWith(EXPECTED_CHAIN_NAMESPACE)) {
    throw new Error(`chain_id must use Sui format like "sui:testnet". Received: ${chainId}`);
  }

  if (!/^0x[0-9a-f]+$/i.test(attester)) {
    throw new Error(`Attester must be a hex-encoded Sui address. Received: ${attester}`);
  }

  return {
    domain: lookupHost.replace(/^_attest\./, ""),
    lookupHost,
    rawRecord,
    chainId,
    attester,
    revoked: parseBoolean(revokedValue),
  };
}

export async function lookupGraniteTxtRecord(
  domain: string,
  providers: DoHProvider[] = GRANITE_DOH_PROVIDERS
): Promise<GraniteDnsDiscovery> {
  const normalizedDomain = normalizeDomainName(domain);
  if (!normalizedDomain) {
    throw new Error("A domain is required for DNS discovery.");
  }

  const lookupHost = `_attest.${normalizedDomain}`;
  const results = await Promise.all(providers.map((provider) => lookupDnsOverHttps(provider, lookupHost)));
  assertConsensus(results);

  const consensusAnswers = (results[0].response.Answer ?? []).filter((answer) => answer.type === TXT_RECORD_TYPE);
  if (consensusAnswers.length === 0) {
    throw new Error(`No TXT record found for ${lookupHost}`);
  }

  const attesterAnswers = consensusAnswers.filter((answer) => answer.data.includes("attester="));
  if (attesterAnswers.length === 0) {
    throw new Error(`No Granite attester TXT record found for ${lookupHost}`);
  }

  if (attesterAnswers.length > 1) {
    throw new Error(`Expected exactly one Granite TXT record for ${lookupHost}, found ${attesterAnswers.length}`);
  }

  return {
    record: parseGraniteTxtRecord(lookupHost, attesterAnswers[0].data),
    providers: results,
    dnssecValidated: results.every((result) => result.response.AD === true),
  };
}
