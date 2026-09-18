import 'dart:convert';

/// A single domain's backend routing + credential, resolved from
/// [AppConstants.otpBackendConfig].
class DomainBackendConfig {
  const DomainBackendConfig({required this.url, required this.apiKey});

  final String url;
  final String apiKey;
}

/// Applies the same on-chain-submission fallback substitution used by
/// attestation submission, so verification recomputes against the same
/// value instead of comparing the substituted chain value against a raw
/// null/empty local field.
String resolveAttestationLabel(String? value, {required String fallback}) {
  final trimmed = value?.trim();
  return trimmed != null && trimmed.isNotEmpty ? trimmed : fallback;
}

abstract final class AppConstants {
  // ── Attestation label fallbacks ───────────────────────────────────────────
  static const String attestationUnknownLabel = 'UNKNOWN';
  static const String attestationUnassignedLabel = 'UNASSIGNED';

  // ── Reconnect notification (offline-capture design doc §7.2) ──────────────
  // Background watchdog that nudges the crew to unlock and submit once
  // connectivity returns while the app is closed/backgrounded - the queue
  // sweep itself (retryPendingAttestations) only ever runs in the
  // foreground, so this is strictly check-and-notify, never signs anything.
  // Android's periodic-task floor is 15 minutes, and the *first* run of a
  // freshly-registered periodic task is not immediate - it can lag a full
  // period behind registration. A one-off task has no such floor and fires
  // as soon as its constraint is met, so both are registered together:
  // the one-off catches the immediate/first reconnect, the periodic one
  // is the durable backstop for a later reconnect after the app was
  // relaunched and the one-off was consumed.
  static const String reconnectNotificationImmediateTaskUniqueName =
      'granite_lake_reconnect_watch_immediate';
  static const String reconnectNotificationPeriodicTaskUniqueName =
      'granite_lake_reconnect_watch_periodic';
  static const String reconnectNotificationTaskName =
      'granite_lake_reconnect_check';
  static const String reconnectNotificationChannelId = 'granite_lake_reconnect';
  static const String reconnectNotificationChannelName = 'Submission reminders';
  static const String reconnectNotificationChannelDescription =
      'Reminds you to unlock and submit captures queued while offline.';
  static const int reconnectNotificationId = 7301;
  // Bare Android drawable resource name (android/app/src/main/res/
  // drawable-*/ic_stat_reconnect.png) - a white-on-transparent silhouette
  // of the T3 mark, generated from assets/logos/trade3/
  // trade3_icon_foreground.png. Deliberately NOT the launcher mipmap: a
  // full-color, fully-opaque launcher icon has no meaningful alpha shape,
  // so Android's notification-icon renderer (which draws only the alpha
  // channel, in white) would show a solid blob instead of the T3 mark.
  static const String reconnectNotificationIcon = 'ic_stat_reconnect';
  static const String reconnectNotificationLastSentConfigKey =
      'reconnect_notification_last_sent_at_ms';
  static const int reconnectNotificationDebounceMinutes = 30;

  // ── App meta ───────────────────────────────────────────────────────────────
  static const String appName = 'TRADE3';
  static const String appTitle = 'Trade3';
  static const String appVersion = 'V1.0';
  static const String walletCreateAsset = 'assets/images/wallet_create.png';
  static const int captureSessionDurationMinutes = 30;
  // Offline-queue at-rest encryption (offline-capture design doc §7.3,
  // intentionally modified from the doc's original no-caching design):
  // independent of, and shorter than, captureSessionDurationMinutes above -
  // governs how long a batch-decrypted queue payload cache stays in memory
  // after one "unlock to submit" prompt before it's destroyed and a fresh
  // unlock is required.
  static const int queueUnlockDurationMinutes = 5;
  static const String captureDirectoryName = 'captures';

  // ── Onboarding ─────────────────────────────────────────────────────────────
  static const String welcomeFlowId = 'ONBOARDING_FLOW_V1.0';
  static const String welcomeStatus = 'READY';
  static const String welcomeEncryptMode = 'DEVICE_TRUST';
  static const String welcomeDisplayId = 'FIELD_CAPTURE_INIT';

  static const String registrationFlowId = 'ACCESS_CONTROL_V1.0';
  static const String registrationStatus = 'SUI_CLAIM';
  static const String registrationEncryptMode = 'PHOTO_ATTESTATION';
  static const String registrationDisplayId = 'USER_CAP_CLAIM';

  static const String identityFlowId = 'IDENTITY_BINDING_V1.0';
  static const String identityStatus = 'KEYPAIR_SETUP';
  static const String identityEncryptMode = 'SUI_KEYPAIR';

  static const String biometricFlowId = 'IDENTITY_BINDING_V1.0';
  static const String biometricStatus = 'BIOMETRIC_STEP';
  static const String biometricEncryptMode = 'SECURE_ENCLAVE';

  static const String defaultSuiRpcUrl =
      'https://graphql.testnet.sui.io/graphql';
  static const String suiTestnetFaucetUrl =
      'https://faucet.sui.io/?network=testnet';

  // OTP / UTC backend configuration.
  //
  // One backend stack is deployed per domain, and each app build serves
  // exactly one client's domain, so production builds embed a single
  // {domain, url, apiKey} object rather than a map covering several
  // tenants. Earlier this was a per-domain map so one build could carry
  // several tenants' credentials at once; extracting the compiled app (see
  // the Security note below) would then have handed over every tenant's
  // key in one string instead of just this build's own. Production builds
  // MUST set GL_OTP_BACKEND_CONFIG. The resolver in `core/utils/utils.dart`
  // will refuse to talk to any domain other than the one configured here.
  //
  // Security: Phase 1 only. The connection is secured by TLS (HTTPS), and
  // apiKey stops opportunistic/scripted callers, but a value embedded in a
  // compiled app is extractable via decompilation or by proxying the app's
  // own traffic \u2014 it does not prove a request came from an unmodified,
  // legitimate copy of the app. See granite-lake-app-auth-design.md at the
  // repo root for the Phase 2 (device attestation) follow-up.
  //
  // Pass this via `--dart-define-from-file=<gitignored-json>` rather than
  // inline on the command line, so the values don't land in shell history,
  // `ps aux` output, or CI logs.
  //
  // For local development, enable dev fallbacks:
  //   --dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true
  //   --dart-define=GL_OTP_BACKEND_DEV_API_KEY=<key matching local server .env>
  static const String _rawOtpBackendConfig = String.fromEnvironment(
    'GL_OTP_BACKEND_CONFIG',
    defaultValue: '',
  );
  static const bool otpBackendDevFallbacksEnabled = bool.fromEnvironment(
    'GL_OTP_BACKEND_DEV_FALLBACKS',
    defaultValue: false,
  );
  static const String otpBackendDevApiKey = String.fromEnvironment(
    'GL_OTP_BACKEND_DEV_API_KEY',
    defaultValue: '',
  );

  /// Bump this whenever the resolver contract changes. The resolver compares it
  /// to a value stored in secure storage and forces a re-resolution on mismatch.
  static const int otpBackendAppBuildVersion = 2;

  /// The one domain this build serves, lowercased and trimmed, parsed from
  /// [_rawOtpBackendConfig]. Null if unset or malformed.
  static String? get otpBackendDomain {
    final domain = (_parsedOtpBackendConfig?['domain'] as String? ?? '')
        .trim()
        .toLowerCase();
    return domain.isEmpty ? null : domain;
  }

  /// This build's single backend config, parsed from [_rawOtpBackendConfig].
  /// Example shape: `{"domain":"acme.com","url":"https://acme-api.example.com","apiKey":"..."}`.
  static DomainBackendConfig? get otpBackendConfig {
    final decoded = _parsedOtpBackendConfig;
    if (decoded == null) {
      return null;
    }

    final url = (decoded['url'] as String? ?? '').trim();
    final apiKey = (decoded['apiKey'] as String? ?? '').trim();
    if (url.isEmpty || apiKey.isEmpty) {
      return null;
    }

    return DomainBackendConfig(url: url, apiKey: apiKey);
  }

  static Map<String, dynamic>? get _parsedOtpBackendConfig {
    final cleaned = _rawOtpBackendConfig.trim();
    if (cleaned.isEmpty) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException {
      return null;
    }

    return decoded is Map<String, dynamic> ? decoded : null;
  }

  static const String defaultPhotoAttestationModule = 'photo_attestation';
  static const String defaultPhotoAttestationPackageId =
      '0xd06ff3a35bb182b5e4577440d71470373fc4c36315c27dca90c8af3e8d9367b6';
  static const String defaultPhotoAttestationRegistryId =
      '0xe8a73abe8d822ad0b9441bd0df47510251c8b2c9d84f1d6ffcaa340bf2daea4e';
  static const double minimumAttestationSuiBalance = 0.004;
  static const int minimumAttestationMistBalance = 4000000;
  static const int maximumAttestationTimeGapMinutes = 15;

  // ConnectivityHeuristicService (offline-capture design doc §5): binary
  // online/offline, driven entirely by the most recent check() - whatever
  // the connection looks like right now, not a windowed/debounced read of
  // recent history.
  static const Duration connectivityPollIntervalOnline = Duration(seconds: 30);
  static const Duration connectivityPollIntervalOffline = Duration(seconds: 75);
}
