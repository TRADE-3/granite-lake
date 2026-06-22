# Granite Lake Verification Portal

Public photo verification portal for Granite Lake, modeled after Granite Ridge's hash-first verification flow.

## What it does

- Accepts a photo upload in the browser
- Computes SHA-256 locally (no file upload)
- Queries Sui `PhotoAttested` events via `suix_queryEvents`
- Scans paginated results until a matching `photo_hash` is found or exhausted
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

- Current lookup strategy is event scan (`O(n)` by pages).
- This is suitable for MVP and audit use.
- If event volume grows substantially, move to a Postgres indexer for `photo_hash -> event`.
