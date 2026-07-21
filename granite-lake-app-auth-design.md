# Granite Lake — App/API Auth Design (OTP & UTC Routes)

**Author:** Nethmi Jayakody
**Status:** Draft for review
**Related:** App/API auth for `/otp/request`, `/otp/verify`, `/utc`; keep `/health` public

## 1. Problem

`/otp/request`, `/otp/verify`, `/otp/:userId`, and `/utc` currently accept unauthenticated calls
from anyone who can reach the server. Only `/admin/*` is gated today, via a static
`x-admin-api-key` header checked in `server/src/routes/admin.ts`. `/health` must stay public for
deployment/uptime checks.

The deployment model is one backend stack per domain (`server/README.md`: "One container stack
equals one domain"). The Flutter client currently targets a single backend via one
`--dart-define=GL_OTP_BACKEND_URL`. Supporting multiple domains from a single app build means this
becomes a per-domain map rather than one value — and the app-level credential needs the same
per-domain treatment.

## 2. Phase 1 — per-domain static API keys

**Server**

- New `APP_API_KEY` env var per domain-stack, following the exact pattern already used for
  `ADMIN_API_KEY` in `server/src/config/env.ts` (required string, no default).
- New `onRequest` hook (same hook type as `admin.ts`, not the `preHandler` used for rate limiting)
  checking an `x-app-api-key` header against `env.APP_API_KEY`. Missing or invalid → `401`, same
  response shape as the admin check: `{ error: "unauthorized", message: "Invalid app API key." }`.
- Applied to `/otp/request`, `/otp/verify`, `/otp/:userId` (all served by the same plugin), and
  `/utc`. `/health` is left completely untouched.

**Client**

- Single `GL_OTP_BACKEND_URL` dart-define is replaced with a per-domain map dart-define, e.g.
  `GL_OTP_BACKEND_MAP='{"acme.com":{"url":"https://acme-api.example.com","apiKey":"..."}}'`,
  looked up by the domain the user enters at registration.
- Passed via `--dart-define-from-file=<gitignored-json>` rather than inline on the command line —
  keeps the values out of shell history, `ps aux` output during the build, and CI logs. This is a
  build-hygiene fix only; see the leak discussion below for why it doesn't solve the deeper
  problem.
- Existing rate limiting on `/otp/request` (5/min) and `/otp/verify` (10/15min) in
  `server/src/utils/rateLimit.ts` needs no changes and continues to apply on top of this.

**Why start here:** fast, reuses proven code paths and test conventions already in the repo
(mirrors `admin.test.ts`), and stops opportunistic/scripted abuse (scanners, randoms hitting the
API without ever having installed the app) immediately.

## 3. Known issues with Phase 1

- **Anything embedded in a compiled client binary is extractable.** `String.fromEnvironment`
  values are baked into the Dart AOT snapshot as literal data — recoverable via decompilation, or
  far more trivially, by running the app through a user-controlled local proxy (any MITM tool with
  a device-installed trusted cert). This applies equally to the backend URL and the API key; the
  app cannot keep either confidential from its own device or user.
- **A decompiled app leaks the entire domain → key map at once**, not just one domain's key.
  Per-domain granularity increases the blast radius of a single extraction event rather than
  containing it — one leaked app build exposes every tenant's key simultaneously.
- **The URL and the key are not equally sensitive, even though their exposure is identical.** The
  URL is routing information — knowing it doesn't let an attacker make an authenticated call. The
  key's entire purpose is to prove "this call came from our real app," and a static value a user
  can pull off their own device structurally cannot prove that against anyone who has ever had a
  copy of the app. It only stops parties who never obtained the app at all.
- **Net effect:** Phase 1 is a real improvement over having no gate — it stops casual and
  automated abuse — but it is explicitly **not** a durable production control against a motivated
  attacker with a copy of the app. This limitation should be stated plainly in both
  `server/README.md` and `app/README.md` wherever `APP_API_KEY` is documented, so it isn't later
  mistaken for a finished security boundary.

## 4. Phase 2 — device attestation + short-lived session tokens

**Goal:** remove any long-lived secret from the client entirely. Move the trust anchor to
hardware-backed platform attestation, verified fresh per session rather than statically.

- **Android — Play Integrity API.** Returns three verdicts per request:
  - `appIntegrity` — `appRecognitionVerdict` (is this our unmodified, Play-recognized package?)
    plus `certificateSha256Digest` (does the signing cert match ours?).
  - `deviceIntegrity` — `deviceRecognitionVerdict` (genuine, non-rooted, non-tampered device vs.
    emulator/modified ROM).
  - `accountDetails` — Play licensing; not meaningful for an internally-distributed tool, ignored.
  - The request is bound to a server-issued nonce (`requestHash`) so a captured token can't be
    replayed against a different call.
- **iOS — App Attest.** Secure Enclave-backed hardware key pair via DeviceCheck; equivalent
  guarantee to Play Integrity. Required for platform parity before Phase 2 is complete — noted
  here for completeness even though this round of design work focused on Android.
- **Flow:**
  1. Client calls a new `POST /otp/session` with `{ domain }`, gets a one-time nonce back.
  2. Client asks the OS (Play Integrity / App Attest) to attest that nonce, gets an opaque,
     signed/encrypted attestation token.
  3. Client sends `{ domain, nonce, attestationToken }` back to `/otp/session`.
  4. Server verifies the token against Google's `playintegrity` API (via a linked Google Cloud
     project + service account) or Apple's App Attest verification, checking package
     name/bundle ID, signing cert, and minimum device-integrity level.
  5. On success, server mints a short-lived JWT (e.g. 15 min TTL), scoped to that domain.
  6. Client attaches `Authorization: Bearer <jwt>` to `/otp/request`, `/otp/verify`, `/otp/:userId`,
     and `/utc`, re-running steps 1–5 on expiry.
- **New components required:**
  - Android: no existing Flutter plugin in use for this — either a pub.dev package or a
    hand-written `MethodChannel` wrapper around `com.google.android.play:integrity`.
  - iOS: native App Attest integration via a plugin or platform channel.
  - Server: a Google API client and a JWT library (`server/package.json` has neither today), a new
    `/otp/session` route, a new `onRequest` hook verifying the bearer JWT in place of the static
    key check, and a new Vault-managed service-account credential for calling Google's
    verification API.

## 5. Prerequisite for Phase 2 to actually work: Play Store distribution

- `appIntegrity.appRecognitionVerdict` only returns `PLAY_RECOGNIZED` when the app is installed
  through a channel Play Services recognizes. A raw sideloaded or MDM-pushed `flutter build apk`
  returns `UNRECOGNIZED_VERSION` instead — Play cannot vouch for a distribution chain it never saw.
- What still works even when sideloaded: device integrity checks (root/tamper/emulator detection)
  and a self-verified comparison of package name + signing certificate digest against known-good
  values — real, but weaker than Play-vouched app integrity, since it relies on the server's own
  check rather than an independent attestation from Google.
- To get the full guarantee, the app needs to be distributed via a **Google Play Console internal
  testing track** — this does not require a public listing; internal or closed testing is
  sufficient. Devices install through the Play Store app via a testing link, not a manually
  transferred APK file.
- This is a distribution/logistics decision, independent of any code change, and should be
  confirmed as operationally viable for how field devices actually receive this app _before_ Phase
  2 is scoped as an implementation issue — it determines whether Phase 2 delivers full or only
  partial attestation guarantees.
- iOS App Attest does not have this exact "recognized channel" gate — attestation is tied to the
  Apple Developer Team ID and bundle ID via DeviceCheck rather than to App Store distribution
  channel specifically — but TestFlight/App Store is still the realistic path to exercise it
  end-to-end in practice. Mentioned briefly; not the focus of this round of design.

## 6. Recommendation

- Ship Phase 1 now as the already-scoped issue. Document its limitations inline in both
  `server/README.md` and `app/README.md` so it's never mistaken for a durable production control.
- Track Phase 2 as a separate, larger follow-up issue, gated on first confirming that Play Console
  internal-testing-track distribution is viable for how this app actually reaches field devices.
