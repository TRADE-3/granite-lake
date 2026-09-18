# Granite Lake — Offline Capture & On-Chain Timestamp Design (Detail)

**Author:** Nethmi Jayakody
**Status:** Implemented (contract deployed, app/verification tooling shipped) — remaining open decisions tracked in §12
**Related:** [granite-lake-offline-capture-design.md](./granite-lake-offline-capture-design.md)

This is the in-depth companion to the high-level design doc. Each section below maps to
a row in that doc's summary table.

## 1. Contract change: `captured_at` / `attested_at` / connectivity & GPS provenance

This is trade3's own contract with nothing deployed yet, so there is no legacy on-chain
event shape to preserve. `PhotoAttested`/`FileAttested` and `attest_photo`/`attest_file`
are modified **in place** — no versioned event scheme (`V2`), no upgrade path, no
`GRANITE_LAKE_ORIGINAL_PACKAGE_ID`-style dual-address tracking. Existing callers are
simply recompiled against the new signatures.

Internet and GPS are each independently optional at capture time. Neither is allowed to
be null silently: whenever one is, the crew must supply a reason, which is hashed
(same convention as `photo_hash`) and stored on-chain as `internet_null_reason_hash` /
`gps_null_reason_hash` — the plaintext reason itself stays in local app storage (§8), not
on a public ledger. GPS fields only apply to `PhotoAttested`; file attestation never
carried location data.

`contracts/sources/granite_lake.move` (implemented — see the actual file for the current
state):

```move
use sui::clock::{Self, Clock};

public struct PhotoAttested has copy, drop {
    photo_hash: vector<u8>,
    gps: vector<u8>,
    altitude: vector<u8>,
    project_id: vector<u8>,
    user_wallet: address,
    domain: vector<u8>,
    captured_at: u64,               // client-supplied, ms since epoch
    attested_at: u64,               // clock::timestamp_ms(clock) at execution — chain-derived
    is_online: bool,                // client-supplied — whether §5's check found the device online-capable at capture time
    is_forced_offline: bool,        // client-supplied — raw state of the §4 "Force Offline Mode" toggle at capture time
    internet_null_reason_hash: vector<u8>, // hash of the mandatory reason; empty when is_online == true
    has_gps: bool,                  // client-supplied — whether a real GPS fix was used for this capture
    is_gps_forced_null: bool,       // client-supplied — raw state of the §4a "Force No GPS" toggle at capture time
    gps_null_reason_hash: vector<u8>, // hash of the mandatory reason; empty when has_gps == true
}
// FileAttested mirrors this with file_hash/file_id in place of photo_hash/gps/altitude,
// and carries captured_at/attested_at/is_online/is_forced_offline/
// internet_null_reason_hash only — no GPS-related fields.

public entry fun attest_photo(
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
    // same auth checks as before
    let attested_at = clock::timestamp_ms(clock);
    event::emit(PhotoAttested { photo_hash: hash, gps, altitude, project_id,
        user_wallet: sender, domain: user_cap.domain, captured_at, attested_at, is_online,
        is_forced_offline });
}
// attest_file mirrors this
```

`attest_photo`'s full parameter list is therefore: `user_cap, registry, hash, gps,
altitude, project_id, captured_at, is_online, is_forced_offline,
internet_null_reason_hash, has_gps, is_gps_forced_null, gps_null_reason_hash, clock,
ctx`; `attest_file` mirrors this without the three GPS-specific params.

**The contract enforces the mandatory-reason invariant on-chain**, not just client-side:
`attest_photo` asserts `internet_null_reason_hash.is_empty() == (is_online &&
!is_forced_offline)` (new error `E_INTERNET_NULL_REASON_MISMATCH`) and
`gps_null_reason_hash.is_empty() == (has_gps && !is_gps_forced_null)` (new error
`E_GPS_NULL_REASON_MISMATCH`); `attest_file` asserts only the first. Each is a single
bidirectional equality check — a reason hash must be non-empty in every state except the
one unambiguous "present, not overridden" case (see §4/§4a's truth tables — a reason is
required not only when the field is genuinely null, but also whenever the crew overrode an
available one via its force toggle) — so a malformed transaction (a reason supplied when
not needed, or omitted when required) is rejected before it can land on-chain, rather than
only being caught after the fact client-side (§6) or during verification (§2). `is_online`/
`is_forced_offline` and `has_gps`/`is_gps_forced_null` themselves remain unvalidated
pass-through values, same as before — only the reason-hash/field-state relationship is
checked.

`sui::clock` is already a framework dependency (present under
`contracts/build/granite_lake/sources/dependencies/Sui/clock.move`), so no new package
dependency is needed.

**Tests:** `contracts/tests/granite_lake_tests.move` covers `captured_at`/`attested_at`/
`is_online`/`is_forced_offline`/`internet_null_reason_hash`/`has_gps`/
`is_gps_forced_null`/`gps_null_reason_hash` (a clock is constructed via
`sui::clock::create_for_testing` in every test that calls `attest_photo`/`attest_file`).
`test_attest_photo_records_online_and_forced_offline_combinations` exercises all four
`is_online`/`is_forced_offline` combinations from §4's truth table (with a reason hash
supplied for every state that now requires one), and an equivalent test exercises the
four `has_gps`/`is_gps_forced_null` combinations from §4a's truth table. Eight tests
confirm the on-chain reason-hash enforcement directly: rejecting a reason hash in the one
no-reason-needed state per axis, rejecting a missing reason in every other state per axis
(including the "field present but overridden" case), and accepting a correctly-supplied
reason in the overridden-but-present case —
`test_attest_photo_rejects_reason_hash_when_online_and_not_forced`,
`test_attest_photo_rejects_missing_reason_hash_when_offline`,
`test_attest_photo_rejects_missing_reason_hash_when_forced_offline_despite_online`,
`test_attest_photo_requires_reason_hash_when_forced_offline_despite_online`,
`test_attest_photo_rejects_reason_hash_when_gps_available_and_not_overridden`,
`test_attest_photo_rejects_missing_reason_hash_when_gps_unavailable`,
`test_attest_photo_requires_reason_hash_when_gps_forced_null_despite_fix`,
`test_attest_file_rejects_reason_hash_mismatch`. 26/26 tests passing.

**Deployment:** a fresh `sui client publish` (or `sui client upgrade` if something has
already been deployed by the time this ships) — no compatibility constraint with prior
events since none exist yet. After deployment:

- `verification_api`/`verification_portal`: set `GRANITE_LAKE_PACKAGE_ID` to the deployed
  address.
- App: update `defaultPhotoAttestationPackageId` in `app_constants.dart`;
  `defaultPhotoAttestationRegistryId` is unchanged.

## 2. Verification updates

**`verification_api`** (`src/constants.ts`, `src/services/attestVerification.ts`): the
existing `PHOTO_ATTESTED_EVENT_TYPES`/`FILE_ATTESTED_EVENT_TYPES` constants are unchanged
(no new event-type arrays needed, since the event is modified in place, not versioned).
`captured_at`/`attested_at` are decoded as plain `u64`s and `is_online`/`is_forced_offline`/
`has_gps`/`is_gps_forced_null` as plain `bool`s (unlike the vector-decoded `gps`/
`project_id` fields); `internet_null_reason_hash`/`gps_null_reason_hash` are decoded as
32-byte hashes using the same `decodePhotoHash`-style path already used for `photo_hash`.

**Reason-hash checking is its own endpoint, deliberately separate from
`/verify-attestation`.** `POST /verify-null-reason` (`src/routes/verifyNullReason.ts`)
takes `{ reasonText, onChainHashHex }` and returns `{ matches }`, hashing with the same
SHA-256 convention `verifyAttestation.ts` already uses for uploaded files. This is the
mechanism by which "checking all of them during verification" (top-level design doc §2)
is actually performed, since the reason text itself is never on-chain. It is kept apart
from the photo/file upload flow rather than added as extra multipart fields there: the
upload in `/verify-attestation` is always compulsory, while a reason disclosure is
optional, arrives independently (often after the fact, from whoever the attester told),
and is checked against a hash the caller already has from an `AttestationRecord` — folding
it into the upload endpoint would tie two unrelated concerns to the same request.

**`verification_portal`** mirrors the decode logic and displays the timestamps and
connectivity/GPS badges reflecting §4/§4a's tables in the result panel. The reason check
itself is **not** a separate tab or an upload-time field — it's a foldable (`<details>`)
control inline next to each Connectivity/GPS Provenance card, shown only once a record is
already loaded and only when that record's `*_null_reason_hash` is non-empty: paste a
disclosed reason, it hashes client-side (Web Crypto `SHA-256`, same as `sha256File` already
uses) and reports match/mismatch against the record's own hash — no network round-trip
needed since the portal already has everything it needs once a record is resolved.

**App side** (`app/lib/core/services/photo_attestation_service.dart`):

- `attestPhoto`/`attestFile` pass `captured_at` as a `u64` pure transaction argument via
  `SuiCallArgPure.u64(BigInt)` and `is_online`/`is_forced_offline`/`has_gps`/
  `is_gps_forced_null` each as a `bool` pure argument via `SuiCallArgPure.boolean(bool)`
  — both constructors confirmed present in the locked `on_chain 8.1.0` package (the
  codebase's existing pure-arg usage was all `.bytes()` before this). Reason hashes
  (`internet_null_reason_hash`/`gps_null_reason_hash`) are passed as `vector<u8>` pure
  args via the existing `.bytes()` constructor, same as `photo_hash`. The shared `Clock`
  object (well-known id `0x6`) is passed as an object argument. The existing
  `_loadRegistryObjectArg` helper (which already builds a `SuiObjectArgSharedObject` for
  the registry) generalizes into `_loadSharedObjectArg(graphqlUrl, objectId)`, reused for
  both the registry and the clock.
- `verifyPhotoAttestation`: `captured_at`/`attested_at`/`is_online`/`is_forced_offline`/
  `has_gps`/`is_gps_forced_null`/`internet_null_reason_hash`/`gps_null_reason_hash` are
  decoded directly from the event and `attested_at` is used as `chainTimestamp`. A
  `capturedAtMatches` check compares on-chain `captured_at` against the locally stored
  value, and `timestampWithinTolerance` becomes `attested_at - captured_at <=
AppConstants.maximumAttestationTimeGapMinutes`, computed from two on-chain values. A
  new check compares the locally stored plaintext reason's hash (computed the same way as
  at capture time) against the on-chain `*_null_reason_hash` whenever one is expected
  (field `false`, or field `true` with its force toggle on), surfacing a mismatch the
  same way `capturedAtMatches` does.

## 3. `TimeSyncService`

New file: `app/lib/core/services/time_sync_service.dart`, wrapping the
[`trusted_time`](https://pub.dev/packages/trusted_time) package rather than a bespoke
wall-clock-offset implementation.

**Scope: offline fallback only, never the online source of truth.** `TimeSyncService.nowUtc()`
is consulted **only** on the path where a live `/utc` fetch is unavailable or failed
(§6's `_fetchBackendUtcTimestamp()` fallback). Whenever the device is online, the existing
live-fetch call remains the sole source for `captured_at`/`submittedAtUtc` — `nowUtc()` is
never called, and its result never overrides a successful live fetch, even opportunistically.
`trusted_time`'s own background syncing (`ensureFreshSync()`, its 30-min `refreshInterval`)
runs independently of this — it exists purely to keep the trust anchor warm for whenever
offline capture _does_ need it later, not to supply a timestamp while already online.

**Why `trusted_time` instead of a bespoke offset.** A simple `deviceNow + lastSyncedOffset`
scheme (the original draft of this section) is defeated by a user manually changing the
system clock while offline — the correction is built on top of `DateTime.now()`, so if
that itself is tampered with after the last sync, the "corrected" time is just as wrong.
`trusted_time` avoids this by anchoring its sync to `SystemClock.elapsedRealtime()` —
Android's hardware monotonic clock, driven by ticks since boot, which manually changing
Settings → Date & Time does not affect. It syncs to a trusted network time source while
online, then derives `now()` offline from elapsed hardware ticks since that sync rather
than from the device's wall clock at all, and it detects tampering/reboots automatically.
Its own listed properties: offline-safe after first sync, persists across app restarts,
detects manual clock/timezone changes, and resyncs automatically after a detected reboot
(`elapsedRealtime()` resets on reboot, which is the one event that invalidates the anchor).

Actual API confirmed by reading the installed `trusted_time` 2.0.2 source (not just its
package description): synchronization is **not** fed by the app's own backend — the
package syncs independently against its own configured NTP/HTTPS/NTS sources
(`pool.ntp.org`, `time.google.com`, `google.com`, `cloudflare.com`, etc. by default) via a
global `TrustedTime.initialize()` called once at app startup, plus periodic
`refreshInterval` (30 min default) and manual `TrustedTime.forceResync()`. There is no
`recordServerTime`-shaped hook to feed it our own `/utc` response.

- `Future<void> ensureFreshSync()` — calls `TrustedTime.forceResync()` opportunistically
  whenever the app already knows it has connectivity (the capture screen's existing
  connectivity-check timer, `ConnectivityHeuristicService` transitioning to `online`),
  rather than waiting on the package's own 30-minute foreground `refreshInterval`. This
  replaces the originally-planned `recordServerTime(DateTime)` shape — `trusted_time`
  doesn't accept an externally-supplied timestamp, it re-runs its own consensus.
- `DateTime nowUtc()` — synchronous, three-tier fallback:
  1. `TrustedTime.now()` when `TrustedTime.isTrusted` — the primary, fully-anchored path.
  2. `TrustedTime.nowEstimated()` when tier 1 throws `TrustedTimeNotReadyException` (not
     yet trusted) — still computed from "elapsed hardware-anchored time since the last
     verified sync," i.e. still monotonic-anchored, not a live wall-clock read; degrades
     gracefully rather than being simply unavailable (`TrustedTimeEstimate.confidence`
     decays from `1.0` fresh to `~0.5` at ~36h since sync to `0.0` stale/invalidated,
     per the package's own documented model). Returns `null` when there's truly nothing
     to extrapolate from (typically: a reboot invalidated the anchor and no resync has
     landed yet, since `elapsedRealtime()` — and therefore the extrapolation baseline —
     resets on reboot).
  3. **Fallback, accepted as an interim gap for now**: only when tier 2 also returns
     `null` — `nowUtc()` falls back to the device's raw, uncorrected wall clock
     (`DateTime.now()`). This is the only tier that reintroduces the clock-tampering
     exposure discussed above, and it's narrower than originally scoped (§12 item 18) now
     that tier 2 covers the "stale but not reboot-invalidated" case gracefully — tier 3 is
     reached only by a reboot-while-offline with no possible resync since.
- `TimeProvenance get provenance` → `fresh | stale | neverSynced` (finalized as the
  originally-scoped 3-state enum — nothing downstream branches on finer granularity, it's
  informational/display-only per §8, so a 4th `degraded` value would be unused complexity),
  derived from which tier answered the last `nowUtc()` call: tier 1 → `fresh`; tier 2 (any
  confidence, including a low-but-non-null `TrustedTimeEstimate`) → `stale`; tier 3 →
  `neverSynced`, regardless of what the device's own clock claims, since `trusted_time`
  could not vouch for it.
- **Boot safety, verified against the actual source, not assumed**: `TrustedTime.initialize()`
  calls `_bootstrap()` → `_performSync()` → `_syncEngine.sync()` on a fresh install (no
  persisted anchor), which **throws `TrustedTimeSyncException`** if it can't reach quorum —
  i.e. a device with zero connectivity on first cold launch makes `initialize()` throw, not
  just return with `isTrusted: false`. Since the entire point of this feature is supporting
  offline field use, an uncaught throw here would crash app startup for exactly the
  scenario the feature exists for. `TimeSyncService.initializeAtStartup()` must wrap the
  call in try/catch (and a defensive timeout, since the exact worst-case duration across
  `_syncEngine`'s retry/backoff logic wasn't fully traced) so a failed/slow first sync
  never blocks or crashes app boot — `nowUtc()`'s tier 3 fallback covers this state
  correctly regardless.
- `trusted_time` persists its own trust anchor state (`TrustedTimeConfig.persistState`,
  `true` by default) — no separate `ConfigDao`/`ConfigDataController` key is needed for
  the sync data itself. `TimeSyncService` remains the app's only call site for
  `nowUtc()`/`ensureFreshSync()` so the rest of the app never imports `trusted_time`
  directly, keeping the dependency swappable later.
- `TrustedTime.initialize()` must be awaited once at app startup (`main.dart`, before
  `runApp`) — it restores the persisted anchor and kicks off the initial sync. Default
  `TrustedTimeConfig` sources are all public internet endpoints (NTP/HTTPS/NTS), so a
  device restricted to only this app's own backend (no general internet reachability)
  would never establish trust under the default config — not expected to matter for a
  normal cellular/Wi-Fi field device, but worth confirming against the actual network
  policy on issued devices; `additionalSources`/a custom `TimeSource` could plug in this
  app's own `/utc` endpoint as one more source later if needed.

`captured_at` is therefore anchored to `trusted_time`'s monotonic-clock-backed estimate
whenever available (tier 1 or 2), with the raw-device-clock fallback (tier 3) as the
explicitly accepted gap for now (design §12 item 18). `trusted_time`'s maintenance status
was checked (§12 item 19): actively maintained but low adoption and an unverified pub.dev
publisher — a real supply-chain-trust caveat, decided to accept for now.

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
  used elsewhere for simple app settings), as a boolean config key — same storage shape as
  the switch it replaces, `offlineCaptureForced` in place of the old
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
`PhotoAttested`/`FileAttested` (§1) and `attest_photo`/`attest_file`, and to the
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

§4b's mandatory reason requirement applies whenever `is_online` is `false`, **or** whenever
`is_forced_offline` is `true` — i.e. every row except the first: a reason is needed not
only when connectivity was genuinely absent, but also when the crew overrode a working
connection, so that override is justified on the record too. The crew must supply a
reason before the shutter proceeds, hashed into `internet_null_reason_hash`; the only case
requiring an empty hash is `is_online: true, is_forced_offline: false`.

## 4a. GPS eligibility: the same treatment, as an independent axis

GPS is optional on exactly the same terms as connectivity (§4), and independently of it —
a capture can be missing internet, missing GPS, both, or neither, each recorded on its
own. This is a separate axis, not a sub-case of "offline mode": a crew with a perfectly
good connection but standing somewhere GPS can't get a fix (indoors, urban canyon, a
site that deliberately shields location) should not have to also go through the
offline/queued submission path just to skip GPS.

- **Fix available, toggle off:** capture proceeds with `has_gps: true`, `gps`/`altitude`
  populated as today — no change from current behavior.
- **No fix available** (GPS disabled, no signal, fix timeout): capture is still allowed
  automatically, with no prior toggle needed — `has_gps: false`, `gps`/`altitude` recorded
  as empty `vector<u8>`.
- **Fix available, toggle on:** see below — `has_gps: true` (ground truth), but
  `gps`/`altitude` are recorded empty because the toggle withholds them.

**"Force No GPS" toggle** mirrors §4's "Force Offline Mode": an independent, app-only,
off-by-default override, living as its own persistent quick-toggle icon in the capture
screen's app bar (alongside, not combined with, the connectivity toggle — a crew may want
to force one without the other). `has_gps` records ground truth — was a real fix actually
obtained — exactly the way `is_online` records ground-truth connectivity regardless of
`is_forced_offline` (§4); the toggle does not change `has_gps`'s meaning. What the toggle
does change is `gps`/`altitude`: they are recorded as empty `vector<u8>` whenever the
toggle is on, even if `has_gps` is `true`, because the point of forcing "no GPS" is to
withhold the location data itself, not to misreport whether a fix existed. So a capture
can have `has_gps: true` with empty `gps`/`altitude` (fix available, withheld by choice) —
this is exactly the `true`/`true` row below, and is the reason this is a 4-state table
rather than 3: it lets a verifier distinguish "GPS genuinely unavailable" from "available
but deliberately withheld," the same distinction §4's table already draws for connectivity.

**This does not touch mock-location detection.** `_detectMockLocation`/
`_isMockLocationDetected` (`capture_screen.dart`) still hard-blocks the shutter exactly as
today — a _detected fake_ fix is a fraud signal, not an optionality question, and is
orthogonal to whether a fix is _missing_. Only "no fix obtained" becomes optional; "a fix
was obtained but it's flagged as mocked" is unaffected by this design.

**Recording the override.** `is_gps_forced_null` is added alongside `has_gps` to
`PhotoAttested` (§1) and `attest_photo`, and to the `photo_captures` table (§8), following
the exact same shape as `is_forced_offline`/`is_online`:

| `has_gps` | `is_gps_forced_null` | Meaning                                                    |
| --------- | -------------------- | ---------------------------------------------------------- |
| `true`    | `false`              | Normal capture with a GPS fix.                             |
| `true`    | `true`               | A fix was available; the crew chose to omit it anyway.     |
| `false`   | `false`              | Automatic — no fix could be obtained.                      |
| `false`   | `true`               | Toggle was on, but moot — no fix was available either way. |

§4b's mandatory reason requirement applies whenever `has_gps` is `false`, **or** whenever
`is_gps_forced_null` is `true` — i.e. every row except the first, mirroring §4's internet
axis exactly: a reason is needed not only when no fix could be obtained, but also when the
crew withheld an available one, so that override is justified on the record too. The crew
must supply a reason before the shutter proceeds, hashed into `gps_null_reason_hash`; the
only case requiring an empty hash is `has_gps: true, is_gps_forced_null: false`.

## 4b. Mandatory null reason + hashing

Neither axis (§4, §4a) is allowed to go null, nor have a working state overridden,
silently. The instant the capture flow determines that internet, GPS, or both will be
null **or force-overridden** for this capture — automatically, or via one of the force
toggles even when the underlying field is still `true` — the crew is required to enter a
non-empty, free-text reason before the shutter is allowed to proceed. This is enforced per
axis independently: a capture missing both internet and GPS (or overriding both) requires
two separate reasons, one for each. Concretely, a reason is required in every state
_except_ the single unambiguous one per axis — `is_online: true` with
`is_forced_offline: false`, and `has_gps: true` with `is_gps_forced_null: false` — per the
§4/§4a truth tables.

- **UI:** a mandatory text-entry prompt (blocking — the shutter stays disabled until
  satisfied) appears in `capture_screen.dart` the moment §5/§4a's checks, or the
  corresponding force toggle, put either axis into a state requiring a reason. Distinct
  prompts for the internet reason and the GPS reason when both apply.
- **Hashing happens at capture time, mirroring `photo_hash`.** The instant a reason is
  entered, its hash is computed right there — same moment `photo_hash` is computed, same
  algorithm and encoding (so `internet_null_reason_hash`/`gps_null_reason_hash` are 32-byte
  hashes, decoded the same way verification already decodes `photo_hash` — see §2) — and
  folded into the same signed metadata bundle as `photo_hash`, `gpsLabel`, etc. This is not
  optional or deferrable: what gets submitted on-chain must be provably the value that was
  signed at capture, not a value recomputed later from mutable local text.
- **Local storage:** both the plaintext reason _and_ its hash are persisted (§8) in
  dedicated `*_null_reason`/`*_null_reason_hash` columns — never discarded. The plaintext
  is kept so the reason can be disclosed later (to a verifier, an auditor, or displayed
  back to the crew); the hash is kept so submission never has to recompute it from
  (potentially edited) local text. Only the hash goes on-chain; the reason text itself
  never does.
- **When not applicable:** only in the one no-reason-needed state per axis (field present,
  toggle off) is the reason not collected and the corresponding `*_null_reason_hash` an
  empty `vector<u8>` on-chain.
- **Enforced on-chain, not just client-side (§1).** `attest_photo`/`attest_file` assert
  `internet_null_reason_hash.is_empty() == (is_online && !is_forced_offline)`, and
  `attest_photo` additionally asserts
  `gps_null_reason_hash.is_empty() == (has_gps && !is_gps_forced_null)` — a transaction
  that gets this wrong reverts (`E_INTERNET_NULL_REASON_MISMATCH`/
  `E_GPS_NULL_REASON_MISMATCH`) rather than only being caught later by verification.
- **Verification:** given a disclosed reason (typically the persisted plaintext read back
  from local storage), verification (§2) recomputes its hash and compares against the
  on-chain `*_null_reason_hash`; a mismatch is surfaced the same way a `capturedAtMatches`
  mismatch is (§2, §12 open item on hard-failure vs. informational).

## 5. Connectivity detection: two checks, not one probe

Today, `_hasNetworkConnectivity` in `capture_screen.dart` is a single boolean derived from
one HTTP round trip: a `Timer.periodic(30s)` calls `_refreshBackendStatus()`, which calls
`AppUtils.hasBackendConnectivity(domain)` (`app/lib/core/utils/utils.dart`), which does a
`forceRefresh` call to `resolveOtpBackendConfig` — a `GET /utc` against each configured
backend candidate in turn, each with its own 3-5s timeout. There's no OS-level
reachability signal to short-circuit that round trip when the radio is plainly off. This
section replaces that single probe with two explicit checks, run by a new
`ConnectivityHeuristicService`, whose result is what §4 uses to decide whether offline
capture is offered.

**`ConnectivityHeuristicService`** (new file:
`app/lib/core/services/connectivity_heuristic_service.dart`) — **implemented and wired
into `capture_screen.dart`**: `_hasNetworkConnectivity` now returns
`_connectivityService.isOnlineCapable` directly, `_startClock()`'s `Timer` reschedules
itself off `_connectivityService.pollInterval` (replacing the old flat 30s interval),
and `_refreshBackendStatus()` reads `.isOnlineCapable`/`.classification` off the service
rather than a single-probe boolean. The service is also unit-tested in isolation
(`app/test/core/services/connectivity_heuristic_service_test.dart`) via a
synthetic-outcome seam (`recordSyntheticOutcomeForTesting`, `@visibleForTesting`) that
drives the classification logic directly, without needing a real platform channel or
HTTP call.

**Binary online/offline, no middle state, no memory of past ticks — revised after field
testing.** The service originally shipped with a third `degraded` state and a rolling
5-outcome window (latency threshold, consecutive-failure/consecutive-confirmation
counters, a debounced `label` distinct from the raw `classification`) meant to smooth
over marginal-signal flapping. On-device testing (S23 Ultra) surfaced the actual cost of
that: a single early transient failure (e.g. the very first backend probe during app
cold start, before the network stack was fully up) could keep the connectivity badge
reading `Degraded` for up to ~5 poll ticks afterward — up to a minute or more — even
though every check in between succeeded quickly, because the classifier was reading a
window of history rather than the current state. That read as "the connection is fine
but the app still says it isn't," which is worse for a field crew than a label that
occasionally flickers on a genuinely marginal connection. The service was simplified to
have no memory beyond the tick that just ran: whatever the connection looks like right
now is what's reported, immediately, every time.

**Step 1 — is a radio on at all.** `connectivity_plus` reports the OS-level interface
state first. No active interface (airplane mode, no SIM and no Wi-Fi) → `offline`
immediately, no network round trip — this is the case where the old single probe was both
most expensive (every candidate times out at 3-5s) and least informative. An active
interface (`wifi` or `mobile` present) moves to step 2; it only confirms a radio is
associated, not that it actually reaches anything, which is exactly what step 2 is for.

**Step 2 — can it actually reach the backend.** Run the existing `GET /utc` probe as a
plain pass/fail reachability check:

- The transaction payload this all exists to submit is tiny — a hash plus a handful of
  short byte fields, no image bytes go on-chain — so a dedicated bandwidth/throughput
  signal was considered and dropped rather than deferred: on top of the earlier concern
  that a large-payload speed test would burn a field crew's data budget precisely in the
  marginal-connectivity conditions being tested, a binary classifier has no "good enough
  but not great" tier left to feed such a number into. `minimumSufficientBandwidthKbps`
  and the native `NetworkCapabilities.getLinkDownstreamBandwidthKbps()` channel discussed
  in earlier drafts of this doc are no longer planned.
- Latency is no longer classified separately either — a probe that succeeds, however
  slowly (up to its own 5s timeout), counts as `online`. A slow-but-working connection is
  still a connection; the crew isn't blocked from trying it, and offline capture remains
  available as a deliberate override (§4) regardless.
- Failing the probe outright (timeout, `SocketException`, non-2xx) with an active
  interface present is `offline` — an interface that can't complete a request is
  functionally no better than no interface.

**Each `check()` call is independent.** `classification` is set directly from that one
tick: no interface → `offline`; no domain configured to probe → `offline`; the probe
throws → `offline`; the probe succeeds → `online`. There is no ring buffer, no
consecutive-failure/consecutive-confirmation counting, and no separate debounced `label`
— `classification` is the only state, and `isOnlineCapable` (`classification == online`)
reads it directly. `online` is the only state §4 treats as online-capable; `offline`
makes offline capture available automatically.

- **Poll cadence — `pollInterval` getter** (30s online / 75s offline, `app_constants.dart`)
  reads directly off the current `classification`. `capture_screen.dart`'s `_startClock()`
  reschedules each tick off `_connectivityService.pollInterval` rather than a flat 30s
  `Timer.periodic`. The existing reconnect trigger (§7: app foreground/resume) still fires
  an immediate out-of-cycle check, so backing off the steady poll doesn't delay recovery.
- **One unified network-error classifier — unaffected by the above.** Both classifiers
  live in one file, `app/lib/core/utils/network_error_classifier.dart`:
  `isTransientNetworkError` (type-based, moved verbatim from `sui_graphql_service.dart`'s
  old `_isTransientNetworkError`) and `looksLikeTransientNetworkFailure` (string-based,
  moved verbatim from `granite_lake_controller.dart`'s old `_shouldRetryChainVerification`
  body). `granite_lake_controller.dart`'s verification-retry catch block (around line 1284) catches a plain `StateError` thrown by `sui_graphql_service.dart`'s
  `getTransaction()` on indexer lag ("...may not be indexed yet") — not a
  `SocketException`/`TimeoutException`/`http.ClientException` by type, so only the
  string-keyword check catches it; that call site stays on
  `looksLikeTransientNetworkFailure`, while `sui_graphql_service.dart`'s
  `_withNetworkRetry` uses `isTransientNetworkError`. `ConnectivityHeuristicService`'s own
  probe-failure classification doesn't consume this classifier directly.

**`is_online` at capture time** is read from `ConnectivityHeuristicService.isOnlineCapable`
(`classification == online`) at the moment of capture, rather than the raw success/failure
of one live timestamp fetch (§3). Same field semantics as originally designed — still
"did this device have live connectivity at capture time" — just sourced from the two-step
classifier's most recent tick instead of a single point-in-time call that could land on
one unlucky retry. `is_forced_offline` (§4) is recorded alongside it from the toggle's raw
state, independently of this classification.

## 6. Capture flow changes

`app/lib/features/capture/screens/capture_screen.dart`:

- The shutter is available without connectivity whenever §5's classifier is not `online`,
  or the §4 "Force Offline Mode" toggle is on regardless of what §5 reports. Independently,
  the shutter is available without a GPS fix whenever no fix was obtained, or the §4a
  "Force No GPS" toggle is on. Mock-location detection remains a hard block in all cases
  (§4a) — it is not an optionality question.
- Whenever the pending capture will have `is_online: false`, `is_forced_offline: true`,
  `has_gps: false`, or `is_gps_forced_null: true`, §4b's mandatory reason prompt(s) must
  be completed before the shutter proceeds — the shutter stays disabled, not just warned,
  until each required reason is non-empty. The only axis states needing no prompt are
  `is_online: true, is_forced_offline: false` and `has_gps: true, is_gps_forced_null:
false`.
- `capturedAtUtc`/`submittedAtUtc` are sourced by preferring a live timestamp fetch (as
  today, when connectivity is available) and falling back to `TimeSyncService.nowUtc()`
  otherwise. `is_online` passed to `attest_photo`/`attest_file` (§2) is read from
  `ConnectivityHeuristicService`'s current state (§5) rather than that one fetch's
  success/failure; `is_forced_offline` is read from the toggle's current state (§4).
  `has_gps`/`is_gps_forced_null` are read from the GPS-fix check and the §4a toggle the
  same way. `internetNullReason`/`gpsNullReason` (plaintext, §4b's prompt input) are
  hashed right here, at the same moment `photo_hash` is computed (see §8's version-11
  note), and both the plaintext and the hash are persisted together — the hash is folded
  into the signed metadata bundle alongside `photo_hash`, so what eventually gets
  submitted on-chain is provably the value that was signed at capture, not something
  recomputed later from local text that could have drifted. What must be right at capture
  time is both which axis states get a reason at all (empty only in the two no-prompt
  states above) and that the hash is computed before signing — getting either wrong means
  the persisted hash won't match what `attest_photo`/`attest_file` expects, and the
  transaction reverts on-chain (§1).

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
  `attest_photo`/`attest_file` with the original `captured_at`/`is_online`/
  `is_forced_offline`/`has_gps`/`is_gps_forced_null`/`internet_null_reason_hash`/
  `gps_null_reason_hash` preserved (a fresh `attested_at` is supplied by the chain
  wherever the submission lands).
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
  Keystore (alias `granite_lake_capture_wrap_key_v2`, `PURPOSE_ENCRYPT | PURPOSE_DECRYPT`,
  OAEP padding: SHA-256 main digest, SHA-1 MGF1 — the only combination Keystore actually
  supports across both the software-path wrap and the Keystore-enforced unwrap, a
  KeyMint restriction confirmed on-device, not assumed) via a small native
  `MethodChannel`, the same pattern already used for the existing biometric gate
  (`granite_lake_secure_state_service.dart:579-593`). Implemented, with one deviation
  from the plan below.
  - **Deviation: a short validity window, not true per-operation auth.**
    `setUserAuthenticationRequired(true)` with **no** validity duration (Keystore's
    default) turned out to require a fresh `Cipher.init()` _and_ a fresh
    `doFinal()`-completing authentication for every single operation — confirmed
    on-device as `KEY_USER_NOT_AUTHENTICATED` on a second row's `doFinal()` even when
    reusing an already-authenticated `Cipher`/`CryptoObject`, because a Keystore2
    operation closes the moment `doFinal()` returns. That's incompatible with "one
    prompt unlocks a whole batch" (below) — a device reconnecting with several queued
    rows would otherwise need one prompt _per row_. The shipped key instead sets a
    **300-second validity window** (`captureWrapKeyValidityDurationSeconds`,
    `setUserAuthenticationValidityDurationSeconds` pre-API-30 /
    `setUserAuthenticationParameters` on API 30+) — every item still gets its own fresh
    `Cipher.init()`/`doFinal()`, but any of them succeed without a new prompt as long as
    they land within 5 minutes of the last successful check. This keeps the point of
    this section intact (a queued row's decrypt key is never cached anywhere near as
    long as the 30-minute signing session, and still can't be unwrapped on a stale
    session alone), just with "fresh" meaning "within the last 5 minutes," not
    "this exact operation." `setInvalidatedByBiometricEnrollment(true)` is also set (see
    §12 item 10 — decided, not left to the platform default).
  - The alias carries a `_v2` suffix because Keystore keys are immutable — the `v1` key
    was generated with the original (broken-for-batches) no-validity-window
    configuration; any row wrapped under `v1` before this fix cannot be recovered under
    `v2` and needs to be recaptured. The public (encrypt/wrap) half needs no
    authentication either way, which is what keeps capture instant regardless of this
    change.
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

  | Time since last decrypt check                                        | Signing key (§7.1)                    | Decrypt key (this section, 300s window — see deviation above) | What happens on reconnect                                                                                                                                        |
  | -------------------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | < 5 min, signing session also still live (< 30 min)                  | Cached — no prompt needed for signing | Within window — no prompt needed                              | Both keys usable with no prompt; decrypt-then-sign proceeds silently — bounded far tighter than the 30-min signing cache, never as loose as "fully cached."      |
  | ≥ 5 min since a decrypt check, signing session still live (< 30 min) | Cached — no prompt needed for signing | Window lapsed — needs a fresh check                           | A biometric prompt is still raised, for the decrypt/unwrap step alone; the cached signing key is then reused to sign once decryption succeeds.                   |
  | ≥ 30 min elapsed, or app was relaunched                              | Cleared — needs `startSession()`      | Window lapsed (or never established) — needs a fresh check    | `pendingAttestationsNeedUnlock` (§7.1) surfaces the CTA; tapping it raises one combined prompt that both re-derives the signing key and unwraps the decrypt key. |

  Before this section, the signing-key column alone decided whether a reconnect was
  silent, on a 30-minute cache. Now the decrypt-key column gates it too — but, per the
  300s-validity deviation above, not by demanding a prompt on literally every reconnect;
  a reconnect can still be silent, just only within a much narrower window (≤5 min since
  the last successful decrypt check) than the 30-minute signing cache ever allowed alone.
  Past that window it always prompts, regardless of whether the signing session is still
  live. This is a real behavior change from the original design's framing of
  resubmission as happening automatically "unchanged" once connectivity is available
  (top-level doc §2) — that's still true for a capture that submits immediately while
  online (never queued, never encrypted), but for anything that spent time in
  `PENDING_SUBMISSION`, "automatic" now means "silent for up to 5 minutes after a real
  check, a fresh prompt otherwise," not "always silent."

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

## 8. Local persistence: `is_online`/`is_forced_offline`/`has_gps`/`is_gps_forced_null`, null reasons, and timestamp provenance

**Implemented, on `databaseVersion = 13`** (`app/lib/core/database/migrations.dart`,
`granite_lake_database_service.dart`; was `9` before this feature — versions 10-13 below
are all part of it). Both the two-part treatment this section originally called for (the
versioned `ALTER TABLE` migration, and matching columns added to
`_createPhotoCapturesTable`/`_createUploadedFilesTable` so a fresh install gets them via
`onCreate` too, not just an upgrade) were applied at every version.

**New columns (connectivity + GPS booleans), version 10.** Unlike `captured_at`, none of
`is_online`/`is_forced_offline`/`has_gps`/`is_gps_forced_null` had a persistence path in
the original design — all four need one, for the same reason `captured_at` does:
`retryPendingAttestations()` (§7) must resubmit with the _original_ values, not values
recomputed at resubmission time (connectivity and GPS availability may well have changed
by then).

```sql
ALTER TABLE photo_captures ADD COLUMN is_online INTEGER NOT NULL DEFAULT 1;
ALTER TABLE photo_captures ADD COLUMN is_forced_offline INTEGER NOT NULL DEFAULT 0;
ALTER TABLE photo_captures ADD COLUMN has_gps INTEGER NOT NULL DEFAULT 1;
ALTER TABLE photo_captures ADD COLUMN is_gps_forced_null INTEGER NOT NULL DEFAULT 0;
ALTER TABLE uploaded_files ADD COLUMN is_online INTEGER NOT NULL DEFAULT 1;
ALTER TABLE uploaded_files ADD COLUMN is_forced_offline INTEGER NOT NULL DEFAULT 0;
-- uploaded_files has no GPS columns: file attestation never carried location data (§1, §4a).
```

following the existing `ALTER TABLE ... ADD COLUMN` pattern used for every prior migration
(e.g. `sui_submission_status` at version 3, `submitted_at` at version 6) and the
existing INTEGER-as-boolean idiom already used for `is_placeholder` on `employeesTable`.
All four are written once at persist time (`persistCaptureWithMetadata`/
`persistFileWithMetadata`, §6) and read back unchanged on every resubmission attempt.

**Version 11: null reasons — plaintext and hash, both persisted, hashed at capture
time.** A `TEXT`/`TEXT` pair per axis: the plaintext reason, and its hash (hex-encoded
text, matching this schema's existing convention — there are no BLOB columns anywhere;
`signature_base64` etc. are all TEXT-encoded too). The hash is computed once, at capture
time — the same moment `photo_hash` is computed — and folded into the same signed
metadata bundle (§6). It is persisted here rather than recomputed later specifically so
what gets submitted on-chain is provably the value that was signed at capture, not a
value derived after the fact from local text that could have been edited in the interim.
The plaintext is kept alongside it, never discarded, so it can still be disclosed to a
verifier later (§4b) — the two columns serve different purposes and neither substitutes
for the other.

```sql
ALTER TABLE photo_captures ADD COLUMN internet_null_reason TEXT;
ALTER TABLE photo_captures ADD COLUMN internet_null_reason_hash TEXT;
ALTER TABLE photo_captures ADD COLUMN gps_null_reason TEXT;
ALTER TABLE photo_captures ADD COLUMN gps_null_reason_hash TEXT;
ALTER TABLE uploaded_files ADD COLUMN internet_null_reason TEXT;
ALTER TABLE uploaded_files ADD COLUMN internet_null_reason_hash TEXT;
-- uploaded_files has no gps_null_reason/gps_null_reason_hash columns, for the same
-- reason as above.
```

Nullable — `NULL` exactly when the corresponding field was present and not overridden
(§4/§4a's one no-reason-needed state per axis). The hash column is what
`retryPendingAttestations()` (§7) submits on-chain unchanged on every resubmission
attempt, the same treatment as `captured_at`; the plaintext column is what §4b's
verification flow discloses to a third party checking a reason. The reason text itself is
never transmitted on-chain, only the hash.

**Version 12: resubmission-attempt tracking (app-local only, not in the original plan
above).** Added during implementation, not anticipated by this section as originally
written: `submission_attempt_count` and `last_attempt_at`, so a crew can see _why_ a row
is still queued (how many real submission attempts have actually been made, and when the
last one happened) instead of it silently sitting there. Never submitted on-chain.

```sql
ALTER TABLE photo_captures ADD COLUMN submission_attempt_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE photo_captures ADD COLUMN last_attempt_at TEXT;
ALTER TABLE uploaded_files ADD COLUMN submission_attempt_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE uploaded_files ADD COLUMN last_attempt_at TEXT;
```

Incremented only for a genuine attempt — an initial online submission or a §7 queue
retry — never for a capture that was persisted while offline/forced-offline and skipped
the network call entirely (§6's initial-attempt skip).

**Version 13 (§7.3): encrypted queued payload — implemented, one encoding change from
the plan above.** `BLOB` was the originally planned type; the shipped migration uses
`TEXT` (base64-encoded) for all three columns instead, matching this schema's
already-established no-BLOB convention (every other binary-shaped value here —
`signature_base64`, the null-reason hashes — is TEXT-encoded too, not a schema
oversight to fix later).

```sql
ALTER TABLE photo_captures ADD COLUMN encrypted_payload TEXT;
ALTER TABLE photo_captures ADD COLUMN payload_iv TEXT;
ALTER TABLE photo_captures ADD COLUMN wrapped_data_key TEXT;
ALTER TABLE uploaded_files ADD COLUMN encrypted_payload TEXT;
ALTER TABLE uploaded_files ADD COLUMN payload_iv TEXT;
ALTER TABLE uploaded_files ADD COLUMN wrapped_data_key TEXT;
```

For a row taking the offline/queued path (§4/§4a/§7.3), `photo_hash`/`gps`/`altitude`/
`captured_at`/`is_online`/`is_forced_offline`/`has_gps`/`is_gps_forced_null`/
`internet_null_reason`/`gps_null_reason` are no longer also written in plaintext —
`encrypted_payload` (base64 AES-GCM ciphertext plus tag), `payload_iv`, and
`wrapped_data_key` (all base64) are the only copies on disk, and the plaintext columns
are read back only after a successful biometric-gated decrypt at resubmission time
(§7.3). Since there's no longer a separate `*_null_reason_hash` column for an encrypted
row (see version 11 above), the earlier question of "should the hash stay unencrypted
for readability" no longer applies — the reason text itself gets the same protection as
`captured_at`/`photo_hash`, full stop, and the hash needed at resubmission is simply
recomputed after decrypt. Rows that submit immediately while online, and existing
pre-migration rows, keep using the plaintext columns directly, so this is additive
rather than a hard schema cutover — reads branch on whether `encrypted_payload` is
`NULL`.

**Narrative provenance.** Alongside the on-chain `captured_at`/`attested_at`, the app also
records locally how the device's own claimed `captured_at` was derived (a fresh live
fetch, `trusted_time`'s network-synced monotonic-clock estimate, or the raw-device-clock
fallback per §3's `TimeProvenance`) and why the capture went through the offline path
(`auto_offline` vs. `forced_offline` vs. not applicable, independently for
connectivity and GPS), folded into the existing signed `proof_payload_json` blob used by
`granite_lake_capture_workflow_service.dart` — the same mechanism that already carries
`gpsLabel`/`altitudeLabel` — so this part needs no new column beyond the raw booleans and
reason text/hash columns above.

## 9. UI

- Capture screen's app bar carries the "Force Offline Mode" toggle (§4) and the
  independent "Force No GPS" toggle (§4a), next to the connectivity and GPS indicators;
  connectivity state (`Connected`/`Offline`, per §5) and GPS state (`Fix
acquired`/`No fix`) are each shown as their own informational banner. When either is
  not in its normal state, the banner explains whether that's automatic or an override.
- §4b's mandatory reason prompt appears inline in the capture flow the moment a field is
  determined to be null — one prompt per null field, blocking the shutter until each is
  filled in.
- History screen shows a pending-sync count, from a new `pendingAttestationCount` getter
  on `GraniteLakeController`. When `pendingAttestationsNeedUnlock` (§7.1) is also true, the
  count becomes an explicit "N ready to submit — unlock to continue" action that calls
  `startSession()`, rather than a passive number. A row in `TAMPER_DETECTED` (§7.3) is
  shown separately from both the pending count and `FAILED_SUBMISSION`, since it means the
  locally stored data itself failed its integrity check, not that the chain rejected
  anything or that a human hasn't unlocked yet.
- Capture-detail screen shows the on-chain `captured_at`/`attested_at`/`is_online`/
  `is_forced_offline`/`has_gps`/`is_gps_forced_null` alongside the local provenance label
  and the disclosed null reasons (with a visible hash-match indicator once verified),
  next to the existing submission-status detail.

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
(force-offline toggle + force-no-GPS toggle UI, §4a; mandatory reason prompts, §4b;
shutter/timestamp changes + connectivity-service wiring), `file_attestation_screen.dart`,
`granite_lake_controller.dart` (`retryPendingAttestations()`,
`pendingAttestationsNeedUnlock`, §7.1; registers/cancels the §7.2 background task as the
pending queue changes; §7.3's decrypt-and-verify step and `TAMPER_DETECTED` handling),
`granite_lake_capture_workflow_service.dart` (encrypt-on-write call for the offline/queued
path, §7.3), `granite_lake_secure_state_service.dart` (Keystore-backed
`capture_encryption_service.dart` reuses the existing native biometric-gate
`MethodChannel`, §7.3), `config_data_controller.dart` (new config keys:
`offlineCaptureForced` and `gpsCaptureForcedNull` replacing the old
`offlineCaptureAllowed`, and the §7.2 last-notified pending count), `migrations.dart` +
`granite_lake_database_service.dart` (version-10 migration, done: `is_online`/
`is_forced_offline`/`has_gps`/`is_gps_forced_null` columns, §8; version-11 migration,
done: `internet_null_reason`/`internet_null_reason_hash`/`gps_null_reason`/
`gps_null_reason_hash` columns, §4b/§8 — plaintext and hash both persisted, hash computed
at capture time; version-12 migration, done: `submission_attempt_count`/`last_attempt_at`
columns, §8 (app-local resubmission tracking, not in the original plan); version-13
migration, done: `encrypted_payload`/`payload_iv`/`wrapped_data_key` columns (TEXT/base64,
not the originally planned BLOB), §7.3/§8), `app.dart`
(lifecycle observer), `capture_tab_screen.dart` (retry-on-unlock wiring, §7.1, combined
with the §7.3 decrypt-key unlock), `history_screen.dart` (unlock-to-submit CTA, §9;
`TAMPER_DETECTED` state, §7.3/§9), `capture_detail_screen.dart`, `app_constants.dart`
(connectivity thresholds/cadences), `AndroidManifest.xml` (`POST_NOTIFICATIONS`
permission, §7.2), `pubspec.yaml` (new `trusted_time`, `connectivity_plus`, `workmanager`,
`flutter_local_notifications` dependencies).

## 11. Verification / testing

- `sui move test` in `contracts/` for the entry functions/events.
- `flutter analyze app`; `npm run lint:verification_api` / `npm run lint:verification_portal`.
- After a testnet deployment: confirm an attestation verifies correctly through
  `verification_api`/`verification_portal`, including a reason-hash check: disclose a
  plaintext reason for a null field and confirm it's reported as matching, then confirm a
  deliberately wrong reason is reported as a mismatch.
- Manual airplane-mode pass: with airplane mode on (toggle off, so offline is purely
  automatic) and an active biometric session, capture succeeds offline and records
  `is_online: false`, `is_forced_offline: false`, plus a mandatory internet-null reason;
  the row appears as `PENDING_SUBMISSION`; reconnecting (via timer and via app
  foreground) triggers submission with the original `captured_at` and a fresh
  `attested_at`; the detail screen and `verification_portal` show matching values. Repeat
  for the file-upload path.
- Manual no-GPS pass (§4a/§4b): with GPS disabled at the OS level (not mock-location —
  actually off) and an active biometric session, capture succeeds and records
  `has_gps: false`, `is_gps_forced_null: false`, plus a mandatory GPS-null reason;
  confirm this is independent of connectivity state (test with connectivity both good and
  bad). Manual force-no-GPS pass: with GPS available and the toggle on, confirm
  `has_gps: false`, `is_gps_forced_null: true` and a reason is still required. Manual
  combined pass: both internet and GPS null in the same capture, confirm both reasons are
  required and both hashes round-trip independently.
- Manual mock-location-still-blocks pass: confirm a detected mock location still hard-blocks
  the shutter even with both force toggles on — this design does not relax that check.
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
- `ConnectivityHeuristicService` unit tests: airplane-mode toggling short-circuits to
  `offline` without a network call; a failed probe classifies `offline` immediately, with
  no consecutive-failure requirement; classification reflects only the most recent
  `check()` call, with no memory of earlier ticks (a probe recovering on the very next
  check reads `online` right away, not delayed by prior history).
- Manual marginal-signal pass (e.g. throttled network via device dev tools or a
  low-signal location): confirm the status label reflects each tick's real outcome (a slow
  but successful probe still reads `Connected`), and that the shutter switches to
  offline-available automatically once §5 reports `offline` (no toggle interaction
  required).
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

1. ~~Confirm the `on_chain` package's constructor for pure `u64`/`bool` transaction
   arguments.~~ Resolved: `SuiCallArgPure.u64(BigInt)` and `SuiCallArgPure.boolean(bool)`
   factory constructors are both present in the locked `on_chain 8.1.0` dependency
   (`app/pubspec.lock`), alongside the `.bytes()` constructor already in use.
2. Decide whether a `capturedAtMatches` mismatch (or a null-reason hash mismatch, §4b) is
   surfaced as a hard verification failure or an informational note in
   `verification_portal`.
3. No longer applicable — the event is modified in place with no versioning, so there is
   only ever one shape of `PhotoAttested`/`FileAttested` to display.
4. Decide the exact icon/state treatment for the app-bar force-offline and force-no-GPS
   toggles (e.g. distinct icon states for "online, toggle off", "online, toggle on
   (override)", "offline, toggle off (automatic)", "offline, toggle on" — doubled for the
   GPS toggle, and however the two are shown together when both apply).
5. Tune the §5 poll cadences (`app_constants.dart`'s `connectivityPollIntervalOnline`/
   `connectivityPollIntervalOffline`) against real field data rather than guessing up
   front — ship with conservative defaults and treat them as adjustable constants.
6. ~~Decide whether `degraded` (as opposed to `offline`) should also make offline capture
   available...~~ No longer applicable — after on-device testing showed the windowed
   `degraded` classifier reading stale ("connection's fine now but still says Degraded"
   for up to ~5 poll ticks after one earlier transient failure), §5 was simplified to a
   binary `online`/`offline` classifier with no history window. There is no middle state
   left to decide eligibility for.
7. Decide whether §5's automatic online/offline banner copy should be dismissible or
   persistent while `offline` holds, so it informs without nagging a crew that's
   deliberately working near the edge of coverage.
8. §7.2's background reconnect task rides on Android `JobScheduler` via `workmanager`,
   which some OEMs (Xiaomi, Huawei, and others with aggressive custom battery-management)
   restrict or delay beyond stock Android's Doze behavior. The in-app §7.1 CTA is the
   guaranteed fallback — the notification is a best-effort improvement on top of it, not
   a dependency — but worth field-testing on the specific device models crews are issued.
9. Decide the exact timing/copy for the `POST_NOTIFICATIONS` permission request (§7.2) —
   at first offline capture, as designed, or bundled into the biometric-binding onboarding
   flow (`biometric_setup_screen.dart`) where the crew is already granting permissions.
10. ~~Decide `setInvalidatedByBiometricEnrollment` for the §7.3 Keystore keypair.~~
    Resolved: set to `true` (`generateCaptureWrapKeyPair`, `MainActivity.kt`) — the
    platform default, kept deliberately rather than by accident, accepting that a
    legitimate crew member re-enrolling their own print loses any not-yet-submitted
    queue, in exchange for closing the attacker-enrolls-their-own-biometric path.
11. **Still open, current default noted.** Decide whether the §7.3 Keystore keypair
    should require `setIsStrongBoxBacked(true)`
    (dedicated secure-element storage) where the device supports it, versus falling back
    to TEE-only storage silently — depends on the hardware profile of the devices crews
    are actually issued. **Current implementation:** `setIsStrongBoxBacked` is not called
    at all, i.e. TEE-only by the platform default — this was never a deliberate choice,
    so it remains genuinely open, not a documentation gap.
12. Decide the exact `TAMPER_DETECTED` (§7.3/§9) UX: block that row from resubmission
    permanently pending admin/support review, or let the crew discard it and re-capture in
    place. Also decide whether a `TAMPER_DETECTED` row should be reported anywhere beyond
    the device itself (e.g. a local-only audit note), given the whole point is that it
    can no longer be trusted enough to submit on-chain.
13. ~~Confirm the hash algorithm/encoding for `internet_null_reason_hash`/
    `gps_null_reason_hash`~~ Resolved: SHA-256, confirmed as this codebase's existing
    convention (`verification_api/src/routes/verifyAttestation.ts` already hashes
    uploads with `createHash("sha256")`; `verification_portal/src/lib/fileHash.ts` with
    `crypto.subtle.digest("SHA-256", ...)`) and reused directly rather than introducing a
    second hashing scheme, in both `hashNullReason` implementations (§2).
14. Decide input constraints on the mandatory reason text (§4b): minimum/maximum length,
    whether free text is sufficient or a short preset-reason list (e.g. "no signal",
    "GPS disabled", "indoors", "privacy-sensitive site") should be offered with an
    "other" free-text fallback — a preset list would also make the disclosed-reason
    verification flow (§2) more predictable to review at scale.
15. **Currently implemented as self-service, unauthenticated** — `POST
/verify-null-reason` has no auth, and `verification_portal`'s inline `NullReasonCheck`
    control is visible to anyone viewing a result. Still open whether that's the right
    final call, or whether disclosure should be gated to specific roles (e.g. only a
    domain admin can pull the plaintext reason from the device/backup and disclose it) —
    revisit before this ships broadly, since the current default was an implementation
    default, not a deliberate product decision.
16. Decide whether a `TAMPER_DETECTED` classification (§7.3) should also apply if only a
    `*_null_reason`/`*_null_reason_hash` column is altered post-capture, independent of
    whether `photo_hash`/`captured_at` are also altered — i.e. whether the null-reason
    fields are load-bearing enough for the tamper check on their own, not just as part of
    the same encrypted blob.
17. Decide whether the narrative-provenance fields folded into `proof_payload_json` (§8) —
    display text like the capture-timestamp-source label — need the same §7.3 at-rest
    protection as the raw `is_online`/`is_forced_offline`/`captured_at` values, or whether
    being informational-only (not read back into the on-chain submission) is enough to
    leave them out of the encrypted payload for now.
18. **Accepted gap, revisit later:** `TimeSyncService`'s raw-device-clock fallback (§3) —
    used only when `trusted_time` itself can't return a valid reading, i.e. a reboot
    happened while offline before a resync could occur — reintroduces the
    clock-tampering exposure `trusted_time` otherwise closes, for that one case. Decided
    to accept this for now rather than block on it; revisit if field data shows
    offline-reboot-then-capture is common enough to matter (a possible future mitigation:
    refuse capture entirely in this specific state rather than silently falling back,
    forcing a reconnect-and-resync first — a stricter trade-off not adopted here).
19. **Checked at design time**: `trusted_time` v2.2.0 (published 43 days prior), pub
    points ~150, but only 16 likes / ~99 weekly downloads and an **unverified uploader**
    (not a verified pub.dev publisher). Technical fit is exactly right (network sync
    anchored to `SystemClock.elapsedRealtime()`, offline-safe via
    `TrustedTimeNotReadyException`/`isTrusted`/`nowEstimated()`, automatic reboot
    detection and resync) and it's actively maintained, but the low-adoption/unverified-
    publisher combination is a real supply-chain-trust caveat for a security-sensitive
    attestation feature. Decided to proceed on this research alone for now; a source-level
    skim (not just the package description) is still worth doing before this ships to
    production.
