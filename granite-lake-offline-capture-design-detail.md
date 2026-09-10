# Granite Lake — Offline Capture & On-Chain Timestamp Design (Detail)

**Author:** Nethmi Jayakody
**Status:** Draft for review
**Related:** [granite-lake-offline-capture-design.md](./granite-lake-offline-capture-design.md)

This is the in-depth companion to the high-level design doc. Each section below maps to
a row in that doc's summary table.

## 1. Contract change: `captured_at` / `attested_at`

Sui package upgrades add new code at a new package address; the layout of an existing
struct and the signature of an existing entry function stay fixed across an upgrade. This
project already upgrades in place rather than republishing — `verification_api/src/constants.ts`
carries both a "current" and an "original" package id, with a comment noting that events
from the original address remain permanently queryable there. This design follows the
same shape: new, versioned structs and entry functions are added alongside the existing
ones, so existing app builds and existing attestations continue to work unchanged.

`contracts/sources/granite_lake.move`:

```move
use sui::clock::{Self, Clock};

public struct PhotoAttestedV2 has copy, drop {
    photo_hash: vector<u8>,
    gps: vector<u8>,
    altitude: vector<u8>,
    project_id: vector<u8>,
    user_wallet: address,
    domain: vector<u8>,
    captured_at: u64,   // client-supplied, ms since epoch
    attested_at: u64,   // clock::timestamp_ms(clock) at execution — chain-derived
    is_online: bool,    // client-supplied — whether the device had live connectivity at capture time
}
// FileAttestedV2 mirrors this with file_hash/file_id in place of photo_hash

public entry fun attest_photo_v2(
    user_cap: &UserCap,
    registry: &Registry,
    hash: vector<u8>,
    gps: vector<u8>,
    altitude: vector<u8>,
    project_id: vector<u8>,
    captured_at: u64,
    is_online: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // same auth checks as attest_photo
    let attested_at = clock::timestamp_ms(clock);
    event::emit(PhotoAttestedV2 { photo_hash: hash, gps, altitude, project_id,
        user_wallet: sender, domain: user_cap.domain, captured_at, attested_at, is_online });
}
// attest_file_v2 mirrors this
```

`sui::clock` is already a framework dependency (present under
`contracts/build/granite_lake/sources/dependencies/Sui/clock.move`), so no new package
dependency is needed. `attest_photo`/`attest_file`/`PhotoAttested`/`FileAttested` remain
in the module unchanged.

**Tests:** extend `contracts/tests/granite_lake_tests.move` with V2 equivalents of the
existing tests (`test_attest_photo_emits_photo_attested_event`,
`test_only_user_cap_owner_can_call_attest_photo`), using `sui::clock`'s test utilities to
assert `attested_at` is populated and `captured_at` round-trips.

**Deployment:** a `sui client upgrade` using the project's retained `UpgradeCap`. The
shared `Registry` and existing `UserCap`s are unaffected — upgrades change code, not
already-shared object state. After upgrade:

- `verification_api`/`verification_portal`: set `GRANITE_LAKE_PACKAGE_ID` to the new
  address; `GRANITE_LAKE_ORIGINAL_PACKAGE_ID` stays pointed at genesis.
- App: update `defaultPhotoAttestationPackageId` in `app_constants.dart`;
  `defaultPhotoAttestationRegistryId` is unchanged.

## 2. Verification updates

**`verification_api`** (`src/constants.ts`, `src/services/attestVerification.ts`): add
`PHOTO_ATTESTED_V2_EVENT_TYPES`/`FILE_ATTESTED_V2_EVENT_TYPES`, recognized alongside the
existing constants when scanning for events. When a V2 event is found, `captured_at`/
`attested_at`/`is_online` are decoded directly (the first two as plain `u64`s, `is_online`
as a plain `bool`, unlike the vector-decoded `gps`/`project_id` fields) and returned
alongside the existing fields; V1 events continue to report time via
`event.timestampMs`/`checkpointTimeIso` as they do today, with no `is_online` value.
**`verification_portal`** mirrors this and displays the timestamps and an online/offline
badge when present.

**App side** (`app/lib/core/services/photo_attestation_service.dart`):

- `attestPhoto`/`attestFile` call `attest_photo_v2`/`attest_file_v2`, passing
  `captured_at` as a `u64` pure transaction argument (the exact `on_chain` package
  constructor for a pure `u64` arg should be confirmed at implementation time — the
  codebase's existing pure-arg usage is all `.bytes()`), `is_online` as a `bool` pure
  argument, and the shared `Clock` object (well-known id `0x6`, `initialSharedVersion: 1`)
  as an object argument. The existing `_loadRegistryObjectArg` helper (which already
  builds a `SuiObjectArgSharedObject` for the registry) generalizes into
  `_loadSharedObjectArg(graphqlUrl, objectId)`, reused for both the registry and the
  clock.
- `verifyPhotoAttestation`: when the transaction's event is `PhotoAttestedV2`,
  `captured_at`/`attested_at`/`is_online` are decoded directly and `attested_at` is used
  as `chainTimestamp`; `_resolveChainTimestamp`'s GraphQL-envelope lookup remains the path
  for V1 events. A `capturedAtMatches` check compares on-chain `captured_at` against the
  locally stored value, and `timestampWithinTolerance` becomes
  `attested_at - captured_at <= AppConstants.maximumAttestationTimeGapMinutes`, computed
  from two on-chain values.

## 3. `TimeSyncService`

New file: `app/lib/core/services/time_sync_service.dart`.

- `Future<void> recordServerTime(DateTime serverUtc)` — called whenever a live `/utc`
  response is already being fetched (the OTP flow, and the capture screen's existing
  connectivity-check timer).
- `DateTime nowUtc()` — synchronous. Derives the current time from `deviceNow +
lastSyncedOffset`, falling back to the device's own wall clock if no sync has happened
  yet.
- `TimeProvenance get provenance` → `fresh | stale | neverSynced`, against thresholds
  added to `app_constants.dart` near `maximumAttestationTimeGapMinutes`.
- Persisted through `ConfigDao`/`ConfigDataController`'s existing JSON key-value store
  (the same mechanism already used for `photoAttestationContractConfig`), as a new config
  key — no schema migration involved.

`captured_at` is derived from a synced wall-clock offset rather than a monotonic device
clock for this iteration — a lighter-weight approach that fits the current threat model of
a company-managed device and an honest field operator. A monotonic-clock variant
(`SystemClock.elapsedRealtime()` via a native channel) can be layered in later without
changing the on-chain shape, since `captured_at` is just a `u64` the client supplies.

## 4. Offline-capture switch

An "Allow Offline Capture" toggle controls whether the offline capture path in this
design is active. It's app-only (no server/domain-admin involvement) and lives as a
persistent quick-toggle icon in the capture screen's app bar, next to the existing
connectivity indicator, rather than in the general settings screen — this lets a crew
enable it pre-emptively before heading into a dead zone, and it stays visible for the
rest of the session as a reminder of which mode is active.

- State is stored locally through `ConfigDao`/`ConfigDataController` (the same
  mechanism used for `TimeSyncService`'s synced offset), as a new boolean config key.
  Default is off — capture requires live connectivity, matching current behavior, until
  a crew explicitly enables offline capture for a trip.
- When on: the shutter, timestamp fallback, and submission queue behave as described in
  the rest of this document.
- When off: capture behaves exactly as it does today (connectivity required at the
  shutter and at timestamp fetch).
- The switch controls whether offline capture is _permitted_; it's independent of the
  on-chain `is_online` field, which simply records whether the device happened to have
  live connectivity at the moment of that particular capture. A capture taken with the
  switch on, while connectivity happens to be available, still records `is_online: true`.

## 5. Capture flow changes

`app/lib/features/capture/screens/capture_screen.dart`:

- The shutter is available without connectivity when the offline-capture switch (§4) is
  on; GPS-fix and mock-location checks remain as they are today regardless of the switch.
- `capturedAtUtc`/`submittedAtUtc` are sourced by preferring a live timestamp fetch (as
  today, when connectivity is available) and falling back to `TimeSyncService.nowUtc()`
  otherwise. The success/failure of that live fetch is also what sets the `is_online`
  value passed to `attest_photo_v2`/`attest_file_v2` (§2).

`app/lib/core/state/granite_lake_controller.dart`:

- `persistCaptureWithMetadata`'s wallet-balance check reads the last-known cached balance
  rather than forcing a fresh RPC read before persisting, so local persistence doesn't
  depend on a live balance query; the same check that runs at actual submission time
  continues to catch a genuinely insufficient balance.
- The existing non-null validation on `capturedAtUtc`/`submittedAtUtc` is unchanged — the
  caller now always supplies a value via the path above.
- The same treatment applies to `persistFileWithMetadata` / `file_attestation_screen.dart`.

## 6. Submission queue

Local persistence (`sui_submission_status = 'PENDING_SUBMISSION'`) already happens
independently of the chain-submission step.

- `_submitPhotoAttestation`/`_submitFileAttestation`'s failure handling distinguishes a
  network-class failure from a definite rejection, reusing the classifier already used by
  `sui_graphql_service.dart` for chain-verification retries (extracted into a small shared
  helper). A network-class failure leaves the row at `PENDING_SUBMISSION`; a definite
  rejection (bad signature, misconfiguration) is reported as it is today.
- `GraniteLakeController` gains `retryPendingAttestations()`, which sweeps
  `PENDING_SUBMISSION` rows oldest-first, sequentially, resubmitting via
  `attest_photo_v2`/`attest_file_v2` with the original `captured_at` preserved (a fresh
  `attested_at` is supplied by the chain wherever the submission lands).
- The sweep runs on two triggers: the capture screen's connectivity timer transitioning
  to connected, and app foreground/resume via a `WidgetsBindingObserver` registered at the
  app root (`app/lib/app.dart`), so it runs even when the capture screen isn't mounted.

## 7. Local timestamp provenance

Alongside the on-chain `captured_at`/`attested_at`, the app also records locally how the
device's own claimed `captured_at` was derived (a fresh live fetch, a synced offset, or an
unsynced device clock), folded into the existing signed `proof_payload_json` blob used by
`granite_lake_capture_workflow_service.dart` — the same mechanism that already carries
`gpsLabel`/`altitudeLabel` — so no new database column is needed.

## 8. UI

- Capture screen's app bar carries the offline-capture toggle (§4) next to the
  connectivity indicator; connectivity state itself is shown as an informational banner
  rather than a blocker.
- History screen shows a pending-sync count, from a new `pendingAttestationCount` getter
  on `GraniteLakeController`.
- Capture-detail screen shows the on-chain `captured_at`/`attested_at`/`is_online`
  alongside the local provenance label, next to the existing submission-status detail.

## 9. Files touched

**Contract:** `contracts/sources/granite_lake.move`, `contracts/tests/granite_lake_tests.move`.

**Verification tooling:** `verification_api/src/constants.ts`,
`verification_api/src/services/attestVerification.ts`, `verification_portal`'s equivalent
lookup code.

**New app files:** `app/lib/core/services/time_sync_service.dart` (and optionally a
shared `isTransientNetworkError` helper extracted from `sui_graphql_service.dart`).

**Modified app files:** `photo_attestation_service.dart`, `capture_screen.dart`
(offline-capture toggle UI + shutter/timestamp changes), `file_attestation_screen.dart`,
`granite_lake_controller.dart`, `granite_lake_capture_workflow_service.dart`,
`config_data_controller.dart` + `granite_lake_database_service.dart` (new config keys:
synced time offset, offline-capture switch state), `app.dart` (lifecycle observer),
`history_screen.dart`, `capture_detail_screen.dart`, `app_constants.dart`.

## 10. Verification / testing

- `sui move test` in `contracts/` for the new entry functions/events.
- `flutter analyze app`; `npm run lint:verification_api` / `npm run lint:verification_portal`.
- After a testnet package upgrade: confirm a historical (V1) attestation and a new V2
  attestation both verify correctly through `verification_api`/`verification_portal`.
- Manual airplane-mode pass: with the offline-capture switch on, capture succeeds
  offline and records `is_online: false`; the row appears as `PENDING_SUBMISSION`;
  reconnecting (via timer and via app foreground) triggers submission with the original
  `captured_at` and a fresh `attested_at`; the detail screen and `verification_portal`
  show matching values. Separately confirm the switch off restores today's
  connectivity-required behavior, and that an online capture with the switch on records
  `is_online: true`. Repeat for the file-upload path.

## 11. Open items

1. Confirm the `on_chain` package's constructor for pure `u64`/`bool` transaction
   arguments.
2. Decide whether a `capturedAtMatches` mismatch is surfaced as a hard verification
   failure or an informational note in `verification_portal`.
3. Decide how history UI should present V1 attestations (no `captured_at`/`attested_at`/
   `is_online`) alongside V2 ones — likely keep the existing time display for V1 and show
   the new fields only where available.
4. Decide the exact icon/state treatment for the app-bar offline-capture toggle (e.g.
   distinct icon states for "online, switch off", "online, switch on", "offline, switch
   on").
