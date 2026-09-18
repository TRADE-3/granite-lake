import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:on_chain/sui/sui.dart';

import '../database/granite_lake_data_controllers.dart';
import '../constants/app_constants.dart';
import '../services/capture_encryption_service.dart';
import '../services/granite_lake_capture_workflow_service.dart';
import '../services/photo_attestation_service.dart';
import '../services/granite_lake_secure_state_service.dart';
import '../utils/network_error_classifier.dart';
import 'granite_lake_models.dart';

export 'granite_lake_models.dart';

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class GraniteLakeController extends ChangeNotifier {
  static GraniteLakeController? _current;

  static GraniteLakeController? get current => _current;

  GraniteLakeController()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      ),
      _dataControllers = GraniteLakeDataControllers.create() {
    _current = this;
    _secureStateService = GraniteLakeSecureStateService(storage: _storage);
    _captureWorkflowService = GraniteLakeCaptureWorkflowService();
    _photoAttestationService = PhotoAttestationService();
    _captureEncryptionService = CaptureEncryptionService();
  }

  final FlutterSecureStorage _storage;
  final GraniteLakeDataControllers _dataControllers;
  late final GraniteLakeSecureStateService _secureStateService;
  late final GraniteLakeCaptureWorkflowService _captureWorkflowService;
  late final PhotoAttestationService _photoAttestationService;
  late final CaptureEncryptionService _captureEncryptionService;

  static const String _queueEncryptionLogTag = '[QueueEncryption]';
  // Offline-queue at-rest encryption (offline-capture design doc §7.3,
  // intentionally modified): independent of the 30-minute signing session
  // above. A single "unlock to submit" prompt batch-decrypts every
  // currently-queued row's payload into this cache; it's destroyed either
  // when this 5-minute window elapses or the moment the queue drains to
  // empty, whichever comes first - never left to ride the general session's
  // own, longer, lifecycle.
  final Map<String, Map<String, dynamic>> _decryptedQueuePayloads = {};
  DateTime? _queueUnlockExpiresAt;
  Timer? _queueUnlockTicker;
  // The signing key recovered as part of the same batch-unwrap as the
  // queue payloads above (unlockQueueForSubmission's normal path) - kept
  // entirely separate from _sessionSigningKey/_session below, on purpose:
  // this one lives only as long as the 5-minute queue-unlock window itself
  // (or until the queue drains, whichever is first, via _lockQueue), never
  // extended into a standing 30-minute capture session. It exists solely
  // so retryPendingAttestations() can sign a resubmission during that
  // window without also being able to authorize a brand-new capture.
  SuiED25519PrivateKey? _queueSigningKey;

  Timer? _sessionTicker;
  bool _isInitializing = true;
  String? _initializationError;
  bool _hasCompletedRegistration = false;
  DeviceRegistrationRecord? _deviceRegistration;
  EmployeeRecord? _employee;
  IdentityRecord? _identity;
  PhotoAttestationClaimRecord? _photoAttestationClaim;
  BiometricBindingRecord? _biometricBinding;
  BiometricGatePayload? _biometricGatePayload;
  SuiED25519PrivateKey? _sessionSigningKey;
  SessionRecord? _session;
  AttestationRecord? _lastAttestation;
  PhotoCaptureRecord? _lastPhotoCapture;
  UploadedFileRecord? _lastUploadedFile;
  List<AttestationRecord> _attestationHistory = const [];
  List<PhotoCaptureRecord> _photoCaptureHistory = const [];
  List<UploadedFileRecord> _uploadedFileHistory = const [];
  Map<String, AttestationChainVerificationRecord> _attestationVerifications =
      const {};
  bool _isRetryingPendingAttestations = false;
  bool _isUnlockingQueueForSubmission = false;
  bool _offlineCaptureForced = false;
  bool _gpsCaptureForcedNull = false;
  Map<String, int> _verificationRetryCounts = const {};
  String? _resetNotice;
  List<ProjectRecord> _projects = const [];
  String? _selectedProjectId;
  PhotoAttestationContractConfig? _photoAttestationConfig;
  bool _requiresLocalDataInitialization = false;
  BigInt? _walletSuiBalanceMist;
  bool _isRefreshingWalletSuiBalance = false;
  bool _isDarkMode = false;

  bool get isInitializing => _isInitializing;
  String? get initializationError => _initializationError;
  bool get hasCompletedRegistration => _hasCompletedRegistration;
  DeviceRegistrationRecord? get deviceRegistration => _deviceRegistration;
  EmployeeRecord? get employee => _employee;
  IdentityRecord? get identity => _identity;
  PhotoAttestationClaimRecord? get photoAttestationClaim =>
      _photoAttestationClaim;
  BiometricBindingRecord? get biometricBinding => _biometricBinding;
  SessionRecord? get session => _session;
  AttestationRecord? get lastAttestation => _lastAttestation;
  PhotoCaptureRecord? get lastPhotoCapture => _lastPhotoCapture;
  UploadedFileRecord? get lastUploadedFile => _lastUploadedFile;
  List<AttestationRecord> get attestationHistory =>
      List.unmodifiable(_attestationHistory);
  List<PhotoCaptureRecord> get photoCaptureHistory =>
      List.unmodifiable(_photoCaptureHistory);
  List<UploadedFileRecord> get uploadedFileHistory =>
      List.unmodifiable(_uploadedFileHistory);
  AttestationChainVerificationRecord? attestationVerificationFor(
    String captureId,
  ) => _attestationVerifications[captureId];
  String? get resetNotice => _resetNotice;
  List<ProjectRecord> get projects => List.unmodifiable(_projects);
  String? get selectedProjectId => _selectedProjectId;
  PhotoAttestationContractConfig? get photoAttestationConfig =>
      _photoAttestationConfig;
  bool get requiresLocalDataInitialization => _requiresLocalDataInitialization;
  BigInt? get walletSuiBalanceMist => _walletSuiBalanceMist;
  bool get isRefreshingWalletSuiBalance => _isRefreshingWalletSuiBalance;
  bool get isDarkMode => _isDarkMode;
  double? get walletSuiBalanceSui => _walletSuiBalanceMist == null
      ? null
      : _walletSuiBalanceMist!.toDouble() / 1000000000;
  bool get hasEnoughSuiForAttestation =>
      (_walletSuiBalanceMist ?? BigInt.zero) >=
      BigInt.from(AppConstants.minimumAttestationMistBalance);
  ProjectRecord? get selectedProject {
    final selectedProjectId = _selectedProjectId;
    if (selectedProjectId == null) {
      return null;
    }

    for (final project in _projects) {
      if (project.projectId == selectedProjectId) {
        return project;
      }
    }
    return null;
  }

  bool get hasProjects => _projects.isNotEmpty;
  bool get hasIdentity => _identity != null;
  bool get hasClaimedPhotoAttestationUser => _photoAttestationClaim != null;
  bool get isBiometricBound => _biometricBinding != null;
  bool get hasActiveSession => _session?.isActive ?? false;

  int get pendingAttestationCount => _attestationHistory
      .where(
        (record) =>
            record.isAttestationPending || _isRecoverableFailure(record),
      )
      .length;

  bool get pendingAttestationsNeedUnlock =>
      pendingAttestationCount > 0 && !hasActiveSession;

  // Offline-queue at-rest encryption (§7.3): the 5-minute decrypted-queue
  // window, independent of the 30-minute signing session above - see the
  // field comment on _decryptedQueuePayloads.
  bool get isQueueUnlocked {
    final expiresAt = _queueUnlockExpiresAt;
    return expiresAt != null && expiresAt.isAfter(DateTime.now().toUtc());
  }

  bool get queueUnlockNeeded => pendingAttestationCount > 0 && !isQueueUnlocked;

  bool get isOfflineCaptureForced => _offlineCaptureForced;
  bool get isGpsCaptureForcedNull => _gpsCaptureForcedNull;

  Future<void> setOfflineCaptureForced(bool value) async {
    if (_offlineCaptureForced == value) {
      return;
    }
    _offlineCaptureForced = value;
    await _dataControllers.config.saveOfflineCaptureForced(value);
    notifyListeners();
  }

  Future<void> setGpsCaptureForcedNull(bool value) async {
    if (_gpsCaptureForcedNull == value) {
      return;
    }
    _gpsCaptureForcedNull = value;
    await _dataControllers.config.saveGpsCaptureForcedNull(value);
    notifyListeners();
  }

  Duration get remainingSessionDuration {
    final session = _session;
    if (session == null) {
      return Duration.zero;
    }

    final remaining = session.expiresAt.difference(DateTime.now().toUtc());
    if (remaining.isNegative) {
      return Duration.zero;
    }

    return remaining;
  }

  Future<void> initialize() async {
    _isInitializing = true;
    _initializationError = null;
    notifyListeners();

    try {
      final secureState = await _secureStateService.loadPersistedState();
      _applySecureInitializationState(secureState);
      // Backfill for installs that registered before
      // claimPhotoAttestationUser() started capturing this (or hit a
      // transient device_info_plus failure at that moment) - an already
      // identified device with no stored record yet should still pick one
      // up on its next launch, rather than showing the Profile screen's
      // "unavailable"/"pending registration" placeholders forever.
      if (_identity != null && _deviceRegistration == null) {
        _deviceRegistration = await _secureStateService
            .storeDeviceRegistration();
      }

      await _dataControllers.initialize(secureStorage: _storage);
      _photoAttestationConfig = await _dataControllers.config
          .syncPhotoAttestationContractConfig();
      await _loadDatabaseState();
      unawaited(refreshWalletSuiBalance());
    } catch (error) {
      _initializationError = 'Application initialization failed: $error';
    } finally {
      _isInitializing = false;
      _syncSessionTicker();
      notifyListeners();
    }
  }

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  void setDarkMode(bool isDark) {
    if (_isDarkMode != isDark) {
      _isDarkMode = isDark;
      notifyListeners();
    }
  }

  Future<ActionResult> initializeLocalData() async {
    try {
      await _dataControllers.employee.seedDefaultEmployee();
      _photoAttestationConfig = await _dataControllers.config
          .syncPhotoAttestationContractConfig();
      await _loadDatabaseState();
      unawaited(refreshWalletSuiBalance());
      notifyListeners();
      return const ActionResult.success();
    } catch (error) {
      return ActionResult.failure('Local data initialization failed: $error');
    }
  }

  Future<ActionResult> createIdentity() async {
    if (_identity != null) {
      return const ActionResult.success();
    }

    final result = await _secureStateService.createIdentity();
    if (!result.isSuccess || result.data == null) {
      return _toActionResult(result);
    }

    try {
      _identity = result.data;
      notifyListeners();
      return const ActionResult.success();
    } catch (error) {
      return ActionResult.failure('Identity generation failed: $error');
    }
  }

  Future<SecureOperationResult<PhotoAttestationOtpRequestResult>>
  requestPhotoAttestationOtp({
    required String domain,
    required String userEmail,
  }) async {
    final normalizedDomain = domain.trim();
    final normalizedUserEmail = userEmail.trim();
    if (normalizedDomain.isEmpty || normalizedUserEmail.isEmpty) {
      return const SecureOperationResult.failure(
        'Company domain and user email are required.',
      );
    }

    try {
      final result = await _photoAttestationService.requestUserOtp(
        domain: normalizedDomain,
        userEmail: normalizedUserEmail,
      );
      return SecureOperationResult.success(result);
    } on PhotoAttestationException catch (error) {
      return SecureOperationResult.failure(error.userMessage);
    } catch (error) {
      debugPrint('[OTP] requestPhotoAttestationOtp unexpected error: $error');
      return const SecureOperationResult.failure(
        'Something went wrong while requesting the OTP. Please try again.',
      );
    }
  }

  Future<ActionResult> claimPhotoAttestationUser({
    required String domain,
    required String userId,
    required String otp,
    required String walletNonce,
  }) async {
    final identity = _identity;
    final config = _photoAttestationConfig;
    if (identity == null) {
      return const ActionResult.failure(
        'Create the local Sui identity before claiming your user record.',
      );
    }
    if (config == null || !config.isComplete) {
      return const ActionResult.failure(
        'Contract config is incomplete. Set RPC URL, package id, registry id, and module name first.',
      );
    }

    final normalizedDomain = domain.trim();
    final normalizedUserId = userId.trim();
    final normalizedOtp = otp.trim();
    final normalizedWalletNonce = walletNonce.trim();
    if (normalizedDomain.isEmpty ||
        normalizedUserId.isEmpty ||
        normalizedOtp.isEmpty ||
        normalizedWalletNonce.isEmpty) {
      return const ActionResult.failure(
        'Company domain, OTP session id, OTP, and wallet nonce are all required.',
      );
    }

    // Proving wallet possession needs the raw signing key. Biometrics are
    // bound before registration runs (see F-09), which strips that key out
    // of the in-memory identity, so unlock it the same way the capture flow
    // does rather than reading it off `identity`. Registration itself has
    // no use for a standing session afterward, so only start one here if
    // none is already active, and tear back down whatever this call started
    // once the signature has been produced - the signing key only needs to
    // exist for the moment it's used.
    final hadActiveSessionBeforeClaim = hasActiveSession;
    if (!hadActiveSessionBeforeClaim) {
      final sessionResult = await startSession(
        promptTitle: 'Confirm your identity',
        promptSubtitle: 'Verify biometrics to complete registration.',
      );
      if (!sessionResult.isSuccess) {
        return sessionResult;
      }
    }
    final sessionSigningKey = _sessionSigningKey;
    if (sessionSigningKey == null) {
      return const ActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }

    try {
      final claim = await _photoAttestationService.claimUserWithOtp(
        identity: identity,
        signingKey: sessionSigningKey,
        config: config,
        input: PhotoAttestationClaimInput(
          domain: normalizedDomain,
          userId: normalizedUserId,
          otp: normalizedOtp,
          walletNonce: normalizedWalletNonce,
        ),
      );
      await _dataControllers.config.savePhotoAttestationClaim(claim);
      await _dataControllers.employee.saveClaimedEmployee(
        employeeId: normalizedUserId,
        companyDomain: normalizedDomain,
        walletAddress: identity.walletAddress,
      );
      _photoAttestationClaim = claim;
      _employee = EmployeeRecord.fromJson(
        (await _dataControllers.employee.loadPrimaryEmployee())!,
      );
      _hasCompletedRegistration = true;
      _resetNotice = null;
      // Captures and persists the real device model/OS/timestamp now that
      // registration has actually completed - re-reading loadPersistedState()
      // here was a no-op, since nothing in this (current) registration flow
      // ever wrote a device registration record for it to find.
      _deviceRegistration ??= await _secureStateService
          .storeDeviceRegistration();
      unawaited(refreshWalletSuiBalance(force: true));
      notifyListeners();
      return const ActionResult.success();
    } on PhotoAttestationException catch (error) {
      return ActionResult.failure(error.userMessage);
    } catch (error) {
      debugPrint('[OTP] claimPhotoAttestationUser unexpected error: $error');
      return const ActionResult.failure(
        'Something went wrong while verifying your OTP. Please try again.',
      );
    } finally {
      if (!hadActiveSessionBeforeClaim) {
        await endSession();
      }
    }
  }

  Future<ActionResult> updatePhotoAttestationConfig({
    required String rpcUrl,
    required String packageId,
    required String registryId,
    required String moduleName,
  }) async {
    final nextConfig = PhotoAttestationContractConfig(
      rpcUrl: rpcUrl.trim(),
      packageId: packageId.trim(),
      registryId: registryId.trim(),
      moduleName: moduleName.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    if (!nextConfig.isComplete) {
      return const ActionResult.failure(
        'RPC URL, package id, and module name are required.',
      );
    }

    await _dataControllers.config.savePhotoAttestationContractConfig(
      nextConfig,
    );
    _photoAttestationConfig = nextConfig;
    notifyListeners();
    return const ActionResult.success();
  }

  Future<ActionResult> bindBiometrics() async {
    final result = await _secureStateService.bindBiometrics(
      identity: _identity,
    );
    if (!result.isSuccess || result.data == null) {
      return _toActionResult(result);
    }

    _identity = result.data!.identity;
    _biometricBinding = result.data!.biometricBinding;
    _biometricGatePayload = result.data!.biometricGatePayload;
    _sessionSigningKey = null;
    _session = null;
    _syncSessionTicker();
    notifyListeners();
    return const ActionResult.success();
  }

  Future<ActionResult> startSession({
    String? promptTitle,
    String? promptSubtitle,
  }) async {
    if (hasActiveSession) {
      return const ActionResult.success();
    }

    final result = await _secureStateService.startSession(
      identity: _identity,
      biometricBinding: _biometricBinding,
      biometricGatePayload: _biometricGatePayload,
      promptTitle: promptTitle,
      promptSubtitle: promptSubtitle,
    );
    if (result.clearedBiometricBinding) {
      _clearLocalBiometricSessionState();
      notifyListeners();
    }

    if (!result.isSuccess || result.data == null) {
      return _toActionResult(result);
    }

    _sessionSigningKey = result.data!.sessionSigningKey;
    _session = result.data!.session;
    _syncSessionTicker();
    notifyListeners();
    if (pendingAttestationCount > 0) {
      unawaited(retryPendingAttestations());
    }
    return const ActionResult.success();
  }

  Future<void> endSession() async {
    await _secureStateService.endSession();
    _clearLocalSessionState();
    notifyListeners();
  }

  /// Sweeps `PENDING_SUBMISSION` rows oldest-first and resubmits each with
  /// its originally-persisted `captured_at`/connectivity/GPS/reason-hash
  /// fields, per the offline-capture design's submission queue (§7). A
  /// fresh `attested_at` is supplied by the chain wherever the submission
  /// actually lands. No-ops entirely (touches no row) unless a signing
  /// session is already active - a caller that needs one first should raise
  /// the biometric unlock via [startSession] itself, whose success already
  /// triggers this sweep.
  Future<void> retryPendingAttestations() async {
    if (_isRetryingPendingAttestations) {
      return;
    }
    // Either signing key unlocks a resubmission - the 30-minute general
    // session (_sessionSigningKey) or the queue-scoped one recovered by
    // unlockQueueForSubmission's normal path (_queueSigningKey, its own
    // separate 5-minute/until-drained lifecycle - see that field's doc).
    final hasUsableSigningKey =
        (hasActiveSession && _sessionSigningKey != null) ||
        _queueSigningKey != null;
    if (!hasUsableSigningKey) {
      return;
    }

    _isRetryingPendingAttestations = true;
    try {
      final pending =
          _attestationHistory
              .where(
                (record) =>
                    record.isAttestationPending ||
                    _isRecoverableFailure(record),
              )
              .toList()
            ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      if (pending.isEmpty) {
        return;
      }

      // Capture time skips this check entirely (balance can't be verified
      // offline - see persistCaptureWithMetadata/persistFileWithMetadata).
      // A retry is only ever attempted once we're back online, so check the
      // real, current balance here first rather than spending a doomed
      // transaction attempt and letting the chain reject it - and record
      // *why* on every affected row, not just leave it silently pending.
      await refreshWalletSuiBalance(force: true);
      if ((_walletSuiBalanceMist ?? BigInt.zero) <
          BigInt.from(AppConstants.minimumAttestationMistBalance)) {
        final insufficientBalanceMessage =
            'Your wallet needs at least ${AppConstants.minimumAttestationSuiBalance.toStringAsFixed(3)} SUI before submitting an attestation. Add test SUI and try again.';
        for (final record in pending) {
          await _updateAttestationRecord(
            record,
            suiSubmissionStatus: 'PENDING_SUBMISSION',
            suiErrorMessage: insufficientBalanceMessage,
          );
        }
        notifyListeners();
        return;
      }

      for (final record in pending) {
        final signingKey =
            (hasActiveSession ? _sessionSigningKey : null) ?? _queueSigningKey;
        if (signingKey == null) {
          break;
        }

        // Offline-queue at-rest encryption (§7.3): a row that took the
        // offline/forced-offline path has its submission-relevant fields
        // blanked in `record` itself (migrations.dart's version-13
        // migration) - the real values only exist in
        // _decryptedQueuePayloads, populated by unlockQueueForSubmission().
        // A row with no entry there yet (5-minute window lapsed, or it was
        // queued after the last unlock) is left untouched rather than
        // misfiled as failed - the same no-op treatment already given to a
        // missing signing key above.
        AttestationRecord? decryptedRecord;
        if (record.isEncryptedAtRest) {
          final decryptedPayload = _decryptedQueuePayloads[record.captureId];
          if (decryptedPayload == null) {
            debugPrint(
              '$_queueEncryptionLogTag[${record.captureId}] submit_attempted=skipped reason=not_unlocked',
            );
            continue;
          }
          decryptedRecord = _rehydrateFromDecryptedPayload(
            record,
            decryptedPayload,
          );
        }

        debugPrint(
          '$_queueEncryptionLogTag[${record.captureId}] submit_attempted encrypted=${record.isEncryptedAtRest}',
        );
        final updated = record.isFile
            ? await _submitFileAttestation(
                record,
                sessionSigningKey: signingKey,
                projectId:
                    decryptedRecord?.attestedProjectId ??
                    record.attestedProjectId,
                decryptedRecord: decryptedRecord,
              )
            : await _submitPhotoAttestation(
                record,
                sessionSigningKey: signingKey,
                gpsLabel:
                    decryptedRecord?.capturedGpsLabel ??
                    record.capturedGpsLabel,
                altitudeLabel:
                    decryptedRecord?.capturedAltitudeLabel ??
                    record.capturedAltitudeLabel,
                projectId:
                    decryptedRecord?.attestedProjectId ??
                    record.attestedProjectId,
                decryptedRecord: decryptedRecord,
              );
        debugPrint(
          '$_queueEncryptionLogTag[${record.captureId}] submit_result=${updated.suiSubmissionStatus}',
        );

        final seededVerification = _seedVerificationFor(updated);
        _attestationVerifications = {
          ..._attestationVerifications,
          updated.captureId: seededVerification,
        };
        notifyListeners();
        if (updated.isAttestationAnchored && !seededVerification.isVerified) {
          unawaited(verifyAttestationOnChain(updated));
        }
      }

      // §7.3's "after the last pending submission is gone, destroy any
      // decrypted in-memory data" - don't wait out the rest of the 5-minute
      // window once there's nothing left it would be protecting.
      if ((_decryptedQueuePayloads.isNotEmpty || _queueSigningKey != null) &&
          pendingAttestationCount == 0) {
        _lockQueue(reason: 'queue_drained');
      }
    } finally {
      _isRetryingPendingAttestations = false;
    }
  }

  // Sentinel id for the raw signing key's slot in the same batch-unwrap
  // call as the queued rows (see unlockQueueForSubmission) - distinct from
  // any real captureId, which is always a numeric microsecond timestamp.
  static const String _signingKeyBatchId = '__signing_key__';

  /// Offline-queue at-rest encryption (§7.3, intentionally modified): the
  /// single entry point for the "unlock to submit" CTA and the reconnect
  /// notification tap. The raw Sui signing key is wrapped with the same
  /// RSA capture-wrap key as every queued row's data key
  /// (`GraniteLakeSecureStateService.wrapAndPersistSigningKeyForQueue`), so
  /// the normal case below is a *single* biometric prompt covering both -
  /// not a separate `startSession()` call plus a separate queue unlock.
  ///
  /// Migration path: a device that bound biometrics before this existed
  /// (or has simply never unlocked the queue before) has no wrapped
  /// signing key on file yet. That one time only, this falls back to the
  /// original two-prompt flow (start the general session the old way,
  /// unwrap the queue separately) and wraps+persists the key for next
  /// time, so every unlock after this one - on this device - is
  /// single-prompt.
  Future<ActionResult> unlockQueueForSubmission() async {
    // Without this guard, a double-tap on the "unlock" CTA (or a
    // notification tap landing while the CTA is already mid-flight) fires
    // two concurrent native unwrapCaptureDataKeys batches for the same
    // rows - observed on-device as two interleaved "unlock_requested"
    // calls racing a single BiometricPrompt/CryptoObject, which is not a
    // supported usage and produces spurious native failures.
    if (_isUnlockingQueueForSubmission) {
      return const ActionResult.success();
    }
    _isUnlockingQueueForSubmission = true;
    try {
      final encryptedPending =
          _attestationHistory
              .where(
                (record) =>
                    (record.isAttestationPending ||
                        _isRecoverableFailure(record)) &&
                    record.isEncryptedAtRest,
              )
              .toList()
            ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));

      final wrappedSigningKeyBase64 = await _secureStateService
          .readQueueWrappedSigningKey();

      if (wrappedSigningKeyBase64 == null) {
        return _unlockQueueViaMigrationFallback(encryptedPending);
      }

      if (encryptedPending.isEmpty) {
        // Nothing queued right now - no reason to prompt for nothing.
        return const ActionResult.success();
      }

      final captureIds = [
        ...encryptedPending.map((record) => record.captureId),
        _signingKeyBatchId,
      ];
      final wrappedKeys = [
        ...encryptedPending.map((record) => record.wrappedDataKey ?? ''),
        wrappedSigningKeyBase64,
      ];

      debugPrint(
        '$_queueEncryptionLogTag unlock_requested batch_size=${captureIds.length} '
        '(includes signing key)',
      );
      final Map<String, Uint8List?> unwrapped;
      try {
        unwrapped = await _captureEncryptionService.unwrapDataKeys(
          captureIds: captureIds,
          wrappedKeysBase64: wrappedKeys,
        );
      } catch (error) {
        debugPrint(
          '$_queueEncryptionLogTag batch_unwrap_result=error error=$error',
        );
        return ActionResult.failure('Could not unlock queued captures: $error');
      }

      final signingKeyBytes = unwrapped[_signingKeyBatchId];
      if (signingKeyBytes == null) {
        debugPrint('$_queueEncryptionLogTag signing_key_unwrap_result=failed');
        return const ActionResult.failure(
          'Your secure signing key could not be unlocked. Try again.',
        );
      }
      final SuiED25519PrivateKey signingKey;
      try {
        signingKey = _secureStateService.restoreSuiPrivateKey(
          utf8.decode(signingKeyBytes),
        );
      } finally {
        signingKeyBytes.fillRange(0, signingKeyBytes.length, 0);
      }
      debugPrint('$_queueEncryptionLogTag signing_key_unwrap_result=ok');

      // Deliberately NOT the general 30-minute session
      // (_sessionSigningKey/_session) - this key is scoped to the same
      // 5-minute/until-drained window as the decrypted queue payloads
      // (_queueSigningKey's field doc), so it never authorizes a brand-new
      // capture, and _lockQueue destroys it the same moment it destroys
      // everything else this unlock produced.
      _queueSigningKey = signingKey;
      notifyListeners();

      return _decryptAndSubmitQueue(encryptedPending, preUnwrapped: unwrapped);
    } finally {
      _isUnlockingQueueForSubmission = false;
    }
  }

  /// One-time-per-device fallback for [unlockQueueForSubmission] when no
  /// RSA-wrapped signing key is on file yet - see that method's doc
  /// comment. Two prompts this once; wraps the key for next time.
  Future<ActionResult> _unlockQueueViaMigrationFallback(
    List<AttestationRecord> encryptedPending,
  ) async {
    if (!hasActiveSession) {
      final sessionResult = await startSession();
      if (!sessionResult.isSuccess) {
        return sessionResult;
      }
    }
    final signingKey = _sessionSigningKey;
    if (signingKey == null) {
      return const ActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }

    // Fire-and-forget: failing to wrap-for-next-time shouldn't block this
    // unlock from proceeding with the queue it already has a valid key
    // for.
    unawaited(
      _secureStateService
          .wrapAndPersistSigningKeyForQueue(signingKey.toSuiPrivateKey())
          .then(
            (_) => debugPrint(
              '$_queueEncryptionLogTag signing_key_wrapped_for_next_unlock',
            ),
          )
          .catchError(
            (Object error) => debugPrint(
              '$_queueEncryptionLogTag signing_key_wrap_failed error=$error',
            ),
          ),
    );

    if (encryptedPending.isEmpty) {
      // startSession() above already triggered retryPendingAttestations()
      // on success for any unencrypted pending rows.
      return const ActionResult.success();
    }
    return _decryptAndSubmitQueue(encryptedPending);
  }

  /// Shared tail of both [unlockQueueForSubmission] paths: unwraps (unless
  /// already unwrapped as part of a combined batch) and decrypts every
  /// row's payload, starts the 5-minute queue-unlock window, and runs the
  /// existing retry sweep. The decrypted cache this populates is destroyed
  /// after that window elapses or once the queue drains, whichever comes
  /// first - see [_lockQueue].
  Future<ActionResult> _decryptAndSubmitQueue(
    List<AttestationRecord> encryptedPending, {
    Map<String, Uint8List?>? preUnwrapped,
  }) async {
    Map<String, Uint8List?> unwrapped;
    if (preUnwrapped != null) {
      unwrapped = preUnwrapped;
    } else {
      final captureIds = encryptedPending
          .map((record) => record.captureId)
          .toList();
      final wrappedKeys = encryptedPending
          .map((record) => record.wrappedDataKey ?? '')
          .toList();
      debugPrint(
        '$_queueEncryptionLogTag unlock_requested batch_size=${captureIds.length}',
      );
      try {
        unwrapped = await _captureEncryptionService.unwrapDataKeys(
          captureIds: captureIds,
          wrappedKeysBase64: wrappedKeys,
        );
      } catch (error) {
        debugPrint(
          '$_queueEncryptionLogTag batch_unwrap_result=error error=$error',
        );
        return ActionResult.failure('Could not unlock queued captures: $error');
      }
    }

    for (final record in encryptedPending) {
      final dataKey = unwrapped[record.captureId];
      if (dataKey == null) {
        await _markTamperDetected(record);
        continue;
      }
      try {
        final decryptedJson = await _captureEncryptionService.decryptPayload(
          captureId: record.captureId,
          ciphertextBase64: record.encryptedPayload!,
          ivBase64: record.payloadIv!,
          dataKeyBytes: dataKey,
        );
        _decryptedQueuePayloads[record.captureId] = decryptedJson;
      } on PayloadTamperedException {
        await _markTamperDetected(record);
      }
    }

    _queueUnlockExpiresAt = DateTime.now().toUtc().add(
      const Duration(minutes: AppConstants.queueUnlockDurationMinutes),
    );
    _syncQueueUnlockTicker();
    notifyListeners();

    await retryPendingAttestations();
    return const ActionResult.success();
  }

  Future<void> _markTamperDetected(AttestationRecord record) async {
    debugPrint(
      '$_queueEncryptionLogTag[${record.captureId}] payload_decrypt_result=tamper_detected',
    );
    await _updateAttestationRecord(
      record,
      suiSubmissionStatus: 'TAMPER_DETECTED',
      suiErrorMessage:
          "This capture's stored data failed its integrity check and cannot be resubmitted.",
    );
    notifyListeners();
  }

  /// Rebuilds the submission-relevant fields a decrypted payload carries
  /// (§7.3) onto a lightweight stand-in [AttestationRecord] used only for
  /// reading at submission time - `record` itself (the persisted row)
  /// keeps its blanked plaintext columns unless/until
  /// `_updateAttestationRecord` declassifies it on a successful anchor.
  AttestationRecord _rehydrateFromDecryptedPayload(
    AttestationRecord record,
    Map<String, dynamic> decryptedPayload,
  ) {
    final proofPayloadJson =
        decryptedPayload['proofPayload'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    return AttestationRecord(
      captureId: record.captureId,
      capturedAt: record.capturedAt,
      submittedAt: record.submittedAt,
      imagePath: record.imagePath,
      imageSha256: decryptedPayload['imageSha256'] as String? ?? '',
      signatureBase64: decryptedPayload['signatureBase64'] as String? ?? '',
      walletAddress: record.walletAddress,
      publicKeyHex: record.publicKeyHex,
      proofPayload: AttestationProofPayload.fromJson(proofPayloadJson),
      suiTxDigest: record.suiTxDigest,
      suiObjectId: record.suiObjectId,
      suiSubmissionStatus: record.suiSubmissionStatus,
      suiErrorMessage: record.suiErrorMessage,
      projectId: record.projectId,
      tags: record.tags,
      note: record.note,
      assetType: record.assetType,
      fileName: record.fileName,
      mimeType: record.mimeType,
      fileSizeBytes: record.fileSizeBytes,
      fileExtension: record.fileExtension,
      previewKind: record.previewKind,
      storageMode: record.storageMode,
      isOnline: decryptedPayload['isOnline'] as bool? ?? true,
      isForcedOffline: decryptedPayload['isForcedOffline'] as bool? ?? false,
      internetNullReason: decryptedPayload['internetNullReason'] as String?,
      internetNullReasonHash:
          decryptedPayload['internetNullReasonHash'] as String?,
      hasGps: decryptedPayload['hasGps'] as bool? ?? true,
      isGpsForcedNull: decryptedPayload['isGpsForcedNull'] as bool? ?? false,
      gpsNullReason: decryptedPayload['gpsNullReason'] as String?,
      gpsNullReasonHash: decryptedPayload['gpsNullReasonHash'] as String?,
      submissionAttemptCount: record.submissionAttemptCount,
      lastAttemptAt: record.lastAttemptAt,
      encryptedPayload: record.encryptedPayload,
      payloadIv: record.payloadIv,
      wrappedDataKey: record.wrappedDataKey,
    );
  }

  Future<void> dismissResetNotice() async {
    if (_resetNotice == null) {
      return;
    }

    _resetNotice = null;
    await _secureStateService.dismissResetNotice();
    notifyListeners();
  }

  Future<void> resetForBiometricInvalidation() async {
    await _resetAppState(GraniteLakeSecureStateService.biometricChangedMessage);
  }

  Future<void> deleteAccount() async {
    final claim = _photoAttestationClaim;
    if (claim != null) {
      // Best-effort: local deletion must succeed even if this fails or the
      // device is offline. Without it, the server (and the on-chain
      // enabled flag) would keep listing this user as active indefinitely.
      try {
        await _photoAttestationService.deactivateUser(
          domain: claim.domain,
          userId: claim.userId,
        );
      } catch (_) {
        // Ignored: nothing the user can do about a failed server sync from
        // the delete-account flow, and their device-local deletion should
        // not be blocked by it.
      }
    }

    await _resetAppState(GraniteLakeSecureStateService.accountDeletedMessage);
  }

  Future<void> _resetAppState(String notice) async {
    await _secureStateService.resetApplicationState(
      biometricBinding: _biometricBinding,
      notice: notice,
    );
    await _captureWorkflowService.clearCaptureArtifacts();
    _clearLocalBiometricSessionState(clearIdentity: true);

    _hasCompletedRegistration = false;
    _deviceRegistration = null;
    _employee = null;
    _photoAttestationClaim = null;
    _lastAttestation = null;
    _lastPhotoCapture = null;
    _lastUploadedFile = null;
    _attestationHistory = const [];
    _photoCaptureHistory = const [];
    _uploadedFileHistory = const [];
    _attestationVerifications = const {};
    _verificationRetryCounts = const {};
    _projects = const [];
    _selectedProjectId = null;
    _photoAttestationConfig = null;
    _requiresLocalDataInitialization = true;
    _resetNotice = notice;
    _walletSuiBalanceMist = null;
    _isRefreshingWalletSuiBalance = false;
    _offlineCaptureForced = false;
    _gpsCaptureForcedNull = false;

    await _dataControllers.photoCapture.clear();
    await _dataControllers.uploadedFile.clear();
    await _dataControllers.project.clear();
    await _dataControllers.employee.clear();
    await _dataControllers.config.clear();
    notifyListeners();
  }

  Future<AttestationActionResult> persistCapture(
    String temporaryImagePath,
  ) async {
    return persistCaptureWithMetadata(temporaryImagePath);
  }

  Future<ActionResult> createProject({
    String? projectId,
    required String title,
  }) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      return const ActionResult.failure('Project title is required.');
    }
    final requestedProjectId = projectId?.trim().toLowerCase();
    final normalizedProjectId =
        requestedProjectId == null || requestedProjectId.isEmpty
        ? _generateProjectId(normalizedTitle)
        : requestedProjectId;
    if (!_uuidPattern.hasMatch(normalizedProjectId)) {
      return const ActionResult.failure(
        'Project ID must be a standard UUID v4.',
      );
    }
    final duplicateId = _projects.any(
      (project) => project.projectId == normalizedProjectId,
    );
    if (duplicateId) {
      return const ActionResult.failure('That project ID already exists.');
    }
    final duplicateTitle = _projects.any(
      (project) => project.title.toLowerCase() == normalizedTitle.toLowerCase(),
    );
    if (duplicateTitle) {
      return const ActionResult.failure('That project title already exists.');
    }

    final project = ProjectRecord(
      projectId: normalizedProjectId,
      title: normalizedTitle,
      createdAt: DateTime.now().toUtc(),
    );

    _projects = [..._projects, project]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _selectedProjectId = project.projectId;
    await _dataControllers.project.saveProject(project.toJson());
    await _persistSelectedProject();
    notifyListeners();
    return const ActionResult.success();
  }

  Future<void> selectProject(String? projectId) async {
    final normalizedProjectId = projectId?.trim();
    if (normalizedProjectId == null || normalizedProjectId.isEmpty) {
      _selectedProjectId = null;
      await _persistSelectedProject();
      notifyListeners();
      return;
    }

    final exists = _projects.any(
      (project) => project.projectId == normalizedProjectId,
    );
    if (!exists) {
      return;
    }

    if (_selectedProjectId == normalizedProjectId) {
      return;
    }

    _selectedProjectId = normalizedProjectId;
    await _persistSelectedProject();
    notifyListeners();
  }

  Future<void> refreshWalletSuiBalance({bool force = false}) async {
    final identity = _identity;
    final config = _photoAttestationConfig;
    if (identity == null || config == null || !config.isComplete) {
      if (_walletSuiBalanceMist != null) {
        _walletSuiBalanceMist = null;
        notifyListeners();
      }
      return;
    }
    if (_isRefreshingWalletSuiBalance && !force) {
      return;
    }

    _isRefreshingWalletSuiBalance = true;
    notifyListeners();
    try {
      _walletSuiBalanceMist = await _photoAttestationService
          .getWalletSuiBalanceMist(
            config: config,
            walletAddress: identity.walletAddress,
          );
    } catch (_) {
      if (force) {
        _walletSuiBalanceMist = null;
      }
    } finally {
      _isRefreshingWalletSuiBalance = false;
      notifyListeners();
    }
  }

  Future<AttestationActionResult> persistCaptureWithMetadata(
    String temporaryImagePath, {
    String? projectId,
    List<String> tags = const <String>[],
    String? note,
    DateTime? capturedAtUtc,
    DateTime? submittedAtUtc,
    String? buildLabel,
    String? gpsLabel,
    String? altitudeLabel,
    String? cameraLabel,
    String? cameraDetailsLabel,
    void Function(AttestationSubmissionProgress progress)? onProgress,
    bool isOnline = true,
    bool isForcedOffline = false,
    String? internetNullReason,
    bool hasGps = true,
    bool isGpsForcedNull = false,
    String? gpsNullReason,
  }) async {
    final identity = _identity;
    final session = _session;
    final sessionSigningKey = _sessionSigningKey;
    if (identity == null) {
      return const AttestationActionResult.failure(
        'Device identity is unavailable.',
      );
    }
    if (session == null || !session.isActive) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure capture session has expired.',
      );
    }
    if (sessionSigningKey == null) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }
    // gps/altitude are only mandatory when a fix was actually available
    // (hasGps) - offline-capture design doc §4a makes GPS optional the same
    // way connectivity is.
    final missingFields = <String>[
      if (capturedAtUtc == null) 'captured_at',
      if (submittedAtUtc == null) 'submitted_at',
      if (hasGps && (gpsLabel == null || gpsLabel.trim().isEmpty)) 'gps',
      if (hasGps && (altitudeLabel == null || altitudeLabel.trim().isEmpty))
        'altitude',
      if (projectId == null || projectId.trim().isEmpty) 'project_id',
    ];
    if (missingFields.isNotEmpty) {
      return AttestationActionResult.failure(
        'Capture submission failed. Missing required fields: ${missingFields.join(', ')}.',
      );
    }
    // Reads whatever balance is already cached rather than forcing a fresh
    // RPC read, so local persistence doesn't depend on live connectivity
    // (offline-capture design doc §6) - the real check still runs at actual
    // submission time via _submitPhotoAttestation. Skipped entirely when
    // this capture won't attempt a live submission anyway (offline, or
    // forced offline): the cached balance can't be verified without a
    // network call, and a device that's never been online yet (so nothing
    // has ever populated the cache) must not be permanently blocked from
    // queuing an offline capture just because the cache defaults to zero.
    final willAttemptLiveSubmission = isOnline && !isForcedOffline;
    if (willAttemptLiveSubmission &&
        (_walletSuiBalanceMist ?? BigInt.zero) <
            BigInt.from(AppConstants.minimumAttestationMistBalance)) {
      return AttestationActionResult.failure(
        'Your wallet needs at least ${AppConstants.minimumAttestationSuiBalance.toStringAsFixed(3)} SUI before submitting an attestation. Add test SUI and try again.',
      );
    }

    final result = await _captureWorkflowService.persistCapture(
      photoCaptureDataController: _dataControllers.photoCapture,
      identity: identity,
      session: session,
      sessionSigningKey: sessionSigningKey,
      temporaryImagePath: temporaryImagePath,
      projectId: projectId,
      tags: tags,
      note: note,
      capturedAtUtc: capturedAtUtc,
      submittedAtUtc: submittedAtUtc,
      buildLabel: buildLabel,
      gpsLabel: gpsLabel,
      altitudeLabel: altitudeLabel,
      cameraLabel: cameraLabel,
      cameraDetailsLabel: cameraDetailsLabel,
      onProgress: onProgress,
      isOnline: isOnline,
      isForcedOffline: isForcedOffline,
      internetNullReason: internetNullReason,
      hasGps: hasGps,
      isGpsForcedNull: isGpsForcedNull,
      gpsNullReason: gpsNullReason,
    );
    if (!result.isSuccess || result.record == null) {
      return result;
    }

    onProgress?.call(
      AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: AttestationSubmissionStageState.active,
        message: (isOnline && !isForcedOffline)
            ? 'Submitting the attestation transaction to Sui testnet.'
            : 'Queuing the capture for submission once connectivity returns.',
      ),
    );
    // Not effectively online (either no connectivity, or the crew forced
    // offline mode despite having it) - skip the doomed network round trip
    // here, at the *initial* attempt only. This must never be decided from
    // the record's own persisted isOnline/isForcedOffline on a later retry
    // attempt (retryPendingAttestations() calls _submitPhotoAttestation
    // directly for exactly that reason) - those fields describe conditions
    // at capture time, which by definition no longer hold once a retry is
    // actually happening, and gating on them there made a queued row
    // permanently unretryable.
    final record = (isOnline && !isForcedOffline)
        ? await _submitPhotoAttestation(
            result.record!,
            sessionSigningKey: sessionSigningKey,
            gpsLabel: gpsLabel,
            altitudeLabel: altitudeLabel,
            projectId: projectId,
          )
        : await _updateAttestationRecord(
            result.record!,
            suiObjectId: _photoAttestationClaim?.userCapObjectId,
            suiSubmissionStatus: 'PENDING_SUBMISSION',
            suiErrorMessage: '',
          );
    final submissionFailed = record.normalizedSuiSubmissionStatus.startsWith(
      'FAILED',
    );
    final submissionQueued =
        record.normalizedSuiSubmissionStatus == 'PENDING_SUBMISSION';
    onProgress?.call(
      AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: submissionFailed
            ? AttestationSubmissionStageState.failed
            : AttestationSubmissionStageState.completed,
        message: submissionFailed
            ? _attestationSubmissionFailureMessage(record)
            : submissionQueued
            ? 'Queued locally - will submit automatically once connectivity returns.'
            : 'Attestation transaction accepted by Sui.',
      ),
    );
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.active,
        message: 'Refreshing the on-device attestation ledger.',
      ),
    );
    final photoRecord = PhotoCaptureRecord.fromAttestationRecord(record);
    _lastAttestation = record;
    _lastPhotoCapture = photoRecord;
    _photoCaptureHistory = [
      photoRecord,
      ..._photoCaptureHistory.where(
        (item) => item.photoCaptureId != photoRecord.photoCaptureId,
      ),
    ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _syncAttestationHistory();
    final seededVerification = _seedVerificationFor(record);
    _attestationVerifications = {
      ..._attestationVerifications,
      record.captureId: seededVerification,
    };
    notifyListeners();
    if (record.isAttestationAnchored && !seededVerification.isVerified) {
      unawaited(verifyAttestationOnChain(record));
    }
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.completed,
        message: 'Local attestation history updated.',
      ),
    );
    return AttestationActionResult.success(record);
  }

  Future<AttestationActionResult> persistFileWithMetadata({
    required String sourceFilePath,
    required String sourceFileName,
    required int fileSizeBytes,
    required String mimeType,
    String? projectId,
    List<String> tags = const <String>[],
    String? note,
    DateTime? capturedAtUtc,
    DateTime? submittedAtUtc,
    String? buildLabel,
    void Function(AttestationSubmissionProgress progress)? onProgress,
    bool isOnline = true,
    bool isForcedOffline = false,
    String? internetNullReason,
  }) async {
    final identity = _identity;
    final session = _session;
    final sessionSigningKey = _sessionSigningKey;
    final claim = _photoAttestationClaim;
    if (identity == null) {
      return const AttestationActionResult.failure(
        'Device identity is unavailable.',
      );
    }
    if (session == null || !session.isActive) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure capture session has expired.',
      );
    }
    if (sessionSigningKey == null) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }
    if (claim == null) {
      return const AttestationActionResult.failure(
        'Claim your on-chain user record before uploading a file for attestation.',
      );
    }

    final missingFields = <String>[
      if (sourceFilePath.trim().isEmpty) 'file_path',
      if (sourceFileName.trim().isEmpty) 'file_name',
      if (fileSizeBytes <= 0) 'file_size_bytes',
      if (mimeType.trim().isEmpty) 'mime_type',
      if (capturedAtUtc == null) 'captured_at',
      if (submittedAtUtc == null) 'submitted_at',
      if (projectId == null || projectId.trim().isEmpty) 'project_id',
    ];
    if (missingFields.isNotEmpty) {
      return AttestationActionResult.failure(
        'File attestation failed. Missing required fields: ${missingFields.join(', ')}.',
      );
    }

    // Reads whatever balance is already cached rather than forcing a fresh
    // RPC read, and skipped entirely when offline - see the matching
    // comment in persistCaptureWithMetadata.
    final willAttemptLiveSubmission = isOnline && !isForcedOffline;
    if (willAttemptLiveSubmission &&
        (_walletSuiBalanceMist ?? BigInt.zero) <
            BigInt.from(AppConstants.minimumAttestationMistBalance)) {
      return AttestationActionResult.failure(
        'Your wallet needs at least ${AppConstants.minimumAttestationSuiBalance.toStringAsFixed(3)} SUI before submitting an attestation. Add test SUI and try again.',
      );
    }

    final result = await _captureWorkflowService.persistFile(
      uploadedFileDataController: _dataControllers.uploadedFile,
      identity: identity,
      session: session,
      sessionSigningKey: sessionSigningKey,
      sourceFilePath: sourceFilePath,
      sourceFileName: sourceFileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      projectId: projectId,
      tags: tags,
      note: note,
      capturedAtUtc: capturedAtUtc,
      submittedAtUtc: submittedAtUtc,
      buildLabel: buildLabel,
      domain: claim.domain,
      onProgress: onProgress,
      isOnline: isOnline,
      isForcedOffline: isForcedOffline,
      internetNullReason: internetNullReason,
    );
    if (!result.isSuccess || result.record == null) {
      return result;
    }

    onProgress?.call(
      AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: AttestationSubmissionStageState.active,
        message: (isOnline && !isForcedOffline)
            ? 'Submitting the file attestation transaction to Sui testnet.'
            : 'Queuing the file for submission once connectivity returns.',
      ),
    );
    // See the matching comment in persistCaptureWithMetadata - this skip
    // belongs only at the initial attempt, never inside
    // _submitFileAttestation itself.
    final record = (isOnline && !isForcedOffline)
        ? await _submitFileAttestation(
            result.record!,
            sessionSigningKey: sessionSigningKey,
            projectId: projectId,
          )
        : await _updateAttestationRecord(
            result.record!,
            suiObjectId: _photoAttestationClaim?.userCapObjectId,
            suiSubmissionStatus: 'PENDING_SUBMISSION',
            suiErrorMessage: '',
          );
    final submissionFailed = record.normalizedSuiSubmissionStatus.startsWith(
      'FAILED',
    );
    final submissionQueued =
        record.normalizedSuiSubmissionStatus == 'PENDING_SUBMISSION';
    onProgress?.call(
      AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: submissionFailed
            ? AttestationSubmissionStageState.failed
            : AttestationSubmissionStageState.completed,
        message: submissionFailed
            ? _attestationSubmissionFailureMessage(record)
            : submissionQueued
            ? 'Queued locally - will submit automatically once connectivity returns.'
            : 'File attestation transaction accepted by Sui.',
      ),
    );
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.active,
        message: 'Refreshing the on-device attestation ledger.',
      ),
    );
    final uploadedFile = UploadedFileRecord.fromAttestationRecord(record);
    _lastAttestation = record;
    _lastUploadedFile = uploadedFile;
    _uploadedFileHistory = [
      uploadedFile,
      ..._uploadedFileHistory.where(
        (item) => item.uploadedFileId != uploadedFile.uploadedFileId,
      ),
    ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _syncAttestationHistory();
    final seededVerification = _seedVerificationFor(record);
    _attestationVerifications = {
      ..._attestationVerifications,
      record.captureId: seededVerification,
    };
    notifyListeners();
    if (record.isAttestationAnchored && !seededVerification.isVerified) {
      unawaited(verifyAttestationOnChain(record));
    }
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.completed,
        message: 'Local attestation history updated.',
      ),
    );
    return AttestationActionResult.success(record);
  }

  @override
  void dispose() {
    if (identical(_current, this)) {
      _current = null;
    }
    _sessionTicker?.cancel();
    _queueUnlockTicker?.cancel();
    unawaited(_dataControllers.dispose());
    super.dispose();
  }

  Future<void> _persistSelectedProject() async {
    await _dataControllers.config.saveSelectedProjectId(_selectedProjectId);
  }

  Future<void> _loadDatabaseState() async {
    final employeeRow = await _dataControllers.employee.loadPrimaryEmployee();
    final projectRows = await _dataControllers.project.loadProjects();
    final photoCaptureRows = await _dataControllers.photoCapture
        .loadPhotoCaptures();
    final uploadedFileRows = await _dataControllers.uploadedFile
        .loadUploadedFiles();
    final selectedProjectId = await _dataControllers.config
        .loadSelectedProjectId();
    _photoAttestationConfig = await _dataControllers.config
        .syncPhotoAttestationContractConfig();
    _photoAttestationClaim = await _dataControllers.config
        .loadPhotoAttestationClaim();
    _offlineCaptureForced = await _dataControllers.config
        .loadOfflineCaptureForced();
    _gpsCaptureForcedNull = await _dataControllers.config
        .loadGpsCaptureForcedNull();

    _employee = employeeRow == null
        ? null
        : EmployeeRecord.fromJson(employeeRow);

    // Sync wallet address for existing employees if identity exists but employee doesn't have wallet
    if (_employee != null &&
        _identity != null &&
        _employee!.walletAddress.isEmpty) {
      await _dataControllers.employee.updateWalletAddress(
        _identity!.walletAddress,
      );
      final updatedRow = await _dataControllers.employee.loadPrimaryEmployee();
      _employee = updatedRow == null
          ? null
          : EmployeeRecord.fromJson(updatedRow);
    }
    _projects = projectRows.map(ProjectRecord.fromJson).toList(growable: false)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _photoCaptureHistory =
        photoCaptureRows
            .map(PhotoCaptureRecord.fromJson)
            .toList(growable: false)
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _uploadedFileHistory =
        uploadedFileRows
            .map(UploadedFileRecord.fromJson)
            .toList(growable: false)
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _lastPhotoCapture = _photoCaptureHistory.isEmpty
        ? null
        : _photoCaptureHistory.first;
    _lastUploadedFile = _uploadedFileHistory.isEmpty
        ? null
        : _uploadedFileHistory.first;
    _syncAttestationHistory();
    _lastAttestation = _attestationHistory.isEmpty
        ? null
        : _attestationHistory.first;
    _attestationVerifications = {
      for (final attestation in _attestationHistory)
        attestation.captureId: _localVerification(attestation),
    };
    _verificationRetryCounts = const {};

    final hasSavedSelection =
        selectedProjectId != null &&
        _projects.any((project) => project.projectId == selectedProjectId);
    _selectedProjectId = hasSavedSelection
        ? selectedProjectId
        : _projects.isEmpty
        ? null
        : _projects.first.projectId;
    _hasCompletedRegistration = _photoAttestationClaim != null;
    _requiresLocalDataInitialization = _employee == null;

    if (!hasSavedSelection || _selectedProjectId == null) {
      await _persistSelectedProject();
    }
  }

  Future<AttestationRecord> _submitPhotoAttestation(
    AttestationRecord record, {
    required SuiED25519PrivateKey sessionSigningKey,
    String? gpsLabel,
    String? altitudeLabel,
    String? projectId,
    // Offline-queue at-rest encryption (§7.3): non-null exactly when
    // `record` came off the queue with its plaintext columns blanked -
    // reads below prefer this over `record` for the fields §7.3 encrypts.
    // `_updateAttestationRecord` also receives it, so a row that actually
    // anchors on this attempt gets declassified (plaintext restored,
    // ciphertext dropped) rather than staying blank forever.
    AttestationRecord? decryptedRecord,
  }) async {
    final submissionSource = decryptedRecord ?? record;
    final identity = _identity;
    final config = _photoAttestationConfig;
    final claim = _photoAttestationClaim;
    if (identity == null ||
        config == null ||
        claim == null ||
        !config.isComplete) {
      return _updateAttestationRecord(
        record,
        suiSubmissionStatus: 'FAILED_NOT_CONFIGURED',
        suiErrorMessage:
            'Sui contract configuration is missing, so on-chain attestation could not be submitted.',
        decryptedRecord: decryptedRecord,
      );
    }

    try {
      final submission = await _photoAttestationService.attestPhoto(
        identity: identity,
        signingKey: sessionSigningKey,
        config: config,
        claim: claim,
        imageSha256: submissionSource.imageSha256,
        gps: resolveAttestationLabel(
          gpsLabel,
          fallback: AppConstants.attestationUnknownLabel,
        ),
        altitude: resolveAttestationLabel(
          altitudeLabel,
          fallback: AppConstants.attestationUnknownLabel,
        ),
        projectId: resolveAttestationLabel(
          projectId,
          fallback: AppConstants.attestationUnassignedLabel,
        ),
        capturedAtMs: record.capturedAt.millisecondsSinceEpoch,
        isOnline: submissionSource.isOnline,
        isForcedOffline: submissionSource.isForcedOffline,
        internetNullReasonHashHex: submissionSource.internetNullReasonHash,
        hasGps: submissionSource.hasGps,
        isGpsForcedNull: submissionSource.isGpsForcedNull,
        gpsNullReasonHashHex: submissionSource.gpsNullReasonHash,
      );
      final updated = await _updateAttestationRecord(
        record,
        suiTxDigest: submission.transactionDigest,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: submission.status,
        suiErrorMessage: '',
        incrementAttempt: true,
        decryptedRecord: decryptedRecord,
      );
      final verification = submission.verification;
      if (verification != null) {
        _attestationVerifications = {
          ..._attestationVerifications,
          record.captureId: AttestationChainVerificationRecord(
            state: verification.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: verification.transactionDigest,
            transactionStatus: verification.transactionStatus,
            photoHashMatches: verification.photoHashMatches,
            senderMatches: verification.senderMatches,
            gpsMatches: verification.gpsMatches,
            altitudeMatches: verification.altitudeMatches,
            projectIdMatches: verification.projectIdMatches,
            timestampWithinTolerance: verification.timestampWithinTolerance,
            chainTimestamp: verification.chainTimestamp,
            failureReason: verification.failureReason,
          ),
        };
      }
      return updated;
    } on PhotoAttestationException catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: _isNetworkClassFailure(error)
            ? 'PENDING_SUBMISSION'
            : 'FAILED_SUBMISSION',
        suiErrorMessage: error.userMessage,
        incrementAttempt: true,
        decryptedRecord: decryptedRecord,
      );
    } catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: _isNetworkClassFailure(error)
            ? 'PENDING_SUBMISSION'
            : 'FAILED_SUBMISSION',
        suiErrorMessage: 'The attestation transaction failed: $error',
        incrementAttempt: true,
        decryptedRecord: decryptedRecord,
      );
    }
  }

  // Treats a Sui object-version race (a stale gas-coin reference from
  // submitting several queued attestations back-to-back - see
  // photo_attestation_service.dart's own 3-attempt retry for this) the same
  // as a network failure here too: not a real rejection, so it must stay
  // PENDING_SUBMISSION rather than terminate as FAILED_SUBMISSION. That
  // keeps it in the same queue as every other pending row, picked up by the
  // existing periodic sweep infrastructure (connectivity-restored trigger,
  // app-foreground trigger, and app.dart's 20s fallback poll) - an
  // unbounded, properly-paced retry until it succeeds, rather than a
  // second bespoke queue duplicating that same machinery.
  bool _isNetworkClassFailure(Object error) {
    if (isTransientNetworkError(error)) {
      return true;
    }
    if (error is PhotoAttestationException) {
      return looksLikeTransientNetworkFailure(error.rawMessage) ||
          looksLikeTransientNetworkFailure(error.userMessage) ||
          looksLikeObjectVersionRaceFailure(error.rawMessage) ||
          looksLikeObjectVersionRaceFailure(error.userMessage);
    }
    return looksLikeTransientNetworkFailure('$error') ||
        looksLikeObjectVersionRaceFailure('$error');
  }

  /// A `FAILED_SUBMISSION` row whose recorded error was actually a
  /// network/object-version-race failure - i.e. one that predates this
  /// classification living in [_isNetworkClassFailure] (or that otherwise
  /// slipped through), so it's stuck permanently excluded from the normal
  /// PENDING_SUBMISSION sweep for no good reason. The retry sweep also
  /// picks these up, so a row doesn't stay stranded just because it failed
  /// once before this classification existed.
  bool _isRecoverableFailure(AttestationRecord record) {
    if (!record.isAttestationFailed) {
      return false;
    }
    final message = record.suiErrorMessage;
    return looksLikeTransientNetworkFailure(message) ||
        looksLikeObjectVersionRaceFailure(message);
  }

  Future<AttestationRecord> _submitFileAttestation(
    AttestationRecord record, {
    required SuiED25519PrivateKey sessionSigningKey,
    required String? projectId,
    // Offline-queue at-rest encryption (§7.3) - see
    // _submitPhotoAttestation's parameter doc.
    AttestationRecord? decryptedRecord,
  }) async {
    final submissionSource = decryptedRecord ?? record;
    final identity = _identity;
    final config = _photoAttestationConfig;
    final claim = _photoAttestationClaim;
    if (identity == null ||
        config == null ||
        claim == null ||
        !config.isComplete) {
      return _updateAttestationRecord(
        record,
        suiSubmissionStatus: 'FAILED_NOT_CONFIGURED',
        suiErrorMessage:
            'Sui contract configuration is missing, so on-chain attestation could not be submitted.',
        decryptedRecord: decryptedRecord,
      );
    }

    try {
      final submission = await _photoAttestationService.attestFile(
        identity: identity,
        signingKey: sessionSigningKey,
        config: config,
        claim: claim,
        record: submissionSource,
        projectId: resolveAttestationLabel(
          projectId,
          fallback: AppConstants.attestationUnassignedLabel,
        ),
        capturedAtMs: record.capturedAt.millisecondsSinceEpoch,
        isOnline: submissionSource.isOnline,
        isForcedOffline: submissionSource.isForcedOffline,
        internetNullReasonHashHex: submissionSource.internetNullReasonHash,
      );
      final updated = await _updateAttestationRecord(
        record,
        suiTxDigest: submission.transactionDigest,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: submission.status,
        suiErrorMessage: '',
        incrementAttempt: true,
        decryptedRecord: decryptedRecord,
      );
      final verification = submission.verification;
      if (verification != null) {
        _attestationVerifications = {
          ..._attestationVerifications,
          record.captureId: AttestationChainVerificationRecord(
            state: verification.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: verification.transactionDigest,
            transactionStatus: verification.transactionStatus,
            photoHashMatches: verification.fileHashMatches,
            senderMatches: verification.senderMatches,
            projectIdMatches: verification.projectIdMatches,
            fileIdMatches: verification.fileIdMatches,
            timestampWithinTolerance: verification.timestampWithinTolerance,
            chainTimestamp: verification.chainTimestamp,
            failureReason: verification.failureReason,
          ),
        };
      }
      return updated;
    } on PhotoAttestationException catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: _isNetworkClassFailure(error)
            ? 'PENDING_SUBMISSION'
            : 'FAILED_SUBMISSION',
        suiErrorMessage: error.userMessage,
        incrementAttempt: true,
        decryptedRecord: decryptedRecord,
      );
    } catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: _isNetworkClassFailure(error)
            ? 'PENDING_SUBMISSION'
            : 'FAILED_SUBMISSION',
        suiErrorMessage: 'The attestation transaction failed: $error',
        incrementAttempt: true,
        decryptedRecord: decryptedRecord,
      );
    }
  }

  String _attestationSubmissionFailureMessage(AttestationRecord record) {
    return switch (record.normalizedSuiSubmissionStatus) {
      'FAILED_NOT_CONFIGURED' =>
        'Sui contract configuration is missing, so on-chain attestation could not be submitted.',
      'FAILED_SUBMISSION' =>
        record.attestationErrorLabel ??
            'The Sui attestation transaction failed. Check network access and wallet gas, then try again later.',
      _ =>
        record.attestationErrorLabel ??
            'The on-chain attestation did not complete successfully.',
    };
  }

  Future<void> verifyAttestationOnChain(AttestationRecord capture) async {
    final config = _photoAttestationConfig;
    if (config == null || !config.isComplete) {
      _attestationVerifications = {
        ..._attestationVerifications,
        capture.captureId: AttestationChainVerificationRecord(
          state: AttestationChainVerificationState.failed,
          checkedAt: DateTime.now().toUtc(),
          transactionDigest: capture.suiTxDigest,
          transactionStatus: capture.suiSubmissionStatus,
          failureReason: 'Contract config is unavailable.',
        ),
      };
      notifyListeners();
      return;
    }

    final baseline = _localVerification(capture);
    if (!capture.isAttestationAnchored) {
      final existing = _attestationVerifications[capture.captureId];
      if (existing == null || existing.state != baseline.state) {
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: baseline,
        };
        notifyListeners();
      }
      return;
    }

    _attestationVerifications = {
      ..._attestationVerifications,
      capture.captureId: AttestationChainVerificationRecord(
        state: AttestationChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      ),
    };
    notifyListeners();

    try {
      if (capture.isFile) {
        final result = await _photoAttestationService.verifyFileAttestation(
          config: config,
          capture: capture,
        );
        final shouldRetry =
            !result.isVerified &&
            _shouldRetryChainVerification(result.failureReason);
        if (shouldRetry && _scheduleVerificationRetry(capture)) {
          _attestationVerifications = {
            ..._attestationVerifications,
            capture.captureId: AttestationChainVerificationRecord(
              state: AttestationChainVerificationState.pending,
              checkedAt: DateTime.now().toUtc(),
              transactionDigest: result.transactionDigest,
              transactionStatus: result.transactionStatus,
              failureReason: result.failureReason,
            ),
          };
          notifyListeners();
          return;
        }
        _clearVerificationRetry(capture.captureId);
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: AttestationChainVerificationRecord(
            state: result.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: result.transactionDigest,
            transactionStatus: result.transactionStatus,
            photoHashMatches: result.fileHashMatches,
            senderMatches: result.senderMatches,
            projectIdMatches: result.projectIdMatches,
            fileIdMatches: result.fileIdMatches,
            timestampWithinTolerance: result.timestampWithinTolerance,
            chainTimestamp: result.chainTimestamp,
            failureReason: result.failureReason,
          ),
        };
      } else {
        final result = await _photoAttestationService.verifyPhotoAttestation(
          config: config,
          capture: capture,
        );
        final shouldRetry =
            !result.isVerified &&
            _shouldRetryChainVerification(result.failureReason);
        if (shouldRetry && _scheduleVerificationRetry(capture)) {
          _attestationVerifications = {
            ..._attestationVerifications,
            capture.captureId: AttestationChainVerificationRecord(
              state: AttestationChainVerificationState.pending,
              checkedAt: DateTime.now().toUtc(),
              transactionDigest: result.transactionDigest,
              transactionStatus: result.transactionStatus,
              failureReason: result.failureReason,
            ),
          };
          notifyListeners();
          return;
        }
        _clearVerificationRetry(capture.captureId);
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: AttestationChainVerificationRecord(
            state: result.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: result.transactionDigest,
            transactionStatus: result.transactionStatus,
            photoHashMatches: result.photoHashMatches,
            senderMatches: result.senderMatches,
            gpsMatches: result.gpsMatches,
            altitudeMatches: result.altitudeMatches,
            projectIdMatches: result.projectIdMatches,
            timestampWithinTolerance: result.timestampWithinTolerance,
            chainTimestamp: result.chainTimestamp,
            failureReason: result.failureReason,
          ),
        };
      }
    } catch (error) {
      // String-based, not the type-based classifier: getTransaction (see
      // sui_graphql_service.dart) throws a plain StateError with an
      // "...may not be indexed yet" message on indexer lag, which isn't a
      // SocketException/TimeoutException/http.ClientException by type, so
      // only the message-keyword check catches it.
      if (_shouldRetryChainVerification('$error') &&
          _scheduleVerificationRetry(capture)) {
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: AttestationChainVerificationRecord(
            state: AttestationChainVerificationState.pending,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: capture.suiTxDigest,
            transactionStatus: capture.suiSubmissionStatus,
            failureReason: '$error',
          ),
        };
        notifyListeners();
        return;
      }
      _clearVerificationRetry(capture.captureId);
      // Reaching this catch block means the verification round-trip itself
      // never completed (network error, timeout, indexer lag, etc.) — it is
      // not evidence the on-chain attestation failed. A genuine on-chain
      // failure comes back as a normal (non-throwing) result with
      // transactionStatus != 'SUCCESS', handled separately above. So we
      // leave this as pending rather than flipping it to a hard "failed",
      // which previously caused the status to flash failed on every
      // exhausted retry even when the device simply had no connection.
      _attestationVerifications = {
        ..._attestationVerifications,
        capture.captureId: AttestationChainVerificationRecord(
          state: AttestationChainVerificationState.pending,
          checkedAt: DateTime.now().toUtc(),
          transactionDigest: capture.suiTxDigest,
          transactionStatus: capture.suiSubmissionStatus,
          failureReason:
              'Could not reach the network to verify this attestation. '
              'It will be re-checked automatically once a connection is '
              'available. ($error)',
        ),
      };
    }
    notifyListeners();
  }

  bool _shouldRetryChainVerification(String? failureReason) {
    return looksLikeTransientNetworkFailure(failureReason);
  }

  bool _scheduleVerificationRetry(AttestationRecord capture) {
    final captureId = capture.captureId;
    final attempt = (_verificationRetryCounts[captureId] ?? 0) + 1;
    const maxAttempts = 5;
    if (attempt > maxAttempts) {
      return false;
    }
    _verificationRetryCounts = {
      ..._verificationRetryCounts,
      captureId: attempt,
    };

    final delay = Duration(seconds: attempt * 3);
    Future<void>.delayed(delay, () async {
      final latest = _attestationHistory
          .where((item) => item.captureId == captureId)
          .firstOrNull;
      if (latest == null || !latest.isAttestationAnchored) {
        _clearVerificationRetry(captureId);
        return;
      }
      await verifyAttestationOnChain(latest);
    });

    return true;
  }

  void _clearVerificationRetry(String captureId) {
    if (!_verificationRetryCounts.containsKey(captureId)) {
      return;
    }
    final next = {..._verificationRetryCounts};
    next.remove(captureId);
    _verificationRetryCounts = next;
  }

  Future<void> verifyAttestationsOnChain(
    Iterable<AttestationRecord> captures,
  ) async {
    for (final capture in captures) {
      final current = _attestationVerifications[capture.captureId];
      if (current?.isVerified == true) {
        continue;
      }
      unawaited(verifyAttestationOnChain(capture));
    }
  }

  AttestationChainVerificationRecord _localVerification(
    AttestationRecord capture,
  ) {
    if (capture.isAttestationAnchored) {
      return AttestationChainVerificationRecord(
        state: AttestationChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      );
    }
    if (capture.isAttestationPending) {
      return AttestationChainVerificationRecord(
        state: AttestationChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      );
    }
    return AttestationChainVerificationRecord(
      state: AttestationChainVerificationState.failed,
      checkedAt: DateTime.now().toUtc(),
      transactionDigest: capture.suiTxDigest,
      transactionStatus: capture.suiSubmissionStatus,
      failureReason: capture.suiSubmissionStatus,
    );
  }

  /// Seeds/refreshes the local (optimistic, not-yet-on-chain-checked)
  /// verification entry for [capture]. Only reuses whatever's already
  /// cached for this captureId when that entry reflects a *real* resolved
  /// check (verified/mismatched/failed from an actual verifyAttestationOnChain
  /// call) - never when it's itself just a local pending placeholder, since
  /// that placeholder was seeded against whatever suiSubmissionStatus held
  /// at the time and goes stale the moment that status changes (e.g. a
  /// PENDING_SUBMISSION row that a queue retry just resolved to
  /// SUCCESS/FAILED_SUBMISSION - reusing the old placeholder verbatim would
  /// keep showing "PENDING" in History forever, since nothing else was
  /// ever going to overwrite it).
  AttestationChainVerificationRecord _seedVerificationFor(
    AttestationRecord capture,
  ) {
    final existing = _attestationVerifications[capture.captureId];
    if (existing != null && !existing.isPending) {
      return existing;
    }
    return _localVerification(capture);
  }

  Future<AttestationRecord> _updateAttestationRecord(
    AttestationRecord record, {
    String? suiTxDigest,
    String? suiObjectId,
    String? suiSubmissionStatus,
    String? suiErrorMessage,
    // App-local only, never submitted on-chain (migrations.dart version-12).
    // Set true from _submitPhotoAttestation/_submitFileAttestation whenever
    // they actually make a network attempt (success or failure alike) -
    // never from the offline-skip path, which never tried at all.
    bool incrementAttempt = false,
    // Offline-queue at-rest encryption (§7.3): the rehydrated stand-in
    // used to read real values at submission time when `record` came off
    // the queue with its plaintext columns blanked. Only used here to
    // *declassify* - see the anchored check below.
    AttestationRecord? decryptedRecord,
  }) async {
    AttestationRecord buildFrom(
      AttestationRecord plaintextSource, {
      required bool clearEncryption,
    }) {
      return AttestationRecord(
        captureId: record.captureId,
        capturedAt: record.capturedAt,
        submittedAt: record.submittedAt,
        imagePath: record.imagePath,
        imageSha256: plaintextSource.imageSha256,
        signatureBase64: plaintextSource.signatureBase64,
        walletAddress: record.walletAddress,
        publicKeyHex: record.publicKeyHex,
        proofPayload: plaintextSource.proofPayload,
        suiTxDigest: suiTxDigest ?? record.suiTxDigest,
        suiObjectId: suiObjectId ?? record.suiObjectId,
        suiSubmissionStatus: suiSubmissionStatus ?? record.suiSubmissionStatus,
        suiErrorMessage: suiErrorMessage ?? record.suiErrorMessage,
        projectId: record.projectId,
        tags: record.tags,
        note: record.note,
        assetType: record.assetType,
        fileName: record.fileName,
        mimeType: record.mimeType,
        fileSizeBytes: record.fileSizeBytes,
        fileExtension: record.fileExtension,
        previewKind: record.previewKind,
        storageMode: record.storageMode,
        isOnline: plaintextSource.isOnline,
        isForcedOffline: plaintextSource.isForcedOffline,
        internetNullReason: plaintextSource.internetNullReason,
        internetNullReasonHash: plaintextSource.internetNullReasonHash,
        hasGps: plaintextSource.hasGps,
        isGpsForcedNull: plaintextSource.isGpsForcedNull,
        gpsNullReason: plaintextSource.gpsNullReason,
        gpsNullReasonHash: plaintextSource.gpsNullReasonHash,
        submissionAttemptCount: incrementAttempt
            ? record.submissionAttemptCount + 1
            : record.submissionAttemptCount,
        lastAttemptAt: incrementAttempt
            ? DateTime.now().toUtc()
            : record.lastAttemptAt,
        encryptedPayload: clearEncryption ? null : record.encryptedPayload,
        payloadIv: clearEncryption ? null : record.payloadIv,
        wrappedDataKey: clearEncryption ? null : record.wrappedDataKey,
      );
    }

    var updated = buildFrom(record, clearEncryption: false);
    // Offline-queue at-rest encryption (§7.3): once a previously-encrypted
    // row is actually anchored on-chain, tamper protection no longer
    // serves a purpose - declassify it (restore the real plaintext columns
    // from the decrypted payload, drop the now-redundant ciphertext) so
    // history/detail UI shows real values instead of the placeholder
    // blanks it was persisted with while still queued. A row that didn't
    // anchor this attempt (still pending, or a definite rejection) stays
    // exactly as blank as it was - only a confirmed on-chain anchor earns
    // this.
    if (record.isEncryptedAtRest &&
        decryptedRecord != null &&
        updated.isAttestationAnchored) {
      debugPrint(
        '$_queueEncryptionLogTag[${record.captureId}] declassified status=${updated.suiSubmissionStatus}',
      );
      updated = buildFrom(decryptedRecord, clearEncryption: true);
    }
    if (updated.isFile) {
      final uploadedFile = UploadedFileRecord.fromAttestationRecord(updated);
      await _dataControllers.uploadedFile.saveUploadedFile(
        uploadedFile.toJson(),
      );
      _lastUploadedFile = uploadedFile;
      _uploadedFileHistory = [
        uploadedFile,
        ..._uploadedFileHistory.where(
          (item) => item.uploadedFileId != uploadedFile.uploadedFileId,
        ),
      ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    } else {
      final photoCapture = PhotoCaptureRecord.fromAttestationRecord(updated);
      await _dataControllers.photoCapture.savePhotoCapture(
        photoCapture.toJson(),
      );
      _lastPhotoCapture = photoCapture;
      _photoCaptureHistory = [
        photoCapture,
        ..._photoCaptureHistory.where(
          (item) => item.photoCaptureId != photoCapture.photoCaptureId,
        ),
      ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    }
    _syncAttestationHistory();
    _lastAttestation = _attestationHistory.isEmpty
        ? null
        : _attestationHistory.first;
    return updated;
  }

  void _syncAttestationHistory() {
    _attestationHistory = [
      ..._photoCaptureHistory.map((item) => item.toAttestationRecord()),
      ..._uploadedFileHistory.map((item) => item.toAttestationRecord()),
    ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  }

  String _generateProjectId(String title) {
    final random = Random.secure();

    while (true) {
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;

      final hex = bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      final candidate = [
        hex.substring(0, 8),
        hex.substring(8, 12),
        hex.substring(12, 16),
        hex.substring(16, 20),
        hex.substring(20, 32),
      ].join('-');

      final exists = _projects.any((project) => project.projectId == candidate);
      if (!exists) {
        return candidate;
      }
    }
  }

  void _applySecureInitializationState(SecureInitializationState state) {
    _hasCompletedRegistration = state.hasCompletedRegistration;
    _deviceRegistration = state.deviceRegistration;
    _identity = state.identity;
    _photoAttestationClaim = state.photoAttestationClaim;
    _biometricBinding = state.biometricBinding;
    _biometricGatePayload = state.biometricGatePayload;
    _resetNotice = state.resetNotice;
    _clearLocalSessionState();
  }

  ActionResult _toActionResult<T>(SecureOperationResult<T> result) {
    if (result.isSuccess) {
      return const ActionResult.success();
    }
    if (result.code != null) {
      return ActionResult.failureWithCode(
        result.code!,
        result.message ?? 'Operation failed.',
      );
    }
    return ActionResult.failure(result.message ?? 'Operation failed.');
  }

  void _clearLocalBiometricSessionState({bool clearIdentity = false}) {
    _biometricBinding = null;
    _biometricGatePayload = null;
    _clearLocalSessionState();
    if (clearIdentity) {
      _identity = null;
    }
  }

  void _clearLocalSessionState() {
    _sessionTicker?.cancel();
    _sessionTicker = null;
    _sessionSigningKey = null;
    _session = null;
    // Tearing down the signing session (biometric invalidation, account
    // reset/deletion) also tears down the independent §7.3 queue-unlock
    // window - there's no scenario where the former goes away but the
    // latter should keep decrypted data alive.
    _lockQueue(reason: 'session_cleared');
  }

  void _syncSessionTicker() {
    _sessionTicker?.cancel();
    final session = _session;
    if (session == null || !session.isActive) {
      _sessionTicker = null;
      return;
    }

    _sessionTicker = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!hasActiveSession) {
        timer.cancel();
        await endSession();
        return;
      }
      notifyListeners();
    });
  }

  // Offline-queue at-rest encryption (§7.3): the 5-minute decrypted-queue
  // window, independent of _syncSessionTicker above.
  void _syncQueueUnlockTicker() {
    _queueUnlockTicker?.cancel();
    if (_queueUnlockExpiresAt == null) {
      _queueUnlockTicker = null;
      return;
    }

    _queueUnlockTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!isQueueUnlocked) {
        timer.cancel();
        _lockQueue(reason: 'ticker_expired');
        return;
      }
      notifyListeners();
    });
  }

  /// Destroys every decrypted queue payload, the queue-scoped signing key,
  /// and cancels the unlock window. Called when the 5-minute ticker fires,
  /// immediately once the queue drains to zero mid-sweep
  /// (`retryPendingAttestations`), and whenever the general signing
  /// session is torn down (`_clearLocalSessionState`).
  void _lockQueue({required String reason}) {
    if (_decryptedQueuePayloads.isEmpty &&
        _queueUnlockExpiresAt == null &&
        _queueSigningKey == null) {
      return;
    }
    debugPrint(
      '$_queueEncryptionLogTag lock_triggered reason=$reason cleared=${_decryptedQueuePayloads.length}',
    );
    _decryptedQueuePayloads.clear();
    _queueSigningKey = null;
    _queueUnlockTicker?.cancel();
    _queueUnlockTicker = null;
    _queueUnlockExpiresAt = null;
    notifyListeners();
  }
}
