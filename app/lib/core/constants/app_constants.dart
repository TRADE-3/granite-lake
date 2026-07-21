import 'dart:convert';

/// A single domain's backend routing + credential, resolved from
/// [AppConstants.otpBackendConfigs].
class DomainBackendConfig {
  const DomainBackendConfig({required this.url, required this.apiKey});

  final String url;
  final String apiKey;
}

abstract final class AppConstants {
  // ── App meta ───────────────────────────────────────────────────────────────
  static const String appName = 'GRANITE LAKE';
  static const String appTitle = 'Granite Lake';
  static const String appVersion = 'V1.0';
  static const String walletCreateAsset = 'assets/images/wallet_create.png';
  static const int captureSessionDurationMinutes = 30;
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
  // One backend stack is deployed per domain, so production builds embed a
  // per-domain map of {url, apiKey} rather than a single URL. Production
  // builds MUST set GL_OTP_BACKEND_MAP. The resolver in
  // `core/utils/utils.dart` will refuse to talk to any domain not present in
  // this map.
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
  static const String _rawOtpBackendMap = String.fromEnvironment(
    'GL_OTP_BACKEND_MAP',
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

  /// Per-domain backend config parsed from [_rawOtpBackendMap], keyed by
  /// lowercased, trimmed domain. Example shape:
  /// `{"acme.com":{"url":"https://acme-api.example.com","apiKey":"..."}}`.
  static Map<String, DomainBackendConfig> get otpBackendConfigs {
    final cleaned = _rawOtpBackendMap.trim();
    if (cleaned.isEmpty) {
      return const {};
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException {
      return const {};
    }

    if (decoded is! Map<String, dynamic>) {
      return const {};
    }

    final result = <String, DomainBackendConfig>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        continue;
      }

      final url = (value['url'] as String? ?? '').trim();
      final apiKey = (value['apiKey'] as String? ?? '').trim();
      if (url.isEmpty || apiKey.isEmpty) {
        continue;
      }

      result[entry.key.trim().toLowerCase()] = DomainBackendConfig(
        url: url,
        apiKey: apiKey,
      );
    }

    return result;
  }

  static const String defaultPhotoAttestationModule = 'photo_attestation';
  static const String defaultPhotoAttestationPackageId =
      '0x2cc255055be3f23c13021f335ee141d15f1dd9f9b8febd819f30ac76796b569e';
  static const String defaultPhotoAttestationRegistryId =
      '0xab1bf31ba2754b488f5c2b7abd1c20ef874f66fb8712778c13b2ac8c1f6b6821';
  static const double minimumAttestationSuiBalance = 0.004;
  static const int minimumAttestationMistBalance = 4000000;
  static const int maximumAttestationTimeGapMinutes = 15;
}
