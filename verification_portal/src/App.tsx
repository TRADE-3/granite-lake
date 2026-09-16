import { ChangeEvent, FormEvent, useEffect, useState } from "react";
import {
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_PACKAGE_ID,
  GRANITE_LAKE_REGISTRY_ID,
  SUI_RPC_URL,
} from "./constants";
import { type GraniteDnsDiscovery, lookupGraniteTxtRecord } from "./lib/dnsLookup";
import { sha256File } from "./lib/fileHash";
import {
  type FileAttestationRecord,
  type PhotoAttestationRecord,
  type WalletAttestationRecord,
  getWalletAttestationsByWallet,
  reasonMatchesHash,
  verifyFileHash,
  verifyPhotoHash,
} from "./lib/suiPhotoVerification";

type VerificationState = "idle" | "working" | "verified" | "unconfirmed" | "error";
type ThemeMode = "light" | "dark";
type PortalTab = "verify" | "wallets";
type VerificationKind = "field_photo" | "uploaded_file";
type VerificationRecord = PhotoAttestationRecord | FileAttestationRecord;
type ReasonCheckState = "idle" | "working" | "match" | "mismatch" | "error";

const THEME_STORAGE_KEY = "granite-lake-portal-theme";

function shorten(value: string): string {
  if (value.length <= 18) return value;
  return `${value.slice(0, 10)}...${value.slice(-6)}`;
}

function displayDecodedOrHex(decoded: string, hex: string): string {
  return decoded || (hex ? `0x${hex}` : "Unavailable");
}

// Mirrors the mobile app's AppConstants.attestationUnknownLabel fallback
// substituted on-chain when GPS/altitude weren't submitted.
function isUnknownValue(decoded: string, hex: string): boolean {
  return displayDecodedOrHex(decoded, hex).trim().toUpperCase() === "UNKNOWN";
}

function dnsConsensusLabel(discovery: GraniteDnsDiscovery | null): string {
  if (!discovery) return "Unavailable";
  return `${discovery.providers.length} / 3 matched`;
}

function walletMatchLabel(record: VerificationRecord | null, discovery: GraniteDnsDiscovery | null): string {
  if (!record || !discovery || !record.domainAdminWallet) {
    return "Unavailable";
  }

  return discovery.record.attester.toLowerCase() === record.domainAdminWallet.toLowerCase() ? "Match" : "Mismatch";
}

function isFileRecord(record: VerificationRecord): record is FileAttestationRecord {
  return "fileHashHex" in record;
}

function attestationTypeLabel(record: WalletAttestationRecord): string {
  return record.attestType === "attest_photo" ? "PHOTO" : "FILE";
}

// Offline-capture design doc §4's truth table, rendered as a label.
function connectivityLabel(isOnline: boolean, isForcedOffline: boolean): string {
  if (isOnline && !isForcedOffline) return "Online";
  if (isOnline && isForcedOffline) return "Online (deferred by crew)";
  if (!isOnline && !isForcedOffline) return "Offline (no connectivity)";
  return "Forced Offline — User might have disrupted internet connectivity intentionally";
}

// Offline-capture design doc §4a's truth table, rendered as a label.
function gpsLabel(hasGps: boolean, isGpsForcedNull: boolean): string {
  if (hasGps && !isGpsForcedNull) return "Location captured";
  if (hasGps && isGpsForcedNull) return "Location captured, but withheld by crew";
  if (!hasGps && !isGpsForcedNull) return "Location unavailable (no signal)";
  return "Location withheld — User might have turned off device location intentionally";
}

// Shared tone for both axes' truth tables: withheld-despite-available is the
// most concerning state (red), genuinely unavailable is the least concerning
// (yellow), and forced-but-moot sits in between (orange). The "available,
// not forced" row is the normal/good case and gets no tone class.
function truthTableTone(wasAvailable: boolean, wasForcedOff: boolean): string {
  if (wasAvailable && wasForcedOff) return "detail-card-danger";
  if (!wasAvailable && !wasForcedOff) return "detail-card-caution";
  if (!wasAvailable && wasForcedOff) return "detail-card-warn";
  return "";
}

function msToLocaleString(ms: string | null | undefined): string {
  if (!ms) return "Unavailable";
  const num = Number(ms);
  return Number.isFinite(num) ? new Date(num).toLocaleString() : "Unavailable";
}

// Foldable, inline check for a disclosed plaintext null-reason (offline-
// capture design doc §4b) against the record's on-chain reason hash,
// already loaded alongside the rest of the result. Renders nothing when
// onChainHashHex is empty - that field was present, no reason was ever
// required, so there is nothing to check.
function NullReasonCheck({ label, onChainHashHex }: { label: string; onChainHashHex: string }) {
  const [reasonText, setReasonText] = useState("");
  const [status, setStatus] = useState<ReasonCheckState>("idle");

  if (!onChainHashHex) {
    return null;
  }

  async function onCheck() {
    const trimmed = reasonText.trim();
    if (!trimmed) return;

    setStatus("working");
    try {
      const matches = await reasonMatchesHash(trimmed, onChainHashHex);
      setStatus(matches ? "match" : "mismatch");
    } catch {
      setStatus("error");
    }
  }

  return (
    <details className="reason-check">
      <summary>Check disclosed {label} reason</summary>
      <div className="reason-check-body">
        <textarea
          className="reason-check-input"
          rows={2}
          value={reasonText}
          placeholder={`Paste the ${label} reason the attester disclosed...`}
          onChange={(event) => {
            setReasonText(event.target.value);
            setStatus("idle");
          }}
        />
        <button
          type="button"
          className="secondary-button"
          onClick={onCheck}
          disabled={status === "working" || !reasonText.trim()}
        >
          {status === "working" ? "Checking..." : "Check hash"}
        </button>
        {status === "match" && (
          <div className="reason-check-result is-match">Matches the on-chain {label} reason hash.</div>
        )}
        {status === "mismatch" && (
          <div className="reason-check-result is-nomatch">Does not match the on-chain {label} reason hash.</div>
        )}
        {status === "error" && <div className="reason-check-result is-nomatch">Could not compute the hash.</div>}
      </div>
    </details>
  );
}

export default function App() {
  const [theme, setTheme] = useState<ThemeMode>(() => {
    if (typeof window === "undefined") {
      return "light";
    }

    const saved = window.localStorage.getItem(THEME_STORAGE_KEY);
    return saved === "dark" ? "dark" : "light";
  });
  const [portalTab, setPortalTab] = useState<PortalTab>("verify");
  const [verificationKind, setVerificationKind] = useState<VerificationKind>("field_photo");
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [photoHash, setPhotoHash] = useState("");
  const [status, setStatus] = useState<VerificationState>("idle");
  const [message, setMessage] = useState(
    "Select an attestation type and upload a file to verify it against public attestation ledger."
  );
  const [record, setRecord] = useState<VerificationRecord | null>(null);
  const [dnsDiscovery, setDnsDiscovery] = useState<GraniteDnsDiscovery | null>(null);
  const [dnsMessage, setDnsMessage] = useState("Not checked");
  const [walletAddress, setWalletAddress] = useState("");
  const [walletStatus, setWalletStatus] = useState<VerificationState>("idle");
  const [walletMessage, setWalletMessage] = useState(
    "Enter a wallet address to list its attested photo and file events."
  );
  const [walletRecords, setWalletRecords] = useState<WalletAttestationRecord[]>([]);
  const [walletPagesScanned, setWalletPagesScanned] = useState(0);
  const [walletEventsScanned, setWalletEventsScanned] = useState(0);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    window.localStorage.setItem(THEME_STORAGE_KEY, theme);
  }, [theme]);

  async function onFileChange(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0] ?? null;
    setSelectedFile(file);
    setRecord(null);
    setDnsDiscovery(null);
    setDnsMessage("Not checked");

    if (!file) {
      setPhotoHash("");
      return;
    }

    const nextHash = await sha256File(file);
    setPhotoHash(nextHash);
  }

  function onVerificationKindChange(event: ChangeEvent<HTMLSelectElement>) {
    const nextKind = event.target.value as VerificationKind;
    setVerificationKind(nextKind);
    setSelectedFile(null);
    setPhotoHash("");
    setStatus("idle");
    setMessage("Select an attestation type and upload a file to verify it against public attestation ledger.");
    setRecord(null);
    setDnsDiscovery(null);
    setDnsMessage("Not checked");
  }

  function onWalletAddressChange(event: ChangeEvent<HTMLInputElement>) {
    setWalletAddress(event.target.value);
    setWalletStatus("idle");
    setWalletMessage("Enter a wallet address to list its attested photo and file events.");
    setWalletRecords([]);
    setWalletPagesScanned(0);
    setWalletEventsScanned(0);
  }

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!selectedFile) {
      setStatus("error");
      setMessage("Select a file first.");
      return;
    }

    setStatus("working");
    setRecord(null);
    setDnsDiscovery(null);
    setDnsMessage("Not checked");
    setMessage(
      verificationKind === "field_photo"
        ? "Hashing file and scanning PhotoAttested events on Sui testnet."
        : "Hashing file and scanning FileAttested events on Sui testnet."
    );

    try {
      const nextHash = photoHash || (await sha256File(selectedFile));
      setPhotoHash(nextHash);

      const result =
        verificationKind === "field_photo"
          ? await verifyPhotoHash({ photoHashHex: nextHash })
          : await verifyFileHash({ fileHashHex: nextHash });

      if (!result.hasMatch) {
        setStatus("unconfirmed");
        setMessage(
          verificationKind === "field_photo"
            ? "No matching PhotoAttested event found after scanning all pages."
            : "No matching FileAttested event found after scanning all pages."
        );
        return;
      }

      if (result.collision) {
        const distinctWallets = Array.from(new Set(result.records.map((record) => record.userWallet)));
        setStatus("unconfirmed");
        setMessage(
          `${distinctWallets.length} different wallets have attested this exact hash (${distinctWallets.join(", ")}). ` +
            "This is not resolved automatically — the file cannot be attributed to a single attester."
        );
        return;
      }

      setRecord(result.record);

      let trustFailureReason: string | null = null;

      if (result.record.domain) {
        try {
          setDnsMessage(`Checking DNS TXT consensus for _attest.${result.record.domain} ...`);
          const discovery = await lookupGraniteTxtRecord(result.record.domain);
          setDnsDiscovery(discovery);

          if (discovery.record.revoked) {
            trustFailureReason = "DNS trust anchor reports this attester as revoked.";
            setDnsMessage(trustFailureReason);
          } else if (result.record.domainAdminWallet) {
            const isMatch = discovery.record.attester.toLowerCase() === result.record.domainAdminWallet.toLowerCase();
            if (isMatch) {
              setDnsMessage("DNS attester wallet matches on-chain domain admin wallet.");
            } else {
              trustFailureReason = "DNS attester wallet does not match on-chain domain admin wallet.";
              setDnsMessage(trustFailureReason);
            }
          } else {
            trustFailureReason = "DNS TXT found, but no on-chain domain admin wallet was resolved for comparison.";
            setDnsMessage(trustFailureReason);
          }
        } catch (dnsError) {
          setDnsDiscovery(null);
          trustFailureReason = dnsError instanceof Error ? dnsError.message : "DNS lookup failed.";
          setDnsMessage(trustFailureReason);
        }
      } else {
        setDnsMessage("No domain found on UserCap, DNS verification skipped.");
      }

      if (trustFailureReason) {
        setStatus("unconfirmed");
        setMessage(`Hash matched on chain, but the trust check failed: ${trustFailureReason}`);
        return;
      }

      setStatus("verified");
      setMessage(
        verificationKind === "field_photo"
          ? "Match found. Public photo attestation metadata loaded from chain."
          : "Match found. Public file attestation metadata loaded from chain."
      );
    } catch (error) {
      setStatus("error");
      setMessage(error instanceof Error ? error.message : "Verification failed.");
    }
  }

  async function onWalletSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const normalizedWallet = walletAddress.trim();
    if (!/^0x[a-fA-F0-9]+$/.test(normalizedWallet)) {
      setWalletStatus("error");
      setWalletMessage("Enter a valid Sui wallet address.");
      return;
    }

    setWalletStatus("working");
    setWalletMessage("Scanning PhotoAttested and FileAttested events for this wallet on Sui testnet.");
    setWalletRecords([]);

    try {
      const result = await getWalletAttestationsByWallet({ wallet: normalizedWallet });
      setWalletPagesScanned(result.pagesScanned);
      setWalletEventsScanned(result.eventsScanned);
      setWalletRecords(result.events);

      if (result.events.length === 0) {
        setWalletStatus("unconfirmed");
        setWalletMessage("No attestation events were found for this wallet.");
        return;
      }

      setWalletStatus("verified");
      setWalletMessage(`Found ${result.events.length} attestation event(s) for this wallet.`);
    } catch (error) {
      setWalletStatus("error");
      setWalletMessage(error instanceof Error ? error.message : "Wallet attestation lookup failed.");
    }
  }

  return (
    <>
      <header className="site-header">
        <div className="site-header-inner">
          <div className="logo-wordmark">
            <div className="logo-mark">T3</div>
            Trade3
          </div>
          <button
            type="button"
            className="theme-toggle"
            onClick={() => setTheme((current) => (current === "light" ? "dark" : "light"))}
            aria-pressed={theme === "dark"}
            aria-label={`Switch to ${theme === "light" ? "dark" : "light"} mode`}
          >
            <span className="toggle-track">
              <span className="toggle-thumb" />
            </span>
          </button>
        </div>
      </header>

      <main className="shell">
        <section className="hero panel">
          <h1>Public Verification Portal</h1>
          <p>Verify attested photos, uploaded files, or list all attestations for a wallet from Sui testnet.</p>
          <div className="tab-switcher" role="tablist" aria-label="Verification mode">
            <button
              type="button"
              className={portalTab === "verify" ? "tab-button is-active" : "tab-button"}
              aria-selected={portalTab === "verify"}
              onClick={() => setPortalTab("verify")}
            >
              Verify attestation
            </button>
            <button
              type="button"
              className={portalTab === "wallets" ? "tab-button is-active" : "tab-button"}
              aria-selected={portalTab === "wallets"}
              onClick={() => setPortalTab("wallets")}
            >
              Wallet attestations
            </button>
          </div>
        </section>

        {portalTab === "verify" ? (
          <section className="workspace">
            <form className="panel form-panel" onSubmit={onSubmit}>
              <div className="form-stack">
                <div className="field">
                  <span>Attestation Type</span>
                  <select className="verification-select" value={verificationKind} onChange={onVerificationKindChange}>
                    <option value="field_photo">Field photo (attested photo)</option>
                    <option value="uploaded_file">Uploaded file (attested file)</option>
                  </select>
                </div>

                <div className="field">
                  <span>{verificationKind === "field_photo" ? "Photo File" : "File"}</span>
                  <label className={`upload-zone${selectedFile ? " has-file" : ""}`}>
                    <input
                      type="file"
                      className="upload-input"
                      accept={verificationKind === "field_photo" ? "image/*" : undefined}
                      onChange={onFileChange}
                    />
                    {selectedFile ? (
                      <>
                        <span className="upload-file-icon">✓</span>
                        <span className="upload-file-name">{selectedFile.name}</span>
                        <small className="upload-hint">Click to replace</small>
                      </>
                    ) : (
                      <>
                        <span className="upload-trigger">
                          {verificationKind === "field_photo" ? "Choose Photo" : "Choose File"}
                        </span>
                        <small className="upload-hint">
                          {verificationKind === "field_photo" ? "No photo selected" : "No file selected"}
                        </small>
                      </>
                    )}
                  </label>
                </div>

                <div className="field field-hash">
                  <span>Computed SHA-256</span>
                  <code>{photoHash || "Pending"}</code>
                </div>

                <button className="primary-button" type="submit" disabled={status === "working"}>
                  {status === "working"
                    ? "Verifying..."
                    : verificationKind === "field_photo"
                      ? "Verify Photo"
                      : "Verify File"}
                </button>
              </div>

              <div className="config-strip">
                <small>RPC: {SUI_RPC_URL}</small>
                <small>Package: {shorten(GRANITE_LAKE_PACKAGE_ID)}</small>
                <small>Original: {shorten(GRANITE_LAKE_ORIGINAL_PACKAGE_ID)}</small>
                <small>Registry: {shorten(GRANITE_LAKE_REGISTRY_ID)}</small>
              </div>
            </form>

            <section className="panel result-panel">
              {status === "idle" ? (
                <div className="result-idle">
                  <span className="idle-icon">🔍</span>
                  <p>
                    {verificationKind === "field_photo"
                      ? "Upload a photo and click Verify Photo to check the public attestation ledger."
                      : "Upload a file and click Verify File to check the public attestation ledger."}
                  </p>
                </div>
              ) : status === "working" ? (
                <div className="result-idle">
                  <span className="idle-icon">⏳</span>
                  <p>{message}</p>
                </div>
              ) : (
                <>
                  <div className="status-line">
                    <strong
                      className={status === "verified" ? "is-match" : status === "unconfirmed" ? "is-nomatch" : ""}
                    >
                      {status === "verified"
                        ? "has_match: true"
                        : status === "unconfirmed"
                          ? "has_match: false"
                          : "has_match: error"}
                    </strong>
                    <span>{message}</span>
                  </div>

                  <div className="summary-grid">
                    <div className="summary-item">
                      <span>Timestamp</span>
                      <strong>{record?.checkpointTime ?? "Unavailable"}</strong>
                    </div>
                    <div className="summary-item">
                      <span>Domain</span>
                      <strong>{record?.domain ?? "Unavailable"}</strong>
                    </div>
                    <div className="summary-item">
                      <span>DNS Consensus</span>
                      <strong>{dnsConsensusLabel(dnsDiscovery)}</strong>
                    </div>
                    <div className="summary-item">
                      <span>Admin Wallet Check</span>
                      <strong>{walletMatchLabel(record, dnsDiscovery)}</strong>
                    </div>
                    <div className="summary-item">
                      <span>DNSSEC</span>
                      <strong className={dnsDiscovery?.dnssecValidated ? "status-success" : "status-warning"}>
                        {dnsDiscovery ? (dnsDiscovery.dnssecValidated ? "Validated" : "Not Validated") : "Unavailable"}
                      </strong>
                    </div>
                  </div>

                  <div className="dns-status">{dnsMessage}</div>

                  {dnsDiscovery && !dnsDiscovery.dnssecValidated && (
                    <div className="dns-status is-warning">
                      DNSSEC could not be validated for this domain. The DNS lookup itself was not cryptographically
                      authenticated, so treat this verification with slightly reduced confidence.
                    </div>
                  )}

                  {record && (
                    <div className="detail-grid">
                      {isFileRecord(record) ? (
                        <>
                          <div className="detail-card detail-card-wide">
                            <span>File Hash</span>
                            <code>{record.fileHashHex}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>File ID</span>
                            <code>{displayDecodedOrHex(record.fileIdDecoded, record.fileIdRawHex)}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>Project ID</span>
                            <code>{displayDecodedOrHex(record.projectIdDecoded, record.projectIdRawHex)}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>Attesting Wallet</span>
                            <code>{record.userWallet}</code>
                          </div>
                          <div className="detail-card">
                            <span>Captured At</span>
                            <code>{msToLocaleString(record.capturedAtMs)}</code>
                          </div>
                          <div className="detail-card">
                            <span>Attested At (on-chain)</span>
                            <code>{msToLocaleString(record.attestedAtMs)}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>Connectivity</span>
                            <code>{connectivityLabel(record.isOnline, record.isForcedOffline)}</code>
                            <NullReasonCheck label="internet" onChainHashHex={record.internetNullReasonHashHex} />
                          </div>
                          <div className="detail-card">
                            <span>Domain (from UserCap)</span>
                            <code>{record.domain ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card">
                            <span>Domain Admin Wallet (on-chain)</span>
                            <code>{record.domainAdminWallet ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>DNS TXT Attester Wallet</span>
                            <code>{dnsDiscovery?.record.attester ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card">
                            <span>DNS Chain ID</span>
                            <code>{dnsDiscovery?.record.chainId ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card">
                            <span>DNS Revoked</span>
                            <code>{dnsDiscovery ? String(dnsDiscovery.record.revoked) : "Unavailable"}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>Transaction</span>
                            <a
                              href={`https://suiscan.xyz/testnet/tx/${record.txDigest}`}
                              target="_blank"
                              rel="noreferrer"
                            >
                              View on explorer
                            </a>
                          </div>
                        </>
                      ) : (
                        <>
                          <div className="detail-card detail-card-wide">
                            <span>Project ID</span>
                            <code>{displayDecodedOrHex(record.projectIdDecoded, record.projectIdRawHex)}</code>
                          </div>
                          <div
                            className={`detail-card ${isUnknownValue(record.gpsDecoded, record.gpsRawHex) ? "detail-card-caution" : ""}`}
                          >
                            <span>GPS</span>
                            <code>{displayDecodedOrHex(record.gpsDecoded, record.gpsRawHex)}</code>
                          </div>
                          <div
                            className={`detail-card ${isUnknownValue(record.altitudeDecoded, record.altitudeRawHex) ? "detail-card-caution" : ""}`}
                          >
                            <span>Altitude</span>
                            <code>{displayDecodedOrHex(record.altitudeDecoded, record.altitudeRawHex)}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>Attesting Wallet</span>
                            <code>{record.userWallet}</code>
                          </div>
                          <div className="detail-card">
                            <span>Captured At</span>
                            <code>{msToLocaleString(record.capturedAtMs)}</code>
                          </div>
                          <div className="detail-card">
                            <span>Attested At (on-chain)</span>
                            <code>{msToLocaleString(record.attestedAtMs)}</code>
                          </div>
                          <div
                            className={`detail-card detail-card-wide ${truthTableTone(record.isOnline, record.isForcedOffline)}`}
                          >
                            <span>Connectivity</span>
                            <code>{connectivityLabel(record.isOnline, record.isForcedOffline)}</code>
                            <NullReasonCheck label="internet" onChainHashHex={record.internetNullReasonHashHex} />
                          </div>
                          <div
                            className={`detail-card detail-card-wide ${truthTableTone(record.hasGps, record.isGpsForcedNull)}`}
                          >
                            <span>GPS Provenance</span>
                            <code>{gpsLabel(record.hasGps, record.isGpsForcedNull)}</code>
                            <NullReasonCheck label="GPS" onChainHashHex={record.gpsNullReasonHashHex} />
                          </div>
                          <div className="detail-card">
                            <span>Domain (from UserCap)</span>
                            <code>{record.domain ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card">
                            <span>Domain Admin Wallet (on-chain)</span>
                            <code>{record.domainAdminWallet ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>DNS TXT Attester Wallet</span>
                            <code>{dnsDiscovery?.record.attester ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card">
                            <span>DNS Chain ID</span>
                            <code>{dnsDiscovery?.record.chainId ?? "Unavailable"}</code>
                          </div>
                          <div className="detail-card">
                            <span>DNS Revoked</span>
                            <code>{dnsDiscovery ? String(dnsDiscovery.record.revoked) : "Unavailable"}</code>
                          </div>
                          <div className="detail-card detail-card-wide">
                            <span>Transaction</span>
                            <a
                              href={`https://suiscan.xyz/testnet/tx/${record.txDigest}`}
                              target="_blank"
                              rel="noreferrer"
                            >
                              View on explorer
                            </a>
                          </div>
                        </>
                      )}
                    </div>
                  )}
                </>
              )}
            </section>
          </section>
        ) : (
          <section className="workspace wallet-workspace">
            <form className="panel form-panel" onSubmit={onWalletSubmit}>
              <div className="form-stack">
                <div className="field">
                  <span>Wallet Address</span>
                  <input
                    className="verification-input"
                    value={walletAddress}
                    onChange={onWalletAddressChange}
                    placeholder="0x..."
                    inputMode="text"
                    autoComplete="off"
                    spellCheck={false}
                  />
                </div>

                <button className="primary-button" type="submit" disabled={walletStatus === "working"}>
                  {walletStatus === "working" ? "Scanning..." : "Load Wallet Attestations"}
                </button>
              </div>

              <div className="config-strip">
                <small>RPC: {SUI_RPC_URL}</small>
                <small>Package: {shorten(GRANITE_LAKE_PACKAGE_ID)}</small>
                <small>Original: {shorten(GRANITE_LAKE_ORIGINAL_PACKAGE_ID)}</small>
                <small>Registry: {shorten(GRANITE_LAKE_REGISTRY_ID)}</small>
              </div>
            </form>

            <section className="panel result-panel wallet-result-panel">
              {walletStatus === "idle" ? (
                <div className="result-idle">
                  <span className="idle-icon">🔍</span>
                  <p>{walletMessage}</p>
                </div>
              ) : walletStatus === "working" ? (
                <div className="result-idle">
                  <span className="idle-icon">⏳</span>
                  <p>{walletMessage}</p>
                </div>
              ) : (
                <>
                  <div className="status-line">
                    <strong
                      className={
                        walletStatus === "verified" ? "is-match" : walletStatus === "unconfirmed" ? "is-nomatch" : ""
                      }
                    >
                      {walletStatus === "verified"
                        ? "has_match: true"
                        : walletStatus === "unconfirmed"
                          ? "has_match: false"
                          : "has_match: error"}
                    </strong>
                    <span>{walletMessage}</span>
                  </div>

                  <div className="summary-grid">
                    <div className="summary-item">
                      <span>Pages Scanned</span>
                      <strong>{walletPagesScanned}</strong>
                    </div>
                    <div className="summary-item">
                      <span>Events Scanned</span>
                      <strong>{walletEventsScanned}</strong>
                    </div>
                    <div className="summary-item">
                      <span>Photo Attestations</span>
                      <strong>{walletRecords.filter((entry) => entry.attestType === "attest_photo").length}</strong>
                    </div>
                    <div className="summary-item">
                      <span>File Attestations</span>
                      <strong>{walletRecords.filter((entry) => entry.attestType === "attest_file").length}</strong>
                    </div>
                  </div>

                  {walletRecords.length > 0 ? (
                    <div className="wallet-event-list">
                      {walletRecords.map((entry) => (
                        <article
                          key={`${entry.txDigest}:${entry.eventSeq}:${entry.attestType}`}
                          className="wallet-event-card"
                        >
                          <div className="wallet-event-card-top">
                            <span
                              className={`wallet-event-chip ${entry.attestType === "attest_photo" ? "is-photo" : "is-file"}`}
                            >
                              {attestationTypeLabel(entry)}
                            </span>
                            <a
                              href={`https://suiscan.xyz/testnet/tx/${entry.txDigest}`}
                              target="_blank"
                              rel="noreferrer"
                            >
                              View transaction
                            </a>
                          </div>

                          <div className="wallet-event-title">{entry.checkpointTime}</div>
                          <div className="wallet-event-grid">
                            <div>
                              <span>Hash</span>
                              <code>{entry.hashHex}</code>
                            </div>
                            <div>
                              <span>Project</span>
                              <code>{displayDecodedOrHex(entry.projectIdDecoded, entry.projectIdRawHex)}</code>
                            </div>
                            <div>
                              <span>Wallet</span>
                              <code>{entry.userWallet}</code>
                            </div>
                            <div>
                              <span>Domain</span>
                              <code>{entry.domain ?? "Unavailable"}</code>
                            </div>
                            <div>
                              <span>Connectivity</span>
                              <code>{connectivityLabel(entry.isOnline, entry.isForcedOffline)}</code>
                            </div>
                            {entry.attestType === "attest_photo" ? (
                              <>
                                <div>
                                  <span>GPS</span>
                                  <code>{displayDecodedOrHex(entry.gpsDecoded ?? "", entry.gpsRawHex ?? "")}</code>
                                </div>
                                <div>
                                  <span>Altitude</span>
                                  <code>
                                    {displayDecodedOrHex(entry.altitudeDecoded ?? "", entry.altitudeRawHex ?? "")}
                                  </code>
                                </div>
                                <div>
                                  <span>GPS Provenance</span>
                                  <code>{gpsLabel(entry.hasGps ?? false, entry.isGpsForcedNull ?? false)}</code>
                                </div>
                              </>
                            ) : (
                              <>
                                <div>
                                  <span>File ID</span>
                                  <code>
                                    {displayDecodedOrHex(entry.fileIdDecoded ?? "", entry.fileIdRawHex ?? "")}
                                  </code>
                                </div>
                                <div>
                                  <span>Enabled At Attestation</span>
                                  <code>
                                    {entry.userEnabledAtAttestation === null
                                      ? "Unavailable"
                                      : String(entry.userEnabledAtAttestation)}
                                  </code>
                                </div>
                              </>
                            )}
                          </div>
                        </article>
                      ))}
                    </div>
                  ) : null}
                </>
              )}
            </section>
          </section>
        )}
      </main>
    </>
  );
}
