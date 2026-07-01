# granite-lake

Open source Granite Lake monorepo for field photo authenticity, domain-scoped user authorization, and Sui-based photo attestation.

## Repository Structure

Top-level folders and what they contain:

- `app/`: Android-focused Flutter application for local wallet creation, biometric protection, photo capture, Sui attestation, and verification.
- `server/`: Per-domain backend API (Fastify + Postgres) for OTP registration, domain user management, and Sui writes.
- `contracts/`: Sui Move package for domain registration, user capabilities, enable/disable controls, and event-only photo attestation.
- `verification_portal/`: Public photo verification portal (Vite + React + TypeScript) for querying attested photos from Sui.
- `verification_api/`: HTTP API backend for photo verification against on-chain attestations with DNS TXT consensus lookup.

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
flutter run
```

The app targets Android. For an Android emulator, the bundled backend resolver tries common local endpoints including `http://10.0.2.2:8080`.

### 4) Start verification API (optional)

```bash
cd verification_api
cp .env.example .env
npm install
npm run dev
```

The verification API runs at `http://localhost:8081` and provides a `/verify-photo` endpoint for photo verification.

### 5) Start verification portal (optional)

```bash
cd verification_portal
npm install
npm run dev
```

The verification portal runs at the Vite dev server URL and provides a web UI for public photo verification.

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
3. Configure the server with matching `DOMAIN`, `ADMIN_WALLET`, `SUI_PRIVATE_KEY`, `SUI_PACKAGE_ID`, and `SUI_REGISTRY_ID`. `SUI_PRIVATE_KEY` can be a literal env value when Vault is disabled, or a `vault://` reference when Vault is enabled.
4. Run OTP registration from the app.
5. Capture and attest photos from an enabled wallet.

See:

- `contracts/README.md` for Move package behavior
- `server/README.md` for API configuration and OTP routes
- `app/README.md` for app storage, onboarding, and attestation flow
