# Granite Lake — Offline Capture & On-Chain Timestamp Design

**Author:** Nethmi Jayakody
**Status:** Draft for review
**Related:** Supporting photo/file attestation for field crews working without connectivity
**Detailed design:** [granite-lake-offline-capture-design-detail.md](./granite-lake-offline-capture-design-detail.md)

## 1. Goal

Field crews sometimes work in areas without internet connectivity. This design adds an
offline capture path so a photo or file can be captured and locally attested at any time,
with the on-chain attestation submitted automatically once connectivity is available —
while keeping the same trust guarantees Granite Lake already provides when a device is
online. It also protects a capture queued while offline from being altered on-device
before it reaches the chain, by encrypting it the instant it's written and requiring a
fresh biometric check to decrypt it once connectivity returns.

As part of this, the on-chain event gains four explicit fields — `captured_at` (the
claimed capture time), `attested_at` (the chain-anchored time), `is_online` (whether the
capture itself was made with live, sufficient connectivity), and `is_forced_offline`
(whether the crew manually overrode a working connection) — so all four are visible
directly on the ledger for any verifier, rather than only being reconstructable
off-chain.

## 2. High-level summary of changes

| Area                            | Design                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Connectivity detection          | Two checks, not one probe: (1) is a radio on at all (OS-level, via `connectivity_plus`), (2) is what it reaches good enough (reachability + latency + estimated bandwidth) — replacing today's single HTTP-probe-per-tick check                                                                                                                                                                                                                                                                                                                                  |
| Offline eligibility             | Automatic: offline capture is offered whenever the check above isn't `online`, with no manual step required — no more relying on a crew to predict a dead zone and pre-toggle a switch                                                                                                                                                                                                                                                                                                                                                                           |
| Force-offline toggle            | A local, app-only override in the capture screen's app bar; off by default. Forces the offline/queued path even when connectivity is fine, for cases where the crew wants that deliberately                                                                                                                                                                                                                                                                                                                                                                      |
| Camera capture                  | Available offline whenever eligible (automatically, or forced via the toggle); GPS-fix and mock-location checks remain regardless                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Capture timestamp               | A synced device-clock offset supplies `captured_at` when a live timestamp fetch isn't available                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Local persistence               | Every capture is written locally immediately, independent of connectivity; for the offline/queued path, the fields needed at resubmission are encrypted the instant they're written rather than sitting on disk in plaintext (see below)                                                                                                                                                                                                                                                                                                                         |
| Offline data-at-rest encryption | A queued capture's submission-relevant fields are encrypted per-record with AES-256-GCM the moment it enters the offline queue; the AES key is wrapped by an Android Keystore RSA keypair whose private (unwrap) half requires a biometric check with no caching, so decrypting — and therefore resubmitting — a queued row always requires a fresh biometric check, regardless of whether the signing session below is still live. GCM's authentication tag also turns on-disk tampering into a detected decrypt failure instead of a silently-signed bad value |
| Attestation submission          | Submitted immediately when connectivity is available (unchanged, never queued or encrypted); a queued capture is auto-_attempted_ when the connectivity classifier transitions to `online`, but a queued row always needs a fresh biometric check to decrypt before it can resubmit — so "auto-retried" now means a prompt is raised automatically, not that submission completes silently, whether or not a signing session is still live (see below)                                                                                                           |
| Signing / biometric session     | Signing needs an in-memory key unlocked by biometrics (30-min cache, always cleared on app relaunch); the queue never auto-submits without one — it surfaces an explicit "unlock to submit" action instead of silently failing or faking a background prompt. Unlike this signing-key cache, the new decrypt-key biometric check has no cache window and fires on every reconnect                                                                                                                                                                                |
| Reconnect notification          | A local (on-device, no server) notification fires when connectivity returns while attestations are queued and the app isn't open, via an OS-scheduled background check — not push, and never capable of signing itself                                                                                                                                                                                                                                                                                                                                           |
| On-chain event                  | New `PhotoAttestedV2` / `FileAttestedV2` events carry `captured_at` (client-supplied), `attested_at` (`sui::clock::Clock`-derived), `is_online` (was connectivity actually sufficient), and `is_forced_offline` (was the override toggle on)                                                                                                                                                                                                                                                                                                                     |
| Verification                    | Reads `captured_at` / `attested_at` / `is_online` / `is_forced_offline` directly from the on-chain event, distinguishing a normal capture from an automatic offline one from a forced override                                                                                                                                                                                                                                                                                                                                                                   |

## 3. Where changes happen

- **`contracts/`** — new `PhotoAttestedV2`/`FileAttestedV2` events and
  `attest_photo_v2`/`attest_file_v2` entry functions, added alongside the existing ones.
- **`verification_api/` and `verification_portal/`** — recognize the new event types and
  read `captured_at`/`attested_at`/`is_online`/`is_forced_offline` from them.
- **`app/`** — a two-step connectivity check (new `connectivity_plus` dependency: radio
  state, then reachability/latency/bandwidth) replacing today's single-probe check, which
  automatically decides offline eligibility rather than requiring a pre-set toggle; a
  force-offline override toggle for the case where a crew wants offline behavior despite
  working connectivity; a new time-sync service supplying offline-safe timestamps;
  capture-flow changes so capture and local persistence don't require connectivity when
  eligible or forced; an Android Keystore-backed encryption service that encrypts a
  queued capture's submission-relevant fields the instant they're written and requires a
  fresh, uncached biometric check to decrypt them before resubmission; a queue that
  submits pending attestations once the classifier reports connectivity restored _and_ a
  biometric signing session is live, surfacing an explicit unlock action otherwise; a
  background-scheduled local notification (new `workmanager`/`flutter_local_notifications`
  dependencies) for when connectivity returns while the app isn't open; and history/detail
  UI showing the on-chain timestamps and mode, plus a distinct state for a queued row
  whose local data fails the decrypt/tamper check.
- **`server/`** — no changes.

See the [detailed design](./granite-lake-offline-capture-design-detail.md) for exact
files, function signatures, and reasoning.

## 4. Rollout plan

1. Ship the contract addition first, independently — it's additive and doesn't affect
   existing flows.
2. Update `verification_api`/`verification_portal` to recognize both event versions.
3. Ship the app-side time-sync, capture-flow, and at-rest encryption changes (Keystore
   keypair generation, encrypt-on-write for the offline/queued path).
4. Ship the submission queue — decrypt-gated, fresh biometric check on every reconnect —
   switching to the new `_v2` entry points in the same release.
5. Ship the history/detail UI updates, including the tamper-detected state.
