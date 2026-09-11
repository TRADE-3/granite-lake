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
online.

As part of this, the on-chain event gains four explicit fields — `captured_at` (the
claimed capture time), `attested_at` (the chain-anchored time), `is_online` (whether the
capture itself was made with live, sufficient connectivity), and `is_forced_offline`
(whether the crew manually overrode a working connection) — so all four are visible
directly on the ledger for any verifier, rather than only being reconstructable
off-chain.

## 2. High-level summary of changes

| Area                        | Design                                                                                                                                                                                                                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Connectivity detection      | Two checks, not one probe: (1) is a radio on at all (OS-level, via `connectivity_plus`), (2) is what it reaches good enough (reachability + latency + estimated bandwidth) — replacing today's single HTTP-probe-per-tick check                              |
| Offline eligibility         | Automatic: offline capture is offered whenever the check above isn't `online`, with no manual step required — no more relying on a crew to predict a dead zone and pre-toggle a switch                                                                       |
| Force-offline toggle        | A local, app-only override in the capture screen's app bar; off by default. Forces the offline/queued path even when connectivity is fine, for cases where the crew wants that deliberately                                                                  |
| Camera capture              | Available offline whenever eligible (automatically, or forced via the toggle); GPS-fix and mock-location checks remain regardless                                                                                                                            |
| Capture timestamp           | A synced device-clock offset supplies `captured_at` when a live timestamp fetch isn't available                                                                                                                                                              |
| Local persistence           | Every capture is written locally immediately, independent of connectivity                                                                                                                                                                                    |
| Attestation submission      | Submitted immediately when connectivity is available (unchanged); queued and auto-retried when it isn't, triggered by the connectivity classifier transitioning to `online` — but only when a live biometric signing session exists (see below)              |
| Signing / biometric session | Signing needs an in-memory key unlocked by biometrics (30-min cache, always cleared on app relaunch); the queue never auto-submits without one — it surfaces an explicit "unlock to submit" action instead of silently failing or faking a background prompt |
| Reconnect notification      | A local (on-device, no server) notification fires when connectivity returns while attestations are queued and the app isn't open, via an OS-scheduled background check — not push, and never capable of signing itself                                       |
| On-chain event              | New `PhotoAttestedV2` / `FileAttestedV2` events carry `captured_at` (client-supplied), `attested_at` (`sui::clock::Clock`-derived), `is_online` (was connectivity actually sufficient), and `is_forced_offline` (was the override toggle on)                 |
| Verification                | Reads `captured_at` / `attested_at` / `is_online` / `is_forced_offline` directly from the on-chain event, distinguishing a normal capture from an automatic offline one from a forced override                                                               |

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
  eligible or forced; a queue that submits pending attestations once the classifier
  reports connectivity restored _and_ a biometric signing session is live, surfacing an
  explicit unlock action otherwise; a background-scheduled local notification (new
  `workmanager`/`flutter_local_notifications` dependencies) for when connectivity returns
  while the app isn't open; and history/detail UI showing the on-chain timestamps and
  mode.
- **`server/`** — no changes.

See the [detailed design](./granite-lake-offline-capture-design-detail.md) for exact
files, function signatures, and reasoning.

## 4. Rollout plan

1. Ship the contract addition first, independently — it's additive and doesn't affect
   existing flows.
2. Update `verification_api`/`verification_portal` to recognize both event versions.
3. Ship the app-side time-sync and capture-flow changes.
4. Ship the submission queue, switching to the new `_v2` entry points in the same release.
5. Ship the history/detail UI updates.
