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
  // Production builds MUST set GL_OTP_BACKEND_URL. The resolver in
  // `core/utils/utils.dart` will refuse to talk to any other host.
  //
  // Security: The connection is secured by TLS (HTTPS). Make sure the server
  // uses a valid TLS certificate.
  //
  // For local development, enable dev fallbacks:
  //   --dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true
  static const String defaultOtpBackendBaseUrl = String.fromEnvironment(
    'GL_OTP_BACKEND_URL',
    defaultValue: '',
  );
  static const bool otpBackendDevFallbacksEnabled = bool.fromEnvironment(
    'GL_OTP_BACKEND_DEV_FALLBACKS',
    defaultValue: false,
  );

  /// Bump this whenever the resolver contract changes. The resolver compares it
  /// to a value stored in secure storage and forces a re-resolution on mismatch.
  static const int otpBackendAppBuildVersion = 1;

  static String get otpBackendBaseUrl {
    return defaultOtpBackendBaseUrl.trim().replaceAll(
      RegExp(r'["}\s\u2060\uFEFF]+$'),
      '',
    );
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
