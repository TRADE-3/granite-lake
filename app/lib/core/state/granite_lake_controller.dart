import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:on_chain/sui/sui.dart';

import '../database/granite_lake_data_controllers.dart';
import '../constants/app_constants.dart';
import '../services/granite_lake_capture_workflow_service.dart';
import '../services/photo_attestation_service.dart';
import '../services/granite_lake_secure_state_service.dart';
import 'granite_lake_models.dart';

export 'granite_lake_models.dart';

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class GraniteLakeController extends ChangeNotifier {
  GraniteLakeController()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      ),
      _dataControllers = GraniteLakeDataControllers.create() {
    _secureStateService = GraniteLakeSecureStateService(storage: _storage);
    _captureWorkflowService = GraniteLakeCaptureWorkflowService();
    _photoAttestationService = PhotoAttestationService();
  }

  final FlutterSecureStorage _storage;
  final GraniteLakeDataControllers _dataControllers;
  late final GraniteLakeSecureStateService _secureStateService;
  late final GraniteLakeCaptureWorkflowService _captureWorkflowService;
  late final PhotoAttestationService _photoAttestationService;

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
  CaptureRecord? _lastCapture;
  List<CaptureRecord> _captureHistory = const [];
  Map<String, CaptureChainVerificationRecord> _captureVerifications = const {};
  String? _resetNotice;
  List<ProjectRecord> _projects = const [];
  String? _selectedProjectId;
  PhotoAttestationContractConfig? _photoAttestationConfig;
  bool _requiresLocalDataInitialization = false;
  BigInt? _walletSuiBalanceMist;
  bool _isRefreshingWalletSuiBalance = false;

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
  CaptureRecord? get lastCapture => _lastCapture;
  List<CaptureRecord> get captureHistory => List.unmodifiable(_captureHistory);
  CaptureChainVerificationRecord? captureVerificationFor(String captureId) =>
      _captureVerifications[captureId];
  String? get resetNotice => _resetNotice;
  List<ProjectRecord> get projects => List.unmodifiable(_projects);
  String? get selectedProjectId => _selectedProjectId;
  PhotoAttestationContractConfig? get photoAttestationConfig =>
      _photoAttestationConfig;
  bool get requiresLocalDataInitialization => _requiresLocalDataInitialization;
  BigInt? get walletSuiBalanceMist => _walletSuiBalanceMist;
  bool get isRefreshingWalletSuiBalance => _isRefreshingWalletSuiBalance;
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
      return SecureOperationResult.failure('OTP request failed: $error');
    }
  }

  Future<ActionResult> claimPhotoAttestationUser({
    required String domain,
    required String userId,
    required String otp,
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
    if (normalizedDomain.isEmpty ||
        normalizedUserId.isEmpty ||
        normalizedOtp.isEmpty) {
      return const ActionResult.failure(
        'Company domain, OTP session id, and OTP are all required.',
      );
    }

    try {
      final claim = await _photoAttestationService.claimUserWithOtp(
        identity: identity,
        config: config,
        input: PhotoAttestationClaimInput(
          domain: normalizedDomain,
          userId: normalizedUserId,
          otp: normalizedOtp,
        ),
      );
      await _dataControllers.config.savePhotoAttestationClaim(claim);
      await _dataControllers.employee.saveClaimedEmployee(
        employeeId: normalizedUserId,
        companyDomain: normalizedDomain,
      );
      _photoAttestationClaim = claim;
      _employee = EmployeeRecord.fromJson(
        (await _dataControllers.employee.loadPrimaryEmployee())!,
      );
      _hasCompletedRegistration = true;
      _resetNotice = null;
      _deviceRegistration ??=
          (await _secureStateService.loadPersistedState()).deviceRegistration;
      unawaited(refreshWalletSuiBalance(force: true));
      notifyListeners();
      return const ActionResult.success();
    } on PhotoAttestationException catch (error) {
      return ActionResult.failure(error.userMessage);
    } catch (error) {
      return ActionResult.failure('User claim failed: $error');
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

  Future<ActionResult> startSession() async {
    if (hasActiveSession) {
      return const ActionResult.success();
    }

    final result = await _secureStateService.startSession(
      identity: _identity,
      biometricBinding: _biometricBinding,
      biometricGatePayload: _biometricGatePayload,
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
    return const ActionResult.success();
  }

  Future<void> endSession() async {
    await _secureStateService.endSession();
    _clearLocalSessionState();
    notifyListeners();
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
    _lastCapture = null;
    _captureHistory = const [];
    _captureVerifications = const {};
    _projects = const [];
    _selectedProjectId = null;
    _photoAttestationConfig = null;
    _requiresLocalDataInitialization = true;
    _resetNotice = notice;
    _walletSuiBalanceMist = null;
    _isRefreshingWalletSuiBalance = false;

    await _dataControllers.capture.clear();
    await _dataControllers.project.clear();
    await _dataControllers.employee.clear();
    await _dataControllers.config.clear();
    notifyListeners();
  }

  Future<CaptureActionResult> persistCapture(String temporaryImagePath) async {
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

  Future<CaptureActionResult> persistCaptureWithMetadata(
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
    void Function(CaptureSubmissionProgress progress)? onProgress,
  }) async {
    final identity = _identity;
    final session = _session;
    final sessionSigningKey = _sessionSigningKey;
    if (identity == null) {
      return const CaptureActionResult.failure(
        'Device identity is unavailable.',
      );
    }
    if (session == null || !session.isActive) {
      await endSession();
      return const CaptureActionResult.failure(
        'Your secure capture session has expired.',
      );
    }
    if (sessionSigningKey == null) {
      await endSession();
      return const CaptureActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }
    final missingFields = <String>[
      if (capturedAtUtc == null) 'captured_at',
      if (submittedAtUtc == null) 'submitted_at',
      if (gpsLabel == null || gpsLabel.trim().isEmpty) 'gps',
      if (altitudeLabel == null || altitudeLabel.trim().isEmpty) 'altitude',
      if (projectId == null || projectId.trim().isEmpty) 'project_id',
    ];
    if (missingFields.isNotEmpty) {
      return CaptureActionResult.failure(
        'Capture submission failed. Missing required fields: ${missingFields.join(', ')}.',
      );
    }
    await refreshWalletSuiBalance(force: true);
    if ((_walletSuiBalanceMist ?? BigInt.zero) <
        BigInt.from(AppConstants.minimumAttestationMistBalance)) {
      return CaptureActionResult.failure(
        'Your wallet needs at least ${AppConstants.minimumAttestationSuiBalance.toStringAsFixed(3)} SUI before submitting a photo. Add test SUI and try again.',
      );
    }

    final result = await _captureWorkflowService.persistCapture(
      captureDataController: _dataControllers.capture,
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
    );
    if (!result.isSuccess || result.record == null) {
      return result;
    }

    onProgress?.call(
      const CaptureSubmissionProgress(
        stage: CaptureSubmissionStage.submittingToChain,
        state: CaptureSubmissionStageState.active,
        message: 'Submitting the attestation transaction to Sui testnet.',
      ),
    );
    final record = await _submitPhotoAttestation(
      result.record!,
      sessionSigningKey: sessionSigningKey,
      gpsLabel: gpsLabel,
      altitudeLabel: altitudeLabel,
      projectId: projectId,
    );
    final submissionFailed = record.normalizedSuiSubmissionStatus.startsWith(
      'FAILED',
    );
    onProgress?.call(
      CaptureSubmissionProgress(
        stage: CaptureSubmissionStage.submittingToChain,
        state: submissionFailed
            ? CaptureSubmissionStageState.failed
            : CaptureSubmissionStageState.completed,
        message: submissionFailed
            ? _captureSubmissionFailureMessage(record)
            : 'Attestation transaction accepted by Sui.',
      ),
    );
    onProgress?.call(
      const CaptureSubmissionProgress(
        stage: CaptureSubmissionStage.refreshingHistory,
        state: CaptureSubmissionStageState.active,
        message: 'Refreshing the on-device capture ledger.',
      ),
    );
    _lastCapture = record;
    _captureHistory = [
      record,
      ..._captureHistory.where((item) => item.captureId != record.captureId),
    ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    final seededVerification =
        _captureVerifications[record.captureId] ?? _localVerification(record);
    _captureVerifications = {
      ..._captureVerifications,
      record.captureId: seededVerification,
    };
    notifyListeners();
    if (record.isAttestationAnchored && !seededVerification.isVerified) {
      unawaited(verifyCaptureOnChain(record));
    }
    onProgress?.call(
      const CaptureSubmissionProgress(
        stage: CaptureSubmissionStage.refreshingHistory,
        state: CaptureSubmissionStageState.completed,
        message: 'Local capture history updated.',
      ),
    );
    return CaptureActionResult.success(record);
  }

  @override
  void dispose() {
    _sessionTicker?.cancel();
    unawaited(_dataControllers.dispose());
    super.dispose();
  }

  Future<void> _persistSelectedProject() async {
    await _dataControllers.config.saveSelectedProjectId(_selectedProjectId);
  }

  Future<void> _loadDatabaseState() async {
    final employeeRow = await _dataControllers.employee.loadPrimaryEmployee();
    final projectRows = await _dataControllers.project.loadProjects();
    final captureRows = await _dataControllers.capture.loadCaptures();
    final selectedProjectId = await _dataControllers.config
        .loadSelectedProjectId();
    _photoAttestationConfig = await _dataControllers.config
        .syncPhotoAttestationContractConfig();
    _photoAttestationClaim = await _dataControllers.config
        .loadPhotoAttestationClaim();

    _employee = employeeRow == null
        ? null
        : EmployeeRecord.fromJson(employeeRow);
    _projects = projectRows.map(ProjectRecord.fromJson).toList(growable: false)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _captureHistory =
        captureRows.map(CaptureRecord.fromJson).toList(growable: false)
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _lastCapture = _captureHistory.isEmpty ? null : _captureHistory.first;
    _captureVerifications = {
      for (final capture in _captureHistory)
        capture.captureId: _localVerification(capture),
    };

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

  Future<CaptureRecord> _submitPhotoAttestation(
    CaptureRecord record, {
    required SuiED25519PrivateKey sessionSigningKey,
    String? gpsLabel,
    String? altitudeLabel,
    String? projectId,
  }) async {
    final identity = _identity;
    final config = _photoAttestationConfig;
    final claim = _photoAttestationClaim;
    if (identity == null ||
        config == null ||
        claim == null ||
        !config.isComplete) {
      return _updateCaptureRecord(
        record,
        suiSubmissionStatus: 'FAILED_NOT_CONFIGURED',
        suiErrorMessage:
            'Sui contract configuration is missing, so on-chain attestation could not be submitted.',
      );
    }

    try {
      final submission = await _photoAttestationService.attestPhoto(
        identity: identity,
        signingKey: sessionSigningKey,
        config: config,
        claim: claim,
        imageSha256: record.imageSha256,
        gps: gpsLabel?.trim().isNotEmpty == true ? gpsLabel!.trim() : 'UNKNOWN',
        altitude: altitudeLabel?.trim().isNotEmpty == true
            ? altitudeLabel!.trim()
            : 'UNKNOWN',
        projectId: projectId?.trim().isNotEmpty == true
            ? projectId!.trim()
            : 'UNASSIGNED',
      );
      final updated = await _updateCaptureRecord(
        record,
        suiTxDigest: submission.transactionDigest,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: submission.status,
        suiErrorMessage: '',
      );
      final verification = submission.verification;
      if (verification != null) {
        _captureVerifications = {
          ..._captureVerifications,
          record.captureId: CaptureChainVerificationRecord(
            state: verification.isVerified
                ? CaptureChainVerificationState.verified
                : CaptureChainVerificationState.mismatched,
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
      return _updateCaptureRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: 'FAILED_SUBMISSION',
        suiErrorMessage: error.userMessage,
      );
    } catch (error) {
      return _updateCaptureRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: 'FAILED_SUBMISSION',
        suiErrorMessage: 'The photo attestation transaction failed: $error',
      );
    }
  }

  String _captureSubmissionFailureMessage(CaptureRecord record) {
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

  Future<void> verifyCaptureOnChain(CaptureRecord capture) async {
    final config = _photoAttestationConfig;
    if (config == null || !config.isComplete) {
      _captureVerifications = {
        ..._captureVerifications,
        capture.captureId: CaptureChainVerificationRecord(
          state: CaptureChainVerificationState.failed,
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
      final existing = _captureVerifications[capture.captureId];
      if (existing == null || existing.state != baseline.state) {
        _captureVerifications = {
          ..._captureVerifications,
          capture.captureId: baseline,
        };
        notifyListeners();
      }
      return;
    }

    _captureVerifications = {
      ..._captureVerifications,
      capture.captureId: CaptureChainVerificationRecord(
        state: CaptureChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      ),
    };
    notifyListeners();

    try {
      final result = await _photoAttestationService.verifyPhotoAttestation(
        config: config,
        capture: capture,
      );
      _captureVerifications = {
        ..._captureVerifications,
        capture.captureId: CaptureChainVerificationRecord(
          state: result.isVerified
              ? CaptureChainVerificationState.verified
              : CaptureChainVerificationState.mismatched,
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
    } catch (error) {
      _captureVerifications = {
        ..._captureVerifications,
        capture.captureId: CaptureChainVerificationRecord(
          state: CaptureChainVerificationState.failed,
          checkedAt: DateTime.now().toUtc(),
          transactionDigest: capture.suiTxDigest,
          transactionStatus: capture.suiSubmissionStatus,
          failureReason: '$error',
        ),
      };
    }
    notifyListeners();
  }

  Future<void> verifyCapturesOnChain(Iterable<CaptureRecord> captures) async {
    for (final capture in captures) {
      final current = _captureVerifications[capture.captureId];
      if (current?.isVerified == true) {
        continue;
      }
      unawaited(verifyCaptureOnChain(capture));
    }
  }

  CaptureChainVerificationRecord _localVerification(CaptureRecord capture) {
    if (capture.isAttestationAnchored) {
      return CaptureChainVerificationRecord(
        state: CaptureChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      );
    }
    if (capture.isAttestationPending) {
      return CaptureChainVerificationRecord(
        state: CaptureChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      );
    }
    return CaptureChainVerificationRecord(
      state: CaptureChainVerificationState.failed,
      checkedAt: DateTime.now().toUtc(),
      transactionDigest: capture.suiTxDigest,
      transactionStatus: capture.suiSubmissionStatus,
      failureReason: capture.suiSubmissionStatus,
    );
  }

  Future<CaptureRecord> _updateCaptureRecord(
    CaptureRecord record, {
    String? suiTxDigest,
    String? suiObjectId,
    String? suiSubmissionStatus,
    String? suiErrorMessage,
  }) async {
    final updated = CaptureRecord(
      captureId: record.captureId,
      capturedAt: record.capturedAt,
      submittedAt: record.submittedAt,
      imagePath: record.imagePath,
      imageSha256: record.imageSha256,
      signatureBase64: record.signatureBase64,
      walletAddress: record.walletAddress,
      publicKeyHex: record.publicKeyHex,
      proofPayload: record.proofPayload,
      suiTxDigest: suiTxDigest ?? record.suiTxDigest,
      suiObjectId: suiObjectId ?? record.suiObjectId,
      suiSubmissionStatus: suiSubmissionStatus ?? record.suiSubmissionStatus,
      suiErrorMessage: suiErrorMessage ?? record.suiErrorMessage,
      projectId: record.projectId,
      tags: record.tags,
      note: record.note,
    );
    await _dataControllers.capture.saveCapture(updated.toJson());
    return updated;
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
}
