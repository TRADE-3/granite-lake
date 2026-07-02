# Granite Lake Verification API

HTTP API that verifies an uploaded photo or file against Granite Lake on-chain attestations.

## What it does

On `POST /verify-attestation` with a multipart file upload and required `attest_type`, the API performs the same verification flow as the web portal:

- Computes SHA-256 of the uploaded file.
- Scans Sui `PhotoAttested` events for a matching `photo_hash` when `attest_type=attest_photo`.
- Scans Sui `FileAttested` events for a matching `file_hash` when `attest_type=attest_file`.
- Resolves domain from `UserCap`.
- Resolves domain admin wallet from `DomainAdded` events.
- Resolves user status at attestation time from `UserEnabled` and `UserDisabled` event history.
- Runs DNS TXT consensus lookup (`_attest.<domain>`) against 3 providers.
- Compares DNS `attester` wallet against on-chain domain admin wallet.

The response is intentionally detailed and includes scan metadata, attestation metadata, DNS evidence, warnings, and total duration.

## Endpoints

- `GET /health`
- `POST /verify-attestation`
- `GET /wallet-attestations/:wallet`

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

- `hasMatch`
- `summary`
- `request` (attestation type, file metadata, and computed hash)
- `config` (effective package/rpc settings)
- `scan` (pages/events scanned)
- `attestation` (full public record on match, otherwise `null`)
- `userEnabledAtAttestation`
- `dnsVerification` (provider-by-provider evidence and wallet match checks)
- `warnings`
- `durationMs`
