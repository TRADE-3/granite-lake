import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/constants/app_constants.dart';
import 'core/services/connectivity_heuristic_service.dart';
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_connectivityChangeSubscription?.cancel());
    _queuePollTimer?.cancel();
    _controller.dispose();
    super.dispose();
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
