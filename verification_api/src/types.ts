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
  ad: boolean | null;
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

export type AttestType = "attest_photo" | "attest_file";

export type AttestationRecord = {
  attestType: AttestType;
  txDigest: string;
  eventSeq: string;
  packageId: string;
  eventTimestampMs: string | null;
  checkpointTimeIso: string | null;
  userCapObjectId: string | null;
  hashHex: string;
  photoHashHex?: string;
  fileHashHex?: string;
  fileIdRawHex?: string;
  fileIdDecoded?: string;
  gpsRawHex?: string;
  gpsDecoded?: string;
  altitudeRawHex?: string;
  altitudeDecoded?: string;
  projectIdRawHex: string;
  projectIdDecoded: string;
  userWallet: string;
  domain: string | null;
  domainAdminWallet: string | null;
  userEnabledAtAttestation: {
    value: boolean | null;
    latestEnabledTimestampMs: number | null;
    latestDisabledTimestampMs: number | null;
  };
};

export type VerificationResponse = {
  hasMatch: boolean;
  // True when more than one distinct wallet has attested this exact hash.
  // The contract accepts a hash from any enabled capability with no link to
  // file ownership, so a collision is not resolved automatically — every
  // matching attestation is returned instead of silently picking one.
  collision: boolean;
  summary: string;
  request: {
    attestType: AttestType;
    fileName: string;
    mimeType: string;
    sizeBytes: number;
    hashHex: string;
    photoHashHex?: string;
    fileHashHex?: string;
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
    eventTypes: string[];
  };
  attestations: AttestationRecord[];
  // Only populated when exactly one distinct wallet attested this hash.
  // A collision has no single attester to check DNS trust for.
  dnsVerification: DnsVerification | null;
  warnings: string[];
  durationMs: number;
};
