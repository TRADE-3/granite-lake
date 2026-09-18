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
      'an active interface but no domain to probe classifies offline - '
      'nothing to probe means step 2 cannot confirm online',
      () async {
        final service = ConnectivityHeuristicService(
          checkConnectivity: () async => [ConnectivityResult.wifi],
        );

        final result = await service.check(domain: null);

        expect(result, ConnectivityClass.offline);
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

    test('a successful probe classifies online', () {
      final result = service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: true,
      );

      expect(result, ConnectivityClass.online);
      expect(service.isOnlineCapable, isTrue);
    });

    test('no OS interface classifies offline', () {
      final result = service.recordSyntheticOutcomeForTesting(
        hasInterface: false,
        success: false,
      );

      expect(result, ConnectivityClass.offline);
    });

    test('an interface present but a failed probe classifies offline', () {
      final result = service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: false,
      );

      expect(result, ConnectivityClass.offline);
    });

    test(
      'classification reflects only the most recent tick, with no memory '
      'of earlier failures - a probe recovering immediately reads online',
      () {
        service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: false,
        );
        expect(service.classification, ConnectivityClass.offline);

        final result = service.recordSyntheticOutcomeForTesting(
          hasInterface: true,
          success: true,
        );

        expect(result, ConnectivityClass.online);
        expect(service.isOnlineCapable, isTrue);
      },
    );
  });

  group('ConnectivityHeuristicService.pollInterval', () {
    test('cadence follows the current classification', () {
      final service = ConnectivityHeuristicService(
        checkConnectivity: () async => [ConnectivityResult.wifi],
      );

      // Default classification is offline before anything has run.
      expect(service.pollInterval, greaterThan(const Duration(seconds: 60)));

      service.recordSyntheticOutcomeForTesting(
        hasInterface: true,
        success: true,
      );
      expect(
        service.pollInterval,
        lessThan(const Duration(seconds: 60)),
      );

      service.recordSyntheticOutcomeForTesting(
        hasInterface: false,
        success: false,
      );
      expect(service.pollInterval, greaterThan(const Duration(seconds: 60)));
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
