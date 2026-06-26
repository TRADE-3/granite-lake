import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/constants/app_constants.dart';
import 'core/state/granite_lake_controller.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

class GraniteLakeApp extends StatefulWidget {
  const GraniteLakeApp({super.key});

  @override
  State<GraniteLakeApp> createState() => _GraniteLakeAppState();
}

class _GraniteLakeAppState extends State<GraniteLakeApp> {
  late final GraniteLakeController _controller;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _controller = GraniteLakeController()..initialize();
    _router = createAppRouter(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
