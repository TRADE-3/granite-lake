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
    is_online: bool,    // client-supplied — whether §5's check found the device online-capable at capture time
    is_forced_offline: bool, // client-supplied — raw state of the §4 "Force Offline Mode" toggle at capture time
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
    is_forced_offline: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // same auth checks as attest_photo
    let attested_at = clock::timestamp_ms(clock);
    event::emit(PhotoAttestedV2 { photo_hash: hash, gps, altitude, project_id,
        user_wallet: sender, domain: user_cap.domain, captured_at, attested_at, is_online,
        is_forced_offline });
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
assert `attested_at` is populated, `captured_at` round-trips, and all four
`is_online`/`is_forced_offline` combinations (table in §4) round-trip independently of
each other.

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
`attested_at`/`is_online`/`is_forced_offline` are decoded directly (the first two as plain
`u64`s, the latter two as plain `bool`s, unlike the vector-decoded `gps`/`project_id`
fields) and returned alongside the existing fields; V1 events continue to report time via
`event.timestampMs`/`checkpointTimeIso` as they do today, with neither value.
**`verification_portal`** mirrors this and displays the timestamps plus a badge reflecting
the §4 table (online / forced-offline-override / auto-offline) when present.

**App side** (`app/lib/core/services/photo_attestation_service.dart`):

- `attestPhoto`/`attestFile` call `attest_photo_v2`/`attest_file_v2`, passing
  `captured_at` as a `u64` pure transaction argument (the exact `on_chain` package
  constructor for a pure `u64` arg should be confirmed at implementation time — the
  codebase's existing pure-arg usage is all `.bytes()`), `is_online`/`is_forced_offline`
  each as a `bool` pure argument, and the shared `Clock` object (well-known id `0x6`,
  `initialSharedVersion: 1`) as an object argument. The existing `_loadRegistryObjectArg`
  helper (which already builds a `SuiObjectArgSharedObject` for the registry) generalizes
  into `_loadSharedObjectArg(graphqlUrl, objectId)`, reused for both the registry and the
  clock.
- `verifyPhotoAttestation`: when the transaction's event is `PhotoAttestedV2`,
  `captured_at`/`attested_at`/`is_online`/`is_forced_offline` are decoded directly and
  `attested_at` is used as `chainTimestamp`; `_resolveChainTimestamp`'s GraphQL-envelope
  lookup remains the path
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

## 4. Offline eligibility: automatic by default, with a manual force-offline override

Whether offline capture is _available_ is no longer something a crew has to predict and
toggle in advance. §5 makes that determination automatically, on the same eligibility
check the shutter already needs: does the device have a working interface (wifi/data),
and is what that interface can reach good enough to actually submit an attestation.

- **Sufficient (online-capable):** offline capture is not offered — the shutter behaves
  as it does today, requiring connectivity and a live timestamp fetch. There's no reason
  to route around a connection that works.
- **Insufficient (no interface, or an interface that can't usably reach the backend):**
  the offline capture path (§6 onward: local persistence, timestamp fallback, queued
  submission) is available automatically, with no prior toggle needed. This is the case
  this whole design exists for — a crew in a dead zone shouldn't need to have
  remembered to flip a switch before losing signal.

**"Force Offline Mode" toggle** replaces the old permission switch, with the opposite
default relationship to connectivity: instead of _unlocking_ offline capture, it
_overrides_ the automatic decision so a capture is routed through the offline/queued path
even while §5 reports the device online-capable. It's app-only (no server/domain-admin
involvement), lives as the same persistent quick-toggle icon in the capture screen's app
bar next to the connectivity indicator, and is off by default.

- State is stored locally through `ConfigDao`/`ConfigDataController` (the same mechanism
  used for `TimeSyncService`'s synced offset), as a boolean config key — same storage
  shape as the switch it replaces, `offlineCaptureForced` in place of the old
  `offlineCaptureAllowed`.
- With the toggle on, a capture always takes the local-persist-then-queue path (§6),
  regardless of what §5's check reports — this is a deliberate override (e.g. a crew that
  doesn't want to wait out a slow submission mid-shoot, or wants every capture from a trip
  queued and submitted together at the end).
- With the toggle off (default), offline vs. online behavior follows §5's automatic
  determination.
- The toggle's raw state at the moment of capture is recorded as `is_forced_offline`,
  separately from `is_online` (§5's ground-truth connectivity finding) — both locally and
  on-chain. See "Recording the override" below.

**Recording the override.** `is_forced_offline` is added alongside `is_online` to
`PhotoAttestedV2`/`FileAttestedV2` (§1) and `attest_photo_v2`/`attest_file_v2`, and to the
`photo_captures`/`uploaded_files` tables (§8) so it survives to resubmission the same way
`captured_at`/`is_online` do. It records the toggle's literal on/off state at capture
time — not a derived "did the override actually change anything" flag — so a verifier can
read both fields together and distinguish all four cases without any hidden logic:

| `is_online` | `is_forced_offline` | Meaning                                                         |
| ----------- | ------------------- | --------------------------------------------------------------- |
| `true`      | `false`             | Normal online capture, submitted immediately.                   |
| `true`      | `true`              | Connectivity was fine; the crew chose to defer/queue it anyway. |
| `false`     | `false`             | Automatic offline — §5 found no usable connectivity.            |
| `false`     | `true`              | Toggle was on, but moot — offline was required either way.      |

## 5. Connectivity detection: two checks, not one probe

Today, `_hasNetworkConnectivity` in `capture_screen.dart` is a single boolean derived from
one HTTP round trip: a `Timer.periodic(30s)` calls `_refreshBackendStatus()`, which calls
`AppUtils.hasBackendConnectivity(domain)` (`app/lib/core/utils/utils.dart`), which does a
`forceRefresh` call to `resolveOtpBackendConfig` — a `GET /utc` against each configured
backend candidate in turn, each with its own 3-5s timeout. One dropped packet flips the
label from `Connected` to `Offline` and back on the next tick; there's no OS-level
reachability signal to short-circuit that round trip when the radio is plainly off, and no
notion of "reachable but too slow to be worth it." This section replaces that single probe
with two explicit checks, run by a new `ConnectivityHeuristicService`, whose combined
result is what §4 uses to decide whether offline capture is offered.

**`ConnectivityHeuristicService`** (new file:
`app/lib/core/services/connectivity_heuristic_service.dart`), used in place of the direct
`AppUtils.hasBackendConnectivity` call in `_refreshBackendStatus`:

**Step 1 — is a radio on at all.** Add `connectivity_plus` as a new dependency and check
the OS-reported interface state first. No active interface (airplane mode, no SIM and no
Wi-Fi) → skip straight to `offline`, no network round trip. This is the case where the
existing probe is both most expensive (every candidate times out at 3-5s) and least
informative — the radio being off already answers the question. An active interface
(`wifi` or `mobile` present) moves to step 2; it only confirms a radio is associated, not
that it actually reaches anything (see the earlier discussion of this limitation), which
is exactly what step 2 is for.

**Step 2 — is what it reaches good enough.** Run the existing `GET /utc` probe and treat
it as a lightweight reachability + quality check rather than only a pass/fail:

- The transaction payload this all exists to submit is tiny — a hash plus a handful of
  short byte fields, no image bytes go on-chain — so raw throughput isn't the real
  constraint; a dedicated large-payload speed test was considered and rejected because it
  would burn a field crew's data budget precisely in the marginal-connectivity conditions
  being tested, for a number that doesn't predict submission success as well as latency
  does. Instead, throughput is estimated for free from the probe already happening
  (response bytes ÷ elapsed time), and on Android, `NetworkCapabilities`'
  `getLinkDownstreamBandwidthKbps()` is read via a small platform channel as an
  instant, zero-cost secondary signal (a driver-reported estimate, not a measurement — iOS
  has no equivalent, so the probe-derived figure is primary there).
- "Good enough" (`minimumSufficientBandwidthKbps` in `app_constants.dart`, a conservative
  default such as 50 Kbps) is really a floor beneath which requests reliably stall or
  time out, not a real bandwidth budget — this is a "not painfully slow" filter more than
  a speed test.
- Latency matters independently of throughput: a probe that succeeds but exceeds a p50
  latency threshold (e.g. 2s) counts as `degraded`, since a connection that's technically
  up but slow to respond will make a crew wait through the exact submission delay offline
  mode exists to avoid.
- Failing the probe outright (timeout, `SocketException`, non-2xx) with an active
  interface present is `degraded`/`offline` depending on persistence (below) — an
  interface that can't complete a request is functionally no better than no interface.

**Rolling classification, not a single shot.** Keep a small ring buffer (last 5 probe
outcomes + latencies) and classify into `online` / `degraded` / `offline`: `offline` after
2 consecutive failures or no OS interface (step 1); `degraded` when probes succeed but
intermittently, fall short of `minimumSufficientBandwidthKbps`, or exceed the latency
threshold; `online` otherwise. `online` is the only state where §4 treats the device as
online-capable; `degraded` and `offline` both make offline capture available
automatically.

- **Hysteresis on the user-facing label.** `_networkStatusLabel` flips only after 2
  consecutive same-direction classifications, not on every tick — this is what stops a
  marginal-signal area from bouncing `Connected`/`Offline` every 30 seconds, which today
  would also bounce the recorded `is_online` value and the §4 eligibility decision itself.
- **Adaptive poll cadence**, replacing the flat 30s timer: poll every 10s while `degraded`
  or immediately after a state-changing failure (to confirm and recover quickly), back off
  to 60-90s once solidly `offline` for a few consecutive polls (polling a dead zone every
  30s only burns battery/data until the crew physically moves), and return to 30s once
  `online`. The existing reconnect trigger (§7: app foreground/resume) still fires an
  immediate out-of-cycle check, so backing off the steady poll doesn't delay recovery.
- **One unified network-error classifier.** `sui_graphql_service.dart`'s
  `_isTransientNetworkError` (type-based: `SocketException` / `TimeoutException` /
  `http.ClientException`) and `granite_lake_controller.dart`'s
  `_shouldRetryChainVerification` (string-matching on the failure reason) currently
  disagree on what counts as a network problem. Both should classify against the same
  predicate — the type-based one is strictly more precise — so a probe failure, a GraphQL
  request failure, and a chain-verification failure all feed the same understanding of
  "is this the network's fault," including into `ConnectivityHeuristicService`'s own
  classification.

**`is_online` at capture time** is read from `ConnectivityHeuristicService`'s current
smoothed state (`online` → `true`, `degraded`/`offline` → `false`) at the moment of
capture, rather than the raw success/failure of one live timestamp fetch (§3). Same field
semantics as originally designed — still "did this device have live connectivity at
capture time" — just sourced from the debounced two-step classifier instead of a single
point-in-time call that could land on one unlucky retry. `is_forced_offline` (§4) is
recorded alongside it from the toggle's raw state, independently of this classification.

## 6. Capture flow changes

`app/lib/features/capture/screens/capture_screen.dart`:

- The shutter is available without connectivity whenever §5's classifier is not `online`,
  or the §4 "Force Offline Mode" toggle is on regardless of what §5 reports; GPS-fix and
  mock-location checks remain as they are today in both cases.
- `capturedAtUtc`/`submittedAtUtc` are sourced by preferring a live timestamp fetch (as
  today, when connectivity is available) and falling back to `TimeSyncService.nowUtc()`
  otherwise. `is_online` passed to `attest_photo_v2`/`attest_file_v2` (§2) is read from
  `ConnectivityHeuristicService`'s current state (§5) rather than that one fetch's
  success/failure; `is_forced_offline` is read from the toggle's current state (§4).

`app/lib/core/state/granite_lake_controller.dart`:

- `persistCaptureWithMetadata`'s wallet-balance check reads the last-known cached balance
  rather than forcing a fresh RPC read before persisting, so local persistence doesn't
  depend on a live balance query; the same check that runs at actual submission time
  continues to catch a genuinely insufficient balance.
- The existing non-null validation on `capturedAtUtc`/`submittedAtUtc` is unchanged — the
  caller now always supplies a value via the path above.
- The same treatment applies to `persistFileWithMetadata` / `file_attestation_screen.dart`.

## 7. Submission queue

Local persistence (`sui_submission_status = 'PENDING_SUBMISSION'`) already happens
independently of the chain-submission step.

- `_submitPhotoAttestation`/`_submitFileAttestation`'s failure handling distinguishes a
  network-class failure from a definite rejection, reusing the unified classifier from §5
  (extracted into a small shared helper). A network-class failure leaves the row at
  `PENDING_SUBMISSION`; a definite rejection (bad signature, misconfiguration) is reported
  as it is today.
- `GraniteLakeController` gains `retryPendingAttestations()`, which sweeps
  `PENDING_SUBMISSION` rows oldest-first, sequentially, resubmitting via
  `attest_photo_v2`/`attest_file_v2` with the original `captured_at` preserved (a fresh
  `attested_at` is supplied by the chain wherever the submission lands).
- The sweep runs on two triggers: `ConnectivityHeuristicService` (§5) transitioning to
  `online`, and app foreground/resume via a `WidgetsBindingObserver` registered at the app
  root (`app/lib/app.dart`), so it runs even when the capture screen isn't mounted.

## 8. Local persistence: `is_online`, `is_forced_offline`, and timestamp provenance

**New columns.** Unlike `captured_at`, neither `is_online` nor `is_forced_offline` had a
persistence path in the original design — both need one, for the same reason
`captured_at` does: `retryPendingAttestations()` (§7) must resubmit with the _original_
values, not values recomputed at resubmission time (connectivity may well have changed by
then). Current schema is at `databaseVersion = 9` (`app/lib/core/database/migrations.dart`,
`granite_lake_database_service.dart`); this design adds a version-10 migration:

```sql
ALTER TABLE photo_captures ADD COLUMN is_online INTEGER NOT NULL DEFAULT 1;
ALTER TABLE photo_captures ADD COLUMN is_forced_offline INTEGER NOT NULL DEFAULT 0;
ALTER TABLE uploaded_files ADD COLUMN is_online INTEGER NOT NULL DEFAULT 1;
ALTER TABLE uploaded_files ADD COLUMN is_forced_offline INTEGER NOT NULL DEFAULT 0;
```

following the existing `ALTER TABLE ... ADD COLUMN` pattern used for every prior migration
(e.g. `sui_submission_status` at version 3, `submitted_at` at version 6) and the
existing INTEGER-as-boolean idiom already used for `is_placeholder` on `employeesTable`.
Both are written once at persist time (`persistCaptureWithMetadata`/
`persistFileWithMetadata`, §6) and read back unchanged on every resubmission attempt.

**Narrative provenance.** Alongside the on-chain `captured_at`/`attested_at`, the app also
records locally how the device's own claimed `captured_at` was derived (a fresh live
fetch, a synced offset, or an unsynced device clock) and why the capture went through the
offline path (`auto_offline` vs. `forced_offline` vs. not applicable), folded into the
existing signed `proof_payload_json` blob used by
`granite_lake_capture_workflow_service.dart` — the same mechanism that already carries
`gpsLabel`/`altitudeLabel` — so this part needs no new column, only the two raw booleans
above.

## 9. UI

- Capture screen's app bar carries the "Force Offline Mode" toggle (§4) next to the
  connectivity indicator; connectivity state (now `Connected`/`Degraded`/`Offline`, per
  §5) is shown as an informational banner. When §5 is not `online`, the banner explains
  offline capture is active automatically; when the toggle is on while §5 _is_ `online`,
  it explains the crew is overriding a working connection.
- History screen shows a pending-sync count, from a new `pendingAttestationCount` getter
  on `GraniteLakeController`.
- Capture-detail screen shows the on-chain `captured_at`/`attested_at`/`is_online`/
  `is_forced_offline` alongside the local provenance label, next to the existing
  submission-status detail.

## 10. Files touched

**Contract:** `contracts/sources/granite_lake.move`, `contracts/tests/granite_lake_tests.move`.

**Verification tooling:** `verification_api/src/constants.ts`,
`verification_api/src/services/attestVerification.ts`, `verification_portal`'s equivalent
lookup code.

**New app files:** `app/lib/core/services/time_sync_service.dart`,
`app/lib/core/services/connectivity_heuristic_service.dart` (§5), and a shared
`isTransientNetworkError` helper extracted from `sui_graphql_service.dart` and reused by
`granite_lake_controller.dart`'s verification-retry classifier (§5).

**Modified app files:** `photo_attestation_service.dart`, `capture_screen.dart`
(force-offline toggle UI + shutter/timestamp changes + connectivity-service wiring),
`file_attestation_screen.dart`, `granite_lake_controller.dart`,
`granite_lake_capture_workflow_service.dart`, `config_data_controller.dart` (new config
key: `offlineCaptureForced`, replacing the old `offlineCaptureAllowed`), `migrations.dart`

- `granite_lake_database_service.dart` (version-10 migration: `is_online`/
  `is_forced_offline` columns, §8), `app.dart` (lifecycle observer), `history_screen.dart`,
  `capture_detail_screen.dart`, `app_constants.dart` (connectivity thresholds/cadences),
  `pubspec.yaml` (new `connectivity_plus` dependency).

## 11. Verification / testing

- `sui move test` in `contracts/` for the new entry functions/events.
- `flutter analyze app`; `npm run lint:verification_api` / `npm run lint:verification_portal`.
- After a testnet package upgrade: confirm a historical (V1) attestation and a new V2
  attestation both verify correctly through `verification_api`/`verification_portal`.
- Manual airplane-mode pass: with airplane mode on (toggle off, so offline is purely
  automatic), capture succeeds offline and records `is_online: false`,
  `is_forced_offline: false`; the row appears as `PENDING_SUBMISSION`; reconnecting (via
  timer and via app foreground) triggers submission with the original `captured_at` and a
  fresh `attested_at`; the detail screen and `verification_portal` show matching values.
  Repeat for the file-upload path.
- Manual force-offline pass: with connectivity good (§5 reports `online`) and the toggle
  on, capture still routes through the offline/queued path and records `is_online: true`,
  `is_forced_offline: true`; confirm this is distinguishable in the detail screen and
  `verification_portal` from the airplane-mode case above (§4's table).
- Manual online pass: connectivity good, toggle off — capture behaves as it does today
  (connectivity required, immediate submission), recording `is_online: true`,
  `is_forced_offline: false`.
- `ConnectivityHeuristicService` unit tests: state transitions require consecutive
  confirmations (no single-probe flapping); airplane-mode toggling short-circuits to
  `offline` without a network call; a simulated slow-but-reachable or under-threshold-
  bandwidth backend classifies as `degraded`, not `online`.
- Manual marginal-signal pass (e.g. throttled network via device dev tools or a
  low-signal location): confirm the status label doesn't flap on every 10-30s tick, and
  that the shutter switches to offline-available automatically once §5 leaves `online`
  (no toggle interaction required).

## 12. Open items

1. Confirm the `on_chain` package's constructor for pure `u64`/`bool` transaction
   arguments.
2. Decide whether a `capturedAtMatches` mismatch is surfaced as a hard verification
   failure or an informational note in `verification_portal`.
3. Decide how history UI should present V1 attestations (no `captured_at`/`attested_at`/
   `is_online`/`is_forced_offline`) alongside V2 ones — likely keep the existing time
   display for V1 and show the new fields only where available.
4. Decide the exact icon/state treatment for the app-bar force-offline toggle (e.g.
   distinct icon states for "online, toggle off", "online, toggle on (override)",
   "offline, toggle off (automatic)", "offline, toggle on").
5. Tune the §5 thresholds (consecutive-failure count for `offline`,
   `minimumSufficientBandwidthKbps`, latency threshold for `degraded`, poll cadences)
   against real field data rather than guessing up front — ship with conservative
   defaults and treat them as adjustable constants.
6. Decide whether `degraded` (as opposed to `offline`) should also make offline capture
   available, or whether a crew should still be required to force it with the toggle in
   that middle state — this design currently treats `degraded` the same as `offline` for
   eligibility (§5), which is the more conservative choice for submission reliability but
   means a merely-slow connection also loses the "try online first" behavior.
7. Decide whether the "enable offline capture?" prompt (§5) should be dismissible for the
   rest of the session (to avoid nagging a crew that's deliberately working online-first
   near the edge of coverage) or reappear on every sustained `offline` transition.
   on").
