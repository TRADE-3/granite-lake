import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:on_chain/sui/sui.dart';

import '../constants/app_constants.dart';
import '../state/granite_lake_models.dart';

class _BiometricGateBinding {
  const _BiometricGateBinding({required this.alias, required this.payload});

  final String alias;
  final BiometricGatePayload payload;
}

class _BiometricGateException implements Exception {
  const _BiometricGateException(this.code, this.message);

  final String code;
  final String message;

  bool get requiresRebind =>
      code == 'biometric_changed' || code == 'gate_missing';
}

class _ProtectedIdentityKeyBundle {
  const _ProtectedIdentityKeyBundle({
    required this.sentinelBase64,
    required this.suiPrivateKey,
  });

  factory _ProtectedIdentityKeyBundle.fromJson(Map<String, dynamic> json) {
    final sentinelBase64 = json['sentinelBase64'] as String?;
    final suiPrivateKey = json['suiPrivateKey'] as String?;
    if (sentinelBase64 == null ||
        sentinelBase64.isEmpty ||
        suiPrivateKey == null ||
        suiPrivateKey.isEmpty) {
      throw const FormatException('Protected identity bundle is incomplete.');
    }

    return _ProtectedIdentityKeyBundle(
      sentinelBase64: sentinelBase64,
      suiPrivateKey: suiPrivateKey,
    );
  }

  final String sentinelBase64;
  final String suiPrivateKey;

  Map<String, dynamic> toJson() {
    return {'sentinelBase64': sentinelBase64, 'suiPrivateKey': suiPrivateKey};
  }
}

class GraniteLakeSecureStateService {
  GraniteLakeSecureStateService({
    required FlutterSecureStorage storage,
    LocalAuthentication? localAuth,
    Random? random,
  }) : _storage = storage,
       _localAuth = localAuth ?? LocalAuthentication(),
       _random = random ?? Random.secure();

  static const MethodChannel _biometricGateChannel = MethodChannel(
    'granite_lake/biometric_gate',
  );
  static const biometricChangedMessage =
      'Biometrics changed on this device. Re-bind required.';
  static const accountDeletedMessage =
      'Account deleted on this device. Registration required to continue.';

  static const _registrationSaltKey = 'registration_code_salt';
  static const _registrationVerifierKey = 'registration_code_verifier';
  static const _deviceRegistrationKey = 'device_registration';
  static const _identityKey = 'identity_record';
  static const _biometricKey = 'biometric_binding';
  static const _biometricGatePayloadKey = 'biometric_gate_payload';
  static const _sessionKey = 'session_record';
  static const _resetNoticeKey = 'reset_notice';
  // Offline-queue at-rest encryption (§7.3, per the user's explicit ask):
  // the raw Sui private key, wrapped with the same RSA capture-wrap public
  // key that wraps each queued row's AES data key
  // (capture_encryption_service.dart), so unlockQueueForSubmission() can
  // recover it in the same native batch-unwrap call - and therefore the
  // same single biometric prompt - as the queued captures, instead of a
  // separate prompt against the AES gate above.
  static const _queueWrappedSigningKeyKey = 'queue_wrapped_signing_key';

  final FlutterSecureStorage _storage;
  final LocalAuthentication _localAuth;
  final Random _random;

  Future<SecureInitializationState> loadPersistedState() async {
    final registrationVerifier = await _storage.read(
      key: _registrationVerifierKey,
    );
    final resetNotice = await _storage.read(key: _resetNoticeKey);

    final hasLegacyRegistration = registrationVerifier != null;

    if (registrationVerifier != null) {
      await _storage.write(
        key: _registrationVerifierKey,
        value: registrationVerifier,
      );
    }

    final deviceRegistrationJson = await _storage.read(
      key: _deviceRegistrationKey,
    );
    DeviceRegistrationRecord? deviceRegistration;
    if (deviceRegistrationJson != null) {
      deviceRegistration = DeviceRegistrationRecord.fromJson(
        jsonDecode(deviceRegistrationJson) as Map<String, dynamic>,
      );
    } else if (hasLegacyRegistration) {
      deviceRegistration = await _storeDeviceRegistration();
    }

    final identityJson = await _storage.read(key: _identityKey);
    IdentityRecord? identity;
    if (identityJson != null) {
      final identityMap = jsonDecode(identityJson) as Map<String, dynamic>;
      identity = IdentityRecord.fromJson(identityMap);
      if (!identityMap.containsKey('walletAddress') ||
          !identityMap.containsKey('publicKeyHex')) {
        await _storage.write(
          key: _identityKey,
          value: jsonEncode(identity.toJson()),
        );
      }
    }

    const hasCompletedRegistration = false;

    BiometricBindingRecord? biometricBinding;
    BiometricGatePayload? biometricGatePayload;
    final biometricJson = await _storage.read(key: _biometricKey);
    final biometricGatePayloadJson = await _storage.read(
      key: _biometricGatePayloadKey,
    );
    if (biometricJson != null) {
      final restoredBinding = BiometricBindingRecord.fromJson(
        jsonDecode(biometricJson) as Map<String, dynamic>,
      );
      final restoredPayload = biometricGatePayloadJson == null
          ? null
          : BiometricGatePayload.fromJson(
              jsonDecode(biometricGatePayloadJson) as Map<String, dynamic>,
            );

      if (restoredBinding.hasGateAlias && restoredPayload != null) {
        biometricBinding = restoredBinding;
        biometricGatePayload = restoredPayload;
      } else {
        await clearBiometricBindingAndSession(
          biometricBinding: restoredBinding,
          deleteNativeGate: false,
        );
      }
    }

    if (biometricBinding != null &&
        biometricGatePayload != null &&
        (identity?.hasExportablePrivateKey ?? false)) {
      // bindBiometrics() writes the gate payload and binding record before
      // clearing the raw key from the identity record. Both prior writes
      // are present, so only that last write was interrupted — finish it
      // using the raw key already in memory instead of tearing down a
      // working hardware gate, which would leave the raw key exposed again
      // until the user re-binds from scratch.
      final protectedIdentity = identity!.withoutPrivateKey();
      await _storage.write(
        key: _identityKey,
        value: jsonEncode(protectedIdentity.toJson()),
      );
      identity = protectedIdentity;
    } else if (biometricBinding != null &&
        (identity?.hasExportablePrivateKey ?? false)) {
      // The gate payload itself is missing, so there's nothing to recover
      // the raw key into; only here does starting over make sense.
      await clearBiometricBindingAndSession(biometricBinding: biometricBinding);
      biometricBinding = null;
      biometricGatePayload = null;
    }

    final sessionJson = await _storage.read(key: _sessionKey);
    if (sessionJson != null) {
      await _storage.delete(key: _sessionKey);
    }

    return SecureInitializationState(
      hasCompletedRegistration: hasCompletedRegistration,
      deviceRegistration: deviceRegistration,
      identity: identity,
      photoAttestationClaim: null,
      biometricBinding: biometricBinding,
      biometricGatePayload: biometricGatePayload,
      resetNotice: resetNotice,
    );
  }

  Future<SecureOperationResult<DeviceRegistrationRecord?>>
  completeRegistration({
    required String registrationCode,
    required Future<List<int>> Function(String registrationCode, List<int> salt)
    deriveRegistrationVerifier,
  }) async {
    try {
      final salt = _randomBytes(16);
      final verifier = await deriveRegistrationVerifier(registrationCode, salt);
      await _storage.write(
        key: _registrationSaltKey,
        value: base64Encode(salt),
      );
      await _storage.write(
        key: _registrationVerifierKey,
        value: base64Encode(verifier),
      );
      await _storage.delete(key: _resetNoticeKey);
      final deviceRegistration = await _storeDeviceRegistration();
      return SecureOperationResult<DeviceRegistrationRecord?>.success(
        deviceRegistration,
      );
    } catch (error) {
      return SecureOperationResult<DeviceRegistrationRecord?>.failure(
        'Registration setup failed: $error',
      );
    }
  }

  Future<SecureOperationResult<IdentityRecord>> createIdentity() async {
    try {
      final privateKey = SuiED25519PrivateKey.fromBytes(_randomBytes(32));
      final account = SuiEd25519Account(privateKey);
      final identity = IdentityRecord(
        walletAddress: account.toAddress().toString(),
        publicKeyHex: account.publicKey.publicKey.toHex(),
        suiPrivateKey: privateKey.toSuiPrivateKey(),
        createdAt: DateTime.now().toUtc(),
      );

      await _storage.write(
        key: _identityKey,
        value: jsonEncode(identity.toJson()),
      );
      return SecureOperationResult<IdentityRecord>.success(identity);
    } catch (error) {
      return SecureOperationResult<IdentityRecord>.failure(
        'Identity generation failed: $error',
      );
    }
  }

  Future<SecureOperationResult<BiometricBindingState>> bindBiometrics({
    required IdentityRecord? identity,
  }) async {
    if (!Platform.isAndroid) {
      return const SecureOperationResult<BiometricBindingState>.failure(
        'This build does not include a native biometric gate on this platform.',
      );
    }

    try {
      if (identity == null || !identity.hasExportablePrivateKey) {
        return const SecureOperationResult<BiometricBindingState>.failure(
          'Create a device identity before binding biometrics on this device.',
        );
      }

      final isSupported = await _localAuth.isDeviceSupported();
      if (!isSupported) {
        return const SecureOperationResult<BiometricBindingState>.failure(
          'This device does not support biometric authentication.',
        );
      }

      final canCheck = await _localAuth.canCheckBiometrics;
      if (!canCheck) {
        return const SecureOperationResult<BiometricBindingState>.failure(
          'No enrolled biometrics were found on this device.',
        );
      }

      final biometricTypes = await _localAuth.getAvailableBiometrics();
      final priorAlias = await _readCurrentBiometricAlias();
      final protectedBundle = _ProtectedIdentityKeyBundle(
        sentinelBase64: base64Encode(_randomBytes(32)),
        suiPrivateKey: identity.suiPrivateKey!,
      );
      final gateBinding = await _createBiometricGate(
        jsonEncode(protectedBundle.toJson()),
      );
      final binding = BiometricBindingRecord(
        boundAt: DateTime.now().toUtc(),
        modalities: biometricTypes.map(_biometricLabel).toList(growable: false),
        gateAlias: gateBinding.alias,
      );
      final protectedIdentity = identity.withoutPrivateKey();

      await _storage.write(
        key: _biometricKey,
        value: jsonEncode(binding.toJson()),
      );
      await _storage.write(
        key: _biometricGatePayloadKey,
        value: jsonEncode(gateBinding.payload.toJson()),
      );
      await _storage.write(
        key: _identityKey,
        value: jsonEncode(protectedIdentity.toJson()),
      );
      // Best-effort: the AES gate above is the primary, required
      // protection for the raw key - this RSA-wrapped copy only exists to
      // collapse unlockQueueForSubmission() to a single prompt, so a
      // failure here (e.g. RSA keypair generation unsupported) must not
      // fail binding itself; it just falls back to the two-prompt path
      // (granite_lake_controller.dart's migration handling).
      try {
        await wrapAndPersistSigningKeyForQueue(identity.suiPrivateKey!);
      } catch (error) {
        debugPrint(
          '[QueueEncryption] bindBiometrics: signing-key wrap for queue-unlock failed (non-fatal): $error',
        );
      }

      if (priorAlias != null &&
          priorAlias.isNotEmpty &&
          priorAlias != gateBinding.alias) {
        await _deleteBiometricGate(priorAlias);
      }

      return SecureOperationResult<BiometricBindingState>.success(
        BiometricBindingState(
          identity: protectedIdentity,
          biometricBinding: binding,
          biometricGatePayload: gateBinding.payload,
        ),
      );
    } on _BiometricGateException catch (error) {
      return SecureOperationResult<BiometricBindingState>.failure(
        error.message,
      );
    } catch (error) {
      return SecureOperationResult<BiometricBindingState>.failure(
        'Biometric binding failed: $error',
      );
    }
  }

  Future<SecureOperationResult<SessionStartState>> startSession({
    required IdentityRecord? identity,
    required BiometricBindingRecord? biometricBinding,
    required BiometricGatePayload? biometricGatePayload,
    String? promptTitle,
    String? promptSubtitle,
  }) async {
    if (identity == null) {
      return const SecureOperationResult<SessionStartState>.failure(
        'Create a device identity before starting a session.',
      );
    }
    if (biometricBinding == null) {
      return const SecureOperationResult<SessionStartState>.failure(
        'Bind biometrics before starting a secure session.',
      );
    }

    try {
      if (!biometricBinding.hasGateAlias || biometricGatePayload == null) {
        await clearBiometricBindingAndSession(
          biometricBinding: biometricBinding,
          deleteNativeGate: false,
        );
        return const SecureOperationResult<SessionStartState>.failure(
          'Biometric binding is outdated. Re-bind biometrics to continue.',
          clearedBiometricBinding: true,
        );
      }

      final decryptedBundleJson = await _unlockBiometricGate(
        biometricBinding.gateAlias,
        biometricGatePayload,
        promptTitle: promptTitle,
        promptSubtitle: promptSubtitle,
      );
      final protectedBundle = _ProtectedIdentityKeyBundle.fromJson(
        jsonDecode(decryptedBundleJson) as Map<String, dynamic>,
      );
      final sessionSigningKey = _restoreSuiPrivateKey(
        protectedBundle.suiPrivateKey,
      );

      final startedAt = DateTime.now().toUtc();
      final session = SessionRecord(
        startedAt: startedAt,
        expiresAt: startedAt.add(
          const Duration(minutes: AppConstants.captureSessionDurationMinutes),
        ),
      );

      await _storage.write(
        key: _sessionKey,
        value: jsonEncode(session.toJson()),
      );

      return SecureOperationResult<SessionStartState>.success(
        SessionStartState(
          session: session,
          sessionSigningKey: sessionSigningKey,
        ),
      );
    } on _BiometricGateException catch (error) {
      if (error.requiresRebind) {
        return const SecureOperationResult<SessionStartState>.failure(
          biometricChangedMessage,
          code: 'biometric_reset_required',
        );
      }

      return SecureOperationResult<SessionStartState>.failure(error.message);
    } catch (error) {
      return SecureOperationResult<SessionStartState>.failure(
        'Session start failed: $error',
      );
    }
  }

  Future<void> endSession() async {
    await _storage.delete(key: _sessionKey);
  }

  Future<void> clearBiometricBindingAndSession({
    required BiometricBindingRecord? biometricBinding,
    bool deleteNativeGate = true,
    bool clearProtectedIdentity = false,
  }) async {
    final alias = biometricBinding?.gateAlias;
    if (deleteNativeGate &&
        alias != null &&
        alias.isNotEmpty &&
        Platform.isAndroid) {
      await _deleteBiometricGate(alias);
    }

    await _storage.delete(key: _biometricKey);
    await _storage.delete(key: _biometricGatePayloadKey);
    await _storage.delete(key: _sessionKey);
    // Stale once the AES gate above is gone - the raw key it wraps may no
    // longer even match a subsequent re-bind, and unlockQueueForSubmission
    // has its own migration path to re-derive and re-persist this.
    await _storage.delete(key: _queueWrappedSigningKeyKey);
    if (clearProtectedIdentity) {
      await _storage.delete(key: _identityKey);
    }
  }

  Future<void> dismissResetNotice() async {
    await _storage.delete(key: _resetNoticeKey);
  }

  Future<void> resetApplicationState({
    required BiometricBindingRecord? biometricBinding,
    required String notice,
  }) async {
    final alias = biometricBinding?.gateAlias;
    if (alias != null && alias.isNotEmpty && Platform.isAndroid) {
      await _deleteBiometricGate(alias);
    }

    await _storage.delete(key: _registrationSaltKey);
    await _storage.delete(key: _registrationVerifierKey);
    await _storage.delete(key: _deviceRegistrationKey);
    await _storage.delete(key: _identityKey);
    await _storage.delete(key: _biometricKey);
    await _storage.delete(key: _biometricGatePayloadKey);
    await _storage.delete(key: _sessionKey);
    await _storage.delete(key: _queueWrappedSigningKeyKey);
    await _storage.write(key: _resetNoticeKey, value: notice);
  }

  Future<DeviceRegistrationRecord?> _storeDeviceRegistration() async {
    final deviceRegistration = await _captureDeviceRegistration();
    if (deviceRegistration == null) {
      return null;
    }

    await _storage.write(
      key: _deviceRegistrationKey,
      value: jsonEncode(deviceRegistration.toJson()),
    );
    return deviceRegistration;
  }

  Future<DeviceRegistrationRecord?> _captureDeviceRegistration() async {
    try {
      final registeredAt = DateTime.now().toUtc();
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        final release = info.version.release;
        return DeviceRegistrationRecord(
          registeredAt: registeredAt,
          model: info.model,
          manufacturer: info.manufacturer,
          platform: 'android',
          osVersion: release.isEmpty ? 'Android' : 'Android $release',
        );
      }

      return DeviceRegistrationRecord(
        registeredAt: registeredAt,
        model: Platform.localHostname,
        manufacturer: 'SYSTEM',
        platform: Platform.operatingSystem,
        osVersion: Platform.operatingSystemVersion,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readCurrentBiometricAlias() async {
    final biometricJson = await _storage.read(key: _biometricKey);
    if (biometricJson == null) {
      return null;
    }

    final binding = BiometricBindingRecord.fromJson(
      jsonDecode(biometricJson) as Map<String, dynamic>,
    );
    return binding.gateAlias;
  }

  List<int> _randomBytes(int length) {
    return List<int>.generate(length, (_) => _random.nextInt(256));
  }

  String _biometricLabel(BiometricType type) {
    switch (type) {
      case BiometricType.face:
        return 'FACE';
      case BiometricType.fingerprint:
        return 'FINGERPRINT';
      case BiometricType.iris:
        return 'IRIS';
      case BiometricType.strong:
        return 'STRONG_BIOMETRIC';
      case BiometricType.weak:
        return 'DEVICE_BIOMETRIC';
    }
  }

  SuiED25519PrivateKey _restoreSuiPrivateKey(String suiPrivateKey) {
    final restoredKey = SuiBasePrivateKey.fromSuiSecretKey(suiPrivateKey);
    if (restoredKey is! SuiED25519PrivateKey) {
      throw FormatException(
        '${AppConstants.appTitle} only supports Sui Ed25519 identities.',
      );
    }

    return restoredKey;
  }

  /// Public alias of [_restoreSuiPrivateKey] - reused by
  /// `GraniteLakeController.unlockQueueForSubmission()` to reconstruct the
  /// signing key from the RSA-unwrapped bytes it gets back from the same
  /// native batch call as the queued captures, so both paths validate the
  /// key format identically.
  SuiED25519PrivateKey restoreSuiPrivateKey(String suiPrivateKey) =>
      _restoreSuiPrivateKey(suiPrivateKey);

  Future<String?> readQueueWrappedSigningKey() {
    return _storage.read(key: _queueWrappedSigningKeyKey);
  }

  /// Wraps the raw Sui private key with the same RSA capture-wrap public
  /// key used for each queued row's AES data key (native
  /// `granite_lake/biometric_gate` channel, `wrapCaptureDataKey`) and
  /// persists it, so a later `unwrapCaptureDataKeys` batch call can recover
  /// it alongside the queue in one prompt. No biometric prompt itself -
  /// wrapping is a public-key operation, same as for a capture's data key.
  Future<void> wrapAndPersistSigningKeyForQueue(String suiPrivateKey) async {
    await _biometricGateChannel.invokeMethod<void>('ensureCaptureWrapKey');
    final wrapped = await _biometricGateChannel
        .invokeMethod<String>('wrapCaptureDataKey', {
          'dataKeyBase64': base64Encode(utf8.encode(suiPrivateKey)),
          'captureId': 'signing_key',
        });
    if (wrapped == null || wrapped.isEmpty) {
      throw const FormatException(
        'Signing key wrap for queue-unlock returned no result.',
      );
    }
    await _storage.write(key: _queueWrappedSigningKeyKey, value: wrapped);
  }

  Future<_BiometricGateBinding> _createBiometricGate(String payload) async {
    try {
      final result = await _biometricGateChannel
          .invokeMapMethod<String, dynamic>('createBiometricGate', {
            'payload': payload,
          });
      if (result == null) {
        throw const _BiometricGateException(
          'binding_failed',
          'Biometric gate creation returned no result.',
        );
      }

      final alias = result['alias'] as String?;
      final ciphertextBase64 = result['ciphertextBase64'] as String?;
      final ivBase64 = result['ivBase64'] as String?;
      if (alias == null || ciphertextBase64 == null || ivBase64 == null) {
        throw const _BiometricGateException(
          'binding_failed',
          'Biometric gate creation returned incomplete data.',
        );
      }

      return _BiometricGateBinding(
        alias: alias,
        payload: BiometricGatePayload(
          ciphertextBase64: ciphertextBase64,
          ivBase64: ivBase64,
        ),
      );
    } on PlatformException catch (error) {
      throw _mapBiometricGateException(error, 'Biometric binding failed.');
    }
  }

  Future<String> _unlockBiometricGate(
    String alias,
    BiometricGatePayload payload, {
    String? promptTitle,
    String? promptSubtitle,
  }) async {
    try {
      final decryptedPayload = await _biometricGateChannel
          .invokeMethod<String>('unlockBiometricGate', {
            'alias': alias,
            'ciphertextBase64': payload.ciphertextBase64,
            'ivBase64': payload.ivBase64,
            'title': ?promptTitle,
            'subtitle': ?promptSubtitle,
          });
      if (decryptedPayload == null || decryptedPayload.isEmpty) {
        throw const _BiometricGateException(
          'gate_missing',
          'Protected identity payload could not be recovered.',
        );
      }

      return decryptedPayload;
    } on PlatformException catch (error) {
      throw _mapBiometricGateException(error, 'Biometric unlock failed.');
    }
  }

  Future<void> _deleteBiometricGate(String alias) async {
    try {
      await _biometricGateChannel.invokeMethod<void>('deleteBiometricGate', {
        'alias': alias,
      });
    } on PlatformException {
      return;
    }
  }

  _BiometricGateException _mapBiometricGateException(
    PlatformException error,
    String fallbackMessage,
  ) {
    switch (error.code) {
      case 'auth_cancelled':
        return _BiometricGateException(
          error.code,
          error.message ?? 'Biometric verification was cancelled or denied.',
        );
      case 'biometric_unavailable':
        return _BiometricGateException(
          error.code,
          error.message ?? 'No enrolled biometrics were found on this device.',
        );
      case 'biometric_changed':
      case 'gate_missing':
        return const _BiometricGateException(
          'biometric_changed',
          biometricChangedMessage,
        );
      default:
        return _BiometricGateException(
          error.code,
          error.message ?? fallbackMessage,
        );
    }
  }
}
