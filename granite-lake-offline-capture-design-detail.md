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

### 7.1 Signing needs a live biometric session — the queue sweep must account for that

Every existing signing call (`persistCaptureWithMetadata`/`persistFileWithMetadata`,
`granite_lake_controller.dart:617-636,758-778`) reads an in-memory
`SuiED25519PrivateKey? _sessionSigningKey`, populated only by an explicit,
user-initiated `startSession()` biometric prompt (`capture_tab_screen.dart:177`) and
cached for `AppConstants.captureSessionDurationMinutes` (30, `app_constants.dart:18`).
Nothing in the codebase re-prompts biometrics transparently at signing time — if the
cached key is gone, signing fails outright. Two things clear it:

- the 30-minute window elapsing while the app stays running (`_sessionTicker`,
  `granite_lake_controller.dart:1553-1568`), and
- **any process kill and relaunch, unconditionally** — `loadPersistedState()` deletes the
  persisted session record on every cold start regardless of remaining time
  (`granite_lake_secure_state_service.dart:185-188`), so closing the app always requires
  a fresh unlock next time, never a resume.

This means `retryPendingAttestations()` cannot assume it can sign. Its two triggers
(connectivity restored, app foreground/resume) are exactly the cases where a session may
well be gone — a crew reconnecting after being offline for over 30 minutes, or reopening
the app after it was closed, are the normal case here, not an edge case.

**The fix is not to make signing more automatic — biometric unlock is one thing that
already works fully offline** (`_unlockBiometricGate` is a native
`MethodChannel`/Android Keystore call, `granite_lake_secure_state_service.dart:579-593`,
no network involved), so a crew can keep capturing past the 30-minute mark in a dead zone
by simply re-touching the sensor, the same as they would online. The gap is specifically
the _unattended_ resubmission path, which has no human present to authorize a prompt:

- `retryPendingAttestations()` checks `hasActiveSession && _sessionSigningKey != null`
  before touching anything. If false, it does nothing — no row is retried, none is marked
  `FAILED_SUBMISSION`, `sui_error_message` is left untouched. A missing signing key is not
  a network-class or rejection failure; treating it as either would misfile it in §5's
  unified classifier and could surface a misleading "failed" state for a capture that
  simply hasn't had a human unlock it yet.
- `GraniteLakeController` gains a `pendingAttestationsNeedUnlock` getter (alongside the
  existing `pendingAttestationCount`, §9): true when there are `PENDING_SUBMISSION` rows
  and no active session. The history screen (and an app-bar affordance, §9) surfaces this
  as an explicit "N captures ready to submit — unlock to continue" call to action that
  calls `controller.startSession()` — the _same_ call site already wired to the existing
  "Start Capture" button (`capture_tab_screen.dart:177`), not a new biometric-prompt code
  path. The app never pops a biometric prompt on its own from a background trigger.
- `startSession()` gains a third trigger for `retryPendingAttestations()`: on success,
  regardless of which UI entry point called it (starting a capture session, or this new
  unlock-to-submit prompt), the sweep runs immediately. One unlock clears the whole queue
  without a separate step.

This is unrelated to §5/connectivity — a fully `online` device with an expired session
hits the same gate, and is handled the same way.

### 7.2 Notifying when connectivity returns, even if the app isn't open

§7.1's "unlock to submit" CTA only helps if the crew has the app open to see it. A crew
that backgrounds or closes the app while waiting to reconnect — the realistic case, e.g.
driving back toward town with the phone away — won't see it until they happen to reopen
the app themselves. A local (device, not push/server) notification fired the moment
connectivity actually returns closes that gap.

**Why this can't just piggyback on §5's poll timer.** `ConnectivityHeuristicService`'s
`Timer.periodic` only runs while the Flutter engine is alive; Android suspends or kills a
backgrounded engine after some time (Doze, OEM background-kill policies vary but are
typically minutes, not hours). A crew with the app backgrounded for the drive back would
get nothing from it — there'd be no running timer left to notice reconnection at all, so
there's nothing to hang a notification off.

**Design:** use `workmanager` (new dependency) instead of the in-app timer for this one
purpose. Register a one-off task with a `NetworkType.connected` constraint whenever
`PENDING_SUBMISSION` rows exist (right after a capture that couldn't submit immediately,
§6/§7); re-register after each time it fires, for as long as the queue stays non-empty.
This is backed by Android's `JobScheduler` — a system service that wakes a background
task specifically when the network constraint is met, independent of whether the app
process is alive, which is the actual guarantee needed here.

- The background task runs in its own minimal Dart isolate (`workmanager`'s callback
  dispatcher) with its own connection to the same sqflite database file — it is **not**
  the same isolate as the running `GraniteLakeController`, and critically has **no access
  to the decrypted signing key**, which only ever exists in the foreground app's memory
  immediately after a biometric prompt (§7.1). So this task's job is strictly
  check-and-notify, never sign-and-submit — it queries `PENDING_SUBMISSION` count and, if
  non-zero, shows a local notification (`flutter_local_notifications`, new dependency):
  "N captures ready to submit." It never attempts a resubmission itself, by construction,
  not just by choice — keeping decrypted key material confined to the interactive
  foreground session is a property worth preserving, not just an implementation detail.
- Tapping the notification deep-links to the history screen's unlock-to-submit CTA
  (§7.1/§9) — the same flow as opening the app normally, not a separate path.
- Debounced: track the pending count (or newest `captured_at`) at the last notification
  shown (a config key, same mechanism as §3/§4); re-notify only if the pending set changed
  since then. Otherwise a marginal-signal area reconnecting and dropping repeatedly would
  refire the same notification every time, which trains crews to ignore it.
- The task is cancelled once the queue drains to zero (all rows submitted) — no reason to
  keep waking a background job to report nothing.
- Runtime `POST_NOTIFICATIONS` permission (required on Android 13+) is requested the first
  time a capture actually lands in the offline queue, not upfront during onboarding, so
  the ask is contextual rather than a blanket permission grab.

This is additive to, not a replacement for, §7.1's in-app CTA and the existing
foreground/reconnect sweep (§7) — when the app _is_ open, those still fire without
waiting on a background task or a tap on a notification. They no longer complete
silently even with a live signing session, though: §7.3's decrypt-key biometric check has
no cache, so every sweep — session live or not — now raises a prompt before it can
resubmit anything.

Android-only for the same reason the rest of this design is (§5): no `ios/` platform
target exists in this project today. Flagging for the record since it's more pointed here
— iOS's background execution model (`BGTaskScheduler`) has no equivalent reliable
"network became available" wake trigger, so this specific mechanism would need real
rework, not just a platform-channel swap, if iOS support is ever added (§12).

### 7.3 At-rest encryption of queued captures (tamper protection)

**Threat.** A row in `PENDING_SUBMISSION` (§7) can sit on the device anywhere from
seconds to the length of a whole field trip before connectivity returns. Absent this
section, the fields that go on-chain unchanged at resubmission — `photo_hash`, `gps`,
`altitude`, `captured_at`, `is_online`, `is_forced_offline` (§8) — sit in the
`photo_captures`/`uploaded_files` tables in plaintext for that entire window. Anyone with
access to the device's storage during that window (root, a compromised app with storage
access, an ADB/backup extraction, or physical tampering) can edit those column values
directly; `retryPendingAttestations()` reads whatever is in the row at resubmission time
and signs it faithfully. The on-chain signature proves "this device's key signed X," not
"X is what the camera actually captured" — closing that gap is the point of this section.

**Design: encrypt instantly, decrypt only with a fresh, uncached biometric check.** New
file `app/lib/core/services/capture_encryption_service.dart` implements a hybrid
encrypt-now/decrypt-with-biometrics scheme, chosen specifically so capture (§6) never
blocks on a biometric prompt while resubmission (§7) always does:

- **Keystore keypair.** On first use, an RSA-2048 keypair is generated in the Android
  Keystore (alias `granite_lake_capture_wrap_key`, `PURPOSE_ENCRYPT | PURPOSE_DECRYPT`,
  OAEP padding) via a small native `MethodChannel`, the same pattern already used for the
  existing biometric gate (`granite_lake_secure_state_service.dart:579-593`). Only the
  private (decrypt/unwrap) half is created with `setUserAuthenticationRequired(true)`
  and, deliberately, no `setUserAuthenticationValidityDurationSeconds` — every use of the
  private key demands its own fresh `BiometricPrompt`/`CryptoObject` authentication, with
  no caching window. The public (encrypt/wrap) half needs no authentication, which is
  what keeps capture instant.
- **Encrypt at persist time, not later.** `persistCaptureWithMetadata`/
  `persistFileWithMetadata` (§6), for a row taking the offline/queued path only (§4:
  auto-offline or forced-offline — a row that submits immediately while online doesn't
  sit at rest long enough to matter), generate a fresh random AES-256 key and 12-byte IV
  per row, AES/GCM/NoPadding-encrypt the JSON-serialized submission payload
  (`photo_hash`/`gps`/`altitude`/`captured_at`/`is_online`/`is_forced_offline`), then wrap
  the AES key with the Keystore public key (`Cipher.WRAP_MODE` — a public-key operation,
  no prompt). This happens synchronously in the same write §6 already does, so there is no
  window where the row exists on disk unencrypted.
- **Decrypt at resubmission, with a prompt every time.** `retryPendingAttestations()`
  (§7) unwraps each row's AES key via the Keystore private key before it has a
  submittable payload to sign. Because that key requires authentication with no validity
  window, this always raises a biometric prompt — including when the existing 30-minute
  `_sessionSigningKey` (§7.1) is still live. This is the "for sure" biometric check: it
  exists specifically so reconnection can never resubmit queued data on the strength of
  an old cached session alone, only on a check performed at that moment. Where possible
  this is combined with the existing signing-key unlock into a single flow — one
  `startSession()` call unlocking both the AES-unwrap key and, if needed, the Sui signing
  key — rather than two separate sensor touches.
- **The two reconnect cases, walked through.** §7's triggers (connectivity restored,
  app foreground/resume) now always land on one of two outcomes, never a silent
  resubmission:

  | Time since last unlock                  | Signing key (§7.1)                    | Decrypt key (this section)          | What happens on reconnect                                                                                                                                        |
  | --------------------------------------- | ------------------------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | < 30 min, session still live            | Cached — no prompt needed for signing | Never cached — always needs a check | A biometric prompt is still raised, for the decrypt/unwrap step alone; the cached signing key is then reused to sign once decryption succeeds.                   |
  | ≥ 30 min elapsed, or app was relaunched | Cleared — needs `startSession()`      | Also needs a fresh check            | `pendingAttestationsNeedUnlock` (§7.1) surfaces the CTA; tapping it raises one combined prompt that both re-derives the signing key and unwraps the decrypt key. |

  Before this section, the left column alone decided whether a reconnect was silent; now
  the right column means it never is, for a queued row, regardless of session state. This
  is a real behavior change from the original design's framing of resubmission as
  happening automatically "unchanged" once connectivity is available (top-level doc §2) —
  that's still true for a capture that submits immediately while online (never queued,
  never encrypted), but no longer true for anything that spent time in
  `PENDING_SUBMISSION`.

- **This is also why §7.2's background task stays check-and-notify, for a second,
  independent reason.** §7.2 already keeps the `workmanager` isolate from signing because
  it has no access to the decrypted Sui key, which only ever lives in the foreground
  app's memory. This section adds a reason that would hold even without that isolation:
  the decrypt key itself demands an interactive, uncached biometric prompt, and a
  background isolate has no UI surface to raise one. So a fully headless resubmission was
  never reachable once this section exists, independent of the memory-isolation argument.
  The worker's job is unchanged from §7.2: detect reconnection and notify, registered only
  while `PENDING_SUBMISSION` rows exist and cancelled once the queue drains — an on-demand
  job tied to queue state, not a permanently-running poller.
- **Tamper is a decrypt failure, not a silent success.** AES-GCM's authentication tag
  covers the ciphertext, so any on-disk edit to `encrypted_payload` after capture — a
  direct SQL edit, a restored/replayed row, a corrupted byte — makes the tag check fail on
  decrypt. `retryPendingAttestations()` treats that failure as a new terminal state,
  `TAMPER_DETECTED`, distinct from `FAILED_SUBMISSION` (§7, which today means the chain
  rejected the transaction) and from the no-active-session no-op (§7.1, which means
  nothing has been attempted yet) — a row that fails to decrypt has definitely been
  altered since capture, a materially different fact from either of those.
- **Key lifetime.** The keypair is long-lived (survives relaunch, unlike the 30-min
  signing session) and is not backed up or exportable — an app uninstall, device wipe, or
  factory reset before a queued row is submitted makes that row permanently
  undecryptable, the same failure mode as losing the device itself. Acceptable under the
  company-managed-device threat model §3 already assumes, but worth surfacing to crews: a
  queued-but-not-yet-submitted capture isn't safe against an uninstall.

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

**Version-11 migration (§7.3): encrypted queued payload.**

```sql
ALTER TABLE photo_captures ADD COLUMN encrypted_payload BLOB;
ALTER TABLE photo_captures ADD COLUMN payload_iv BLOB;
ALTER TABLE photo_captures ADD COLUMN wrapped_data_key BLOB;
ALTER TABLE uploaded_files ADD COLUMN encrypted_payload BLOB;
ALTER TABLE uploaded_files ADD COLUMN payload_iv BLOB;
ALTER TABLE uploaded_files ADD COLUMN wrapped_data_key BLOB;
```

For a row taking the offline/queued path (§4/§7.3), `photo_hash`/`gps`/`altitude`/
`captured_at`/`is_online`/`is_forced_offline` are no longer also written in plaintext —
`encrypted_payload` (AES-GCM ciphertext plus tag), `payload_iv`, and `wrapped_data_key`
are the only copies on disk, and the plaintext columns are read back only after a
successful biometric-gated decrypt at resubmission time (§7.3). Rows that submit
immediately while online, and existing pre-migration rows, keep using the plaintext
columns directly, so this is additive rather than a hard schema cutover — reads branch on
whether `encrypted_payload` is `NULL`.

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
  on `GraniteLakeController`. When `pendingAttestationsNeedUnlock` (§7.1) is also true, the
  count becomes an explicit "N ready to submit — unlock to continue" action that calls
  `startSession()`, rather than a passive number. A row in `TAMPER_DETECTED` (§7.3) is
  shown separately from both the pending count and `FAILED_SUBMISSION`, since it means the
  locally stored data itself failed its integrity check, not that the chain rejected
  anything or that a human hasn't unlocked yet.
- Capture-detail screen shows the on-chain `captured_at`/`attested_at`/`is_online`/
  `is_forced_offline` alongside the local provenance label, next to the existing
  submission-status detail.

## 10. Files touched

**Contract:** `contracts/sources/granite_lake.move`, `contracts/tests/granite_lake_tests.move`.

**Verification tooling:** `verification_api/src/constants.ts`,
`verification_api/src/services/attestVerification.ts`, `verification_portal`'s equivalent
lookup code.

**New app files:** `app/lib/core/services/time_sync_service.dart`,
`app/lib/core/services/connectivity_heuristic_service.dart` (§5),
`app/lib/core/services/reconnect_notification_service.dart` (§7.2: `workmanager`
registration/cancellation, the background callback dispatcher, and the
`flutter_local_notifications` wrapper), `app/lib/core/services/capture_encryption_service.dart`
(§7.3: Keystore keypair generation, encrypt-on-write, biometric-gated decrypt-on-resubmit),
and a shared `isTransientNetworkError` helper extracted from `sui_graphql_service.dart` and
reused by `granite_lake_controller.dart`'s verification-retry classifier (§5).

**Modified app files:** `photo_attestation_service.dart`, `capture_screen.dart`
(force-offline toggle UI + shutter/timestamp changes + connectivity-service wiring),
`file_attestation_screen.dart`, `granite_lake_controller.dart` (`retryPendingAttestations()`,
`pendingAttestationsNeedUnlock`, §7.1; registers/cancels the §7.2 background task as the
pending queue changes; §7.3's decrypt-and-verify step and `TAMPER_DETECTED` handling),
`granite_lake_capture_workflow_service.dart` (encrypt-on-write call for the offline/queued
path, §7.3), `granite_lake_secure_state_service.dart` (Keystore-backed
`capture_encryption_service.dart` reuses the existing native biometric-gate
`MethodChannel`, §7.3), `config_data_controller.dart` (new config keys:
`offlineCaptureForced` replacing the old `offlineCaptureAllowed`, and the §7.2
last-notified pending count), `migrations.dart` + `granite_lake_database_service.dart`
(version-10 migration: `is_online`/`is_forced_offline` columns, §8; version-11 migration:
`encrypted_payload`/`payload_iv`/`wrapped_data_key` columns, §7.3/§8), `app.dart`
(lifecycle observer), `capture_tab_screen.dart` (retry-on-unlock wiring, §7.1, combined
with the §7.3 decrypt-key unlock), `history_screen.dart` (unlock-to-submit CTA, §9;
`TAMPER_DETECTED` state, §7.3/§9), `capture_detail_screen.dart`, `app_constants.dart`
(connectivity thresholds/cadences), `AndroidManifest.xml` (`POST_NOTIFICATIONS`
permission, §7.2), `pubspec.yaml` (new `connectivity_plus`, `workmanager`,
`flutter_local_notifications` dependencies).

## 11. Verification / testing

- `sui move test` in `contracts/` for the new entry functions/events.
- `flutter analyze app`; `npm run lint:verification_api` / `npm run lint:verification_portal`.
- After a testnet package upgrade: confirm a historical (V1) attestation and a new V2
  attestation both verify correctly through `verification_api`/`verification_portal`.
- Manual airplane-mode pass: with airplane mode on (toggle off, so offline is purely
  automatic) and an active biometric session, capture succeeds offline and records
  `is_online: false`, `is_forced_offline: false`; the row appears as
  `PENDING_SUBMISSION`; reconnecting (via timer and via app foreground) triggers
  submission with the original `captured_at` and a fresh `attested_at`; the detail screen
  and `verification_portal` show matching values. Repeat for the file-upload path.
- Manual expired-session pass (§7.1): capture offline, then let the 30-minute session
  expire (or kill and relaunch the app) before reconnecting. Confirm reconnecting does
  _not_ attempt a submission, does _not_ mark the row `FAILED_SUBMISSION`, and that
  `pendingAttestationsNeedUnlock` surfaces the unlock CTA; confirm tapping it (one
  biometric prompt) submits all queued rows immediately. Also confirm capturing a _new_
  photo after the session has expired, while still offline, only requires re-touching the
  sensor — no connectivity needed to keep capturing.
- Manual force-offline pass: with connectivity good (§5 reports `online`) and the toggle
  on, capture still routes through the offline/queued path and records `is_online: true`,
  `is_forced_offline: true`; confirm this is distinguishable in the detail screen and
  `verification_portal` from the airplane-mode case above (§4's table).
- Manual online pass: connectivity good, toggle off — capture behaves as it does today
  (connectivity required, immediate submission), recording `is_online: true`,
  `is_forced_offline: false`.
- Manual tamper pass (§7.3): capture offline so a row lands in `PENDING_SUBMISSION` with
  an encrypted payload, then directly edit `encrypted_payload` (or `payload_iv`) via
  sqlite outside the app. Reconnect and confirm `retryPendingAttestations()` marks the row
  `TAMPER_DETECTED` rather than resubmitting it or marking it `FAILED_SUBMISSION`, and
  that the history/detail screens (§9) surface this distinctly.
- Manual "for sure" biometric pass (§7.3): capture offline, then — while the 30-minute
  `_sessionSigningKey` (§7.1) is still live — reconnect. Confirm a biometric prompt is
  still raised before resubmission (for the decrypt-key unwrap), rather than the existing
  signing session alone being enough to auto-submit.
- `ConnectivityHeuristicService` unit tests: state transitions require consecutive
  confirmations (no single-probe flapping); airplane-mode toggling short-circuits to
  `offline` without a network call; a simulated slow-but-reachable or under-threshold-
  bandwidth backend classifies as `degraded`, not `online`.
- Manual marginal-signal pass (e.g. throttled network via device dev tools or a
  low-signal location): confirm the status label doesn't flap on every 10-30s tick, and
  that the shutter switches to offline-available automatically once §5 leaves `online`
  (no toggle interaction required).
- Manual background-reconnect pass (§7.2): capture offline, force-stop or background the
  app (not just navigate away — actually leave it backgrounded long enough that Android
  would suspend a plain in-app timer), then restore connectivity at the OS level.
  Confirm the notification appears without the app having been reopened, and that tapping
  it lands on the unlock-to-submit CTA. Separately, confirm reconnecting twice in a row
  without submitting doesn't produce two notifications (debounce), and that a new capture
  added to the queue after the first notification does produce a fresh one.
- Confirm the §7.2 background task never has access to signing material: with
  `flutter_local_notifications`/`workmanager` mocked or logged, assert the background
  isolate's code path never touches `_sessionSigningKey` or the biometric-gate channel —
  only a read-only query against the pending count.

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
7. Decide whether §5's automatic online/offline banner copy should be dismissible or
   persistent while `degraded`/`offline` holds, so it informs without nagging a crew
   that's deliberately working near the edge of coverage.
8. §7.2's background reconnect task rides on Android `JobScheduler` via `workmanager`,
   which some OEMs (Xiaomi, Huawei, and others with aggressive custom battery-management)
   restrict or delay beyond stock Android's Doze behavior. The in-app §7.1 CTA is the
   guaranteed fallback — the notification is a best-effort improvement on top of it, not
   a dependency — but worth field-testing on the specific device models crews are issued.
9. Decide the exact timing/copy for the `POST_NOTIFICATIONS` permission request (§7.2) —
   at first offline capture, as designed, or bundled into the biometric-binding onboarding
   flow (`biometric_setup_screen.dart`) where the crew is already granting permissions.
10. Decide `setInvalidatedByBiometricEnrollment` for the §7.3 Keystore keypair. Android's
    default (`true`) invalidates the private key the moment any new fingerprint/face is
    enrolled on the device, which is desirable against an attacker enrolling their own
    biometric to gain access to queued data, but also means a legitimate crew member
    re-enrolling their own print (lost finger access, new phone policy, etc.) permanently
    loses any not-yet-submitted queue. This needs an explicit decision, not the platform
    default by accident.
11. Decide whether the §7.3 Keystore keypair should require `setIsStrongBoxBacked(true)`
    (dedicated secure-element storage) where the device supports it, versus falling back
    to TEE-only storage silently — depends on the hardware profile of the devices crews
    are actually issued.
12. Decide the exact `TAMPER_DETECTED` (§7.3/§9) UX: block that row from resubmission
    permanently pending admin/support review, or let the crew discard it and re-capture in
    place. Also decide whether a `TAMPER_DETECTED` row should be reported anywhere beyond
    the device itself (e.g. a local-only audit note), given the whole point is that it
    can no longer be trusted enough to submit on-chain.
13. Decide whether the narrative-provenance fields folded into `proof_payload_json` (§8) —
    display text like the capture-timestamp-source label — need the same §7.3 at-rest
    protection as the raw `is_online`/`is_forced_offline`/`captured_at` values, or whether
    being informational-only (not read back into the on-chain submission) is enough to
    leave them out of the encrypted payload for now.
