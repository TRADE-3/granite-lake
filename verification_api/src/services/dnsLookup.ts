import { DnsProviderResult, GraniteDnsRecord } from "../types.js";

type JsonDoHAnswer = {
  name: string;
  type: number;
  TTL: number;
  data: string;
};

type JsonDoHResponse = {
  Status: number;
  AD?: boolean;
  Answer?: JsonDoHAnswer[];
};

type DoHProvider = {
  name: string;
  endpoint: string;
};

const TXT_RECORD_TYPE = 16;
const EXPECTED_CHAIN_NAMESPACE = "sui:";

const PROVIDERS: DoHProvider[] = [
  { name: "AliDNS", endpoint: "https://dns.alidns.com/resolve" },
  { name: "Cloudflare", endpoint: "https://cloudflare-dns.com/dns-query" },
  { name: "Google", endpoint: "https://dns.google/resolve" },
];

function normalizeDomainName(domain: string): string {
  return domain.trim().replace(/\.+$/, "").toLowerCase();
}

function normalizeJsonTxtData(data: string): string {
  return data.replace(/^"|"$/g, "").replace(/""/g, "");
}

function normalizeAnswers(answers: JsonDoHAnswer[] | undefined): string[] {
  return (answers ?? [])
    .filter((answer) => answer.type === TXT_RECORD_TYPE)
    .map((answer) => `${answer.name.toLowerCase()}|TXT|${normalizeJsonTxtData(answer.data).trim()}`)
    .sort();
}

function parseBoolean(value: string): boolean {
  const normalizedValue = value.trim().toLowerCase();
  if (normalizedValue === "true") return true;
  if (normalizedValue === "false") return false;
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
    throw new Error(`TXT record for ${lookupHost} must include chain_id, attester, and revoked.`);
  }
  if (!chainId.toLowerCase().startsWith(EXPECTED_CHAIN_NAMESPACE)) {
    throw new Error(`chain_id must use Sui format like "sui:testnet". Received: ${chainId}`);
  }
  if (!/^0x[0-9a-f]+$/i.test(attester)) {
    throw new Error(`Attester must be a hex-encoded Sui address. Received: ${attester}`);
  }

  return {
    lookupHost,
    rawRecord,
    chainId,
    attester,
    revoked: parseBoolean(revokedValue),
  };
}

function recordKey(record: GraniteDnsRecord): string {
  return `${record.chainId.toLowerCase()}|${record.attester.toLowerCase()}|${record.revoked ? "true" : "false"}`;
}

async function lookupProvider(provider: DoHProvider, lookupHost: string): Promise<DnsProviderResult> {
  const url = new URL(provider.endpoint);
  url.searchParams.set("name", lookupHost);
  url.searchParams.set("type", "TXT");

  try {
    const response = await fetch(url, {
      method: "GET",
      headers: { accept: "application/dns-json" },
    });

    if (!response.ok) {
      return {
        provider: provider.name,
        endpoint: provider.endpoint,
        status: null,
        answers: [],
        error: `${response.status} ${response.statusText}`,
      };
    }

    const payload = (await response.json()) as JsonDoHResponse;
    const answers = (payload.Answer ?? [])
      .filter((answer) => answer.type === TXT_RECORD_TYPE)
      .map((answer) => ({
        name: answer.name,
        type: answer.type,
        ttl: answer.TTL,
        data: normalizeJsonTxtData(answer.data),
      }));

    return {
      provider: provider.name,
      endpoint: provider.endpoint,
      status: payload.Status,
      answers,
      error: null,
    };
  } catch (error) {
    return {
      provider: provider.name,
      endpoint: provider.endpoint,
      status: null,
      answers: [],
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

export async function lookupGraniteTxtConsensus(domain: string): Promise<{
  domain: string;
  lookupHost: string;
  providerResults: DnsProviderResult[];
  consensusMatched: boolean;
  dnssecValidated: boolean;
  record: GraniteDnsRecord;
}> {
  const normalizedDomain = normalizeDomainName(domain);
  if (!normalizedDomain) {
    throw new Error("A domain is required for DNS discovery.");
  }

  const lookupHost = `_attest.${normalizedDomain}`;
  const providerResults = await Promise.all(PROVIDERS.map((provider) => lookupProvider(provider, lookupHost)));

  const parsedRecords: GraniteDnsRecord[] = [];

  for (const providerResult of providerResults) {
    if (providerResult.error) {
      continue;
    }

    const attesterAnswers = providerResult.answers.filter((answer) => answer.data.includes("attester="));
    for (const answer of attesterAnswers) {
      try {
        parsedRecords.push(parseGraniteTxtRecord(lookupHost, answer.data));
      } catch {
        // Ignore malformed TXT answers from one resolver and continue with others.
      }
    }
  }

  if (parsedRecords.length === 0) {
    throw new Error(`No valid Granite attester TXT record found for ${lookupHost}`);
  }

  const keyCounts = new Map<string, { record: GraniteDnsRecord; count: number }>();
  for (const record of parsedRecords) {
    const key = recordKey(record);
    const existing = keyCounts.get(key);
    if (existing) {
      existing.count += 1;
    } else {
      keyCounts.set(key, { record, count: 1 });
    }
  }

  const sortedCandidates = Array.from(keyCounts.values()).sort((a, b) => b.count - a.count);
  const record = sortedCandidates[0].record;

  const providerAnswerSets = providerResults
    .filter((result) => !result.error)
    .map((result) =>
      JSON.stringify({
        status: result.status,
        answers: normalizeAnswers(
          result.answers.map((answer) => ({
            name: answer.name,
            type: answer.type,
            TTL: answer.ttl,
            data: answer.data,
          }))
        ),
      })
    );

  const providerErrors = providerResults.some((result) => Boolean(result.error));
  const exactAnswerConsensus = providerAnswerSets.length > 0 && new Set(providerAnswerSets).size === 1;
  const parsedRecordConsensus = keyCounts.size === 1;
  const consensusMatched = exactAnswerConsensus || (!providerErrors && parsedRecordConsensus);

  return {
    domain: normalizedDomain,
    lookupHost,
    providerResults,
    consensusMatched,
    dnssecValidated: false,
    record,
  };
}
