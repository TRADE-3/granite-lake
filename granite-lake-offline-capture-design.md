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

As part of this, the on-chain event gains three explicit fields — `captured_at` (the
claimed capture time), `attested_at` (the chain-anchored time), and `is_online` (whether
the capture itself was made with live connectivity) — so all three are visible directly
on the ledger for any verifier, rather than only being reconstructable off-chain.

## 2. High-level summary of changes

| Area                   | Design                                                                                                                                                                                          |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Offline-capture switch | A local, app-only toggle in the capture screen's app bar; off by default, controls whether offline capture is permitted                                                                         |
| Camera capture         | Available offline when the switch is on; GPS-fix and mock-location checks remain regardless                                                                                                     |
| Capture timestamp      | A synced device-clock offset supplies `captured_at` when a live timestamp fetch isn't available                                                                                                 |
| Local persistence      | Every capture is written locally immediately, independent of connectivity                                                                                                                       |
| Attestation submission | Submitted immediately when connectivity is available (unchanged); queued and auto-retried when it isn't                                                                                         |
| On-chain event         | New `PhotoAttestedV2` / `FileAttestedV2` events carry `captured_at` (client-supplied), `attested_at` (`sui::clock::Clock`-derived), and `is_online` (whether the capture had live connectivity) |
| Verification           | Reads `captured_at` / `attested_at` / `is_online` directly from the on-chain event                                                                                                              |

## 3. Where changes happen

- **`contracts/`** — new `PhotoAttestedV2`/`FileAttestedV2` events and
  `attest_photo_v2`/`attest_file_v2` entry functions, added alongside the existing ones.
- **`verification_api/` and `verification_portal/`** — recognize the new event types and
  read `captured_at`/`attested_at` from them.
- **`app/`** — an app-bar toggle to permit offline capture, a new time-sync service
  supplying offline-safe timestamps, capture-flow changes so capture and local
  persistence don't require connectivity when the toggle is on, a queue that submits
  pending attestations once connectivity returns, and history/detail UI showing the
  on-chain timestamps.
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
