# Granite Lake Verification Portal

Public verification portal for Granite Lake, modeled after Granite Ridge's hash-first verification flow.

## What it does

- Requires selecting whether the upload is a field photo or an uploaded file
- Computes SHA-256 locally in the browser
- Queries Sui `PhotoAttested` or `FileAttested` events via `suix_queryEvents`
- Scans paginated results until a matching `photo_hash` or `file_hash` is found or exhausted
- Displays public on-chain metadata when matched:
  - GPS
  - Altitude
  - Project ID
  - Attesting wallet
  - Timestamp (from event envelope `timestampMs`, plus the offline-capture `captured_at`/
    `attested_at` pair described below)
  - Domain from `UserCap` (via `suix_getOwnedObjects`)
  - User enabled status at attestation time (latest `UserEnabled` / `UserDisabled` before timestamp)
- Offline-capture provenance (`granite-lake-offline-capture-design-detail.md` §2): for each
  matched record, shows whether the capture was made online/offline and, for photos,
  with/without a GPS fix (`is_online`/`is_forced_offline`, and `has_gps`/
  `is_gps_forced_null` on photo attestations), distinguishing an automatic offline/no-GPS
  capture from a deliberate crew override. Whenever a `*_null_reason_hash` is present on
  the matched record, an inline foldable "Connectivity"/"GPS Provenance" control lets a
  verifier paste a disclosed reason and checks it client-side (Web Crypto SHA-256, no
  network round-trip) against the on-chain hash — the plaintext reason itself is never
  on-chain, only its hash, so this is the only way to confirm a disclosed reason is
  genuine.
- Domain trust check: looks up the `_attest.<domain>` DNS TXT record for the claimed
  domain across multiple DNS-over-HTTPS providers (requiring consensus across them, to
  resist a single spoofed/stale resolver), extracts its `chain_id`/`attester`/`revoked`
  fields, and compares the attester wallet against the on-chain domain admin wallet
  resolved from the matched record's `UserCap` — surfacing a trust-failure reason when
  they don't agree or no TXT record/on-chain admin wallet can be resolved.

## Environment

Copy `.env.example` to `.env` if you need overrides.

Defaults are aligned to Granite Lake testnet constants currently used by the mobile app.

- `VITE_SUI_RPC_URL` — Sui JSON-RPC endpoint used for event queries and object lookups.
- `VITE_GRANITE_LAKE_PACKAGE_ID` — the deployed Move package id (`contracts/`) events and
  objects are read from.
- `VITE_GRANITE_LAKE_ORIGINAL_PACKAGE_ID` — optional; defaults to
  `VITE_GRANITE_LAKE_PACKAGE_ID`. Only set this once the package has itself been upgraded
  and old events need to resolve against the original id.
- `VITE_GRANITE_LAKE_REGISTRY_ID` — the shared registry object id used to resolve domain
  admin wallets for the domain trust check above.

## Run

```bash
npm install
npm run dev
```

Then open the URL printed by Vite.

## Notes

- Current lookup strategy is event scan (`O(n)` by pages) across both photo and file attestation event types.
- This is suitable for MVP and audit use.
- If event volume grows substantially, move to a Postgres indexer for `photo_hash -> event`.
