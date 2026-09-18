# Granite Lake Verification API

HTTP API that verifies an uploaded photo or file against Granite Lake on-chain attestations.

## What it does

On `POST /verify-attestation` with a multipart file upload and required `attest_type`, the API performs the same verification flow as the web portal:

- Computes SHA-256 of the uploaded file.
- Scans Sui `PhotoAttested` events for a matching `photo_hash` when `attest_type=attest_photo`.
- Scans Sui `FileAttested` events for a matching `file_hash` when `attest_type=attest_file`.
- Returns every matching event, not just one: the contract accepts a hash from any enabled capability with no link to file ownership, so more than one distinct wallet attesting the same hash is a genuine collision with no automatic way to pick a winner. `collision: true` and every candidate record is returned when this happens; DNS trust checking is skipped in that case since there's no single attester to check.
- Resolves domain from `UserCap`.
- Resolves domain admin wallet from `DomainAdded` events.
- Resolves user status at attestation time from `UserEnabled` and `UserDisabled` event history.
- Runs DNS TXT consensus lookup (`_attest.<domain>`) against 3 providers.
- Compares DNS `attester` wallet against on-chain domain admin wallet.

The response is intentionally detailed and includes scan metadata, attestation metadata, DNS evidence, warnings, and total duration.

Each returned attestation record also carries the offline-capture provenance fields recorded on-chain (see the [offline-capture design doc](../granite-lake-offline-capture-design-detail.md)): `capturedAtMs`/`attestedAtMs`, `isOnline`/`isForcedOffline` + `internetNullReasonHashHex`, and for photo attestations `hasGps`/`isGpsForcedNull` + `gpsNullReasonHashHex`. A non-empty `*NullReasonHashHex` means the crew's device recorded internet and/or GPS as missing or force-overridden at capture time and gave a reason for it — see `POST /verify-null-reason` below to check a disclosed reason against that hash.

## Endpoints

- `GET /health`
- `POST /verify-attestation`
- `GET /wallet-attestations/:wallet`
- `POST /verify-null-reason`

## Environment

Copy `.env.example` to `.env` and adjust values as needed.

Main settings:

- `PORT` default `8081`
- `HOST` default `0.0.0.0`
- `SUI_RPC_URL`
- `GRANITE_LAKE_PACKAGE_ID`
- `GRANITE_LAKE_ORIGINAL_PACKAGE_ID`
- `GRANITE_LAKE_REGISTRY_ID`

## Local run

```bash
npm install
npm run dev
```

Build:

```bash
npm run build
```

## Docker

Build image:

```bash
docker build -t granite-lake-verification-api .
```

Run container:

```bash
docker run --rm -p 8081:8081 --env-file .env granite-lake-verification-api
```

## Request example

```bash
curl -X POST "http://localhost:8081/verify-attestation" \
  -F "attest_type=attest_photo" \
  -F "file=@/absolute/path/to/capture1.jpg"
```

```bash
curl -X POST "http://localhost:8081/verify-attestation" \
  -F "attest_type=attest_file" \
  -F "file=@/absolute/path/to/document.pdf"
```

## Wallet attestations

`GET /wallet-attestations/:wallet` returns every attestation event owned by a wallet, including both photo and file attestations.

Query parameters:

- `attest_type=photo` or `attest_type=attest_photo` to filter photo attestations
- `attest_type=file` or `attest_type=attest_file` to filter file attestations
- omit `attest_type` to return both

Example:

```bash
curl "http://localhost:8081/wallet-attestations/0x48da47049ce3ca6ffea81a74c74f20592ad6accc9a19f3ae3c1c7b57e986422c"
```

```bash
curl "http://localhost:8081/wallet-attestations/0x48da47049ce3ca6ffea81a74c74f20592ad6accc9a19f3ae3c1c7b57e986422c?attest_type=file"
```

Response fields include:

- `wallet`
- `attestTypeFilter`
- `pagesScanned`
- `eventsScanned`
- `photoCount`
- `fileCount`
- `events`
- `durationMs`

## Response shape summary

Top-level response includes:

- `hasMatch` — `true` only when exactly one attestation matched and the trust checks below all passed
- `collision` — `true` when more than one distinct wallet has attested this exact hash; every candidate is returned in `attestations` with none picked automatically, and `dnsVerification` is `null` in this case
- `summary`
- `request` (attestation type, file metadata, and computed hash)
- `config` (effective package/rpc settings)
- `scan` (pages/events scanned)
- `attestations` — array of every matching public record (empty when no match, one entry in the normal case, more than one only on `collision`). Each record includes, alongside the base fields (`txDigest`, `hashHex`, `userWallet`, `domain`, `projectIdDecoded`, `userEnabledAtAttestation`, etc.), the offline-capture provenance fields described above (`capturedAtMs`, `attestedAtMs`, `isOnline`, `isForcedOffline`, `internetNullReasonHashHex`, and for photos `hasGps`, `isGpsForcedNull`, `gpsNullReasonHashHex`)
- `dnsVerification` (provider-by-provider evidence and wallet match checks; `null` on a collision or when no attestation matched)
  - `dnssecValidated`: `true` only when Cloudflare and Google both report the `AD` (Authenticated Data) flag on the `_attest.<domain>` TXT lookup; AliDNS is excluded from this check since its public resolver never sets `AD`, even for correctly signed zones. `null` if DNS verification wasn't attempted.
  - `providerResults[].ad`: raw per-provider `AD` flag (`true`/`false`/`null` on error)
- `warnings`
- `durationMs`

## Verify a disclosed null reason

`POST /verify-null-reason` checks a disclosed plaintext reason (for a missing/overridden internet or GPS field at capture time) against the on-chain reason hash from an `attestations[]` record above — the reason text itself is never stored on-chain, so this is the only way to confirm a disclosed reason is genuine rather than made up after the fact.

Request body:

- `reasonText` — the plaintext reason being disclosed
- `onChainHashHex` — the corresponding `internetNullReasonHashHex` or `gpsNullReasonHashHex` from an attestation record

Example:

```bash
curl -X POST "http://localhost:8081/verify-null-reason" \
  -H "Content-Type: application/json" \
  -d '{"reasonText": "No signal in this area", "onChainHashHex": "<hash from an attestation record>"}'
```

Response: `{ "matches": true | false }`.

No authentication — this endpoint (and the plaintext-reason disclosure UI in `verification_portal`) is currently self-service and open to anyone who has both a reason and its hash.
