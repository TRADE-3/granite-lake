import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/constants/app_constants.dart';
import 'core/services/connectivity_heuristic_service.dart';
import 'core/services/reconnect_notification_service.dart';
import 'core/state/granite_lake_controller.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class GraniteLakeApp extends StatefulWidget {
  const GraniteLakeApp({super.key});

  @override
  State<GraniteLakeApp> createState() => _GraniteLakeAppState();
}

class _GraniteLakeAppState extends State<GraniteLakeApp>
    with WidgetsBindingObserver {
  late final GraniteLakeController _controller;
  late final GoRouter _router;
  // App-wide, lives for the whole session - the capture screen has its own
  // instance for its live readiness UI, but that one stops listening the
  // moment the crew navigates away from it (its dispose() cancels the
  // subscription). Retrying the PENDING_SUBMISSION queue when connectivity
  // returns must not depend on which screen happens to be open, so this
  // instance/subscription is owned here instead.
  final ConnectivityHeuristicService _connectivityService =
      ConnectivityHeuristicService();
  StreamSubscription<List<ConnectivityResult>>? _connectivityChangeSubscription;
  // Fallback for when the OS connectivity-change broadcast doesn't fire
  // reliably (seen on some emulators/OEM builds) - cheap no-op via
  // _checkConnectivityAndRetryQueue's early return whenever nothing is
  // actually queued, so this isn't a meaningful battery/data cost.
  Timer? _queuePollTimer;
  // Offline-capture design doc §7.2 - nudges the crew while the app is
  // closed/backgrounded. Lives here, not on the controller, since it owns
  // OS-level (WorkManager) and plugin (local notifications) state that
  // shouldn't leak into app-state/business-logic code.
  final ReconnectNotificationService _reconnectNotificationService =
      ReconnectNotificationService.instance;

  @override
  void initState() {
    super.initState();
    _controller = GraniteLakeController()..initialize();
    _router = createAppRouter(_controller);
    WidgetsBinding.instance.addObserver(this);
    _connectivityChangeSubscription = Connectivity().onConnectivityChanged
        .listen((_) {
          unawaited(_checkConnectivityAndRetryQueue());
        });
    _queuePollTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_checkConnectivityAndRetryQueue());
    });
    unawaited(_startReconnectNotificationService());
    _controller.addListener(_syncReconnectNotificationSchedule);
  }

  // Deferred past the first frame, not fired synchronously here: this is
  // the very first moment of the app's life, while the native splash
  // screen is still mid-exit-transition and GoRouter's redirect is
  // actively hopping through boot -> localDataInit -> (onboarding or
  // dashboard) as _controller's async initialize() resolves each step
  // (see app_router.dart's redirect, driven by refreshListenable:
  // controller). Requesting POST_NOTIFICATIONS synchronously into that
  // churn is the same failure mode confirmed on-device for the capture
  // screen's location permission (capture_screen.dart's initState): a
  // system permission dialog competing with active window/surface/route
  // transitions for the Activity's focus can silently fail to render at
  // all. The settle delay after the first frame is a deliberate trade-off
  // for a still-upfront, once-per-launch request - it's not a signal tied
  // to any specific redirect hop (which, for a brand-new install walking
  // through onboarding, can take far longer than any fixed delay), just
  // enough for the splash-exit animation and boot's near-instant first
  // redirect to clear before the dialog is requested.
  Future<void> _startReconnectNotificationService() async {
    final firstFrame = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => firstFrame.complete());
    await firstFrame.future;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) {
      return;
    }
    await _reconnectNotificationService
        .initialize(
          onNotificationTapped: () =>
              _router.go('${AppRoutes.dashboard}?tab=0'),
        )
        // initialize() is async; the controller can finish loading
        // pending rows and fire its own notifyListeners() before this
        // resolves, which would otherwise make the first
        // _syncReconnectNotificationSchedule() call no-op (it's guarded
        // on being initialized) and silently drop an already-queued
        // capture from being watched. Re-sync once initialize() actually
        // lands to catch that case.
        .then((_) => _syncReconnectNotificationSchedule());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_connectivityChangeSubscription?.cancel());
    _queuePollTimer?.cancel();
    _controller.removeListener(_syncReconnectNotificationSchedule);
    _controller.dispose();
    super.dispose();
  }

  void _syncReconnectNotificationSchedule() {
    unawaited(
      _reconnectNotificationService.syncSchedule(
        hasPendingSubmissions: _controller.pendingAttestationCount > 0,
      ),
    );
  }

  Future<void> _checkConnectivityAndRetryQueue() async {
    if (_controller.pendingAttestationCount == 0) {
      return;
    }
    // Retry whenever there's pending work and we're currently online -
    // not just on an offline->online *edge* transition. A row can end up
    // PENDING_SUBMISSION for reasons that have nothing to do with the
    // device ever having gone offline (a transient gas-coin-version race,
    // a brief GraphQL hiccup) - if the device was online the whole time,
    // that edge never fires, and this sweep would otherwise never run
    // again for that row until something else (foreground, a real
    // connectivity drop-and-restore, or a manual retry) happened to
    // trigger it. retryPendingAttestations() already guards its own
    // re-entrancy and is cheap to call when nothing needs it.
    final domain = _controller.employee?.companyDomain;
    await _connectivityService.check(domain: domain);
    if (_connectivityService.isOnlineCapable) {
      unawaited(_controller.retryPendingAttestations());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Offline-capture design doc §7: app foreground/resume is one of two
    // triggers (alongside the capture screen's connectivity transition) for
    // sweeping the PENDING_SUBMISSION queue - fires even when the capture
    // screen isn't mounted. A no-op when there's no active session or
    // nothing queued (retryPendingAttestations() guards both itself).
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.retryPendingAttestations());
    }
  }

  @override
  Widget build(BuildContext context) {
    return GraniteLakeScope(
      controller: _controller,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => MaterialApp.router(
          title: AppConstants.appTitle,
          debugShowCheckedModeBanner: false,
          theme: _controller.isDarkMode ? AppTheme.dark : AppTheme.light,
          routerConfig: _router,
        ),
      ),
    );
  }
}

class GraniteLakeScope extends InheritedNotifier<GraniteLakeController> {
  const GraniteLakeScope({
    super.key,
    required GraniteLakeController controller,
    required super.child,
  }) : super(notifier: controller);

  static GraniteLakeController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<GraniteLakeScope>();
    assert(scope != null, 'GraniteLakeScope not found in widget tree.');
    return scope!.notifier!;
  }
}
