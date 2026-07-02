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
  - Timestamp (from event envelope `timestampMs`)
  - Domain from `UserCap` (via `suix_getOwnedObjects`)
  - User enabled status at attestation time (latest `UserEnabled` / `UserDisabled` before timestamp)

## Environment

Copy `.env.example` to `.env` if you need overrides.

Defaults are aligned to Granite Lake testnet constants currently used by the mobile app.

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
