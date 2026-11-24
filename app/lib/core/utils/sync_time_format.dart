/// Formats a "last synced" timestamp so a stale value can't pass for a fresh
/// one: time only for today, "Yesterday HH:mm" for the previous day, and the
/// full date plus time otherwise. [now] is injectable for tests.
String formatSyncStamp(DateTime value, {DateTime? now}) {
  final local = value.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  final dayDelta = DateTime(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime(local.year, local.month, local.day)).inDays;

  if (dayDelta == 0) {
    return time;
  }
  if (dayDelta == 1) {
    return 'Yesterday $time';
  }
  final date =
      '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
  return '$date $time';
}
