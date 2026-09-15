import 'dart:async';
import 'dart:collection';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../constants/app_constants.dart';
import '../utils/utils.dart';

/// Two-step, debounced connectivity classifier (offline-capture design doc
/// §5), replacing a single HTTP-probe-per-tick with: (1) is a radio on at
/// all (OS-level, no network round trip), (2) is what it reaches good
/// enough (reachability + latency, via the existing `/utc` probe).
///
/// [online] is the only state the offline-capture design treats as
/// online-capable; [degraded] and [offline] both make offline capture
/// available automatically.
enum ConnectivityClass { online, degraded, offline }

class _ProbeOutcome {
  const _ProbeOutcome({
    required this.hasInterface,
    required this.success,
    this.latency,
  });

  /// Step 1: was an OS-level network interface present at all. `false`
  /// means the probe in step 2 was skipped entirely — no network call.
  final bool hasInterface;

  /// Step 2: did the `/utc` probe succeed. Only meaningful when
  /// [hasInterface] is `true` — always `false` otherwise, by convention.
  final bool success;

  final Duration? latency;
}

/// Wraps `connectivity_plus` (step 1) and the existing backend `/utc` probe
/// (step 2) into a debounced `online`/`degraded`/`offline` classification,
/// per the offline-capture design doc §5. Not a singleton — one instance is
/// expected to live for the lifetime of whatever screen/controller needs
/// live connectivity classification (mirroring how other services in this
/// app are constructed and held, not globally shared).
class ConnectivityHeuristicService {
  /// [checkConnectivity] defaults to `Connectivity().checkConnectivity`.
  /// Overridable as a plain function reference (rather than injecting a
  /// `Connectivity` instance) because `Connectivity`'s constructor is
  /// private behind a singleton factory, so it can't be subclassed for a
  /// test fake — a function seam is the only practical way to fake step 1
  /// in tests without a real platform channel.
  ConnectivityHeuristicService({
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
  }) : _checkConnectivity =
           checkConnectivity ?? Connectivity().checkConnectivity;

  final Future<List<ConnectivityResult>> Function() _checkConnectivity;

  static const _ringBufferSize = 5;
  final Queue<_ProbeOutcome> _recentOutcomes = Queue<_ProbeOutcome>();

  ConnectivityClass _classification = ConnectivityClass.offline;
  ConnectivityClass _label = ConnectivityClass.offline;

  // Tracks a run of *consecutive identical* raw classifications that
  // disagree with the current label — not merely "disagrees with the
  // label," which would let two different non-label classifications in a
  // row (e.g. online, then degraded) incorrectly accumulate toward a flip
  // even though they're not the same direction as each other.
  ConnectivityClass? _pendingLabelDirection;
  int _pendingLabelStreak = 0;

  // The hysteresis below exists to stop a *live* label from flapping on a
  // single marginal tick - it isn't meant to delay the very first reading
  // of a session. Without this, [_label] starts hardcoded at [offline] and
  // a freshly opened screen with real connectivity would still report
  // offline for a full extra check (until a second consecutive "online"
  // tick confirms it), which reads as "always offline until you retry."
  bool _hasClassifiedOnce = false;

  // Whether the most recent tick saw an OS-level network interface at all
  // (step 1) - independent of whether step 2's probe then succeeded. This
  // is what distinguishes "no internet because the device genuinely can't
  // reach anything despite wifi/data being on" (not the crew's doing) from
  // "no internet because wifi/data are off, or airplane mode is on" (a
  // deliberate device-level action - see [hasOsInterface] doc).
  bool _hasOsInterface = true;

  /// The raw classification from the most recent [check] call, updated
  /// every tick with no debouncing.
  ConnectivityClass get classification => _classification;

  /// `false` when the most recent tick found no OS-level network interface
  /// at all - wifi and mobile data both off, or airplane mode on. This is a
  /// deliberate device-level action, not a passive "no signal here"
  /// circumstance, which is why the offline-capture design treats it as
  /// equivalent to the crew's own Force Offline Mode toggle (both mean
  /// "the crew chose this") rather than as an ordinary unforced outage
  /// (interface present, probe just fails - a dead zone or a router with no
  /// upstream, not something the crew did). Raw, per-tick, no debouncing -
  /// mirrors [classification], not [label].
  bool get hasOsInterface => _hasOsInterface;

  // Raw interfaces from the most recent real check() call - only used by
  // hasBothWifiAndMobileActive below, never by the classifier itself.
  List<ConnectivityResult> _lastInterfaces = const [];

  /// `true` only when *both* wifi and mobile data are simultaneously
  /// reporting active - deliberately stricter than [hasOsInterface] (which
  /// a single interface already satisfies, and which is what the actual
  /// online/offline classification above uses). This exists purely for the
  /// capture screen's "why is this blocked" messaging, which wants to be
  /// able to tell the crew to turn on a *specific* radio - never for
  /// [isOnlineCapable]/[classification]/[label], where a Wi-Fi-only or
  /// data-only device must keep being treated as online-capable like
  /// normal device usage actually works.
  ///
  /// Also doubles as an airplane-mode check with no extra platform code:
  /// airplane mode disables every radio, so if both wifi and mobile are
  /// simultaneously active, airplane mode cannot be on. connectivity_plus
  /// has no direct airplane-mode API to check that separately.
  bool get hasBothWifiAndMobileActive =>
      _lastInterfaces.contains(ConnectivityResult.wifi) &&
      _lastInterfaces.contains(ConnectivityResult.mobile);

  /// The debounced, user-facing classification — flips only after
  /// [AppConstants.connectivityConsecutiveConfirmationsForLabelFlip]
  /// consecutive same-direction [classification] results, so a
  /// marginal-signal area doesn't bounce the displayed state (and, more
  /// importantly, the recorded `is_online` value) on every tick. This is
  /// what offline-capture eligibility (design §4) and `is_online` at
  /// capture time (§5) both read from — never [classification] directly.
  ConnectivityClass get label => _label;

  /// `true` only when [label] is [ConnectivityClass.online] — the single
  /// state the offline-capture design treats as online-capable.
  bool get isOnlineCapable => _label == ConnectivityClass.online;

  /// Adaptive poll cadence for a `Timer.periodic`-style caller: short while
  /// degraded (confirm/recover quickly), long once solidly offline
  /// (conserve battery/data in a dead zone), standard once online.
  Duration get pollInterval {
    switch (_label) {
      case ConnectivityClass.degraded:
        return AppConstants.connectivityPollIntervalDegraded;
      case ConnectivityClass.offline:
        return AppConstants.connectivityPollIntervalOffline;
      case ConnectivityClass.online:
        return AppConstants.connectivityPollIntervalOnline;
    }
  }

  /// Runs one classification cycle and returns the updated raw
  /// [classification]. [domain] is the company domain used to resolve the
  /// backend probe target (same as the existing `AppUtils` connectivity
  /// calls) — a null/empty domain is treated as step 2 failing outright
  /// (nothing to probe), same as today's behavior.
  Future<ConnectivityClass> check({required String? domain}) async {
    final interfaces = await _checkConnectivity();
    _lastInterfaces = interfaces;
    final hasInterface = interfaces.any(
      (result) => result != ConnectivityResult.none,
    );

    if (!hasInterface) {
      _recordOutcome(const _ProbeOutcome(hasInterface: false, success: false));
      return _reclassify();
    }

    if (domain == null || domain.isEmpty) {
      _recordOutcome(const _ProbeOutcome(hasInterface: true, success: false));
      return _reclassify();
    }

    final stopwatch = Stopwatch()..start();
    try {
      // Reuses the existing `/utc` probe rather than a dedicated speed
      // test: the transaction payload this all exists to submit is tiny,
      // so raw throughput isn't the real constraint — latency is a better
      // predictor of submission success, and a dedicated large-payload
      // test would burn a field crew's data budget precisely in the
      // marginal-connectivity conditions being tested (design §5).
      await AppUtils.resolveOtpBackendConfig(
        domain: domain,
        forceRefresh: true,
        timeout: const Duration(seconds: 5),
      );
      _recordOutcome(
        _ProbeOutcome(
          hasInterface: true,
          success: true,
          latency: stopwatch.elapsed,
        ),
      );
    } catch (_) {
      _recordOutcome(
        _ProbeOutcome(
          hasInterface: true,
          success: false,
          latency: stopwatch.elapsed,
        ),
      );
    }

    return _reclassify();
  }

  /// Drives the classifier with a synthetic probe outcome, bypassing
  /// `connectivity_plus`/HTTP entirely — the seam unit tests use to exercise
  /// the ring-buffer/threshold/hysteresis logic in isolation and
  /// deterministically. Not for production call sites.
  @visibleForTesting
  ConnectivityClass recordSyntheticOutcomeForTesting({
    required bool hasInterface,
    required bool success,
    Duration? latency,
  }) {
    _recordOutcome(
      _ProbeOutcome(
        hasInterface: hasInterface,
        success: success,
        latency: latency,
      ),
    );
    return _reclassify();
  }

  void _recordOutcome(_ProbeOutcome outcome) {
    _hasOsInterface = outcome.hasInterface;
    _recentOutcomes.addLast(outcome);
    while (_recentOutcomes.length > _ringBufferSize) {
      _recentOutcomes.removeFirst();
    }
  }

  int _trailingConsecutiveProbeFailures() {
    var count = 0;
    for (final outcome in _recentOutcomes.toList().reversed) {
      if (outcome.hasInterface && !outcome.success) {
        count += 1;
      } else {
        break;
      }
    }
    return count;
  }

  ConnectivityClass _reclassify() {
    if (_recentOutcomes.isEmpty) {
      _classification = ConnectivityClass.offline;
      _updateLabelWithHysteresis(_classification);
      return _classification;
    }

    final last = _recentOutcomes.last;

    if (!last.hasInterface) {
      // No OS interface — offline immediately, per-tick, no consecutive-
      // failure requirement (design §5 step 1). This is a deterministic
      // OS-level signal (the radio is off), not a noisy probe result, so it
      // also bypasses the label's hysteresis below rather than waiting for
      // a second confirming tick - a crew that turns off wifi/data must see
      // the app go offline immediately, not up to a full poll cycle later.
      // The reverse (interface returns, probe succeeds) still debounces
      // normally, since a probe outcome genuinely can be flaky/marginal.
      _classification = ConnectivityClass.offline;
      _hasClassifiedOnce = true;
      _label = ConnectivityClass.offline;
      _pendingLabelDirection = null;
      _pendingLabelStreak = 0;
      return _classification;
    } else if (!last.success) {
      final consecutiveFailures = _trailingConsecutiveProbeFailures();
      _classification =
          consecutiveFailures >=
              AppConstants.connectivityConsecutiveFailuresForOffline
          ? ConnectivityClass.offline
          : ConnectivityClass.degraded;
    } else if (last.latency != null &&
        last.latency! > AppConstants.connectivityDegradedLatencyThreshold) {
      _classification = ConnectivityClass.degraded;
    } else if (_recentOutcomes.any((outcome) => !outcome.success)) {
      // Succeeded this tick, but the recent window shows a failure —
      // "succeeds but intermittently" (design §5).
      _classification = ConnectivityClass.degraded;
    } else {
      _classification = ConnectivityClass.online;
    }

    _updateLabelWithHysteresis(_classification);
    return _classification;
  }

  void _updateLabelWithHysteresis(ConnectivityClass next) {
    if (!_hasClassifiedOnce) {
      _hasClassifiedOnce = true;
      _label = next;
      _pendingLabelDirection = null;
      _pendingLabelStreak = 0;
      return;
    }

    if (next == _label) {
      _pendingLabelDirection = null;
      _pendingLabelStreak = 0;
      return;
    }

    if (next == _pendingLabelDirection) {
      _pendingLabelStreak += 1;
    } else {
      _pendingLabelDirection = next;
      _pendingLabelStreak = 1;
    }

    if (_pendingLabelStreak >=
        AppConstants.connectivityConsecutiveConfirmationsForLabelFlip) {
      _label = next;
      _pendingLabelDirection = null;
      _pendingLabelStreak = 0;
    }
  }
}
