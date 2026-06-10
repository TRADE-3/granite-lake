# Granite Lake API

TypeScript/Fastify API for Granite Lake domain-scoped OTP verification. Each running Docker stack is for one configured domain and one domain admin wallet. OTP sessions and users are stored in Postgres; user add/enable/disable operations are submitted to Sui.

## Deployment Model

One container stack equals one domain.

- `CLIENT_ID` is the Docker/Postgres naming slug. Use the domain label without `.com` or dots, for example `CLIENT_ID=acme`.
- `DOMAIN` is the actual email/on-chain domain, for example `DOMAIN=acme.com`.
- `ADMIN_WALLET` is the public wallet address for the domain admin.
- `SUI_PRIVATE_KEY` must belong to `ADMIN_WALLET`.

Compose names are derived from:

```txt
<NODE_ENV>_<CLIENT_ID>_granite_lake
```

## Before Starting

Register the domain and admin wallet on-chain before starting the API stack. The Move contract requires the domain to exist in the shared registry, and `add_user`, `enable_user`, and `disable_user` must be signed by that domain's admin wallet.

Make sure these values all refer to the same on-chain domain setup:

- `DOMAIN` is the domain already added to the Sui registry.
- `ADMIN_WALLET` is the admin wallet recorded for that domain.
- `SUI_PRIVATE_KEY` is the private key for `ADMIN_WALLET`.
- `SUI_PACKAGE_ID` and `SUI_REGISTRY_ID` point to the deployed Granite Lake package and registry that contain the domain.

If the domain was not added first, OTP verification will fail when the server submits `add_user`.

## Environment

Required for runtime:

```env
NODE_ENV=development
CLIENT_ID=acme
DOMAIN=acme.com
ADMIN_WALLET=0x...
ADMIN_API_KEY=<admin-api-key>
GOOGLE_CHAT_WEBHOOK_URL=<google-chat-webhook-url>
SUI_RPC_URL=https://fullnode.testnet.sui.io:443
SUI_PRIVATE_KEY=<domain-admin-suiprivkey>
SUI_PACKAGE_ID=0x...
SUI_REGISTRY_ID=0x...
```

Optional:

```env
PORT=8080
HOST=0.0.0.0
OTP_TTL_MS=300000
SUI_NETWORK=testnet
SUI_MODULE=photo_attestation
SUI_GAS_BUDGET=10000000
```

`SUI_MODULE` is only the Move module name. Even though the source declares `module granite_lake::photo_attestation`, the transaction target is built as `<SUI_PACKAGE_ID>::<SUI_MODULE>::<function>`, so use `SUI_MODULE=photo_attestation`, not `granite_lake::photo_attestation`.

### OTP Delivery

OTP codes are currently posted to a Google Chat incoming webhook using `GOOGLE_CHAT_WEBHOOK_URL`. This is a temporary delivery path until the paid email service is available. The API still requires `user_email` so it can validate the user belongs to the configured domain and record the verified user identity.

## Local Development

```bash
npm install
cp .env.example .env
docker compose --env-file .env up --build -d
```

The app always derives `DATABASE_URL` from `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, and `POSTGRES_DB`. If running the API directly on your machine, set `POSTGRES_HOST=localhost`.

Run checks:

```bash
npm run build
npm test
docker compose --env-file .env.example config
```

## Authentication

Admin routes require:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

OTP and health routes are public.

## API Reference

### `GET /health`

Checks API and database connectivity.

Response:

```json
{
  "ok": true,
  "service": "granite-lake-api",
  "database": "up"
}
```

### `GET /utc`

Returns server UTC time.

Response:

```json
{
  "utc": "2026-06-05T05:30:00.000Z"
}
```

### `POST /otp/request`

Creates an OTP session and posts the OTP details to the configured Google Chat webhook. This replaces email delivery for now, until the paid email service is enabled.

Rules:

- `domain` must match env `DOMAIN`.
- `user_email` must be a valid email.
- `user_email` domain must match env `DOMAIN`.
- `user_email` must not already exist in the `users` table.
- The OTP is not returned by the API.

Request:

```json
{
  "domain": "acme.com",
  "user_email": "alice@acme.com"
}
```

Success `201`:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "expiresAt": "2026-06-05T05:35:00.000Z",
  "domain": "acme.com",
  "userEmail": "alice@acme.com"
}
```

Possible errors:

```json
{
  "error": "invalid_email_domain",
  "message": "user_email must belong to acme.com."
}
```

```json
{
  "error": "user_email_exists",
  "message": "User email alice@acme.com is already registered."
}
```

### `GET /otp/:userId`

Returns OTP session status for debugging/status polling.

Response:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "domain": "acme.com",
  "userEmail": "alice@acme.com",
  "userWallet": null,
  "adminWallet": "0x...",
  "txDigest": null,
  "userCapId": null,
  "status": "pending_verification",
  "createdAt": "2026-06-05T05:30:00.000Z",
  "expiresAt": "2026-06-05T05:35:00.000Z",
  "verifiedAt": null,
  "error": null
}
```

### `POST /otp/verify`

Verifies the OTP and submits on-chain `add_user`.

Rules:

- OTP session must exist.
- OTP must not be expired.
- OTP must match.
- `domain` must match env `DOMAIN`.
- `userWallet` must be a Sui address.
- Sui `add_user` must succeed before the user is stored as active.

Request:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "otp": "123456",
  "domain": "acme.com",
  "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}
```

Success:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "domain": "acme.com",
  "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "txDigest": "9k...",
  "userCapId": "0x...",
  "status": "completed",
  "verifiedAt": "2026-06-05T05:31:00.000Z"
}
```

### `GET /admin/users`

Lists users for this domain container.

Headers:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Response:

```json
{
  "users": [
    {
      "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
      "domain": "acme.com",
      "userEmail": "alice@acme.com",
      "userWallet": "0x...",
      "adminWallet": "0x...",
      "status": "active",
      "userCapId": "0x...",
      "addUserTxDigest": "9k...",
      "disableUserTxDigest": null,
      "enableUserTxDigest": null,
      "createdAt": "2026-06-05T05:31:00.000Z",
      "updatedAt": "2026-06-05T05:31:00.000Z",
      "lastVerifiedAt": "2026-06-05T05:31:00.000Z",
      "disabledAt": null
    }
  ]
}
```

### `PATCH /admin/users/:userId/disable`

Submits on-chain `disable_user`, then marks the user as disabled in Postgres.

Headers:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Success:

```json
{
  "message": "User disabled successfully.",
  "user": {
    "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
    "status": "disabled",
    "disableUserTxDigest": "8s..."
  }
}
```

### `PATCH /admin/users/:userId/enable`

Submits on-chain `enable_user`, then marks the user as active in Postgres.

Headers:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Success:

```json
{
  "message": "User enabled successfully.",
  "user": {
    "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
    "status": "active",
    "enableUserTxDigest": "7q..."
  }
}
```

## Data Model

`otp_sessions` stores pending/completed OTP flows:

- `user_id`
- `user_email`
- `user_wallet`
- `otp_hash`
- `status`
- `expires_at`
- `verified_at`
- `tx_digest`
- `user_cap_id`
- `error`

`users` stores verified users:

- `user_id`
- `user_email`
- `user_wallet`
- `status`
- `user_cap_id`
- `add_user_tx_digest`
- `disable_user_tx_digest`
- `enable_user_tx_digest`
- timestamps

The database does not store `domain` or `admin_wallet`; those come from env because each stack is domain-scoped.

## Flow

1. User requests an OTP with `domain` and `user_email`.
2. Server validates the email domain and checks the email is not already registered.
3. Server stores an OTP session and posts the OTP to Google Chat.
4. User submits `userId`, `otp`, `domain`, and `userWallet`.
5. Server verifies OTP and submits Sui `add_user`.
6. Server stores the user as `active`.
7. Admin can call disable/enable endpoints, which also submit Sui transactions.
