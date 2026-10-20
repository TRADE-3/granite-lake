# Granite Lake

**Granite Lake** is an open-source, mobile-first platform that turns everyday field photos and critical project documents into cryptographically attested records. By hardware-locking user identity via a biometric gate and anchoring a signed hash of each record to the Sui blockchain, Granite Lake provides a permanent, tamper-evident record of who submitted a given photo or document and when — for industries like construction, insurance, and logistics.

## Core Capabilities

- **Hardware-Locked Identity**
  Cryptographic signing keys are secured by the user's physical fingerprint via a biometric gate.

- **Flexible Field Workflows**
  Teams can seamlessly capture field photos or securely upload critical documents (like PDFs and compliance logs).

- **Attested Context**
  Photos are bound with the device's self-reported GPS coordinates, altitude, and timestamp, and all assets (photos and documents) are tagged with project IDs. These values are recorded as submitted by the signing device and are not independently verified.

- **Zero-Trust Verification**
  Every file's cryptographic hash is anchored on-chain, allowing a public web portal to let anyone select a raw file and check whether a matching, trust-anchored attestation exists, or run comprehensive, chronological audits on a user's entire field history directly against the public ledger.

## Repository Structure

Top-level folders and what they contain:

- `app/`: Android-focused Flutter application for local wallet creation, biometric protection, photo capture, file upload, Sui attestation, and verification.
- `server/`: Per-domain backend API (Fastify + Postgres) for OTP registration, domain user management, and Sui writes.
- `contracts/`: Sui Move package for domain registration, user capabilities, enable/disable controls, and event-only photo and file attestation.
- `verification_portal/`: Public verification portal (Vite + React + TypeScript) for querying attested photos or uploaded files from Sui.
- `verification_api/`: HTTP API backend for photo and file verification against on-chain attestations with DNS TXT consensus lookup.

Folder-specific documentation:

- `app/README.md`
- `server/README.md`
- `contracts/README.md`
- `verification_portal/README.md`
- `verification_api/README.md`

## Local Development

Run Granite Lake locally with the API stack and Flutter app.

### 1) Install root tooling

```bash
npm install
```

This installs repository-level tooling such as ESLint, Prettier, and Husky. It does not install dependencies for `server/` or Flutter packages for `app/`; install those in the folders you are developing.

### 2) Start server stack

```bash
cd server
cp .env.example .env
npm install
docker compose --env-file .env up --build -d
```

This starts:

- API at `http://localhost:8080`
- Postgres for OTP sessions and registered users

Before using OTP verification, make sure the configured domain and admin wallet already exist in the deployed Sui registry. The server can read `SUI_PRIVATE_KEY` directly from `.env`, or from HashiCorp Vault when Vault is enabled. See `server/README.md` for the required environment variables, Vault setup, and deployment model.

### 3) Start Flutter app

```bash
cd app
flutter pub get
flutter run --dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true
```

The app targets Android. For local development, pass `--dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true` to enable localhost fallback to `http://10.0.2.2:8080` (Android emulator) or `http://127.0.0.1:8080` (localhost).

For convenience, you can create `app/.env.local` (add to `.gitignore`) with:

```
GL_OTP_BACKEND_DEV_FALLBACKS=true
```

### 4) Start verification API (optional)

```bash
cd verification_api
cp .env.example .env
npm install
npm run dev
```

The verification API runs at `http://localhost:8081` and provides a `/verify-attestation` endpoint for photo and file verification.

### 5) Start verification portal (optional)

```bash
cd verification_portal
npm install
npm run dev
```

The verification portal runs at the Vite dev server URL and provides a web UI for public photo or file verification.

### 6) Quick health check

```bash
curl http://localhost:8080/health
curl http://localhost:8081/health  # if verification_api is running
```

## Contributing

This project is open source and contributions are welcome.

### Standard GitHub Flow

1. Open an issue describing the bug, enhancement, or proposal.
2. Create a branch from `main` tied to that issue.
3. Use an issue-based branch name, for example:

```txt
<issue-number>-short-description
```

Examples:

```txt
42-fix-otp-expiry-handling
107-add-photo-verification-indexer
```

4. Make focused commits that reference the issue number.
5. Open a pull request that links the issue and explains what changed, why it changed, and how it was tested.
6. Address review feedback, then merge when approved.

### Code Style And Checks

All root checks run from the repository root.

Run server and app checks:

```bash
npm run check:server
npm run check:app
npm run check:verification_api
npm run check:verification_portal
```

Or run the combined lint and format checks:

```bash
npm run lint
npm run format:check
```

These commands cover server, app, verification_api, and verification_portal.

To auto-format supported files:

```bash
npm run format
```

The Git hooks run these checks automatically:

- `pre-commit`: server/verification_api/verification_portal format/lint checks and Flutter format/analyze checks
- `pre-push`: pre-commit checks plus server build, server tests, contracts Move tests, verification_api build, and verification_portal build

### Server Checks

```bash
npm run build:server
npm run test:server
```

### Flutter App Checks

```bash
npm run lint:app
npm run format:app:check
```

`lint:app` runs `flutter analyze app`. Flutter tests can be added to the root scripts once the app has test files.

### Verification Checks

```bash
npm run lint:verification_api
npm run lint:verification_portal
```

## Domain And Contract Setup

Granite Lake requires the Sui contract registry to know the domain before users can be registered through OTP verification.

At a high level:

1. Publish or use the configured Granite Lake Move package.
2. Register a domain with its admin wallet in the shared registry.
3. Configure the server with matching `DOMAIN`, `ADMIN_WALLET`, `SUI_PRIVATE_KEY`, `SUI_PACKAGE_ID`, and `SUI_REGISTRY_ID`. `SUI_PRIVATE_KEY` can be a literal env value when Vault is disabled, or a `vault://` reference when Vault is enabled. See [Wallet Setup And Funding](#wallet-setup-and-funding) for creating and funding the admin wallet (and, optionally, a sponsor wallet).
4. Publish a DNS TXT record at `_attest.<domain>` so `verification_api` and `verification_portal` can each confirm the domain's attester wallet out-of-band from the chain. The record value must be `;`-separated `key=value` pairs including `chain_id`, `attester`, and `revoked`, for example:

   ```text
   chain_id=sui:testnet;attester=0x<admin-wallet-address>;revoked=false
   ```

   `attester` must match the domain's admin wallet registered in step 2, and `chain_id` must match the network the registry entry lives on (e.g. `sui:testnet`, `sui:mainnet`). Set `revoked=true` to invalidate the record without removing it. Both `verification_api` (server-side) and `verification_portal` (client-side, in-browser) look this record up against Cloudflare, Google, and AliDNS for consensus, and additionally report DNSSEC validation when both Cloudflare and Google confirm the `AD` flag on the lookup.

5. Enable DNSSEC on the domain so the `AD` flag can be confirmed:

   1. Sign the zone in your DNS provider's dashboard or CLI (e.g. Cloudflare, Route 53, Google Cloud DNS) — most providers offer a one-click "Enable DNSSEC" toggle that generates the signing keys and DS record for you.
   2. Copy the resulting DS record (key tag, algorithm, digest type, digest) from your DNS provider.
   3. Add that DS record at your domain registrar (not the DNS provider, if they differ) to chain the trust up to the parent zone.
   4. Wait for DNS propagation (can take up to 24-48 hours depending on TTLs), then confirm signing is live:

      ```bash
      dig +dnssec _attest.<domain> TXT
      ```

      Look for the `RRSIG` record in the answer and the `ad` flag in the response header. You can also validate the full chain with:

      ```bash
      delv _attest.<domain> TXT
      ```

   Without DNSSEC enabled, the `_attest.<domain>` TXT lookup still works, but `dnssecValidated` reports `null`/`false` instead of `true`. See `verification_api/README.md` for how `dnssecValidated` is computed.

6. Run OTP registration from the app.
7. Capture and attest photos from an enabled wallet.

See:

- `contracts/README.md` for Move package behavior
- `server/README.md` for API configuration and OTP routes
- `app/README.md` for app storage, onboarding, and photo/file attestation flow
- `verification_api/README.md` for the server-side DNS TXT consensus lookup and DNSSEC validation details
- `verification_portal/README.md` for the client-side (in-browser) DNS TXT consensus lookup
- `verification_api/README.md` for DNS TXT consensus lookup and DNSSEC validation details

## Wallet Setup And Funding

Each domain stack uses up to two server-side wallets. Both are separate from the device wallets the app creates for users.

| Wallet                 | Env vars                                | Signs                                                            | Pays for                                              |
| ---------------------- | --------------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------- |
| **Admin** (required)   | `ADMIN_WALLET`, `SUI_PRIVATE_KEY`       | `add_user` / `enable_user` / `disable_user`, and sponsor top-ups | Its own gas, and the SUI it sends to the sponsor      |
| **Sponsor** (optional) | `SPONSOR_WALLET`, `SPONSOR_PRIVATE_KEY` | Gas for users' `attest_photo` / `attest_file`                    | Attestation network fees, so user wallets need no SUI |

The admin key controls user administration for the whole domain, so it is the highest-value secret in the system. The sponsor key is used on every attestation, so it holds only a small working balance and has no admin rights. **They must be different wallets**: the server refuses to start with sponsorship enabled if `SPONSOR_WALLET` equals `ADMIN_WALLET`.

### 1) Create the wallets

With the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install), create one ed25519 address per wallet and export its private key:

```bash
sui client new-address ed25519 acme-admin     # prints the address
sui client new-address ed25519 acme-sponsor
sui keytool export --key-identity acme-admin   # prints suiprivkey1...
sui keytool export --key-identity acme-sponsor
```

Put the values in `server/.env`, or in Vault as `vault://` references (see `server/README.md` → HashiCorp Vault Secrets). Each per-domain stack should be scoped to only its own secret paths.

```env
ADMIN_WALLET=0x<acme-admin address>
SUI_PRIVATE_KEY=suiprivkey1...          # or vault://...
# Only for domain-sponsored attestation gas:
SPONSOR_ENABLED=true
SPONSOR_WALLET=0x<acme-sponsor address>
SPONSOR_PRIVATE_KEY=suiprivkey1...      # or vault://...
```

Use new wallets per network: never reuse testnet keys on mainnet. Then have the contract owner register the domain with the **admin** address (`add_domain`, step 2 above), and use the same address as `attester` in the `_attest.<domain>` DNS TXT record (step 4). The sponsor wallet is never registered on-chain and never appears in DNS. It only pays gas.

### 2) Fund the admin wallet

The admin wallet needs SUI for its own transactions (roughly 0.001–0.01 SUI each), plus whatever it will pass on to the sponsor.

- **Testnet:** request SUI from the [Sui faucet](https://faucet.sui.io) for the admin address, or run `sui client faucet --address <admin address>`.
- **Mainnet:** buy SUI on an exchange, withdraw it to a treasury wallet you control offline, and transfer working amounts to the admin wallet.

Check balances with `sui client balance <address>`. Coin objects and the address balance both work for the admin wallet.

### 3) Fund the sponsor wallet (only with `SPONSOR_ENABLED=true`)

Sponsored gas is paid from the sponsor's **address balance**, not from coin objects. Use one of these, in order of preference:

1. **Top up from the admin wallet (recommended).** This moves SUI from the admin wallet directly into the sponsor's address balance, recorded and limited to `SPONSOR_TOPUP_MAX_PER_DAY_MIST` per UTC day (default 10 SUI):

   ```bash
   curl -X POST https://<server>/admin/sponsor/top-up \
     -H "x-admin-api-key: <ADMIN_API_KEY>" -H "content-type: application/json" \
     -d '{"amountMist":"2000000000"}'   # 2 SUI; 1 SUI = 1,000,000,000 MIST
   ```

2. **Send SUI to the sponsor address directly** (from any wallet, an exchange, or the faucet). It arrives as coin objects, which can't pay sponsored gas until they are moved. The server sweeps them into the address balance automatically every `SPONSOR_LEAK_CHECK_INTERVAL_MS` (default 15 minutes) once they total at least `SPONSOR_COIN_SWEEP_MIN_MIST` (default 0.1 SUI). To sweep immediately:

   ```bash
   curl -X POST https://<server>/admin/sponsor/sweep -H "x-admin-api-key: <ADMIN_API_KEY>"
   ```

Keep about one to two weeks of expected attestation spend in the sponsor. While its address balance is below `SPONSOR_MIN_BALANCE_MIST`, the server stops sponsoring, posts a low-balance Google Chat alert, and app captures wait in the queue. Check the state at any time:

```bash
curl https://<server>/admin/sponsor/summary -H "x-admin-api-key: <ADMIN_API_KEY>"
```

It reports the sponsor's address and coin balances, today's spend against the caps, recent top-ups, and whether sponsorship is paused. If the balance drops by more than recorded attestations explain, sponsorship pauses automatically and an alert is sent. Investigate, then resume with `POST /admin/sponsor/resume`. See `server/README.md` → Sponsored Attestations for all sponsor settings, and `design/granite-lake-sponsored-transactions-design.md` for the full design.

## Notes

- **GPS location data is intentionally removed from a photo's own file before it's
  hashed and attested.** This is deliberate, not a bug or an omission: the photo's GPS
  coordinates are still captured and included in the signed attestation record itself —
  removing them from the image file only stops Android from silently altering that file
  (and its hash) later, outside the app's control, when it's saved, shared, or opened
  elsewhere. See [`app/README.md` → "GPS Data Is Removed From The Photo File
  Itself"](./app/README.md#gps-data-is-removed-from-the-photo-file-itself) for the full
  technical explanation.

## License

Granite Lake is licensed under the [Apache License, Version 2.0](LICENSE).
