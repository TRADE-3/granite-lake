import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/state/granite_lake_controller.dart';
import '../../features/capture/screens/capture_screen.dart';
import '../../features/capture/screens/capture_method_screen.dart';
import '../../features/capture/screens/file_attestation_screen.dart';
import '../../features/history/screens/capture_detail_screen.dart';
import '../../features/profile/screens/recovery_key_screen.dart';
import '../../features/shell/screens/main_shell.dart';
import '../../features/system/screens/boot_screen.dart';
import '../../features/system/screens/local_data_init_screen.dart';
import '../../features/trade3/screens/trade3_pairing_screen.dart';
import '../../features/onboarding/screens/biometric_setup_screen.dart';
import '../../features/onboarding/screens/identity_setup_screen.dart';
import '../../features/onboarding/screens/welcome_screen.dart';

abstract final class AppRoutes {
  static const String boot = '/boot';
  static const String localDataInit = '/local-data-init';
  static const String welcome = '/';
  static const String identitySetup = '/identity-setup';
  static const String biometricSetup = '/biometric-setup';
  static const String dashboard = '/dashboard';
  static const String capture = '/capture';
  static const String capturePhoto = '/capture/photo';
  static const String captureFile = '/capture/file';
  static const String historyDetail = '/history-detail';
  static const String pair = '/pair';
  static const String recoveryKey = '/recovery-key';
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

      // Biometric binding is checked before registration: the identity's
      // raw signing key exists unprotected in storage from the moment it's
      // created until it's wrapped by the hardware-backed biometric gate,
      // so that gate is created as early in the flow as possible rather
      // than after registration's out-of-band code wait.
      if (!controller.isBiometricBound) {
        return location == AppRoutes.biometricSetup ||
                location == AppRoutes.identitySetup
            ? null
            : AppRoutes.biometricSetup;
      }

      // Linking Trade3 is how an account is registered.
      if (controller.mustSaveRecoveryKey) {
        return location == AppRoutes.recoveryKey ? null : AppRoutes.recoveryKey;
      }
      if (!controller.hasCompletedRegistration) {
        return location == AppRoutes.pair || location == AppRoutes.recoveryKey
            ? null
            : AppRoutes.pair;
      }

      // A Trade3 pairing code can arrive via deep link at any point of
      // onboarding (fresh install opened straight from a QR code). It waits
      // as "pending" until the pairing screen takes over; the screen consumes
      // it, so this cannot loop.
      if (controller.pendingTrade3PairingCode != null &&
          location != AppRoutes.pair) {
        return AppRoutes.pair;
      }

      final isCaptureRoute =
          location == AppRoutes.capture ||
          location == AppRoutes.capturePhoto ||
          location == AppRoutes.captureFile;
      if (isCaptureRoute && controller.isAttestationBlocked) {
        return AppRoutes.pair;
      }
      if (isCaptureRoute && !controller.hasActiveSession) {
        return AppRoutes.dashboard;
      }

      if (location == AppRoutes.boot ||
          location == AppRoutes.localDataInit ||
          location == AppRoutes.welcome ||
          location == AppRoutes.identitySetup ||
          location == AppRoutes.biometricSetup) {
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
        path: AppRoutes.pair,
        pageBuilder: (context, state) => NoTransitionPage(
          child: Trade3PairingScreen(
            routeCode: state.uri.queryParameters['code'],
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.recoveryKey,
        pageBuilder: (context, state) =>
            const MaterialPage(child: RecoveryKeyScreen()),
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
          return NoTransitionPage(
            key: ValueKey('dashboard-$initialTab'),
            child: MainShell(
              key: ValueKey('dashboard-shell-$initialTab'),
              initialTab: initialTab,
            ),
          );
        },
      ),
      GoRoute(
        path: AppRoutes.capture,
        pageBuilder: (context, state) =>
            const MaterialPage(child: CaptureMethodScreen()),
      ),
      GoRoute(
        path: AppRoutes.capturePhoto,
        pageBuilder: (context, state) =>
            const MaterialPage(child: CaptureScreen()),
      ),
      GoRoute(
        path: AppRoutes.captureFile,
        pageBuilder: (context, state) =>
            const MaterialPage(child: FileAttestationScreen()),
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

AttestationRecord _resolveCaptureRecord(Object? extra) {
  if (extra is AttestationRecord) {
    return extra;
  }
  if (extra is Map<String, dynamic>) {
    return AttestationRecord.fromJson(extra);
  }
  if (extra is Map) {
    return AttestationRecord.fromJson(Map<String, dynamic>.from(extra));
  }
  throw ArgumentError(
    'History detail route expected a AttestationRecord or serialized map, got ${extra.runtimeType}.',
  );
}
