import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/utils/sync_time_format.dart';

void main() {
  final now = DateTime(2026, 11, 24, 18, 12);

  test('same day shows time only', () {
    expect(formatSyncStamp(DateTime(2026, 11, 24, 9, 5), now: now), '09:05');
  });

  test('previous day is labelled Yesterday', () {
    expect(
      formatSyncStamp(DateTime(2026, 11, 23, 23, 59), now: now),
      'Yesterday 23:59',
    );
  });

  test('older values show the full date', () {
    expect(
      formatSyncStamp(DateTime(2026, 11, 1, 7, 30), now: now),
      '2026-11-01 07:30',
    );
  });
}
