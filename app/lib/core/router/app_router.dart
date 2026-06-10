import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/state/granite_lake_controller.dart';
import '../../features/capture/screens/capture_screen.dart';
import '../../features/history/screens/capture_detail_screen.dart';
import '../../features/shell/screens/main_shell.dart';
import '../../features/system/screens/boot_screen.dart';
import '../../features/system/screens/local_data_init_screen.dart';
import '../../features/onboarding/screens/biometric_setup_screen.dart';
import '../../features/onboarding/screens/identity_setup_screen.dart';
import '../../features/onboarding/screens/welcome_screen.dart';
import '../../features/onboarding/screens/registration_screen.dart';

abstract final class AppRoutes {
  static const String boot = '/boot';
  static const String localDataInit = '/local-data-init';
  static const String welcome = '/';
  static const String registration = '/registration';
  static const String identitySetup = '/identity-setup';
  static const String biometricSetup = '/biometric-setup';
  static const String dashboard = '/dashboard';
  static const String capture = '/capture';
  static const String historyDetail = '/history-detail';
}

GoRouter createAppRouter(GraniteLakeController controller) {
  return GoRouter(
    initialLocation: AppRoutes.boot,
    debugLogDiagnostics: false,
    refreshListenable: controller,
    redirect: (context, state) {
      final location = state.matchedLocation;
      if (controller.isInitializing || controller.initializationError != null) {
        return location == AppRoutes.boot ? null : AppRoutes.boot;
      }

      if (controller.requiresLocalDataInitialization) {
        return location == AppRoutes.localDataInit
            ? null
            : AppRoutes.localDataInit;
      }

      if (!controller.hasIdentity) {
        return location == AppRoutes.welcome ||
                location == AppRoutes.identitySetup
            ? null
            : AppRoutes.identitySetup;
      }

      if (!controller.hasCompletedRegistration) {
        return location == AppRoutes.registration ||
                location == AppRoutes.identitySetup
            ? null
            : AppRoutes.registration;
      }

      if (!controller.isBiometricBound) {
        return location == AppRoutes.biometricSetup
            ? null
            : AppRoutes.biometricSetup;
      }

      if (location == AppRoutes.capture && !controller.hasActiveSession) {
        return AppRoutes.dashboard;
      }

      if (location == AppRoutes.boot ||
          location == AppRoutes.localDataInit ||
          location == AppRoutes.welcome ||
          location == AppRoutes.identitySetup ||
          location == AppRoutes.biometricSetup ||
          location == AppRoutes.registration) {
        return AppRoutes.dashboard;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.boot,
        pageBuilder: (context, state) =>
            NoTransitionPage(child: BootScreen(controller: controller)),
      ),
      GoRoute(
        path: AppRoutes.localDataInit,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: LocalDataInitScreen()),
      ),
      GoRoute(
        path: AppRoutes.welcome,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: WelcomeScreen()),
      ),
      GoRoute(
        path: AppRoutes.registration,
        pageBuilder: (context, state) =>
            const MaterialPage(child: RegistrationScreen()),
      ),
      GoRoute(
        path: AppRoutes.identitySetup,
        pageBuilder: (context, state) =>
            const MaterialPage(child: IdentitySetupScreen()),
      ),
      GoRoute(
        path: AppRoutes.biometricSetup,
        pageBuilder: (context, state) =>
            const MaterialPage(child: BiometricSetupScreen()),
      ),
      GoRoute(
        path: AppRoutes.dashboard,
        pageBuilder: (context, state) {
          final requestedTab =
              int.tryParse(state.uri.queryParameters['tab'] ?? '') ?? 1;
          final initialTab = requestedTab >= 0 && requestedTab <= 3
              ? requestedTab
              : 1;
          return NoTransitionPage(child: MainShell(initialTab: initialTab));
        },
      ),
      GoRoute(
        path: AppRoutes.capture,
        pageBuilder: (context, state) =>
            const MaterialPage(child: CaptureScreen()),
      ),
      GoRoute(
        path: AppRoutes.historyDetail,
        pageBuilder: (context, state) {
          final record = _resolveCaptureRecord(state.extra);
          return MaterialPage(child: CaptureDetailScreen(record: record));
        },
      ),
    ],
  );
}

CaptureRecord _resolveCaptureRecord(Object? extra) {
  if (extra is CaptureRecord) {
    return extra;
  }
  if (extra is Map<String, dynamic>) {
    return CaptureRecord.fromJson(extra);
  }
  if (extra is Map) {
    return CaptureRecord.fromJson(Map<String, dynamic>.from(extra));
  }
  throw ArgumentError(
    'History detail route expected a CaptureRecord or serialized map, got ${extra.runtimeType}.',
  );
}
