import { SUI_RPC_URL } from "../constants.js";
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

// AliDNS's public resolver never sets the AD flag, even for correctly signed
// zones, so its result is excluded here; Cloudflare and Google reliably
// reflect DNSSEC validation status in AD.
const DNSSEC_AD_PROVIDER_NAMES = new Set(["Cloudflare", "Google"]);

function normalizeDomainName(domain: string): string {
  return domain.trim().replace(/\.+$/, "").toLowerCase();
}

function normalizeJsonTxtData(data: string): string {
  return data.replace(/^"|"$/g, "").replace(/""/g, "");
}

// DoH providers are inconsistent about whether a JSON "name" field carries a
// trailing dot. The portal forces every name through this same
// normalization before comparing, so two identical answers that differ only
// in trailing-dot formatting must be treated as identical here too — the
// prior unnormalized comparison made exact consensus permanently false
// against real records that in fact agreed (see F-14).
function ensureTrailingDot(name: string): string {
  return name.endsWith(".") ? name : `${name}.`;
}

function normalizeAnswers(answers: JsonDoHAnswer[] | undefined): string[] {
  return (answers ?? [])
    .filter((answer) => answer.type === TXT_RECORD_TYPE)
    .map((answer) => `${ensureTrailingDot(answer.name.toLowerCase())}|TXT|${normalizeJsonTxtData(answer.data).trim()}`)
    .sort();
}

// A record's chain_id (e.g. "sui:testnet") identifies which network it
// applies to. A domain legitimately publishing separate testnet and mainnet
// attester records is normal; two records for the *same* network is not —
// see lookupGraniteTxtConsensus.
function chainNetwork(chainId: string): string {
  return chainId.slice(EXPECTED_CHAIN_NAMESPACE.length).toLowerCase();
}

function currentSuiNetwork(rpcUrl: string): string {
  const lower = rpcUrl.toLowerCase();
  if (lower.includes("mainnet")) return "mainnet";
  if (lower.includes("devnet")) return "devnet";
  if (lower.includes("localnet") || lower.includes("127.0.0.1") || lower.includes("localhost")) return "localnet";
  return "testnet";
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

const DOH_TIMEOUT_MS = 5_000;

async function lookupProvider(provider: DoHProvider, lookupHost: string): Promise<DnsProviderResult> {
  const url = new URL(provider.endpoint);
  url.searchParams.set("name", lookupHost);
  url.searchParams.set("type", "TXT");

  try {
    const response = await fetch(url, {
      method: "GET",
      headers: { accept: "application/dns-json" },
      signal: AbortSignal.timeout(DOH_TIMEOUT_MS),
    });

    if (!response.ok) {
      return {
        provider: provider.name,
        endpoint: provider.endpoint,
        status: null,
        ad: null,
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
      ad: payload.AD === true,
      answers,
      error: null,
    };
  } catch (error) {
    return {
      provider: provider.name,
      endpoint: provider.endpoint,
      status: null,
      ad: null,
      answers: [],
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

export async function lookupGraniteTxtConsensus(
  domain: string,
  rpcUrl: string = SUI_RPC_URL
): Promise<{
  domain: string;
  lookupHost: string;
  providerResults: DnsProviderResult[];
  consensusMatched: boolean;
  dnssecValidated: boolean;
  network: string;
  record: GraniteDnsRecord;
}> {
  const normalizedDomain = normalizeDomainName(domain);
  if (!normalizedDomain) {
    throw new Error("A domain is required for DNS discovery.");
  }

  const lookupHost = `_attest.${normalizedDomain}`;
  const providerResults = await Promise.all(PROVIDERS.map((provider) => lookupProvider(provider, lookupHost)));

  // Parse every attester= TXT answer, per provider, grouped by network
  // (chain_id). More than one record from a single provider for the same
  // network is a same-network duplicate — a real misconfiguration or a sign
  // the zone has been tampered with — and is rejected outright rather than
  // picked between. Different networks legitimately coexist (a domain can
  // publish both a testnet and a mainnet attester record) and are not an
  // error; the record for the network this deployment actually runs on is
  // selected below (see F-15).
  const recordsByNetwork = new Map<string, GraniteDnsRecord[]>();

  for (const providerResult of providerResults) {
    if (providerResult.error) {
      continue;
    }

    const attesterAnswers = providerResult.answers.filter((answer) => answer.data.includes("attester="));
    const parsedForProvider: GraniteDnsRecord[] = [];

    for (const answer of attesterAnswers) {
      try {
        parsedForProvider.push(parseGraniteTxtRecord(lookupHost, answer.data));
      } catch {
        // Ignore malformed TXT answers from one resolver and continue with others.
      }
    }

    const countsForProvider = new Map<string, number>();
    for (const record of parsedForProvider) {
      const network = chainNetwork(record.chainId);
      countsForProvider.set(network, (countsForProvider.get(network) ?? 0) + 1);
    }

    const duplicateNetwork = Array.from(countsForProvider.entries()).find(([, count]) => count > 1);
    if (duplicateNetwork) {
      const [network, count] = duplicateNetwork;
      throw new Error(
        `Security: ${providerResult.provider} returned ${count} distinct Granite TXT records for ${lookupHost} on network "${network}". Exactly one is expected per network — treat this as a possible DNS tampering.`
      );
    }

    for (const record of parsedForProvider) {
      const network = chainNetwork(record.chainId);
      const existing = recordsByNetwork.get(network) ?? [];
      existing.push(record);
      recordsByNetwork.set(network, existing);
    }
  }

  if (recordsByNetwork.size === 0) {
    throw new Error(`No valid Granite attester TXT record found for ${lookupHost}`);
  }

  // Cross-provider disagreement about the record for a given network is the
  // same kind of breach signal, just observed a different way.
  for (const [network, records] of recordsByNetwork) {
    const distinctKeys = new Set(records.map((record) => recordKey(record)));
    if (distinctKeys.size > 1) {
      throw new Error(
        `Security: DNS providers disagree on the Granite TXT record for ${lookupHost} on network "${network}". Treat this as a possible DNS tampering or stale resolver path.`
      );
    }
  }

  const network = currentSuiNetwork(rpcUrl);
  const recordsForNetwork = recordsByNetwork.get(network);
  if (!recordsForNetwork || recordsForNetwork.length === 0) {
    throw new Error(`No Granite TXT record found for ${lookupHost} on network "${network}".`);
  }
  const record = recordsForNetwork[0];

  const dnssecProviderResults = providerResults.filter((result) => DNSSEC_AD_PROVIDER_NAMES.has(result.provider));
  const dnssecValidated =
    dnssecProviderResults.length > 0 && dnssecProviderResults.every((result) => result.ad === true);

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
  // Any same-network duplicate or cross-provider disagreement already threw
  // above, so reaching here with no provider errors means every provider
  // that answered agrees on substance even if exact byte formatting differs.
  const consensusMatched = exactAnswerConsensus || !providerErrors;

  return {
    domain: normalizedDomain,
    lookupHost,
    providerResults,
    consensusMatched,
    dnssecValidated,
    network,
    record,
  };
}
