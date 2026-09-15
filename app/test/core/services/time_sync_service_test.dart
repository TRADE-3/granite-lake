import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/services/time_sync_service.dart';
import 'package:trusted_time/trusted_time.dart';

void main() {
  late TrustedTimeMock mock;
  late TimeSyncService service;

  setUp(() {
    mock = TrustedTimeMock(initial: DateTime.utc(2026, 1, 1, 12));
    TrustedTime.overrideForTesting(mock);
    service = TimeSyncService();
  });

  tearDown(() {
    TrustedTime.resetOverride();
    mock.dispose();
  });

  group('TimeSyncService.nowUtc', () {
    test('tier 1: returns the trusted time and reports fresh provenance when trusted', () {
      final result = service.nowUtc();

      expect(result, mock.now);
      expect(service.provenance, TimeProvenance.fresh);
    });

    test(
      'tier 2: falls back to the degraded estimate and reports stale provenance '
      'when untrusted but a reboot anchor exists to extrapolate from',
      () {
        mock.simulateReboot();
        mock.advanceTime(const Duration(hours: 1));

        final result = service.nowUtc();

        expect(result, mock.now);
        expect(service.provenance, TimeProvenance.stale);
      },
    );

    test(
      'tier 3: falls back to the raw device clock and reports neverSynced provenance '
      'when untrusted with nothing to extrapolate from',
      () {
        mock.setTrusted(false);

        final before = DateTime.now().toUtc();
        final result = service.nowUtc();
        final after = DateTime.now().toUtc();

        expect(result.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
        expect(result.isBefore(after.add(const Duration(seconds: 1))), isTrue);
        expect(service.provenance, TimeProvenance.neverSynced);
      },
    );

    test('provenance transitions across tiers as trust state changes on the same instance', () {
      expect(service.nowUtc(), mock.now);
      expect(service.provenance, TimeProvenance.fresh);

      mock.simulateReboot();
      service.nowUtc();
      expect(service.provenance, TimeProvenance.stale);

      mock.restoreTrust();
      expect(service.nowUtc(), mock.now);
      expect(service.provenance, TimeProvenance.fresh);
    });

    test('provenance defaults to neverSynced before nowUtc has ever been called', () {
      expect(service.provenance, TimeProvenance.neverSynced);
    });
  });
}
