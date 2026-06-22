export type DnsAnswer = {
  name: string;
  type: number;
  ttl: number;
  data: string;
};

export type DnsProviderResult = {
  provider: string;
  endpoint: string;
  status: number | null;
  answers: DnsAnswer[];
  error: string | null;
};

export type GraniteDnsRecord = {
  lookupHost: string;
  rawRecord: string;
  chainId: string;
  attester: string;
  revoked: boolean;
};

export type DnsVerification = {
  attempted: boolean;
  domain: string | null;
  lookupHost: string | null;
  consensusMatched: boolean | null;
  dnssecValidated: boolean | null;
  providerResults: DnsProviderResult[];
  record: GraniteDnsRecord | null;
  attesterMatchesDomainAdminWallet: boolean | null;
  error: string | null;
};

export type AttestationRecord = {
  txDigest: string;
  eventSeq: string;
  packageId: string;
  eventTimestampMs: string | null;
  checkpointTimeIso: string | null;
  userCapObjectId: string | null;
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
};

export type VerificationResponse = {
  hasMatch: boolean;
  summary: string;
  request: {
    fileName: string;
    mimeType: string;
    sizeBytes: number;
    photoHashHex: string;
  };
  config: {
    rpcUrl: string;
    packageId: string;
    originalPackageId: string;
    registryId: string;
  };
  scan: {
    pagesScanned: number;
    eventsScanned: number;
    eventType: string;
  };
  attestation: AttestationRecord | null;
  userEnabledAtAttestation: {
    value: boolean | null;
    latestEnabledTimestampMs: number | null;
    latestDisabledTimestampMs: number | null;
  };
  dnsVerification: DnsVerification;
  warnings: string[];
  durationMs: number;
};
