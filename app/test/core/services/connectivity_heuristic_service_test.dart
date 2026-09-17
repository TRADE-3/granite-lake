import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/services/connectivity_heuristic_service.dart';

void main() {
  group('ConnectivityHeuristicService.check — step 1 (radio presence)', () {
    test(
      'no OS interface classifies offline, even with a domain configured to probe',
      () async {
        var checkConnectivityCalls = 0;
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async {
            checkConnectivityCalls += 1;
            return [ConnectivityResult.none];
          },
        );

        // acme.com has no real backend configured in this test environment
        // — if step 2 ran anyway, `AppUtils.resolveOtpBackendConfig` would
        // throw and check()'s catch block would still record a failure, so
        // this alone can't distinguish "step 2 skipped" from "step 2 ran
        // and failed." The skip itself (an early return before the domain
        // check/probe) is verified by reading
        // ConnectivityHeuristicService.check()'s source, not by a runtime
        // assertion here; what this test does verify end-to-end is the
        // step 1 short-circuit's actual output: no interface -> `offline`.
        final result = await service.check(domain: 'acme.com');

        expect(result, ConnectivityClass.offline);
        expect(checkConnectivityCalls, 1);
      },
    );

    test(
      'an active interface but no domain to probe counts as one probe '
      'failure (degraded, not offline) — step 1 alone never forces offline',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.wifi],
        );

        final result = await service.check(domain: null);

        expect(result, ConnectivityClass.degraded);
      },
    );

    // Regression test: on a multi-radio device, turning Wi-Fi off while
    // mobile is still active leaves connectivity_plus reporting an
    // interface throughout (hasInterface never goes false) - so
    // isWifiRadioOn/isConnectivityRuleBroken must be refreshed on every
    // check() call, not only when hasInterface is false, or the Wi-Fi
    // toggle change is silently missed.
    test(
      'refreshes radio state (and picks up Wi-Fi being turned off) even '
      'when another interface (mobile) keeps hasInterface true throughout',
      () async {
        var isWifiRadioOnValue = true;
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.mobile],
          hasActiveSimCheck: () async => true,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => isWifiRadioOnValue,
          mobilePhoneStateCheck: () async => const MobilePhoneState(
            serviceState: 'in_service',
            dataEnabled: true,
          ),
        );

        await service.check(domain: null);
        expect(service.isWifiRadioOn, isTrue);
        expect(service.isConnectivityRuleBroken, isFalse);

        // Crew turns Wi-Fi off - mobile is still active, so
        // connectivity_plus keeps reporting an interface the whole time.
        isWifiRadioOnValue = false;
        await service.check(domain: null);

        expect(service.isWifiRadioOn, isFalse);
        expect(service.isConnectivityRuleBroken, isTrue);
      },
    );
  });

  group('ConnectivityHeuristicService classification (synthetic outcomes)', () {
    late ConnectivityHeuristicService service;

    setUp(() {
      service = ConnectivityHeuristicService(
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );
    });

    test('a single successful, fast probe classifies online', () {
      final result = service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: true,
        latency: const Duration(milliseconds: 200),
      );

      expect(result, ConnectivityClass.online);
    });

    test('no OS interface classifies offline on the very first tick', () {
      final result = service.recordSyntheticOutcomeForTesting(
        hasInterface: false,
        success: false,
      );

      expect(result, ConnectivityClass.offline);
    });

    test(
      'a single probe failure (interface present) classifies degraded, not offline',
      () {
        final result = service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: false,
        );

        expect(result, ConnectivityClass.degraded);
      },
    );

    test('two consecutive probe failures classify offline', () {
      service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: false,
      );
      final result = service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: false,
      );

      expect(result, ConnectivityClass.offline);
    });

    test(
      'a successful probe exceeding the latency threshold classifies degraded',
      () {
        final result = service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(seconds: 3),
        );

        expect(result, ConnectivityClass.degraded);
      },
    );

    test(
      'succeeds but intermittently (a recent failure in the window) classifies degraded, not online',
      () {
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: false,
        );
        final result = service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(milliseconds: 200),
        );

        expect(result, ConnectivityClass.degraded);
      },
    );

    test('recovers to online once the failure ages out of the ring buffer', () {
      service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: false,
      );
      // Ring buffer holds 5 — 5 more clean successes push the one failure out.
      for (var i = 0; i < 5; i++) {
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(milliseconds: 200),
        );
      }

      expect(service.classification, ConnectivityClass.online);
    });
  });

  group('ConnectivityHeuristicService.label hysteresis', () {
    late ConnectivityHeuristicService service;

    setUp(() {
      service = ConnectivityHeuristicService(
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );
    });

    test('label starts offline before any check has run', () {
      expect(service.label, ConnectivityClass.offline);
      expect(service.isOnlineCapable, isFalse);
    });

    test(
      'losing the OS interface entirely flips the label to offline '
      'immediately, bypassing hysteresis - a deterministic signal (the '
      'radio is off), not a noisy probe result, so a crew that turns off '
      'wifi/data must see the app go offline on this tick, not after a '
      'second confirming one',
      () {
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(milliseconds: 200),
        );
        expect(service.label, ConnectivityClass.online);

        service.recordSyntheticOutcomeForTesting(
          hasInterface: false,
          success: false,
        );

        expect(service.classification, ConnectivityClass.offline);
        expect(service.label, ConnectivityClass.offline);
        expect(service.isOnlineCapable, isFalse);
      },
    );

    test(
      'a single opposite-direction classification does not flip the label '
      '(no single-probe flapping)',
      () {
        // The very first classification of a session seeds the label
        // immediately (no debounce) - establish that baseline here as a
        // clean offline reading (via no OS interface, itself an instant,
        // non-debounced seed - see the test above), so this test exercises
        // hysteresis on an *established* label via a genuinely noisy signal
        // (a probe outcome), not the no-interface fast path.
        service.recordSyntheticOutcomeForTesting(
          hasInterface: false,
          success: false,
        );
        expect(service.label, ConnectivityClass.offline);

        // One degraded-classifying tick (high latency - deterministic
        // regardless of ring-buffer history, unlike a plain success) should
        // NOT flip an established label on its own.
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(seconds: 3),
        );

        expect(service.classification, ConnectivityClass.degraded);
        expect(service.label, ConnectivityClass.offline);
      },
    );

    test(
      'two consecutive same-direction classifications flip the label',
      () {
        // Baseline offline reading, same reasoning as above.
        service.recordSyntheticOutcomeForTesting(
          hasInterface: false,
          success: false,
        );
        expect(service.label, ConnectivityClass.offline);

        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(seconds: 3),
        );
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(seconds: 3),
        );

        expect(service.label, ConnectivityClass.degraded);
      },
    );

    test(
      'alternating classifications never accumulate toward a flip — the '
      'streak requires 2 *consecutive identical* classifications, not 2 '
      'ticks that merely disagree with the current label',
      () {
        // Baseline online reading. Deliberately never records a
        // success:false/no-interface outcome anywhere in this test - doing
        // so would linger in the ring buffer and make a later low-latency
        // success tick classify as degraded via the intermittent-success
        // rule instead of online, which would confound the assertions
        // below. Every tick here is success:true, varying only latency.
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(milliseconds: 200),
        );
        expect(service.label, ConnectivityClass.online);

        // tick 1: degraded (1st degraded confirmation attempt).
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(seconds: 3),
        );
        expect(service.classification, ConnectivityClass.degraded);

        // tick 2: back to online - matches the current label directly, so
        // this resets any pending streak rather than extending it (online
        // and degraded aren't the same direction as each other).
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(milliseconds: 200),
        );
        expect(service.classification, ConnectivityClass.online);

        // tick 3: degraded again — only the 1st consecutive degraded
        // confirmation again (tick 2 reset the pending streak), so the
        // label must still not have flipped.
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(seconds: 3),
        );
        expect(service.classification, ConnectivityClass.degraded);

        expect(service.label, ConnectivityClass.online);
      },
    );

    test(
      'the very first classification of a session seeds the label '
      'immediately, with no debounce delay - a freshly opened screen with '
      'real connectivity must not report offline until a second tick '
      'confirms it',
      () {
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
          latency: const Duration(milliseconds: 200),
        );

        expect(service.classification, ConnectivityClass.online);
        expect(service.label, ConnectivityClass.online);
        expect(service.isOnlineCapable, isTrue);
      },
    );
  });

  group('ConnectivityHeuristicService.pollInterval', () {
    test('cadence follows the debounced label, not the raw classification', () {
      final service = ConnectivityHeuristicService(
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );

      // Default label is offline before anything has run.
      expect(service.pollInterval, greaterThan(const Duration(seconds: 60)));

      // Baseline offline reading so the label is already established
      // before exercising hysteresis on the next (differing) tick.
      service.recordSyntheticOutcomeForTesting(
        hasInterface: false,
        success: false,
      );
      expect(service.label, ConnectivityClass.offline);

      service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: false,
      );
      // Raw classification is degraded, but label hasn't flipped yet
      // (still offline) — cadence should reflect the label.
      expect(service.classification, ConnectivityClass.degraded);
      expect(service.label, ConnectivityClass.offline);
    });
  });

  // isConnectivityRuleBroken is a soft, advisory signal (messaging +
  // is_forced_offline attribution), never a block condition - these tests
  // only exercise the signal itself, not capture eligibility.
  group('ConnectivityHeuristicService.isConnectivityRuleBroken', () {
    test(
      'mobilePhoneStateCheck (and its READ_PHONE_STATE prompt) is never '
      'invoked when there is no SIM - nothing to check Mobile Data on',
      () async {
        var mobilePhoneStateCheckCalls = 0;
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => false,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => false,
          mobilePhoneStateCheck: () async {
            mobilePhoneStateCheckCalls += 1;
            return const MobilePhoneState(
              serviceState: 'in_service',
              dataEnabled: true,
            );
          },
        );

        await service.refreshRadioState();

        expect(mobilePhoneStateCheckCalls, 0);
        expect(service.mobileServiceState, isNull);
        expect(service.isMobileDataEnabled, isNull);
      },
    );

    test(
      'Wi-Fi on, airplane mode off, no SIM - rule satisfied even though '
      'nothing is actually reachable (a genuine dead zone, not a rule '
      'break)',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => false,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => true,
          mobilePhoneStateCheck: () async =>
              const MobilePhoneState(serviceState: null, dataEnabled: null),
        );

        final result = await service.check(domain: 'acme.com');

        expect(result, ConnectivityClass.offline);
        expect(service.isWifiRadioOn, isTrue);
        expect(service.isConnectivityRuleBroken, isFalse);
      },
    );

    test('airplane mode on is always a rule break', () async {
      final service = ConnectivityHeuristicService(
        checkConnectivity: () async => [ConnectivityResult.none],
        hasActiveSimCheck: () async => false,
        isAirplaneModeOnCheck: () async => true,
        isWifiRadioOnCheck: () async => false,
        mobilePhoneStateCheck: () async =>
            const MobilePhoneState(serviceState: null, dataEnabled: null),
      );

      await service.check(domain: 'acme.com');

      expect(service.isConnectivityRuleBroken, isTrue);
    });

    test(
      'Wi-Fi off, no SIM is a rule break - nothing else could possibly work',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => false,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => false,
          mobilePhoneStateCheck: () async =>
              const MobilePhoneState(serviceState: null, dataEnabled: null),
        );

        await service.check(domain: 'acme.com');

        expect(service.isConnectivityRuleBroken, isTrue);
      },
    );

    test(
      'Wi-Fi off, SIM present, Mobile Data confirmed off is a rule break',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => true,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => false,
          mobilePhoneStateCheck: () async =>
              const MobilePhoneState(serviceState: null, dataEnabled: false),
        );

        await service.check(domain: 'acme.com');

        expect(service.isMobileDataEnabled, isFalse);
        expect(service.isConnectivityRuleBroken, isTrue);
      },
    );

    test(
      'Wi-Fi on, SIM present, Mobile Data confirmed off is still a rule '
      'break - Wi-Fi alone does not excuse a SIM whose data is off',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => true,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => true,
          mobilePhoneStateCheck: () async =>
              const MobilePhoneState(serviceState: null, dataEnabled: false),
        );

        await service.check(domain: 'acme.com');

        expect(service.isMobileDataEnabled, isFalse);
        expect(service.isConnectivityRuleBroken, isTrue);
      },
    );

    test(
      'Wi-Fi off is a rule break even with SIM present and Mobile Data '
      'confirmed on - Wi-Fi is mandatory by rule, cellular is never a '
      'substitute for it being off',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => true,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => false,
          mobilePhoneStateCheck: () async => const MobilePhoneState(
            serviceState: 'out_of_service',
            dataEnabled: true,
          ),
        );

        await service.check(domain: 'acme.com');

        expect(service.isMobileDataEnabled, isTrue);
        expect(service.isConnectivityRuleBroken, isTrue);
      },
    );

    test(
      'Wi-Fi on, SIM present, Mobile Data unknown (READ_PHONE_STATE not '
      'granted) is not treated as a rule break - never over-claims a '
      'deliberate setting from an unreadable signal',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => true,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async => true,
          mobilePhoneStateCheck: () async =>
              const MobilePhoneState(serviceState: null, dataEnabled: null),
        );

        await service.check(domain: 'acme.com');

        expect(service.isMobileDataEnabled, isNull);
        expect(service.isConnectivityRuleBroken, isFalse);
      },
    );

    test(
      'a native check throwing a non-PlatformException error still lets '
      'check() complete, failing open rather than crashing',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.none],
          hasActiveSimCheck: () async => false,
          isAirplaneModeOnCheck: () async => false,
          isWifiRadioOnCheck: () async =>
              throw Exception('simulated MissingPluginException'),
          mobilePhoneStateCheck: () async =>
              const MobilePhoneState(serviceState: null, dataEnabled: null),
        );

        final result = await service.check(domain: 'acme.com');

        expect(result, ConnectivityClass.offline);
        // Falls back to the fail-open default (true) rather than crashing
        // or leaving the field in some undefined state.
        expect(service.isWifiRadioOn, isTrue);
      },
    );
  });
}
