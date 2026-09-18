import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants/app_constants.dart';
import '../utils/utils.dart';

const MethodChannel _nativeChannel = MethodChannel(
  'granite_lake/biometric_gate',
);

/// Result of the native `getMobilePhoneState` call - bundled into one class
/// (rather than two separate native calls) specifically so the two values,
/// both gated behind the same `READ_PHONE_STATE` request, can't race on
/// `MainActivity.kt`'s single pending-permission-result slot.
class MobilePhoneState {
  const MobilePhoneState({
    required this.serviceState,
    required this.dataEnabled,
  });

  /// `'in_service'` / `'out_of_service'` / `'emergency_only'` /
  /// `'power_off'`, or `null` when unreadable (permission not granted, or
  /// no `ServiceState` available).
  final String? serviceState;

  /// The actual "Mobile Data" toggle, independent of [serviceState] - full
  /// signal with data switched off is a real, common combination this
  /// exists to catch. `null` when unreadable.
  final bool? dataEnabled;
}

/// Two states only: [online] means the most recent [check] found an OS-level
/// interface and reached the backend; everything else - no interface, no
/// domain to probe, or the probe failing - is [offline]. Whatever the
/// connection looks like right now, not a windowed/debounced read of recent
/// history.
enum ConnectivityClass { online, offline }

/// Wraps `connectivity_plus` (step 1: is a radio on at all) and the existing
/// backend `/utc` probe (step 2: can it actually reach the backend) into a
/// binary `online`/`offline` classification (offline-capture design doc §5).
/// Not a singleton — one instance is expected to live for the lifetime of
/// whatever screen/controller needs live connectivity classification
/// (mirroring how other services in this app are constructed and held, not
/// globally shared).
class ConnectivityHeuristicService {
  /// [checkConnectivity] defaults to `Connectivity().checkConnectivity`.
  /// Overridable as a plain function reference (rather than injecting a
  /// `Connectivity` instance) because `Connectivity`'s constructor is
  /// private behind a singleton factory, so it can't be subclassed for a
  /// test fake — a function seam is the only practical way to fake step 1
  /// in tests without a real platform channel.
  /// [hasActiveSimCheck], [isAirplaneModeOnCheck], [isWifiRadioOnCheck], and
  /// [mobilePhoneStateCheck] all default to their respective native calls
  /// (`MainActivity.kt`, Android only) - overridable the same way
  /// [checkConnectivity] is, so tests can drive them without a real
  /// platform channel.
  ConnectivityHeuristicService({
    Future<List<ConnectivityResult>> Function()? checkConnectivity,
    Future<bool> Function()? hasActiveSimCheck,
    Future<bool> Function()? isAirplaneModeOnCheck,
    Future<bool> Function()? isWifiRadioOnCheck,
    Future<MobilePhoneState> Function()? mobilePhoneStateCheck,
  }) : _checkConnectivity =
           checkConnectivity ?? Connectivity().checkConnectivity,
       _hasActiveSimCheck = hasActiveSimCheck ?? _defaultHasActiveSimCheck,
       _isAirplaneModeOnCheck =
           isAirplaneModeOnCheck ?? _defaultIsAirplaneModeOnCheck,
       _isWifiRadioOnCheck = isWifiRadioOnCheck ?? _defaultIsWifiRadioOnCheck,
       _mobilePhoneStateCheck =
           mobilePhoneStateCheck ?? _defaultMobilePhoneStateCheck;

  final Future<List<ConnectivityResult>> Function() _checkConnectivity;
  final Future<bool> Function() _hasActiveSimCheck;
  final Future<bool> Function() _isAirplaneModeOnCheck;
  final Future<bool> Function() _isWifiRadioOnCheck;
  final Future<MobilePhoneState> Function() _mobilePhoneStateCheck;

  // Deliberately catches *any* exception, not just PlatformException -
  // MissingPluginException (thrown when the native side doesn't implement
  // a given channel method at all, e.g. an old build reached via hot
  // reload, which only reloads Dart, never Kotlin) is a sibling class, not
  // a subtype, and would otherwise slip past an `on PlatformException`
  // catch. These four checks exist purely to make messaging/
  // is_forced_offline attribution more precise - a soft, advisory
  // signal, never a hard block - so failing open (never letting one of
  // them throw at all) is the right trade-off regardless of why the
  // native call failed.
  static Future<bool> _defaultHasActiveSimCheck() async {
    if (!Platform.isAndroid) {
      return true;
    }
    try {
      final result = await _nativeChannel.invokeMethod<bool>('hasActiveSim');
      return result ?? true;
    } catch (_) {
      // Fail open: still suggest mobile data rather than silently hiding a
      // suggestion that might actually be actionable.
      return true;
    }
  }

  static Future<bool> _defaultIsAirplaneModeOnCheck() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final result = await _nativeChannel.invokeMethod<bool>(
        'isAirplaneModeOn',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _defaultIsWifiRadioOnCheck() async {
    if (!Platform.isAndroid) {
      return true;
    }
    try {
      final result = await _nativeChannel.invokeMethod<bool>('isWifiRadioOn');
      // Fail open: assume the radio might be on rather than wrongly telling
      // the crew to turn on a radio that already is.
      return result ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<MobilePhoneState> _defaultMobilePhoneStateCheck() async {
    if (!Platform.isAndroid) {
      return const MobilePhoneState(serviceState: null, dataEnabled: null);
    }
    try {
      final result = await _nativeChannel.invokeMapMethod<String, Object?>(
        'getMobilePhoneState',
      );
      return MobilePhoneState(
        serviceState: result?['serviceState'] as String?,
        dataEnabled: result?['dataEnabled'] as bool?,
      );
    } catch (_) {
      return const MobilePhoneState(serviceState: null, dataEnabled: null);
    }
  }

  ConnectivityClass _classification = ConnectivityClass.offline;

  // Whether the most recent tick saw an OS-level network interface at all
  // (step 1) - independent of whether step 2's probe then succeeded. This
  // is what distinguishes "no internet because the device genuinely can't
  // reach anything despite wifi/data being on" (not the crew's doing) from
  // "no internet because wifi/data are off, or airplane mode is on" (a
  // deliberate device-level action - see [hasOsInterface] doc).
  bool _hasOsInterface = true;

  /// The classification from the most recent [check] call - purely a
  /// function of that one tick, updated every call with no debouncing or
  /// memory of past ticks.
  ConnectivityClass get classification => _classification;

  /// `true` only when [classification] is [ConnectivityClass.online] — the
  /// single state the offline-capture design treats as online-capable.
  bool get isOnlineCapable => _classification == ConnectivityClass.online;

  /// `false` when the most recent tick found no OS-level network interface
  /// at all - wifi and mobile data both off, or airplane mode on. This is a
  /// deliberate device-level action, not a passive "no signal here"
  /// circumstance, which is why the offline-capture design treats it as
  /// equivalent to the crew's own Force Offline Mode toggle (both mean
  /// "the crew chose this") rather than as an ordinary unforced outage
  /// (interface present, probe just fails - a dead zone or a router with no
  /// upstream, not something the crew did).
  bool get hasOsInterface => _hasOsInterface;

  // Refreshed only when check() finds no interface (see check() below) -
  // these are a soft, advisory signal (messaging + is_forced_offline
  // attribution), never part of the hasInterface/classification pipeline
  // above, so there's no reason to pay for a platform-channel round trip
  // (or risk the READ_PHONE_STATE prompt firing) while normally online.
  bool _hasSim = true;
  bool _isAirplaneModeOn = false;
  bool _isWifiRadioOn = true;
  String? _mobileServiceState;
  bool? _mobileDataEnabled;

  /// Whether this device has an active SIM (physical or eSIM) at all.
  /// `true` (fail-open default) until the first [check]/[refreshRadioState]
  /// resolves it, or if the native call fails.
  bool get hasSim => _hasSim;

  /// Direct, unambiguous "did the crew turn on airplane mode" signal -
  /// unlike inferring it from a lack of any active interface, which can't
  /// tell that apart from "Wi-Fi on but out of range of any AP." `false`
  /// until the first [check]/[refreshRadioState] resolves it, or if the
  /// native call fails.
  bool get isAirplaneModeOn => _isAirplaneModeOn;

  /// The real Wi-Fi radio toggle state (native `WifiManager.isWifiEnabled`),
  /// independent of whether it's currently associated with a network. `true`
  /// (fail-open default) until the first [check]/[refreshRadioState]
  /// resolves it, or if the native call fails.
  bool get isWifiRadioOn => _isWifiRadioOn;

  /// The actual "Mobile Data" toggle (native `TelephonyManager.
  /// isDataEnabled`), independent of signal strength - `null` when
  /// unreadable (`READ_PHONE_STATE` not granted, no SIM, or the call
  /// failed), never assumed either way in that case.
  bool? get isMobileDataEnabled => _mobileDataEnabled;

  /// `'in_service'` / `'out_of_service'` / `'emergency_only'` /
  /// `'power_off'`, or `null` when unreadable. Exposed mainly for
  /// diagnostics/messaging detail; [isConnectivityRuleBroken] only reads
  /// [isMobileDataEnabled] and [isWifiRadioOn]/[isAirplaneModeOn], not this.
  String? get mobileServiceState => _mobileServiceState;

  /// The soft connectivity rule this app expects to hold: Wi-Fi on, airplane
  /// mode off, and - only if this device actually has a SIM - Mobile Data
  /// on too. `true` when any of those is violated.
  ///
  /// This is advisory only - it never blocks capture (offline capture stays
  /// available exactly as the offline-capture design already allows) and
  /// is independent of whether the device can actually *reach* anything
  /// right now: a device that satisfies this rule but still can't get
  /// online (Wi-Fi on, out of range, no real signal - a genuine dead zone)
  /// reports `false` here, same as a fully online device. What this
  /// *does* feed is (a) the capture screen's advisory messaging, telling
  /// the crew specifically which setting to fix, and (b) `is_forced_offline`
  /// at capture time when the device turns out to be offline - a rule
  /// violation means the crew's own settings caused it, worth recording as
  /// deliberate; a dead zone with the rule satisfied is not.
  bool get isConnectivityRuleBroken {
    if (_isAirplaneModeOn) {
      return true;
    }
    if (!_isWifiRadioOn) {
      return true;
    }
    if (_hasSim && _mobileDataEnabled == false) {
      return true;
    }
    return false;
  }

  /// Lightweight, standalone refresh of the four signals above (SIM
  /// presence, airplane mode, Wi-Fi, mobile phone state) - unlike [check],
  /// this never touches `connectivity_plus` or the `/utc` probe, so it's
  /// safe and cheap to call directly wherever the capture screen needs a
  /// fresh read (e.g. right before building its advisory message).
  /// [check] also relies on this when it finds no interface, rather than
  /// duplicating the fetch logic.
  Future<void> refreshRadioState() async {
    try {
      final results = await Future.wait<bool>([
        _hasActiveSimCheck(),
        _isAirplaneModeOnCheck(),
        _isWifiRadioOnCheck(),
      ]);
      _hasSim = results[0];
      _isAirplaneModeOn = results[1];
      _isWifiRadioOn = results[2];

      if (_hasSim) {
        // Only checked (and only ever prompts for READ_PHONE_STATE) when
        // there's actually a SIM to have Mobile Data on in the first
        // place - a no-SIM device has no mobile phone state worth asking
        // the OS, or the crew, to grant a permission for.
        final phoneState = await _mobilePhoneStateCheck();
        _mobileServiceState = phoneState.serviceState;
        _mobileDataEnabled = phoneState.dataEnabled;
      } else {
        _mobileServiceState = null;
        _mobileDataEnabled = null;
      }
    } catch (error, stack) {
      // Each individual check already fails open internally (see their
      // shared doc comment) - this is a last-resort net in case a future
      // change to one of them reintroduces an uncaught throw. This is a
      // soft, advisory signal, so swallowing here and keeping whatever
      // was already resolved is correct - it must never propagate and
      // break a caller that isn't expecting it.
      debugPrint('Connectivity radio-state refresh failed: $error\n$stack');
    }
  }

  /// Adaptive poll cadence for a `Timer.periodic`-style caller: short-ish
  /// while online, long once offline (conserve battery/data in a dead
  /// zone).
  Duration get pollInterval {
    switch (_classification) {
      case ConnectivityClass.offline:
        return AppConstants.connectivityPollIntervalOffline;
      case ConnectivityClass.online:
        return AppConstants.connectivityPollIntervalOnline;
    }
  }

  /// Runs one classification cycle and returns the updated [classification]
  /// - purely a function of this tick: no OS interface, no domain to probe,
  /// or the probe failing are all [ConnectivityClass.offline]; an interface
  /// plus a successful probe is [ConnectivityClass.online]. [domain] is the
  /// company domain used to resolve the backend probe target (same as the
  /// existing `AppUtils` connectivity calls).
  Future<ConnectivityClass> check({required String? domain}) async {
    // Refreshed on every call, unconditionally - not just when hasInterface
    // below is false. A multi-radio device (Wi-Fi off, mobile still on as a
    // fallback interface) keeps hasInterface true even with Wi-Fi switched
    // off, so gating this on "no interface at all" left isWifiRadioOn stuck
    // at a stale value whenever some other interface was still up - exactly
    // the case this signal most needs to be right for. These are cheap,
    // mostly permission-free local calls (see refreshRadioState's own doc
    // for the one exception), so paying for them every tick is the correct
    // trade-off for a signal that feeds messaging and is_forced_offline
    // attribution.
    await refreshRadioState();

    final interfaces = await _checkConnectivity();
    _hasOsInterface = interfaces.any(
      (result) => result != ConnectivityResult.none,
    );

    if (!_hasOsInterface) {
      _classification = ConnectivityClass.offline;
      return _classification;
    }

    if (domain == null || domain.isEmpty) {
      _classification = ConnectivityClass.offline;
      return _classification;
    }

    try {
      // Reuses the existing `/utc` probe rather than a dedicated speed
      // test: the transaction payload this all exists to submit is tiny,
      // so raw throughput isn't the real constraint (design §5).
      await AppUtils.resolveOtpBackendConfig(
        domain: domain,
        forceRefresh: true,
        timeout: const Duration(seconds: 5),
      );
      _classification = ConnectivityClass.online;
    } catch (_) {
      _classification = ConnectivityClass.offline;
    }

    return _classification;
  }

  /// Drives the classifier with a synthetic outcome, bypassing
  /// `connectivity_plus`/HTTP entirely — the seam unit tests use to exercise
  /// the classification logic in isolation and deterministically. Not for
  /// production call sites.
  @visibleForTesting
  ConnectivityClass recordSyntheticOutcomeForTesting({
    required bool hasInterface,
    required bool success,
  }) {
    _hasOsInterface = hasInterface;
    _classification = (hasInterface && success)
        ? ConnectivityClass.online
        : ConnectivityClass.offline;
    return _classification;
  }
}
