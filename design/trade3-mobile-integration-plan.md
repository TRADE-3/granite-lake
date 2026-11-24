# Trade3 Mobile Integration — Implementation Plan

Date: 2026-11-24 · Branch: `feat/gl-tr3-mobile-integration` · Companion docs: `mobile_integration.md` (primary API reference), `Trade3_Granite_Architecture_Mobile_Pairing_Migration.md` (architecture), `t3_new.md` (older draft)

This plan implements the Trade3 backend integration described in `mobile_integration.md`: pairing via deep link, hierarchy sync, document upload after Sui anchoring, and disconnect.

## Current Status

**Done on this branch:**

- Android App Links config (`app/android/app/src/main/AndroidManifest.xml`): `https` intent-filter for host `granite.trade3.io` with `autoVerify="true"`.
- Release signing/build cleanup in `app/android/app/build.gradle.kts` (keystore properties loading, `compileSdk` pin).

**Already working in the app (granite-lake stack, unchanged):**

- Local Sui wallet + hardware-backed biometric gate.
- OTP registration against the granite-lake server (mints the on-chain `UserCap` that authorizes attestations).
- Sui attestation submission (self-paid or domain-sponsored), offline queue with at-rest encryption, history/verification.

**Not started (all Trade3 work):**

- Dart-side deep-link handling — the manifest opens the app, but nothing consumes `?code=`; no `app_links` dependency.
- Trade3 API client, token storage, refresh-on-401 logic.
- Pairing screen, hierarchy explorer, EP-04 upload hook, Disconnect button.
- Server-side routes on `dev-api.trade3.io` are implemented by the Trade3 backend team (out of this repo's scope).

## Contract Discrepancies To Resolve Before Coding

**Resolved (2026-11-24):** `mobile_integration.md` now carries the confirmed backend contract — EP-01 is `POST /api/auth/pairing/consume` with a `pairing_code` (UUID) + optional `device_id` JSON body; EP-02 authenticates via `refresh_token` in the JSON body only (no auth header); EP-04 returns only the inserted-record essentials (`id`, `payment_schedule_id`, `document_hash`). The app implements this confirmed shape (`app/lib/core/services/trade3_api_service.dart`).

The table below is kept as a record of what the three docs originally disagreed on:

| Item            | `mobile_integration.md` (pre-confirm) | `t3_new.md`                                      | Migration doc                             |
| --------------- | ------------------------------------- | ------------------------------------------------ | ----------------------------------------- |
| EP-01 path      | `/api/auth/mobile/consume`            | `/api/auth/consume` ("verify prefix in Swagger") | `/api/v1/auth/pairing/consume`            |
| Base URL        | `https://dev-api.trade3.io`           | (implied `dev.evm.tr3.io` stack)                 | —                                         |
| Deep-link shape | `https://granite.trade3.io/?code=…`   | `Granite/pair?code=…`                            | `https://granite.trade3.io/pair?code=XYZ` |

Still worth confirming against the live Swagger (`https://izimio.github.io/swagger/`, password from the backend team):

- EP-02 response shape: whether the `refresh_token` rotates on refresh or only the `access_token` is returned. The app handles both.
- Error response schema — the app refreshes on any 401 status regardless of body, so this is robustness only.

## Phases

### Phase 0 — Unblock (day 1, needs the backend team)

1. Confirm against Swagger: exact EP-01 path, EP-02 request shape, token TTLs, error schema.
2. Confirm the exact deep-link URL path, and that `assetlinks.json` served from `granite.trade3.io` matches package `io.trade3.app` plus the release keystore SHA-256 fingerprint. A signing-cert change silently breaks App Links — the integration guide warns about this explicitly.
3. Decide the relationship between Trade3 pairing and the existing granite-lake OTP registration. They coexist for now (OTP mints the Sui `UserCap`; pairing links the Trade3 account), but the migration doc calls the legacy token system "technical debt" that must be reworked before production. Get a decision on the end state so the pairing UX is not built twice.
4. Get Tailscale + `trade3` exit-node access for dev testing; commit the three design docs.

### Phase 1 — Trade3 API client + token foundation

- `Trade3ApiService` in `app/lib/core/services/`, following the existing `PhotoAttestationService` pattern (injectable `http.Client` for tests) — endpoints EP-01 through EP-05.
- Tokens (`access_token`, `refresh_token`) in `FlutterSecureStorage`; single-flight refresh-on-401-then-retry; refresh failure clears to an "unpaired" state.
- Base URL via dart-define in `app/secrets.json` (mirror the `GL_OTP_BACKEND_CONFIG` pattern), e.g. `GL_TRADE3_API_URL`.
- Unit tests for refresh/retry and hierarchy JSON parsing.

### Phase 2 — Deep link + pairing (EP-01)

- Add `app_links`; handle cold-start and warm-start links.
- Route `/pair?code=…` through the router so it survives the boot/onboarding redirect chain (`app_router.dart`); store a pending code if the app has not finished onboarding yet.
- Pairing screen: manual code entry plus auto-consume from the link; states for consuming / success / already-paired / error.

### Phase 3 — Hierarchy sync + explorer (EP-03)

- Silent sync on launch plus manual refresh.
- Dynamic fetch, no DB persistence (the migration doc explicitly favors this).
- Explorer UI (likely the Projects tab) rendering Master Contract → Transaction → Payment Schedule → Documents; grey out completed payment schedules; empty-state copy for permission-limited responses (`can_view_transactions` / `can_view_documents` false).

### Phase 4 — Capture targeting + upload (EP-04) — largest piece

- Capture flow: cascading target selector (Master Contract → Transaction → Payment Schedule).
- Persist the chosen IDs on the capture record — SQLite migration (schema currently version 13, `app/lib/core/database/migrations.dart`).
- Hook EP-04 into the `_submitPhotoAttestation` / `_submitFileAttestation` success paths (`app/lib/core/state/granite_lake_controller.dart`): after Sui anchors, upload the file bytes with `transaction_id` + `payment_schedule_id`; chunk batches larger than 10 files (API limit).
- Failure policy: Sui OK but EP-04 failed → mark the record for Trade3-upload retry (reuse the reconnect/retry pattern); offline captures upload after their deferred Sui submission succeeds. Store `ipfs_cid` / document id for history display.

### Phase 5 — Disconnect (EP-05)

- Profile screen: "Trade3 account" section (paired status + Disconnect) → call EP-05, wipe tokens and hierarchy cache, revert capture flow to non-Trade3 mode.

### Phase 6 — Release (per root `TODO`)

- App: production `secrets.json` → signed release APK → send the new signing fingerprint to the backend team for `granite.trade3.io` before distributing.
- Server: add the new envs; verification portal repo/env change (Paul).
- Update `AGENTS.md` and READMEs to document the integration.

## Verification

- Per-phase: `flutter analyze lib`, `dart format lib`, unit tests (`flutter test`); the Husky pre-commit runs all four package checks.
- End-to-end manual pass against dev (Tailscale exit node `trade3`, web app `dev.evm.trade3.io`):
  - Pair via QR deep link and via manual code entry.
  - Force a token expiry and confirm silent refresh.
  - Sync hierarchy; capture → select target → confirm the document appears in the dev web UI with the Granite-verified badge (`is_verified_by_granite: true`).
  - Deep-link test: `adb shell am start -a android.intent.action.VIEW -d "https://granite.trade3.io/?code=<code>"`.
  - Disconnect and confirm tokens are gone and capture flow reverts.

## Risks

- API contract drift between the docs — resolve in Phase 0 or the client gets built twice.
- App Links verification depends on backend-hosted `assetlinks.json`; if the fingerprint mismatches, links open in the browser instead of the app.
- The 10-file-per-request EP-04 limit vs unbounded batch capture — chunking required.
- Migration doc's "critical technical limitation" (NFT-minting documents must use the Trade3 relayer, not self-sponsored) may constrain the sponsored-transaction flow for file attestations — clarify scope during Phase 0.
- Pairing vs OTP-registration end state is undecided; the pairing UX should be built so it can survive that decision.
