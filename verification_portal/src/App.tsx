import { ChangeEvent, FormEvent, useEffect, useState } from "react";
import {
  GRANITE_LAKE_ORIGINAL_PACKAGE_ID,
  GRANITE_LAKE_PACKAGE_ID,
  GRANITE_LAKE_REGISTRY_ID,
  SUI_RPC_URL,
} from "./constants";
import { type GraniteDnsDiscovery, lookupGraniteTxtRecord } from "./lib/dnsLookup";
import { sha256File } from "./lib/fileHash";
import { type PhotoAttestationRecord, verifyPhotoHash } from "./lib/suiPhotoVerification";

type VerificationState = "idle" | "working" | "verified" | "unconfirmed" | "error";
type ThemeMode = "light" | "dark";

const THEME_STORAGE_KEY = "granite-lake-portal-theme";

function shorten(value: string): string {
  if (value.length <= 18) return value;
  return `${value.slice(0, 10)}...${value.slice(-6)}`;
}

function displayDecodedOrHex(decoded: string, hex: string): string {
  return decoded || (hex ? `0x${hex}` : "Unavailable");
}

function dnsConsensusLabel(discovery: GraniteDnsDiscovery | null): string {
  if (!discovery) return "Unavailable";
  return `${discovery.providers.length} / 3 matched`;
}

function walletMatchLabel(record: PhotoAttestationRecord | null, discovery: GraniteDnsDiscovery | null): string {
  if (!record || !discovery || !record.domainAdminWallet) {
    return "Unavailable";
  }

  return discovery.record.attester.toLowerCase() === record.domainAdminWallet.toLowerCase() ? "Match" : "Mismatch";
}

export default function App() {
  const [theme, setTheme] = useState<ThemeMode>(() => {
    if (typeof window === "undefined") {
      return "light";
    }

    const saved = window.localStorage.getItem(THEME_STORAGE_KEY);
    return saved === "dark" ? "dark" : "light";
  });
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [photoHash, setPhotoHash] = useState("");
  const [status, setStatus] = useState<VerificationState>("idle");
  const [message, setMessage] = useState("Drop or upload a photo to verify whether it exists in Granite Lake.");
  const [record, setRecord] = useState<PhotoAttestationRecord | null>(null);
  const [dnsDiscovery, setDnsDiscovery] = useState<GraniteDnsDiscovery | null>(null);
  const [dnsMessage, setDnsMessage] = useState("Not checked");

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

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!selectedFile) {
      setStatus("error");
      setMessage("Select a photo file first.");
      return;
    }

    setStatus("working");
    setRecord(null);
    setDnsDiscovery(null);
    setDnsMessage("Not checked");
    setMessage("Hashing file and scanning PhotoAttested events on Sui testnet.");

    try {
      const nextHash = photoHash || (await sha256File(selectedFile));
      setPhotoHash(nextHash);

      const result = await verifyPhotoHash({ photoHashHex: nextHash });

      if (!result.hasMatch) {
        setStatus("unconfirmed");
        setMessage("No matching PhotoAttested event found after scanning all pages.");
        return;
      }

      setRecord(result.record);

      if (result.record.domain) {
        try {
          setDnsMessage(`Checking DNS TXT consensus for _attest.${result.record.domain} ...`);
          const discovery = await lookupGraniteTxtRecord(result.record.domain);
          setDnsDiscovery(discovery);

          if (result.record.domainAdminWallet) {
            const isMatch = discovery.record.attester.toLowerCase() === result.record.domainAdminWallet.toLowerCase();
            setDnsMessage(
              isMatch
                ? "DNS attester wallet matches on-chain domain admin wallet."
                : "DNS attester wallet does not match on-chain domain admin wallet."
            );
          } else {
            setDnsMessage("DNS TXT found, but no on-chain domain admin wallet was resolved for comparison.");
          }
        } catch (dnsError) {
          setDnsDiscovery(null);
          setDnsMessage(dnsError instanceof Error ? dnsError.message : "DNS lookup failed.");
        }
      } else {
        setDnsMessage("No domain found on UserCap, DNS verification skipped.");
      }

      setStatus("verified");
      setMessage("Match found. Public attestation metadata loaded from chain.");
    } catch (error) {
      setStatus("error");
      setMessage(error instanceof Error ? error.message : "Verification failed.");
    }
  }

  return (
    <main className="shell">
      <section className="hero panel">
        <div className="hero-top">
          <p className="eyebrow">Granite Lake</p>
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

        <h1>Public Photo Verification Portal</h1>
      </section>

      <section className="workspace">
        <form className="panel form-panel" onSubmit={onSubmit}>
          <div className="form-stack">
            <div className="field">
              <span>Photo File</span>
              <label className={`upload-zone${selectedFile ? " has-file" : ""}`}>
                <input type="file" className="upload-input" accept="image/*" onChange={onFileChange} />
                {selectedFile ? (
                  <>
                    <span className="upload-file-icon">✓</span>
                    <span className="upload-file-name">{selectedFile.name}</span>
                    <small className="upload-hint">Click to replace</small>
                  </>
                ) : (
                  <>
                    <span className="upload-trigger">Choose Photo</span>
                    <small className="upload-hint">No file selected</small>
                  </>
                )}
              </label>
            </div>

            <div className="field field-hash">
              <span>Computed SHA-256</span>
              <code>{photoHash || "Pending"}</code>
            </div>

            <button className="primary-button" type="submit" disabled={status === "working"}>
              {status === "working" ? "Verifying..." : "Verify Photo"}
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
                Upload a photo and click <strong>Verify Photo</strong> to check the Granite Lake attestation ledger.
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
                <strong className={status === "verified" ? "is-match" : status === "unconfirmed" ? "is-nomatch" : ""}>
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
              </div>

              <div className="dns-status">{dnsMessage}</div>

              {record && (
                <div className="detail-grid">
                  <div className="detail-card detail-card-wide">
                    <span>Project ID</span>
                    <code>{displayDecodedOrHex(record.projectIdDecoded, record.projectIdRawHex)}</code>
                  </div>
                  <div className="detail-card">
                    <span>GPS</span>
                    <code>{displayDecodedOrHex(record.gpsDecoded, record.gpsRawHex)}</code>
                  </div>
                  <div className="detail-card">
                    <span>Altitude</span>
                    <code>{displayDecodedOrHex(record.altitudeDecoded, record.altitudeRawHex)}</code>
                  </div>
                  <div className="detail-card detail-card-wide">
                    <span>Attesting Wallet</span>
                    <code>{record.userWallet}</code>
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
                    <a href={`https://suiscan.xyz/testnet/tx/${record.txDigest}`} target="_blank" rel="noreferrer">
                      View on explorer
                    </a>
                  </div>
                </div>
              )}
            </>
          )}
        </section>
      </section>
    </main>
  );
}
