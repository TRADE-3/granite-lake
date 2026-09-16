import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../constants/app_constants.dart';
import '../database/dao/config_dao.dart';
import '../database/dao/photo_capture_dao.dart';
import '../database/dao/uploaded_file_dao.dart';
import '../database/granite_lake_database_service.dart';

/// T3 brand purple (matches --accent in the web verification portal), used
/// to tint the notification's small-icon background on Android versions
/// that render one.
const Color _reconnectNotificationAccentColor = Color(0xFF3B128D);

/// Background reconnect watchdog (offline-capture design doc §7.2).
///
/// The in-app queue sweep (`GraniteLakeController.retryPendingAttestations`)
/// only ever runs while the app process is alive - if a crew closes the app
/// while captures are queued, nothing tells them when it's safe to come back
/// and unlock. This service registers an OS-level job (Android WorkManager,
/// via the `workmanager` plugin) that wakes up on a ~15-minute cadence only
/// while connectivity is available, checks the local queue read-only, and
/// fires a local notification if anything is still waiting - debounced so a
/// flaky connection doesn't renotify every wakeup.
///
/// This never signs or submits anything from the background isolate: it has
/// no access to the in-memory Sui signing session (§7.1), which only ever
/// lives in the foreground app's memory, and (once §7.3's at-rest encryption
/// lands) no access to the decrypt key either, since that demands an
/// interactive biometric prompt the background isolate has no UI to raise.
@pragma('vm:entry-point')
void reconnectNotificationCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != AppConstants.reconnectNotificationTaskName) {
      return true;
    }
    await ReconnectNotificationService._checkAndNotify();
    return true;
  });
}

class ReconnectNotificationService {
  ReconnectNotificationService._();

  static final ReconnectNotificationService instance =
      ReconnectNotificationService._();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _taskScheduled = false;

  /// Sets up the background job runner and the local notifications plugin.
  /// [onNotificationTapped] is invoked (in the foreground app) when the
  /// crew taps the reminder - wire it to open the history screen's existing
  /// "unlock to submit" call to action (§9), not a new UI.
  Future<void> initialize({required VoidCallback onNotificationTapped}) async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    await Workmanager().initialize(reconnectNotificationCallbackDispatcher);

    const androidInit = AndroidInitializationSettings(
      AppConstants.reconnectNotificationIcon,
    );
    await _notifications.initialize(
      settings: const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (_) => onNotificationTapped(),
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  /// Schedules or cancels the background watchdog to match whether there's
  /// currently anything queued. Idempotent and cheap to call on every
  /// controller change - only actually registers/cancels the OS job on a
  /// transition, so call it freely from a `ChangeNotifier` listener.
  Future<void> syncSchedule({required bool hasPendingSubmissions}) async {
    if (!_initialized) {
      return;
    }

    if (hasPendingSubmissions && !_taskScheduled) {
      _taskScheduled = true;
      // Fast path: fires as soon as connectivity is available, no 15-minute
      // floor - this is what actually catches "just reconnected."
      await Workmanager().registerOneOffTask(
        AppConstants.reconnectNotificationImmediateTaskUniqueName,
        AppConstants.reconnectNotificationTaskName,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );
      // Durable backstop: Android won't run a periodic task's first
      // execution immediately, but this keeps checking every ~15 minutes
      // for as long as the queue stays non-empty, covering a reconnect
      // that happens after the one-off task above has already been
      // consumed (e.g. the app was relaunched and re-queued something new
      // without the queue ever fully draining).
      await Workmanager().registerPeriodicTask(
        AppConstants.reconnectNotificationPeriodicTaskUniqueName,
        AppConstants.reconnectNotificationTaskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } else if (!hasPendingSubmissions && _taskScheduled) {
      _taskScheduled = false;
      await Workmanager().cancelByUniqueName(
        AppConstants.reconnectNotificationImmediateTaskUniqueName,
      );
      await Workmanager().cancelByUniqueName(
        AppConstants.reconnectNotificationPeriodicTaskUniqueName,
      );
      await _notifications.cancel(id: AppConstants.reconnectNotificationId);
    }
  }

  /// Runs inside the background isolate (and is also safe to call from the
  /// foreground for manual testing). Read-only: counts queued rows across
  /// both tables, debounces against the last time a notification actually
  /// fired, and self-cancels the OS job once nothing is queued so a stale
  /// job doesn't keep waking the device after the crew already submitted
  /// via the foreground app.
  static Future<void> _checkAndNotify() async {
    final databaseService = GraniteLakeDatabaseService();
    final photoCaptureDao = PhotoCaptureDao(databaseService);
    final uploadedFileDao = UploadedFileDao(databaseService);
    final configDao = ConfigDao(databaseService);

    final pendingCount =
        await photoCaptureDao.countPendingSubmissions() +
        await uploadedFileDao.countPendingSubmissions();

    if (pendingCount == 0) {
      await Workmanager().cancelByUniqueName(
        AppConstants.reconnectNotificationImmediateTaskUniqueName,
      );
      await Workmanager().cancelByUniqueName(
        AppConstants.reconnectNotificationPeriodicTaskUniqueName,
      );
      return;
    }

    final lastSentRaw = await configDao.readValue(
      AppConstants.reconnectNotificationLastSentConfigKey,
    );
    final lastSentMs = int.tryParse(lastSentRaw ?? '');
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final debounceMs =
        AppConstants.reconnectNotificationDebounceMinutes * 60 * 1000;
    if (lastSentMs != null && nowMs - lastSentMs < debounceMs) {
      return;
    }

    final backgroundNotifications = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings(
      AppConstants.reconnectNotificationIcon,
    );
    await backgroundNotifications.initialize(
      settings: const InitializationSettings(android: androidInit),
    );

    final captureWord = pendingCount == 1 ? 'capture' : 'captures';
    await backgroundNotifications.show(
      id: AppConstants.reconnectNotificationId,
      title: 'Ready to submit',
      body: '$pendingCount $captureWord queued - unlock Trade3 to submit.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          AppConstants.reconnectNotificationChannelId,
          AppConstants.reconnectNotificationChannelName,
          channelDescription:
              AppConstants.reconnectNotificationChannelDescription,
          icon: AppConstants.reconnectNotificationIcon,
          color: _reconnectNotificationAccentColor,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );

    await configDao.writeValue(
      AppConstants.reconnectNotificationLastSentConfigKey,
      nowMs.toString(),
    );
  }
}
