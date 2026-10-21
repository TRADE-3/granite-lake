# Granite Lake — Domain-Sponsored Attestation Gas

**Author:** Nethmi Jayakody
**Status:** Draft for review
**Related:** [Sui sponsored transactions](https://docs.sui.io/develop/transaction-payment/sponsor-txn),
`granite-lake-app-auth-design.md` (API-key model the new routes inherit),
`server/src/services/SuiService.ts`, `app/lib/core/services/photo_attestation_service.dart`

## 1. Problem

Every account created through OTP registration gets a device-local Sui wallet, and today that
wallet must hold SUI before the user can attest anything:

- `attest_photo` / `attest_file` transactions are built with `gasData.owner == sender == user
wallet` (`photo_attestation_service.dart`, `attestPhoto` / `attestFile`).
- Capture submission and queue retry are gated on `hasEnoughSuiForAttestation`, which requires at
  least `minimumAttestationMistBalance` = 4,000,000 MIST (`granite_lake_controller.dart`,
  `app_constants.dart`).
- The profile screen's "HOW TO TOP UP" steps send users to the faucet (`AppConstants.topUpUrl`).

This causes three problems:

- **Onboarding friction.** Field crews are not crypto users. A manual funding step after
  registration is the step most likely to stall a rollout, and on mainnet it means someone has to
  buy and distribute SUI to every device.
- **Funds are stranded on devices.** SUI sent to a device wallet is lost when the device is reset
  or biometrics are re-enrolled (which triggers the app reset flow). It is also stuck when the
  user is disabled, and it can be spent on things other than attestations.
- **No central control of spend.** The domain cannot cap, monitor or stop gas spend per user.

## 2. Background — Sui sponsored transactions

From the Sui documentation:

- `TransactionData` carries `kind`, `sender`, `gas_data` and `expiration`. When
  `gas_data.owner != sender`, the transaction is **sponsored**: the gas owner pays, and the
  sender is still the author of the transaction.
- Both the sender and the gas owner sign the **entire** `TransactionData`, including `GasData`.
  Changing any byte after either party signs invalidates that party's signature.
- Gas can be paid from the gas owner's **address balance** by leaving `gas_data.payment` empty.
  This requires a `ValidDuring` expiration (an epoch range, the chain id and a nonce) for replay
  protection. The TypeScript SDK fills these in when building with a connected client. The app
  already uses this mechanism for self-paid gas (`_bcsWithValidDuringExpiration`).
- The docs give these hardening rules, all adopted here: per-user rate limits, an allowlist of
  `moveCall` targets, a per-transaction budget cap, monitoring spend through `gas_cost_summary`,
  and a dedicated sponsor address instead of the main admin address.

Two properties of Granite Lake make sponsorship a clean fit:

1. **The contract already pins the sender.** `attest_photo` / `attest_file` assert
   `tx_context::sender(ctx) == user_cap.user_wallet` (`E_NOT_USER`), and `assert_user_enabled`
   re-checks the registry. A sponsored transaction keeps `sender = user`, so every existing
   on-chain guarantee is unchanged.
2. **Attestations are event-only.** They take no coin parameters and create no objects, so gas
   use is small and predictable, and tight per-transaction caps are practical.

## 3. Goals and non-goals

**Goals**

- Users attest photos and files with **zero SUI** in their wallet: no faucet, no top-up, no
  balance gates.
- Each domain pays gas for its own users from one sponsor wallet that the domain admin funds and
  controls.
- The sponsor key only ever signs allowlisted `attest_photo` / `attest_file` transactions, and
  only ones that an active registered user of the domain has **already signed**.
- Spend is bounded and observable through per-transaction, per-user and per-domain caps, with
  alerts before the sponsor runs dry or if it is drained unexpectedly.
- The user's signature remains informed consent: the app verifies exactly what it signs.

**Non-goals**

- No contract changes.
- No changes to the verification portal or the verification API. See §15.
- No changes to capture, hashing, GPS stripping, at-rest encryption, biometric gating or the
  offline queue model.
- No sponsoring of `add_user`, `enable_user` or `disable_user`. These are already admin-signed
  and admin-paid in `SuiService.executeDomainAdminCall`.
- No third-party gas station and no wildcard gas payments, where the client could attach
  sponsor gas to any transaction it builds.

## 4. Design decisions

### 4.1 A dedicated sponsor wallet, funded by the domain admin

The domain admin is the funder and owner of sponsorship. However, gas is signed by a
**dedicated per-domain sponsor wallet**, not by `SUI_PRIVATE_KEY`.

- **Reason: the admin key is the highest-value secret in the system.** It controls `add_user`,
  `enable_user` and `disable_user` for the whole domain. The sponsor path is reachable by every
  app install and runs on every attestation. Keeping the two keys separate means a bug or
  compromise in the sponsor path can at most spend the sponsor's balance. It can never touch
  user administration.
- **Small blast radius.** The sponsor wallet holds a small working balance, topped up by the
  admin, while the bulk of the domain's SUI stays in the admin wallet.
- **Simple rotation.** A sponsor key can be rotated by changing env vars and moving the remaining
  balance. No on-chain action is needed, whereas rotating the admin key needs the contract owner
  (`set_domain_admin`).
- **Enforced, not by convention.** When sponsorship is enabled, the server refuses to boot if
  `SPONSOR_WALLET` equals `ADMIN_WALLET`. There is no fallback from `SPONSOR_PRIVATE_KEY` to
  `SUI_PRIVATE_KEY`.

### 4.2 The server builds the whole transaction from attestation values

The app sends **attestation values** (hash, GPS, project, flags and so on), not transaction
bytes. The server builds the entire `TransactionData`: inputs, the single `MoveCall`, sender and
gas data.

| Option                                                | Verdict                                                                                                                                                     |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App builds full `TransactionData` including `GasData` | Rejected. The server would have to validate untrusted gas data, and the app would need the sponsor's state.                                                 |
| App sends a gasless transaction kind; server adds gas | Rejected. The server must parse and allowlist untrusted transaction bytes, and one validation gap (e.g. an extra `SplitCoins(GasCoin)`) drains the sponsor. |
| **App sends values; server builds everything**        | **Chosen.** No untrusted transaction bytes reach the sponsor path. The server can only ever build the single allowlisted call.                              |

### 4.3 The user signs first; the sponsor signs only user-signed bytes

The flow has two steps, `prepare` and `submit`:

1. **Prepare.** The server builds the transaction, simulates it, caches the bytes and returns
   them **unsigned**.
2. **Sign on the device.** The app verifies the bytes (§8) and signs them with the
   biometric-gated key.
3. **Submit.** The server verifies the user's signature over the exact bytes it cached. Only then
   does it sign as sponsor.

A sponsor signature therefore never exists for a transaction that an active user has not already
authorized. Spamming `prepare` costs nothing in gas, and a leaked `APP_API_KEY` alone cannot
spend sponsor funds.

### 4.4 The server submits; the app confirms on-chain

After signing as sponsor, the server submits both signatures and records the actual gas used
from the transaction effects. This gives exact, immediate spend accounting and idempotent
retries with no reconciliation job in the normal path.

The trade-off from the Sui docs is censorship: a sponsor could withhold a signed transaction.
That adds no real risk here, because the sponsor can always refuse to sign in the first place,
and the sponsor is the domain's own backend.

The server's response is still not trusted as proof of attestation. After `submit` returns, the
app looks the digest up on-chain and checks the `PhotoAttested` / `FileAttested` event before
marking the capture attested (§11).

### 4.5 Gas is paid from the sponsor's address balance

The sponsor pays from its SUI **address balance** (`payment = []`), not from coin objects.

- **No gas coin pool or locking.** Sponsors that pay with coin objects must keep a pool of coins
  and track which ones are in flight. Two transactions that reference the same coin version
  equivocate, and the coin can be locked until the end of the epoch. Address-balance payment
  references no gas object, so concurrent sponsorships for many users are safe and the server
  holds no coin-reservation state.
- **App verification is unaffected.** The `ValidDuring` expiration this requires is a layout the
  app already serializes, so it can verify it exactly (§8).

## 5. End-to-end flow

```text
App                                    Server (per-domain stack)                Sui fullnode
 |                                       |                                        |
 |-- POST /sponsor/prepare ------------->|                                        |
 |   { userWallet, kind, args }          |-- API key, rate limit                  |
 |                                       |-- validate args (§7.1)                 |
 |                                       |-- user active? quota? balance?         |
 |                                       |-- resolve UserCap / Registry / Clock --|--> object reads
 |                                       |-- build TransactionData                |
 |                                       |   sender = user                        |
 |                                       |   gas owner = SPONSOR_WALLET           |
 |                                       |   payment = [] (address balance)       |
 |                                       |   expiration = ValidDuring             |
 |                                       |-- simulate, set budget, enforce caps --|--> simulate
 |                                       |-- cache bytes by digest (TTL)          |
 |<-- { digest, txBytes, declared ... } -|                                        |
 |                                       |                                        |
 | rebuild expected bytes from own       |                                        |
 | capture values; exact prefix match;   |                                        |
 | check expiration tail, gas owner,     |                                        |
 | budget, price  -> ABORT on mismatch   |                                        |
 |                                       |                                        |
 |-- biometric-gated key signs bytes     |                                        |
 |                                       |                                        |
 |-- POST /sponsor/submit -------------->|                                        |
 |   { userWallet, digest, signature }   |-- API key, rate limit                  |
 |                                       |-- user still active? quota re-check    |
 |                                       |-- verify user sig over cached bytes    |
 |                                       |-- insert ledger row (budget reserved)  |
 |                                       |-- sponsor-sign same bytes              |
 |                                       |-- execute [userSig, sponsorSig] -------|--> execute
 |                                       |-- record gas used from effects         |
 |<-- { digest, status, gasUsed } -------|                                        |
 |                                       |                                        |
 |-- look up digest, check event ------------------------------------------------>|
 |-- mark capture attested (existing path)                                        |
```

## 6. API

The new route plugin is `server/src/routes/sponsor.ts`, registered alongside `otpRoutes`. It uses
an `onRequest` hook calling the existing `requireAppApiKey` (same pattern as `otp.ts`), and every
body is zod-validated. A small `bodyLimit` (e.g. 16 KB) applies to the route.

### 6.1 `GET /sponsor/status`

This endpoint lets the app decide between the sponsored and self-paid paths, and tells the
profile screen to hide the top-up steps. It also gives the app the sponsor address it checks
against in §8.

```json
{ "enabled": true, "sponsorWallet": "0x...", "maxGasBudgetMist": "50000000", "maxGasPriceMist": "1000" }
```

When sponsorship is disabled it returns `{ "enabled": false }`. The sponsor balance is never
included.

### 6.2 `POST /sponsor/prepare`

Request (photo variant; `kind: "file"` replaces the GPS fields with `fileId`):

```json
{
  "userWallet": "0x...",
  "kind": "photo",
  "args": {
    "hash": "<64 lowercase hex chars>",
    "gps": "<utf8>",
    "altitude": "<utf8>",
    "projectId": "<utf8>",
    "capturedAtMs": 1760000000000,
    "isOnline": true,
    "isForcedOffline": false,
    "internetNullReasonHash": "<64 hex chars or empty>",
    "hasGps": true,
    "isGpsForcedNull": false,
    "gpsNullReasonHash": "<64 hex chars or empty>"
  }
}
```

The server encodes arguments **exactly as the app does today**, so events are unchanged and the
portal keeps working:

- `hash`, `gps`, `altitude`, `projectId` and `fileId` are passed as the UTF-8 bytes of the string.
  For `hash`, that is the 64-character hex text, **not** 32 decoded bytes (`utf8.encode(...)` in
  `attestPhoto` / `attestFile`).
- The two null-reason hashes are hex-decoded to 32 raw bytes, or passed as empty vectors
  (`_hexToBytes(...)`).
- The input order matches the contract signatures and the app's current builder: `UserCap`,
  `Registry`, the values, then `Clock`.

Response (`201`):

```json
{
  "digest": "<base58 tx digest>",
  "txBytes": "<base64 TransactionData BCS>",
  "sender": "0x...",
  "gasData": { "owner": "0x...", "price": "1000", "budget": "6000000", "payment": [] },
  "objectRefs": {
    "userCap": { "objectId": "0x...", "version": "5", "digest": "<base58>" },
    "registry": { "objectId": "0x...", "initialSharedVersion": "3", "mutable": false },
    "clock": { "objectId": "0x6", "initialSharedVersion": "1", "mutable": false }
  },
  "validDuring": { "minEpoch": "812", "maxEpoch": "813", "chain": "<base58>", "nonce": 123456789 },
  "expiresAt": "2026-10-19T12:05:00.000Z"
}
```

`expiresAt` is the server-side prepare TTL (`SPONSOR_PREPARE_TTL_MS`). After it passes, `submit`
is refused and the app must prepare again.

### 6.3 `POST /sponsor/submit`

```json
{ "userWallet": "0x...", "digest": "<base58>", "userSignature": "<base64 serialized Sui signature>" }
```

The client never re-sends transaction bytes. The signature is verified against the bytes the
server cached at prepare time.

Responses:

```json
// 200, executed (also returned for an idempotent repeat of an executed digest)
{ "digest": "...", "status": "executed", "gasUsedMist": "1980000" }

// 200, landed on-chain but aborted (rare race with disable_user); app re-prepares
{ "digest": "...", "status": "failed", "gasUsedMist": "1000000", "error": "..." }
```

### 6.4 Error mapping

| Status | Code                                       | Meaning / app behavior                                                                   |
| ------ | ------------------------------------------ | ---------------------------------------------------------------------------------------- |
| 400    | `invalid_request`                          | Malformed body or argument fails validation (§7.1). Abort; do not retry as-is.           |
| 400    | `invalid_user_signature`                   | Signature doesn't verify against the cached bytes for this wallet. Abort.                |
| 401    | `unauthorized`                             | Bad `x-app-api-key`.                                                                     |
| 403    | `user_not_active`                          | Unknown, disabled, or no `user_cap_id`. Abort; capture stays `FAILED_SUBMISSION`.        |
| 404    | `prepared_tx_not_found`                    | Digest unknown, expired or evicted (e.g. server restart). Re-prepare.                    |
| 409    | `quota_exceeded`                           | User or domain daily cap reached. Keep queued; retry later. Never fall back to self-pay. |
| 422    | `simulation_failed`                        | The transaction would abort on-chain (e.g. null-reason mismatch). Abort, show error.     |
| 429    | `rate_limit_exceeded`                      | Back off using `Retry-After`; keep queued. Never fall back to self-pay.                  |
| 502    | `sui_rpc_failed`                           | Chain/RPC error, retryable (treated like the app's existing network-class failures).     |
| 503    | `sponsor_disabled` / `sponsor_unavailable` | Off, balance below reserve, gas price above cap, or paused (§14.3). Self-pay fallback.   |

## 7. Server validation pipeline

Steps are ordered from cheap to expensive. A request that fails any step never reaches the sponsor
key.

### 7.1 Prepare

1. **API key:** `x-app-api-key` equals `APP_API_KEY`.
2. **Request rate:** per `userWallet` and per IP, using new `RateLimiter` instances in
   `utils/rateLimit.ts` (e.g. 30/min each). These limit request volume only; money caps are
   in Postgres (§9).
3. **Argument shape:** `userWallet` is a valid Sui address, and zod parses a union keyed on
   `kind`. Then each field is checked:

   | Field                                         | Rule                                                                |
   | --------------------------------------------- | ------------------------------------------------------------------- |
   | `hash`                                        | Exactly 64 lowercase hex chars                                      |
   | `gps`, `altitude`                             | ≤ 64 UTF-8 bytes each                                               |
   | `projectId`, `fileId`                         | ≤ 128 UTF-8 bytes each                                              |
   | `internetNullReasonHash`, `gpsNullReasonHash` | Empty, or exactly 64 hex chars (32 bytes)                           |
   | `capturedAtMs`                                | Safe integer, ≥ 0, not more than 5 min in the future (past allowed) |

   The future-skew limit allows for device clock drift; there is no lower bound because offline
   captures can be old. Size limits bound what each sponsored transaction can cost.

4. **User:** `findUserBy("wallet", userWallet)` must return a row with `status = 'active'` and a
   `user_cap_id`. This checks the server's own records first, so the sponsor never pays for a
   transaction that would abort on `E_USER_DISABLED`.
5. **Quota:** the daily caps (§9), computed from `sponsor_transactions`.
6. **Sponsor health:** the sponsor's address balance is at least `SPONSOR_MIN_BALANCE_MIST`
   (cached for about 30 s), the reference gas price is at most `SPONSOR_MAX_GAS_PRICE_MIST`,
   and sponsorship is not paused (§14.3).
7. **Objects:** resolve the `UserCap` by `users.user_cap_id` and assert its type is
   `<package>::photo_attestation::UserCap` and its owner is `userWallet`. Resolve the shared
   `Registry` (`SUI_REGISTRY_ID`) and `Clock` (`0x6`), both **immutable**. The functions take
   `&Registry`, and marking this hot shared object mutable would needlessly serialize every
   attestation.
8. **Build:** `new Transaction()` with exactly one `moveCall` to
   `${SUI_PACKAGE_ID}::${SUI_MODULE}::attest_photo|attest_file`. This is the only call
   `SponsorService` can construct; there is no code path that accepts a target from the client.
   Then `setSender(userWallet)`, `setGasOwner(SPONSOR_WALLET)`, `setGasPayment([])` and
   `setGasPrice(referenceGasPrice)`.
9. **Simulate:** run with the sponsor as gas owner. It must return `SUCCESS`. Simulation is the
   semantic check: it catches `E_NOT_USER`, `E_USER_DISABLED`, the null-reason invariants and
   `UserCap` problems before any gas is at risk.
10. **Budget:** `computationCost + storageCost + overhead`, the same formula as the app's
    `_dryRun`. Refuse with `422` if it exceeds `SPONSOR_MAX_GAS_BUDGET_MIST`.
11. **Build and cache:** `build({ client })` produces the bytes, with the SDK filling in the
    `ValidDuring` expiration and nonce. Compute the digest and cache
    `{ bytes, userWallet, kind, budget, expiresAt }` in memory, keyed by digest. There is one
    container per domain stack, so an in-memory cache is enough, and a lost entry only forces a
    re-prepare. Cap the number of outstanding prepared transactions per wallet (e.g. 5) to
    bound memory.

### 7.2 Submit

1. **API key and rate limit:** as in prepare.
2. **Cached bytes:** an entry exists for `digest`, has not expired, and its `userWallet` matches
   the request.
3. **User still active:** re-run the user lookup and require `status = 'active'`. An admin may
   have disabled the user between prepare and submit.
4. **User signature:** `verifyTransactionSignature(bytes, userSignature, { address: userWallet })`
   from `@mysten/sui/verify`. **This is the property the whole design rests on: the sponsor key
   only signs bytes the server itself built and an active registered user has signed.**
5. **Idempotency and quota:** if a row for this digest already exists, return its stored result
   (or resolve it, §12). Otherwise re-check the daily caps and insert a row with
   `status = 'signed'` and the budget reserved.
6. **Sponsor-sign and execute:** `sponsorKeypair.signTransaction(bytes)`, then
   `executeTransaction` with `[userSignature, sponsorSignature]`. Read the effects and update the
   row to `executed` or `failed`, recording `gas_used`
   (`computationCost + storageCost − storageRebate`).
7. **Evict:** remove the cache entry, so a digest can be sponsor-signed only once.

## 8. App-side verification before signing

The user's signature authorizes the whole `TransactionData`. A compromised server must not be
able to make the device key sign an attestation of content the user never captured, or move gas
costs onto the user. The app only signs if all of the following hold:

1. **Exact prefix match.** The app rebuilds the expected `SuiTransactionDataV1` using its existing
   builder (`attestPhoto` / `attestFile`), from:
   - its **own** capture values;
   - the server's `objectRefs`, after checking that `userCap.objectId` equals its stored
     `userCapObjectId`, `registry.objectId` equals the bundled registry id, and the clock is
     `0x6`;
   - the server's declared `gasData`, with `payment: []`.

   It serializes this with `expiration: None`, drops the final `None` tag byte, and requires
   `txBytes` to start with exactly those bytes. This pins the package, module, function,
   arguments, sender and every gas field.

2. **Expiration tail.** The remaining bytes must be exactly one `ValidDuring` expiration, in the
   layout `_bcsWithValidDuringExpiration` already writes:
   - variant 2;
   - `minEpoch` equal to the current epoch, and `maxEpoch ≤ minEpoch + 1`;
   - no timestamp bounds;
   - the chain id equal to the one from `getChainInfo`;
   - a 4-byte nonce;
   - nothing after it.
3. **Gas sanity.** The following must all hold, or the app refuses to sign:
   - `gasData.owner == sponsorWallet` from `/sponsor/status`.
   - `gasData.owner != own wallet`. This is the check that stops a compromised server from
     quietly making the user pay.
   - `budget ≤ maxGasBudgetMist`.
   - `price ≤ maxGasPriceMist`.

The key is never used on any mismatch.

The app checks the gas owner against `/sponsor/status` instead of a value pinned at
registration. The user's signature can only authorize their own attestation, and the only way a
gas owner other than the real sponsor could harm the user is if it were the user's own wallet,
which check 3 rejects. Not pinning the address also means sponsor key rotation needs no app
change.

A cross-SDK fixture test (§16) pins the guarantee that the TypeScript builder and the Dart
builder produce identical bytes for the same attestation.

## 9. Spend controls and quotas

Money caps are computed from `sponsor_transactions` in Postgres, so they survive restarts and
redeploys. A user's daily gas is `gas_used` for resolved rows plus `gas_budget` for unresolved
(`signed`) rows. Values reported by the client are never used for enforcement.

| Env var (server)                      | Default          | Purpose                                                                  |
| ------------------------------------- | ---------------- | ------------------------------------------------------------------------ |
| `SPONSOR_ENABLED`                     | `false`          | Master switch per domain stack.                                          |
| `SPONSOR_PRIVATE_KEY`                 | none (required)  | Sponsor key; literal or `vault://` ref via `resolveSecretValue`.         |
| `SPONSOR_WALLET`                      | none (required)  | Must match the key and must differ from `ADMIN_WALLET`, checked at boot. |
| `SPONSOR_MAX_GAS_BUDGET_MIST`         | `50_000_000`     | Per-transaction budget ceiling (the app's current build budget).         |
| `SPONSOR_MAX_GAS_PRICE_MIST`          | `1_000`          | Refuse to sponsor while the reference gas price is above this.           |
| `SPONSOR_TX_PER_USER_PER_DAY`         | `200`            | Daily transaction count cap per user.                                    |
| `SPONSOR_GAS_PER_USER_PER_DAY_MIST`   | `1_000_000_000`  | Daily gas cap per user (1 SUI).                                          |
| `SPONSOR_TX_PER_DOMAIN_PER_DAY`       | `5_000`          | Daily transaction count cap for the domain.                              |
| `SPONSOR_GAS_PER_DOMAIN_PER_DAY_MIST` | `50_000_000_000` | Daily gas cap for the domain (50 SUI).                                   |
| `SPONSOR_PREPARE_TTL_MS`              | `300_000`        | How long prepared bytes stay submittable.                                |
| `SPONSOR_MIN_BALANCE_MIST`            | `1_000_000_000`  | Below this, return `503 sponsor_unavailable` and alert.                  |
| `SPONSOR_LEAK_CHECK_INTERVAL_MS`      | `900_000`        | Interval of the unexpected-spend check (§14.3).                          |

The caps and the allowlist bound the worst case for a fully compromised app, or for a stolen
device that is still unlocked: it can spend the per-user and per-domain caps on valid
attestations, and nothing else. It can never transfer the sponsor's funds.

Planning figure: a sponsored attestation costs roughly a few million MIST at testnet prices.
The app's existing 4,000,000 MIST gate is the current upper estimate. Measure it on testnet
during rollout and tune the caps from real numbers.

## 10. Data model

`server/src/db/migrations/008_add_sponsor_transactions.sql`:

```sql
create table if not exists sponsor_transactions (
  tx_digest text primary key,
  user_id text not null references users(user_id),
  kind text not null check (kind in ('photo', 'file')),
  status text not null check (status in ('signed', 'executed', 'failed', 'dropped')),
  gas_budget bigint not null,
  gas_used bigint,
  max_epoch bigint not null,
  error text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists sponsor_transactions_user_created_idx on sponsor_transactions (user_id, created_at);
create index if not exists sponsor_transactions_status_created_idx on sponsor_transactions (status, created_at);
```

**Privacy minimization.** The table stores **no attestation content**: no hashes, GPS, project
ids or transaction bytes. The server sees the values briefly at prepare time, as it already does
with registration data, but never persists them.

New repository functions follow the plain-function style of `repositories.ts`:
`insertSponsorTransaction`, `resolveSponsorTransaction`, `getSponsorUsage(scope, day)` and
`listUnresolvedSponsorTransactions`.

## 11. App changes and fallback behavior

- **New `SponsorAttestationService`** (`app/lib/core/services/sponsor_attestation_service.dart`).
  It makes the status, prepare and submit calls over the existing `GL_OTP_BACKEND_CONFIG`
  backend and runs the §8 verification. Signing stays on the existing path
  (`SuiEd25519Account.signTransaction([0, 0, 0, ...bytes])`) with the same keys and the same
  biometric requirements.
- **`photo_attestation_service.dart`.** Extract the argument and transaction-building core so
  the self-paid path and the sponsored verification share one builder.
- **On-chain confirmation.** After `submit` returns `executed`, fetch the transaction by digest
  over GraphQL and confirm a `PhotoAttested` / `FileAttested` event with the expected hash and
  wallet. Only then update the capture row through the existing path. A server cannot report an
  attestation that never landed.
- **`GraniteLakeController`.** Check `/sponsor/status` at startup and on resume. When
  sponsorship is enabled:
  - route fresh captures and queued retries through the sponsored path;
  - skip the `hasEnoughSuiForAttestation` gates;
  - make the profile screen hide the "HOW TO TOP UP" steps and show plain-language copy such
    as "Your organisation covers the network fee". No chain jargon, per the onboarding rule.
- **Fallback to self-pay.** Only on `503 sponsor_disabled` / `sponsor_unavailable`, and only
  when the wallet passes today's balance gate. Otherwise the capture stays queued. `409` and
  `429` never fall back, so a rate-limited or capped user doesn't silently start spending their
  own funds. One app build works for both sponsored and self-paid domains.
- **Queue semantics.** Network-class failures leave the row `PENDING_SUBMISSION` as they do
  today. Every retry runs the full prepare, verify, sign, submit cycle with a fresh transaction,
  and still requires a biometric unlock. Capture-time behavior and at-rest encryption are
  unchanged: sponsorship is only requested at submission, which already needs connectivity.

## 12. Failure modes

| Failure                                       | Behavior                                                                                                                           |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Server unreachable or 5xx                     | Capture stays queued; retried on resume or when connectivity returns, as today.                                                    |
| Prepared tx expired or evicted (restart, TTL) | `404 prepared_tx_not_found`; app re-prepares. No gas at risk, since the sponsor never signed.                                      |
| App backgrounded between prepare and submit   | Prepared bytes expire; nothing is signed or charged.                                                                               |
| User disabled between prepare and submit      | `403` at submit. If the database lagged, on-chain `assert_user_enabled` aborts it and the gas is charged and recorded.             |
| Simulation passes but execution aborts        | Row `failed` with `gas_used` counted against the caps; app re-prepares or surfaces the error.                                      |
| Execute call times out (outcome unknown)      | Row stays `signed`. A repeated submit, or the periodic sweep, looks up the digest and resolves it to `executed` / `failed`.        |
| Signed tx never lands                         | The sweep marks the row `dropped` once the chain epoch passes `max_epoch`, releasing its reserved budget.                          |
| Duplicate submit after a network loss         | Idempotent: the existing row's result is returned.                                                                                 |
| `UserCap` version moved since prepare         | Simulation or execution reports an object-version error; the app's existing version-race retry re-prepares with a fresh reference. |
| Sponsor balance below reserve                 | `503 sponsor_unavailable` plus an alert; app falls back to self-pay or keeps the capture queued.                                   |

## 13. Threat model

| Threat                                              | Mitigation                                                                                                                                                             |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sponsor signs an arbitrary transaction (coin drain) | Structurally impossible: the server builds the only transaction it can sign, a single allowlisted `MoveCall`. No endpoint sponsor-signs client-supplied bytes.         |
| Gas drain through prepare spam                      | Prepare never signs or spends; request rate limits bound the cost to simulations.                                                                                      |
| Gas drain by a legitimate user or a stolen device   | Per-user and per-domain transaction and gas caps, a per-transaction budget cap, and argument size limits. The admin can `disable_user`, which blocks the next prepare. |
| Leaked `APP_API_KEY`                                | Not enough to spend: submit requires a valid signature from an active registered user's device key.                                                                    |
| Signatures collected now, used later                | The sponsor signs only inside `submit` and executes immediately. A digest is signed at most once, and `ValidDuring` bounds how long the bytes can land.                |
| Compromised server swaps attestation content        | App-side exact byte verification against its own capture values (§8); the key is never used on a mismatch.                                                             |
| Compromised server makes the user pay gas           | The app requires `gasData.owner != own wallet` and that it equals the advertised sponsor (§8).                                                                         |
| Bytes altered after signing                         | Protocol-level: both signatures cover the full `TransactionData`, so any change invalidates them.                                                                      |
| Server falsely reports success                      | The app confirms the digest and event on-chain before marking the capture attested (§11).                                                                              |
| Replay of a dual-signed transaction                 | Sui executes a digest at most once; the `ValidDuring` nonce and epoch bounds prevent replay outside the window; the ledger is keyed by digest.                         |
| Sponsor gas-coin equivocation                       | Address-balance gas: no gas coin objects are referenced (§4.5).                                                                                                        |
| Sponsor key compromise                              | Dedicated key in Vault with a small balance and no admin rights. Unexpected-spend detection pauses sponsorship (§14.3). Rotation needs no on-chain action.             |
| Admin key exposure through the sponsor path         | The sponsor code path never loads `SUI_PRIVATE_KEY`; boot fails if the two wallets are the same (§4.1).                                                                |
| Disabled user burning gas                           | Active check at prepare and submit, plus simulation; on-chain `assert_user_enabled` as the final backstop.                                                             |
| Quota evasion through many accounts                 | Registration needs an OTP to a unique email, and disabled users cannot re-register (existing boundary). Domain-wide caps bound the total regardless.                   |
| Testnet keys or funds reused on mainnet             | Separate sponsor wallets and caps per `SUI_NETWORK`.                                                                                                                   |

## 14. Operations

### 14.1 Funding

- The domain admin funds the sponsor wallet's **address balance**, keeping a working float of
  roughly one to two weeks of expected spend.
- SUI held in coin objects cannot pay gas with `payment = []`. The status route (§14.4) reports
  coin balance and address balance separately, as `SuiService.logGasState` already does, so a
  mis-funded wallet is obvious.

### 14.2 Rotation

1. Generate a new sponsor key and store it in Vault.
2. Update `SPONSOR_WALLET` / `SPONSOR_PRIVATE_KEY`.
3. Move the remaining balance and redeploy.

Apps pick up the new address from `/sponsor/status` (§8), so no app release is needed.

### 14.3 Unexpected-spend detection

A periodic job (`SPONSOR_LEAK_CHECK_INTERVAL_MS`) compares the drop in the sponsor balance since
the last run with the gas recorded in `sponsor_transactions` over the same window.

- **If the balance fell by noticeably more than the ledger explains,** something other than
  this server is spending from the sponsor wallet. The job pauses sponsorship (prepare returns
  `503 sponsor_unavailable`) and sends a Google Chat alert. Re-enabling it is a deliberate admin
  action.
- **Top-ups can mask a drain.** A top-up only raises the balance, so a drain could go unnoticed
  in the window where a top-up happened. The next window still catches it.

The same job also resolves stale `signed` rows (§12).

### 14.4 Monitoring

- `GET /admin/sponsor/summary` (behind `ADMIN_API_KEY`) returns: enabled or paused state, the
  sponsor address, coin and address balances, today's and the last 7 days' transaction counts
  and gas per user and per domain, unresolved rows, and recent failures.
- Alerts go through a new generic `GoogleChatService.sendText`:
  - balance below `SPONSOR_MIN_BALANCE_MIST`;
  - domain daily gas above 80% of its cap;
  - a user hitting their quota (rate-limited, not sent on every occurrence);
  - unexpected spend (§14.3).

  A failure to send an alert must never fail a user request.

- `/health` stays public and does not expose balances.

### 14.5 Incident response

- **Sponsor key compromised:** set `SPONSOR_ENABLED=false`, move the remaining balance to the
  admin wallet, then rotate.
- **Abusive user:** `disable_user` through the existing admin route. The `users.status` check
  blocks their next prepare immediately.

## 15. Effect on verification

No change is needed in the verification portal or the verification API.

- **The attester is still the user's wallet.** `sender` is the user's wallet, signed by the
  user. The contract requires `sender == user_cap.user_wallet`, and the events record
  `user_wallet: sender`.
- **Who submitted is not recorded on-chain**, and the gas payer appears only in the
  transaction's gas data, never in the event.
- **Lookup by file** reads `user_wallet` and `domain` from the event, which are unchanged.
- **Search by wallet** matches the event's `sender` or `user_wallet` in the portal (`matchesWallet`)
  and `user_wallet` in the API (`getAttestationsByWallet`). Both are still the user's wallet, so
  results are identical. Searching the sponsor wallet correctly returns no attestations.

## 16. Testing

**Server (vitest, `server/tests/sponsor.test.ts`, following `otp.test.ts` conventions)**

- Auth gating.
- User outcomes: unknown, disabled, or no `user_cap_id`.
- Every argument rule in §7.1.
- `UserCap` owner and type mismatch.
- Gas-price and balance `503` responses.
- Quota math: count and gas, reserved versus resolved rows.
- Signature verification: a valid signature from a throwaway keypair, a signature from the wrong
  wallet, and a signature over different bytes.
- Expired or unknown digest; idempotent repeat submit.
- Boot failure when `SPONSOR_WALLET == ADMIN_WALLET` or when the key doesn't match.
- The sweep resolving `signed` rows to `executed` / `failed` / `dropped`.
- The unexpected-spend check pausing sponsorship.

The chain client is mocked, as in the existing tests.

**Cross-SDK fixture.** One logical attestation is built by the server (`@mysten/sui`) and by the
app (`on_chain` `SuiTransactionDataV1` plus the `ValidDuring` tail). The BCS must be identical.
The fixture bytes are shared between `server/tests/` and
`app/test/core/services/sponsor_attestation_test.dart`. This is the test that makes §8 safe.

**App (flutter_test)**

- Verification accepts a valid prepared transaction.
- It rejects each of the following: a changed argument, a different `UserCap` or registry, gas
  owner equal to the user's own wallet or different from the advertised sponsor, a budget or
  price over its cap, a wrong epoch or chain id, and trailing bytes.
- Fallback and queue behavior for `503`, `409` and `429`.

**Testnet end-to-end smoke**

1. Fund the sponsor's address balance.
2. Register a user whose wallet has zero SUI.
3. Attest a photo and a file.
4. Confirm the user's balance is still 0, the sponsor's balance dropped by the recorded
   `gas_used`, and the portal verifies both files and lists them under the user's wallet.

## 17. Rollout

1. Ship the server change with `SPONSOR_ENABLED=false`. There is no behavior change for existing
   stacks.
2. Create and fund a testnet sponsor wallet for one domain, enable sponsorship, and run the
   end-to-end smoke. Watch `/admin/sponsor/summary` for a few days and measure the real cost per
   attestation.
3. Release the app with the sponsored path and self-pay fallback. It also works against stacks
   where sponsorship is off.
4. Enable sponsorship per production domain when ready, and tune the caps from measured costs.
5. For fully sponsored domains, retire the balance gates and top-up UI. Keep the self-pay code
   path as a fallback until mainnet.

## 18. Open questions

- **Mainnet values:** per-network defaults for `SPONSOR_MAX_GAS_PRICE_MIST` and the daily caps,
  once real per-attestation cost is measured on testnet.
- **Funding helper:** the exact SDK call the admin uses to deposit into the sponsor's address
  balance. Should the admin summary offer a one-step top-up from the admin wallet, under a
  per-day ceiling?
- **Self-pay fallback:** should a domain be able to turn it off entirely, so captures simply
  wait in the queue while the sponsor is unavailable?
- **Protocol check:** confirm the address-balance gas and `ValidDuring` requirements against the
  Sui protocol version current at implementation time (`@mysten/sui` 2.17 on the server,
  `on_chain` in the app).
