import 'dart:async';

import 'package:trusted_time/trusted_time.dart';

/// How trustworthy a [TimeSyncService.nowUtc] reading is. Informational only
/// (folded into the local `proof_payload_json` narrative — see the
/// offline-capture design doc §8) — nothing branches on this beyond display.
enum TimeProvenance {
  /// Backed by `trusted_time`'s fully-anchored [TrustedTime.now] — a live
  /// sync has established a trust anchor and it hasn't been invalidated.
  fresh,

  /// Backed by `trusted_time`'s degraded [TrustedTime.nowEstimated] —
  /// extrapolated from the last verified anchor, still monotonic-clock
  /// derived (not a live wall-clock read), but the anchor has aged or its
  /// confidence has otherwise decayed.
  stale,

  /// Backed by the raw, uncorrected device clock. Reached only when
  /// `trusted_time` has nothing to extrapolate from at all — typically a
  /// reboot invalidated its anchor while offline, before a resync could
  /// land. This is the one state where a manually changed system clock
  /// would go undetected; see design doc §12 item 18.
  neverSynced,
}

/// Offline-safe capture timestamp source, wrapping the `trusted_time`
/// package (chosen over a bespoke wall-clock-offset scheme specifically
/// because it anchors to `SystemClock.elapsedRealtime` — Android's hardware
/// monotonic clock — rather than the device's wall clock, so it isn't
/// defeated by a user manually changing the system time while offline; see
/// design doc §3).
///
/// **Scope: offline fallback only.** [nowUtc] must only be consulted where a
/// live backend `/utc` fetch is unavailable or has failed. Callers should
/// always prefer a live fetch when online — this service never supplies a
/// timestamp while one is available, and its own background resyncing
/// exists purely to keep `trusted_time`'s anchor warm for later offline use,
/// not to serve as an online timestamp source.
class TimeSyncService {
  static const _initTimeout = Duration(seconds: 10);

  /// Must be awaited exactly once at app startup, before `runApp` (see
  /// `main.dart`). Never throws: `TrustedTime.initialize()` calls into a
  /// network sync on a fresh install with no persisted anchor, and that sync
  /// throws `TrustedTimeSyncException` if it can't reach quorum — i.e. a
  /// device with zero connectivity on first cold launch would otherwise
  /// crash app startup, which would defeat the entire point of this
  /// feature. A failed or slow first sync here just leaves `nowUtc()`
  /// falling back through its tiers until a sync eventually succeeds.
  static Future<void> initializeAtStartup() async {
    try {
      await TrustedTime.initialize().timeout(_initTimeout);
    } catch (_) {
      // Expected on a first launch without connectivity — not an error
      // worth surfacing, nowUtc() degrades gracefully on its own.
    }
  }

  TimeProvenance _lastProvenance = TimeProvenance.neverSynced;

  /// Calls `TrustedTime.forceResync()` opportunistically whenever the app
  /// already knows it has connectivity (the capture screen's connectivity
  /// check, `ConnectivityHeuristicService` transitioning to `online`) rather
  /// than waiting on `trusted_time`'s own 30-minute foreground
  /// `refreshInterval`. Best-effort: a failed resync just leaves whatever
  /// anchor state already existed in place.
  Future<void> ensureFreshSync() async {
    try {
      await TrustedTime.forceResync();
    } catch (_) {
      // Best-effort — see doc comment above.
    }
  }

  /// Offline-fallback timestamp only (see class doc — never call this while
  /// a live fetch is available). Synchronous, three-tier fallback:
  /// 1. `TrustedTime.now()` when trusted — the fully-anchored path.
  /// 2. `TrustedTime.nowEstimated()` when (1) isn't available — still
  ///    monotonic-anchor-derived, degrading gracefully rather than failing
  ///    outright.
  /// 3. The raw device clock, only when (2) also has nothing to extrapolate
  ///    from (typically an offline reboot with no resync since).
  ///
  /// Updates [provenance] as a side effect, reflecting whichever tier
  /// answered this call.
  DateTime nowUtc() {
    if (TrustedTime.isTrusted) {
      try {
        final now = TrustedTime.now();
        _lastProvenance = TimeProvenance.fresh;
        return now;
      } on TrustedTimeNotReadyException {
        // isTrusted flipped false between the check and the call (e.g. an
        // integrity event fired concurrently) — fall through to tier 2.
      }
    }

    final estimate = TrustedTime.nowEstimated();
    if (estimate != null) {
      _lastProvenance = TimeProvenance.stale;
      return estimate.estimatedTime;
    }

    _lastProvenance = TimeProvenance.neverSynced;
    return DateTime.now().toUtc();
  }

  /// The provenance of the value returned by the most recent [nowUtc] call.
  /// [neverSynced] before [nowUtc] has ever been called on this instance.
  TimeProvenance get provenance => _lastProvenance;
}
