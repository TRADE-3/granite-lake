# Granite Lake — Offline Capture & On-Chain Timestamp Design

**Author:** Nethmi Jayakody
**Status:** Draft for review
**Related:** Supporting photo/file attestation for field crews working without connectivity
**Detailed design:** [granite-lake-offline-capture-design-detail.md](./granite-lake-offline-capture-design-detail.md)

## 1. Goal

Field crews sometimes work in areas without internet connectivity, without a usable GPS
fix, or both. This design adds an offline capture path so a photo or file can be captured
and locally attested at any time, with the on-chain attestation submitted automatically
once connectivity is available — while keeping the same trust guarantees Granite Lake
already provides when a device is online and located. It also protects a capture queued
while offline from being altered on-device before it reaches the chain, by encrypting it
the instant it's written and requiring a fresh biometric check to decrypt it once
connectivity returns.

Connectivity and GPS are each treated as independently optional, not as a single
"offline mode": a capture can be missing internet, missing GPS, or both, and each is
recorded on its own. Neither one is ever allowed to go missing, nor have a working state
overridden, silently — whenever either is null, or the crew deliberately overrides a
working connection or an available GPS fix via its force toggle, the crew member must
supply a reason before the capture is allowed to proceed, and that reason is hashed and
stored so a verifier can later confirm a disclosed reason matches what was recorded at
capture time without the reason text itself needing to live on a public ledger. This is
enforced on-chain: `attest_photo`/`attest_file` revert if a reason hash is missing when
required, or supplied when it shouldn't be.

As part of this, the on-chain event carries the following explicit fields, so all of
them are visible directly on the ledger for any verifier rather than only being
reconstructable off-chain:

- `captured_at` — the claimed capture time (client-supplied).
- `attested_at` — the chain-anchored time (`sui::clock`-derived).
- `is_online` — whether the capture itself was made with live, sufficient connectivity
  (ground truth, unaffected by `is_forced_offline`).
- `is_forced_offline` — whether the crew manually overrode a working connection.
- `internet_null_reason_hash` — hash of the mandatory reason, required whenever
  `is_online` is `false` **or** `is_forced_offline` is `true`; empty only when
  `is_online: true, is_forced_offline: false`. Present on both photo and file
  attestations.
- `has_gps` (photo attestation only) — whether a real GPS fix was available (ground
  truth, unaffected by `is_gps_forced_null`).
- `is_gps_forced_null` (photo attestation only) — whether the crew manually chose to
  withhold GPS despite a fix being available.
- `gps_null_reason_hash` (photo attestation only) — hash of the mandatory reason,
  required whenever `has_gps` is `false` **or** `is_gps_forced_null` is `true`; empty
  only when `has_gps: true, is_gps_forced_null: false`.

This is trade3's own contract with no prior on-chain attestations to preserve, so these
fields are added directly to the existing `PhotoAttested`/`FileAttested` events and
`attest_photo`/`attest_file` entry functions — there is no versioned event scheme
(`V1`/`V2`) and no upgrade path to maintain; existing callers are simply recompiled
against the new signatures.

## 2. High-level summary of changes

| Area                            | Design                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Connectivity detection          | Two checks, not one probe: (1) is a radio on at all (OS-level, via `connectivity_plus`), (2) is what it reaches good enough (reachability + latency + estimated bandwidth) — replacing today's single HTTP-probe-per-tick check                                                                                                                                                                                                                                                                                                                                  |
| Offline eligibility             | Automatic: offline capture is offered whenever the check above isn't `online`, with no manual step required — no more relying on a crew to predict a dead zone and pre-toggle a switch                                                                                                                                                                                                                                                                                                                                                                           |
| Force-offline toggle            | A local, app-only override in the capture screen's app bar; off by default. Forces the offline/queued path even when connectivity is fine, for cases where the crew wants that deliberately                                                                                                                                                                                                                                                                                                                                                                      |
| GPS eligibility                 | Independent of connectivity: a capture may proceed without a GPS fix (no fix obtained, or the crew deliberately skips it via a "Force No GPS" toggle, off by default, in the capture screen's app bar). Mock-location detection is unaffected by this — a _detected fake_ fix still hard-blocks the shutter; only a _missing_ fix becomes optional                                                                                                                                                                                                               |
| Mandatory null reason           | Whenever internet or GPS is null at capture time, **or** the crew overrides a working connection / available GPS fix via its force toggle, the crew must enter a free-text reason before the shutter proceeds — the only state needing no reason is "present, not overridden." Required per-axis independently: a capture can be missing/overriding one, the other, or both, each with its own reason. Enforced on-chain, not just client-side                                                                                                                   |
| Null-reason hashing             | Each mandatory reason is hashed (same convention as `photo_hash`/`file_hash`) before being stored; the hash goes on-chain, the plaintext reason stays in local storage so it can be disclosed and checked against the hash during verification without ever putting free-text crew explanations on a public ledger                                                                                                                                                                                                                                               |
| Camera capture                  | Available without connectivity and/or without GPS whenever eligible (automatically, or forced via the relevant toggle); mock-location detection remains a hard block regardless                                                                                                                                                                                                                                                                                                                                                                                  |
| Capture timestamp               | The `trusted_time` package (network-synced, anchored to the hardware monotonic clock so it survives the user changing the system clock while offline) supplies `captured_at` when a live timestamp fetch isn't available; falls back to the raw device clock only if `trusted_time` itself can't return a reading (e.g. a reboot happened while offline, invalidating its anchor before a resync) — an accepted gap for now                                                                                                                                      |
| Local persistence               | Every capture is written locally immediately, independent of connectivity; for the offline/queued path, the fields needed at resubmission are encrypted the instant they're written rather than sitting on disk in plaintext (see below)                                                                                                                                                                                                                                                                                                                         |
| Offline data-at-rest encryption | A queued capture's submission-relevant fields are encrypted per-record with AES-256-GCM the moment it enters the offline queue; the AES key is wrapped by an Android Keystore RSA keypair whose private (unwrap) half requires a biometric check with no caching, so decrypting — and therefore resubmitting — a queued row always requires a fresh biometric check, regardless of whether the signing session below is still live. GCM's authentication tag also turns on-disk tampering into a detected decrypt failure instead of a silently-signed bad value |
| Attestation submission          | Submitted immediately when connectivity is available (unchanged, never queued or encrypted); a queued capture is auto-_attempted_ when the connectivity classifier transitions to `online`, but a queued row always needs a fresh biometric check to decrypt before it can resubmit — so "auto-retried" now means a prompt is raised automatically, not that submission completes silently, whether or not a signing session is still live (see below)                                                                                                           |
| Signing / biometric session     | Signing needs an in-memory key unlocked by biometrics (30-min cache, always cleared on app relaunch); the queue never auto-submits without one — it surfaces an explicit "unlock to submit" action instead of silently failing or faking a background prompt. Unlike this signing-key cache, the new decrypt-key biometric check has no cache window and fires on every reconnect                                                                                                                                                                                |
| Reconnect notification          | A local (on-device, no server) notification fires when connectivity returns while attestations are queued and the app isn't open, via an OS-scheduled background check — not push, and never capable of signing itself                                                                                                                                                                                                                                                                                                                                           |
| On-chain event                  | `PhotoAttested`/`FileAttested` (modified in place, no versioning) carry `captured_at`, `attested_at`, `is_online`, `is_forced_offline`, `internet_null_reason_hash`; `PhotoAttested` additionally carries `has_gps`, `is_gps_forced_null`, `gps_null_reason_hash`                                                                                                                                                                                                                                                                                                |
| Verification                    | Reads all of the above directly from the on-chain event: distinguishes a normal capture from an automatic offline one from a forced override, independently for both internet and GPS, and checks that a disclosed reason's hash matches the on-chain `*_null_reason_hash` whenever one is expected (field null, or field present but overridden)                                                                                                                                                                                                                |

## 3. Where changes happen

- **`contracts/`** — `PhotoAttested`/`FileAttested` and `attest_photo`/`attest_file` are
  modified in place to add the fields listed above, plus a `clock: &Clock` parameter used
  to derive `attested_at`. No versioned event scheme, no upgrade path — this is trade3's
  own contract with nothing deployed yet to preserve compatibility with.
- **`verification_api/` and `verification_portal/`** — read the expanded field set from
  `PhotoAttested`/`FileAttested`, and independently check, for internet and for GPS: is
  the field present; if not, was it forced or automatic; and does a disclosed reason's
  hash match the on-chain `*_null_reason_hash`.
- **`app/`** — a two-step connectivity check (new `connectivity_plus` dependency: radio
  state, then reachability/latency/bandwidth) replacing today's single-probe check, which
  automatically decides offline eligibility rather than requiring a pre-set toggle; a
  force-offline override toggle and an independent force-no-GPS override toggle for the
  cases where a crew wants that path despite working connectivity/a good fix; a mandatory
  reason prompt whenever either field will be null, hashed via the same convention as
  `photo_hash`, with the plaintext kept in local storage; a new time-sync service
  supplying offline-safe timestamps; capture-flow changes so capture and local
  persistence don't require connectivity or GPS when eligible or forced; an Android
  Keystore-backed encryption service that encrypts a queued capture's submission-relevant
  fields the instant they're written and requires a fresh, uncached biometric check to
  decrypt them before resubmission; a queue that submits pending attestations once the
  classifier reports connectivity restored _and_ a biometric signing session is live,
  surfacing an explicit unlock action otherwise; a background-scheduled local
  notification (new `workmanager`/`flutter_local_notifications` dependencies) for when
  connectivity returns while the app isn't open; and history/detail UI showing the
  on-chain timestamps, connectivity/GPS mode, and reasons, plus a distinct state for a
  queued row whose local data fails the decrypt/tamper check.
- **`server/`** — no changes.

See the [detailed design](./granite-lake-offline-capture-design-detail.md) for exact
files, function signatures, and reasoning.

## 4. Rollout plan

1. Ship the contract change first, independently — modified in place, no legacy events
   to preserve compatibility with.
2. Update `verification_api`/`verification_portal` to read the expanded field set and
   check disclosed reasons against their on-chain hashes.
3. Ship the app-side time-sync, capture-flow (connectivity + GPS optionality, mandatory
   reason prompts), and at-rest encryption changes (Keystore keypair generation,
   encrypt-on-write for the offline/queued path).
4. Ship the submission queue — decrypt-gated, fresh biometric check on every reconnect.
5. Ship the history/detail UI updates, including the tamper-detected state and the
   reason/GPS-mode display.
