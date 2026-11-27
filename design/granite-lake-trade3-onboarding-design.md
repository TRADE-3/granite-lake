# Granite Lake — Trade3 onboarding, GL sessions, wallet import and restore

**Status:** Draft for review
**Based on:** the Trade3 → GL token exchange sequence diagram, a sample `200` response from Trade3 `/company/me`, and the current `server/`, `app/` and `contracts/` code
**Supersedes for Trade3 users:** OTP registration, and the static-key auth in `granite-lake-app-auth-design.md`

## 1. Goals

1. Onboard with Trade3 pairing only: no email entry, no OTP.
2. No email-domain rule. Keep the email as information taken from Trade3.
3. GL issues its own access and refresh tokens and uses them for app to server calls.
4. A reinstalled app can import its wallet.
5. A reinstalled app can restore history and files.

Non-goals: contract changes, verification portal changes, recovering a lost private key.

## 2. Gaps in the sequence diagram

| Gap                                      | Why it matters                                       | Fix                                             |
| ---------------------------------------- | ---------------------------------------------------- | ----------------------------------------------- |
| No wallet address in `/auth/exchange`    | The server cannot call `add_user` without it         | Send the wallet address                         |
| No proof the caller holds the wallet     | Anyone with a T3 token could register any address    | Nonce plus wallet signature, as OTP does today  |
| `/user/me` shows `{ user_id, ... }` only | We want the email, and it must not come from the app | Resolved: `/company/me` returns both (4.2)      |
| No on-chain step                         | A user without a `UserCap` cannot attest             | `/auth/exchange` calls `add_user` for new users |
| No token refresh or logout               | Sessions cannot be renewed or ended                  | `/auth/refresh`, `/auth/logout`                 |

## 3. Dropping the email-domain rule

Removing the check at registration is not enough. `server/src/db/repositories.ts` **derives each user's on-chain domain from their email** every time a user row is read (`withConfiguredUserFields` → `configuredDomainForEmail`), and throws for a non-matching email. That breaks admin listing, disable and enable, and sponsorship.

Minimal change:

- Add `users.registry_domain`. Backfill existing rows using today's derivation.
- New users get the stack's registry domain from a new env var, `REGISTRY_DOMAIN` (must be one of `DOMAINS`).
- Read the column instead of deriving from the email. `SponsorService.resolveUserCap` then works unchanged.
- Keep `users.user_email` as stored information. `EMAIL_DOMAIN_ALIASES` is only used by the old OTP path.

**Consequence to accept:** every user onboarded by a stack attests under that stack's domain, whatever their email says. Verifiers see that domain and check its `_attest.<domain>` DNS record. The domain now means "attested through this organisation's Granite server", not "this person works at this organisation".

**Who may register** also changes. Today it is "anyone with a company email". Without a rule it becomes "anyone with a Trade3 account". `/company/me` returns the company and the user's permissions, so the server can check them (rule in 4.2).

## 4. Server

### 4.1 Endpoints

| Endpoint               | Auth                                 | Purpose                                                                  |
| ---------------------- | ------------------------------------ | ------------------------------------------------------------------------ |
| `POST /auth/challenge` | App key                              | Body `{ userWallet }`, returns a single-use nonce (5 min)                |
| `POST /auth/exchange`  | App key + `Bearer <t3_access_token>` | Body `{ userWallet, nonce, signature }`, returns GL tokens and the claim |
| `POST /auth/refresh`   | App key + refresh token in body      | Rotates the refresh token                                                |
| `POST /auth/logout`    | App key + refresh token in body      | Unlink: revokes the refresh token family                                 |

`/auth/exchange` returns what the app already stores after OTP (`userId`, `domain`, `userCapId`, `txDigest`, `userEmail`), so the attestation code does not change. It also returns a `profile` object: `{ trade3UserId, name, email, position, companyId, companyName, role }`.

### 4.2 What GL reads from Trade3 `/company/me`

The app sends its Trade3 access token to GL, and the server calls `GET <TRADE3_API_URL>/api/company/me` with it (dev: `https://dev-api.trade3.io/api/company/me`). A caller who is not a Trade3 user gets `401`, which GL passes on as a failed exchange with no chain call.

The response is `{ success, key, message, user }`. Everything GL needs is under `user`.

| Field                                    | GL use                                                    |
| ---------------------------------------- | --------------------------------------------------------- |
| `user.id` (integer)                      | The "T3 id". Stored as `users.trade3_user_id`             |
| `user.email`                             | Stored as `users.user_email`. Not `user.company.email`    |
| `user.is_active`                         | Must be `true`                                            |
| `user.company_id`                        | Stored as `users.trade3_company_id`                       |
| `user.company.is_whitelisted`            | Must be `true`                                            |
| `user.permissions.can_deposit_documents` | Not a registration rule. The app uses it (5.4)            |
| `user.name`, `user.position`             | Returned to the app to fill the local employee profile    |
| `user.role` (for example `OWNER`)        | Returned to the app, stored and shown (5.5). Display only |
| `user.company.name`                      | Returned to the app, stored and shown (5.5)               |

**Who may register:** `is_active` and `company.is_whitelisted` are both true. There is no company allowlist in GL: eligibility is left to Trade3's whitelisting. A failed check returns `403 not_eligible` before any chain call.

**Consequence to accept:** any whitelisted Trade3 company's user can register on any stack they can reach, and then attests under that stack's domain.

The check runs on every exchange, including for known users. GL refresh does not call Trade3, so a change in Trade3 (deactivated user, removed company) takes effect in GL only at the next exchange. To cut someone off at once, an admin disables them in GL.

**Do not use these as the GL wallet:** `user.connectedWalletAddress` is a 20-byte `0x` address (EVM format), not a 32-byte Sui address. `user.wallets` and `company.wallet_addresses` are empty in the sample. The GL wallet comes only from the signed `/auth/exchange` request.

**Data handling:** the response also carries the company address, bank accounts, phone and business number, and a list of every company user. Parse only the fields above, with a strict schema that fails closed if a required one is missing or has the wrong type. Never log or store the response body.

**Not in the response:** any sign that the email is verified. Email is only information, except when linking an existing OTP user, where the wallet signature is also required.

### 4.3 Exchange rules

1. Verify the nonce and the wallet signature.
2. Call `GET <TRADE3_API_URL>/api/company/me`. The URL comes from server config only. Never store or log the T3 token.
3. Require `success: true` and the eligibility rule in 4.2.
4. Apply the first matching rule (T3 id = `user.id`):

| Situation                                              | Result                                                            |
| ------------------------------------------------------ | ----------------------------------------------------------------- |
| Known T3 id, disabled                                  | `403 user_disabled`                                               |
| Known T3 id, same wallet                               | Issue tokens. No chain call (this is the reinstall + import case) |
| Known T3 id, different wallet                          | `409 wallet_mismatch`: import your recovery key                   |
| New T3 id, email and wallet match an existing OTP user | Link the T3 id to that user, then apply the rules above           |
| New T3 id, email or wallet belongs to someone else     | `409`                                                             |
| New T3 id, new wallet                                  | `add_user`, create the row, issue tokens                          |

Two exchanges at once must not both call `add_user`: take a database lock on the T3 id and wallet first. If `add_user` succeeded but the database write failed, the retry hits `E_USER_EXISTS`; recover by looking up the wallet's `UserCap`.

Matching an old user by email alone is never enough; the wallet signature must match too.

### 4.4 Tokens

- **Access:** signed JWT, lifetime from `GL_ACCESS_TOKEN_TTL`. Claims: GL user id, wallet, `aud` = `CLIENT_ID`. Per-stack secret `GL_JWT_SECRET` (Vault-capable).
- **Refresh:** random opaque value, lifetime from `GL_REFRESH_TOKEN_TTL`, stored hashed, rotated on every use. A rotated token keeps the family's original expiry. Reuse of an old token revokes the family, with a short grace window for a lost response.
- Every request also checks that the user is still active, so disabling takes effect immediately.
- **Fixed 6 months:** the session ends 6 months after the QR scan, however often the app is used, so everyone rescans every 6 months. This applies to Trade3 and GL (`GL_REFRESH_TOKEN_TTL`). The 15-minute access lifetime is a working value.
- **When either session ends:** if the Trade3 or the GL refresh token expires or is rejected, both are ended and the user starts again with a QR scan (5.6).

### 4.5 Existing routes

| Route                               | Change                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------- |
| `/sponsor/*`                        | Require the GL access token; `userWallet` must equal the token's wallet |
| `/otp/:userId/deactivate*`          | Require the token for that user; keep the wallet signature              |
| `GET /otp/:userId` (email backfill) | Own record only                                                         |
| `/otp/request`, `/otp/verify`       | Behind `OTP_ENABLED`; off once the new app is rolled out                |
| `/utc`                              | Unchanged: app key only                                                 |
| `/admin/*`, `/health`               | Unchanged                                                               |

`/utc` stays on the app key because it is also the app's connectivity probe and clock source. It never depends on a GL token, so an expired token cannot make a capture look offline.

During rollout, a flag lets protected routes accept the old app key too, so installed apps keep working.

### 4.6 Database (migration `010`)

- `users`: add `registry_domain`, `trade3_user_id` (unique, nullable), `trade3_company_id` (nullable). `user_email` stays required.
- **Drop the `users.user_id → otp_sessions` foreign key** (added in migration `004`). Trade3 users have no OTP session, so inserts would fail.
- New `auth_challenges` (nonce hash, wallet, expiry, used).
- New `auth_refresh_tokens` (token hash, user id, family, expiry, revoked).

Rate-limit all `/auth/*` routes. New env: `TRADE3_API_URL`, `REGISTRY_DOMAIN`, `GL_JWT_SECRET`, `OTP_ENABLED`, `GL_ACCESS_TOKEN_TTL`, `GL_REFRESH_TOKEN_TTL`.

## 5. App

### 5.1 Onboarding

New order: **create or import wallet → biometrics → link Trade3 → done.**

- `identity_setup_screen`: two choices, "Create new" and "I have a recovery key".
- `registration_screen`: replace the email and OTP form with Trade3 linking (QR link or pairing code).
- `app_router.dart`: allow pairing before registration. Today an early pairing code waits until registration completes.
- The backend URL still comes from the build config. `employee.companyDomain` is filled from the server's `domain` response.
- Name, email, user id, company, role and position come from the exchange response (4.2), so the user types nothing.
- `403 not_eligible` shows a plain message: ask your company admin for access.

### 5.2 GL session

- New `GlTokenStore` (secure storage) and one `GlApiClient` that attaches the token, refreshes once on `401` (single-flight, like `Trade3ApiService`), and retries.
- Move `photo_attestation_service`, `sponsor_attestation_service` and the OTP-route calls in `AppUtils` onto it. The `/utc` calls stay as they are.
- Refresh needs no biometric. A full re-exchange does (wallet signature) and follows a new QR scan.
- Captures already queued are kept when a session ends (5.6).

### 5.3 Recovery key (import in phase 2, export in phase 5)

- **Export:** during onboarding and later from Profile, behind a biometric prompt (the raw key is only available after unlock). Show it once per request, block screenshots, avoid the clipboard, and ask the user to confirm they saved it.
- **Import:** paste the `suiprivkey1...` value, derive the wallet, then continue with biometrics and linking. The server returns the existing account.
- Use plain wording ("recovery key"), per the onboarding copy rule.

**Trade-off to accept:** the key is no longer bound to one phone. Anyone who obtains it can attest as that user and move any SUI in the wallet, and two phones can use it at once. Mitigation: admins can disable the user.

**Lost key:** the account stays blocked. It needs an admin action that disables the old wallet and releases the Trade3 id for a new one (later phase).

### 5.4 Deposit permission

Trade3 rejects `/pin` when `can_deposit_documents` is `false`, because the user lacks the right. Such a user can still onboard.

- **Upload failure (required):** Trade3 answers `/pin` with a non-`200` status when the right is missing. Mark the upload failed, and when the cached flag is `false` show "Insufficient rights, contact your company admin". The on-chain attestation is unaffected. Allow a manual retry once the right is granted. This also covers a right removed after capture, including offline captures.
- **Selection block (nice to have):** when the flag is `false`, disable payment schedule selection in the picker and show the same message. This is a UI block only; Trade3 remains the one that enforces it.
- **Where the flag comes from:** the app reads `/company/me` with its Trade3 token on each hierarchy sync, so changes are picked up, and caches it for offline use. If the flag is unknown, do not block.

**Effect to accept:** a paired app requires a payment schedule before it can capture or upload a file. With selection blocked, this user cannot create new attestations at all.

### 5.5 Trade3 profile details

The app stores the user's Trade3 details and shows them on Profile, including offline.

Store them in the existing `employees` table (database migration `15`):

| Profile label | Source              | Column              | Change                          |
| ------------- | ------------------- | ------------------- | ------------------------------- |
| Name          | `user.name`         | `full_name`         | Exists, currently a placeholder |
| Email         | `user.email`        | `email`             | New                             |
| User ID       | `user.id`           | `trade3_user_id`    | New                             |
| Company       | `user.company.name` | `company_name`      | New                             |
| Role          | `user.role`         | `role`              | Exists, currently a placeholder |
| Position      | `user.position`     | `position`          | New                             |
| Not shown     | `user.company_id`   | `trade3_company_id` | New                             |

- "User ID" is the Trade3 id. `employee_id` stays the GL user id, which attestation and deactivation use.
- `saveClaimedEmployee` currently keeps the old name and role (placeholders). It must write the values from the server.
- `tenant_name` and `company_domain` keep holding the registry domain. The company name is not the on-chain domain and is not used in attestations.
- Format the role for reading (`OWNER` → "Owner"). Hide a row with no value, for example for OTP users who have not linked Trade3.
- Refresh on each hierarchy sync, from the same `/company/me` read as 5.4. Only apply it if `user.id` matches the stored `trade3_user_id`.
- Clear these with the rest of the employee record on app reset.
- Role is display only. Access decisions use permissions (5.4).
- Store nothing else from the response.

### 5.6 Unlink, expiry and relink

The Trade3 and GL sessions live and end together. Three things end both:

- the user unlinks;
- the Trade3 refresh token expires or is rejected;
- the GL refresh token expires or is rejected.

An expired access token is not one of them: it is refreshed silently. Only a definite rejection from a refresh call ends the session, never a network error, timeout or `5xx`.

**On unlink** (confirm with the user first) **or expiry** (no confirmation):

1. Call `/auth/logout`, so the server revokes the refresh token family. Delete the GL access token.
2. Call Trade3 logout (EP-05), if that session is still valid, and delete the Trade3 tokens.
3. Store an "unlinked" state that survives restarts and works offline.

**While unlinked:**

- No new captures or file attestations. The screens show "Scan the Trade3 QR code to continue", and say the session expired when that is the reason. Today an unpaired app falls back to local projects and can still attest, so this needs an explicit block.
- Captures already queued stay encrypted on the phone and are not submitted. Pending Trade3 uploads wait too.
- The wallet, history, local files and profile stay. History can still be viewed.
- If the phone is offline at unlink, block at once, and keep the refresh token only to retry `/auth/logout`.

**On relink:** scan the QR code (or enter the pairing code), then `/auth/exchange` with the same wallet. The server finds the existing user and issues new tokens, with no new `add_user`. Queued captures and uploads then resume. A different Trade3 account on this wallet gets `409`, so the queue is never submitted under another account.

**Offline:** the app stores the GL refresh expiry date and blocks once it has passed, using the network-synced clock. A rejection before that date is only seen when the phone is next online.

**Server side:** GL does not hear from Trade3 directly. When Trade3 rejects the app, the app calls `/auth/logout`. If it never does, the GL refresh token stays valid until its own expiry.

**Limit to accept:** the block is in the app. Attestations go straight to the chain with the user's own wallet and `UserCap`, and unlinking changes neither. The server stops sponsoring gas, but a modified app, or an imported key, could still attest. Blocking on-chain would need `disable_user` on unlink and `enable_user` on relink, kept separate from admin disables.

## 6. Restore after reinstall

The chain says **what was attested**; Trade3 holds **the files**.

1. After import and linking, read this wallet's `PhotoAttested` and `FileAttested` events (the app already has a Sui GraphQL client).
2. Take `project_id` (`t3:<contract>:<transaction>:<schedule>`) and match it to the synced hierarchy.
3. For each hash, ask Trade3 for the matching file and download it.
4. Recompute SHA-256. Save only if it equals the on-chain hash.
5. Insert a history row marked as restored.

**Trade3 must add** (not in EP-01 to EP-05 today):

- a list of the user's Granite documents with `id`, `document_hash`, `payment_schedule_id`;
- a download that returns the **original decrypted bytes**.

| Restored                                         | Not restorable                                     |
| ------------------------------------------------ | -------------------------------------------------- |
| Hash, time, location, offline flags, transaction | Notes and tags (only stored on the phone)          |
| Project grouping, for Trade3 targets             | Captures still queued and never anchored           |
| Files that were uploaded to Trade3               | Files never uploaded (no target, or upload failed) |

Entries without a file should still appear. History and detail screens read `localAssetPath` directly, so they need a "file not on this device" state. The original local signature bundle should not be recreated; show it as unavailable. Add a database migration if a "restored" flag is stored.

## 7. Questions for Trade3

Answered: the identity endpoint is `/api/company/me` and takes the app's access token; `user.id` and `company_id` are stable and unique across environments; `/pin` returns a non-`200` status without the deposit right.

1. Is `user.email` verified?
2. We assume the 6-month refresh lifetime is fixed from pairing and using or rotating the token does not extend it. Please confirm. How long does the access token last?
3. Can you provide the document list and decrypted download in section 6?
4. Which status and error key does `/pin` return without the deposit right?
5. Can mobile tokens get a smaller response, without bank accounts and other users?

## 8. Plan

| Phase | Work                                                                                                                     | Size | Depends on  |
| ----- | ------------------------------------------------------------------------------------------------------------------------ | ---- | ----------- |
| 0     | Confirm decisions (section 9)                                                                                            | S    | Done        |
| 1     | Server: migration `010`, domain decoupling, `/auth/*`, token checks on routes, tests                                     | L    | Phase 0     |
| 2     | App: onboarding order, Trade3 linking, GL session, wallet import, deposit permission, profile details, unlink and relink | L    | Phase 1     |
| 3     | Cutover: `OTP_ENABLED=false`, app-key fallback off (not `/utc`), READMEs and `AGENTS.md`                                 | S    | rollout     |
| 4     | Restore: chain events and Trade3 download, history rows                                                                  | L    | Phase 2, Q3 |
| 5     | Recovery key export                                                                                                      | M    | Phase 2     |

**Risk of exporting last:** until phase 5, a user cannot save the key of a wallet the app created. After a reinstall they get a new wallet, `/auth/exchange` returns `409 wallet_mismatch`, and they stay blocked. Import and restore do not help them. Shipping export with phase 2 avoids this.

Phase 1 can be built against a stubbed `/company/me` shaped like the sample response. The domain decoupling is independent and worth doing first.

### Tests that must exist

- Every row of the exchange table, including concurrent exchanges.
- Each eligibility check fails with `403` and no chain call; a malformed `/company/me` response is rejected.
- The `/company/me` body and T3 token never appear in logs.
- Existing OTP users: admin list, disable, enable and sponsorship still work after the migration.
- Refresh rotation, reuse detection, and disabled user with a still-valid access token.
- Import reproduces the same wallet address; restore rejects a file with the wrong hash.
- A user without `can_deposit_documents` can onboard, sees the message, and a refused `/pin` leaves the attestation intact.
- Profile details are saved, replace the placeholders, survive the database upgrade and show offline.
- Unlink revokes the refresh token and blocks attestation, including after a restart and offline; relink resumes the queue without a new `add_user`; a different Trade3 account cannot take it over.
- Expiry or rejection of either refresh token ends both sessions and keeps the queue; a network error, `5xx` or expired access token does not.
- Rotating a refresh token does not extend the 6 months.

### Phase 1 as built

- `users.registry_domain` is not backfilled in SQL, which cannot apply `EMAIL_DOMAIN_ALIASES`. Older rows are derived from the email when read, and the value is stored when the user links Trade3.
- The wallet signs `auth:<wallet>:<nonce>`.
- Token lifetimes are in seconds; 6 months is 180 days.
- The server flag for rollout is `AUTH_REQUIRE_USER_TOKEN`. Until it is `true`, unlinking does not stop gas sponsorship.

### Phase 2 as built

- The existing pairing screen is onboarding step 3 and the relink screen. The email and OTP screen is removed, so this app version needs a server with `/auth/*`.
- There is no in-app QR scanner: scanning with the phone camera opens the link, or the code is pasted.
- `employees.company_domain` stays the domain used to reach the server; `tenant_name` holds the registry domain.
- OTP users who have not linked Trade3 keep working. Only an unlink or an expired session blocks.
- Expiry is checked on launch, on resume and before each capture.
- Uploads refused for the deposit right are retried automatically once Trade3 grants it.

### Phase 3 as built

- `OTP_ENABLED` now defaults to `false` and `AUTH_REQUIRE_USER_TOKEN` to `true`. A server still serving old apps must set both back.
- The OTP code stays, behind the flag.
- `/utc` is unchanged.
- After cutover, an OTP-registered user who has not linked Trade3 can still submit attestations paid from their own wallet, but gets no sponsored gas and cannot delete their account until they link.

### Phase 4 as built (history only)

- **Restore files** appears on History after a wallet import. It disappears once a restore succeeds, even with nothing to restore; a failure keeps it. `employees.wallet_restored` and `files_restored` record this (database version 17).
- Source: Trade3 hierarchy documents with a `hash` and `is_verified_by_granite`, kept only if this wallet attested that hash on-chain. One entry per hash.
- Rebuilt: hash, capture and attestation times, GPS and altitude, offline flags and reason hashes, domain, project, transaction digest, file name and Trade3 ids. Marked `is_restored` (database version 16).
- Not rebuilt: file contents (Trade3 has no download), notes, tags, reason text and the local signature.
- Attestations with no Trade3 document are not restored.

### Phase 5 as built (before phase 4)

- A new secure ID must have its recovery key confirmed as saved after biometrics, before linking. There is no skip, and closing the app does not bypass it. Profile shows the key later.
- Showing the key always needs a biometric prompt. It is hidden when the app goes to the background, and screenshots are blocked app-wide. A copy button puts it on the clipboard (this replaces "avoid the clipboard" in 5.3).
- Before registration, the linking screen can remove the new ID so a recovery key can be used instead.
- File contents (section 6, steps 3 and 4) are not restored.

| Decision                    | Outcome                                                                |
| --------------------------- | ---------------------------------------------------------------------- |
| Who may register            | Active user in a whitelisted company; no allowlist                     |
| Identity endpoint           | `GET /api/company/me` with the app's Trade3 access token               |
| No deposit right            | Onboard, but block payment schedule selection                          |
| Existing OTP users          | Link by email **and** wallet signature                                 |
| `/utc` auth                 | App key only, as today                                                 |
| Trade3 ids                  | Stable and unique; the exchange keys on `trade3_user_id`               |
| Registry domain             | Proposed: one per stack, `REGISTRY_DOMAIN`                             |
| Unlinking Trade3 in the app | Ends both sessions and blocks attestation; a QR scan restores it (5.6) |
| Session expiry              | Either one expiring ends both; start again with a QR scan              |
| Refresh token lifetime      | 6 months from the QR scan, not extended by use; Trade3 and GL          |
| Recovery key export         | Last phase; see the risk in section 8                                  |
