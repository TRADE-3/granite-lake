import 'package:on_chain/sui/sui.dart';
import 'package:path/path.dart' as path;

import '../constants/app_constants.dart';

class ActionResult {
  const ActionResult._({required this.isSuccess, this.message, this.code});

  const ActionResult.success() : this._(isSuccess: true);

  const ActionResult.failure(String message)
    : this._(isSuccess: false, message: message);

  const ActionResult.failureWithCode(String code, String message)
    : this._(isSuccess: false, message: message, code: code);

  final bool isSuccess;
  final String? message;
  final String? code;
}

class AttestationActionResult extends ActionResult {
  const AttestationActionResult.success(this.record) : super._(isSuccess: true);

  const AttestationActionResult.failure(String message)
    : record = null,
      super._(isSuccess: false, message: message);

  final AttestationRecord? record;
}

enum AttestationSubmissionStage {
  signing,
  savingLocalRecord,
  submittingToChain,
  refreshingHistory,
}

enum AttestationSubmissionStageState { pending, active, completed, failed }

class AttestationSubmissionProgress {
  const AttestationSubmissionProgress({
    required this.stage,
    required this.state,
    this.message,
  });

  final AttestationSubmissionStage stage;
  final AttestationSubmissionStageState state;
  final String? message;
}

class SecureOperationResult<T> {
  const SecureOperationResult.success(this.data)
    : isSuccess = true,
      message = null,
      code = null,
      clearedBiometricBinding = false;

  const SecureOperationResult.failure(
    String this.message, {
    this.code,
    this.clearedBiometricBinding = false,
  }) : isSuccess = false,
       data = null;

  final bool isSuccess;
  final T? data;
  final String? message;
  final String? code;
  final bool clearedBiometricBinding;
}

class SecureInitializationState {
  const SecureInitializationState({
    required this.hasCompletedRegistration,
    required this.deviceRegistration,
    required this.identity,
    required this.photoAttestationClaim,
    required this.biometricBinding,
    required this.biometricGatePayload,
    required this.resetNotice,
  });

  final bool hasCompletedRegistration;
  final DeviceRegistrationRecord? deviceRegistration;
  final IdentityRecord? identity;
  final PhotoAttestationClaimRecord? photoAttestationClaim;
  final BiometricBindingRecord? biometricBinding;
  final BiometricGatePayload? biometricGatePayload;
  final String? resetNotice;
}

class BiometricBindingState {
  const BiometricBindingState({
    required this.identity,
    required this.biometricBinding,
    required this.biometricGatePayload,
  });

  final IdentityRecord identity;
  final BiometricBindingRecord biometricBinding;
  final BiometricGatePayload biometricGatePayload;
}

class SessionStartState {
  const SessionStartState({
    required this.session,
    required this.sessionSigningKey,
  });

  final SessionRecord session;
  final SuiED25519PrivateKey sessionSigningKey;
}

class IdentityRecord {
  const IdentityRecord({
    required this.walletAddress,
    required this.publicKeyHex,
    this.suiPrivateKey,
    required this.createdAt,
  });

  factory IdentityRecord.fromJson(Map<String, dynamic> json) {
    final suiPrivateKey = json['suiPrivateKey'] as String?;
    late final String walletAddress;
    late final String publicKeyHex;
    String? normalizedPrivateKey;

    if (suiPrivateKey != null) {
      final restoredKey = SuiBasePrivateKey.fromSuiSecretKey(suiPrivateKey);
      if (restoredKey is! SuiED25519PrivateKey) {
        throw FormatException(
          '${AppConstants.appTitle} only supports Sui Ed25519 identities.',
        );
      }

      final account = SuiEd25519Account(restoredKey);
      walletAddress =
          json['walletAddress'] as String? ?? account.toAddress().toString();
      publicKeyHex =
          json['publicKeyHex'] as String? ??
          account.publicKey.publicKey.toHex();
      normalizedPrivateKey = restoredKey.toSuiPrivateKey();
    } else if (json['walletAddress'] is String &&
        json['publicKeyHex'] is String) {
      walletAddress = json['walletAddress'] as String;
      publicKeyHex = json['publicKeyHex'] as String;
    } else {
      throw const FormatException('Identity record is missing key material.');
    }

    return IdentityRecord(
      walletAddress: walletAddress,
      publicKeyHex: publicKeyHex,
      suiPrivateKey: normalizedPrivateKey,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    );
  }

  final String walletAddress;
  final String publicKeyHex;
  final String? suiPrivateKey;
  final DateTime createdAt;

  bool get hasExportablePrivateKey => (suiPrivateKey?.isNotEmpty ?? false);

  SuiED25519PrivateKey get privateKey {
    final suiPrivateKey = this.suiPrivateKey;
    if (suiPrivateKey == null || suiPrivateKey.isEmpty) {
      throw const FormatException(
        'Identity record does not contain exportable key material.',
      );
    }

    final restoredKey = SuiBasePrivateKey.fromSuiSecretKey(suiPrivateKey);
    if (restoredKey is! SuiED25519PrivateKey) {
      throw FormatException(
        '${AppConstants.appTitle} only supports Sui Ed25519 identities.',
      );
    }
    return restoredKey;
  }

  String get walletTag {
    if (walletAddress.length <= 22) {
      return walletAddress;
    }

    return '${walletAddress.substring(0, 10)}...${walletAddress.substring(walletAddress.length - 10)}';
  }

  String get fingerprint {
    if (publicKeyHex.length <= 24) {
      return publicKeyHex.toUpperCase();
    }

    return '${publicKeyHex.substring(0, 12).toUpperCase()}...${publicKeyHex.substring(publicKeyHex.length - 12).toUpperCase()}';
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'walletAddress': walletAddress,
      'publicKeyHex': publicKeyHex,
      'createdAt': createdAt.toIso8601String(),
    };
    if (hasExportablePrivateKey) {
      json['suiPrivateKey'] = suiPrivateKey;
    }

    return json;
  }

  IdentityRecord withoutPrivateKey() {
    return IdentityRecord(
      walletAddress: walletAddress,
      publicKeyHex: publicKeyHex,
      createdAt: createdAt,
    );
  }
}

class PhotoAttestationClaimRecord {
  const PhotoAttestationClaimRecord({
    required this.domain,
    required this.userId,
    required this.userCapObjectId,
    required this.claimTxDigest,
    required this.claimedAt,
  });

  factory PhotoAttestationClaimRecord.fromJson(Map<String, dynamic> json) {
    return PhotoAttestationClaimRecord(
      domain: json['domain'] as String,
      userId: json['userId'] as String,
      userCapObjectId: json['userCapObjectId'] as String,
      claimTxDigest: json['claimTxDigest'] as String? ?? '',
      claimedAt: DateTime.parse(json['claimedAt'] as String).toUtc(),
    );
  }

  final String domain;
  final String userId;
  final String userCapObjectId;
  final String claimTxDigest;
  final DateTime claimedAt;

  String get domainLabel => domain.trim().isEmpty ? 'UNSET' : domain;
  String get userLabel => userId.trim().isEmpty ? 'UNSET' : userId;

  Map<String, dynamic> toJson() {
    return {
      'domain': domain,
      'userId': userId,
      'userCapObjectId': userCapObjectId,
      'claimTxDigest': claimTxDigest,
      'claimedAt': claimedAt.toIso8601String(),
    };
  }
}

class PhotoAttestationContractConfig {
  const PhotoAttestationContractConfig({
    required this.rpcUrl,
    required this.packageId,
    required this.registryId,
    required this.moduleName,
    required this.updatedAt,
  });

  factory PhotoAttestationContractConfig.fromJson(Map<String, dynamic> json) {
    return PhotoAttestationContractConfig(
      rpcUrl: json['rpcUrl'] as String? ?? '',
      packageId: json['packageId'] as String? ?? '',
      registryId: json['registryId'] as String? ?? '',
      moduleName: json['moduleName'] as String? ?? '',
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
    );
  }

  final String rpcUrl;
  final String packageId;
  final String registryId;
  final String moduleName;
  final DateTime updatedAt;

  bool get isComplete =>
      rpcUrl.trim().isNotEmpty &&
      packageId.trim().isNotEmpty &&
      registryId.trim().isNotEmpty &&
      moduleName.trim().isNotEmpty;

  Map<String, dynamic> toJson() {
    return {
      'rpcUrl': rpcUrl,
      'packageId': packageId,
      'registryId': registryId,
      'moduleName': moduleName,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  PhotoAttestationContractConfig copyWith({
    String? rpcUrl,
    String? packageId,
    String? registryId,
    String? moduleName,
    DateTime? updatedAt,
  }) {
    return PhotoAttestationContractConfig(
      rpcUrl: rpcUrl ?? this.rpcUrl,
      packageId: packageId ?? this.packageId,
      registryId: registryId ?? this.registryId,
      moduleName: moduleName ?? this.moduleName,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class BiometricBindingRecord {
  const BiometricBindingRecord({
    required this.boundAt,
    required this.modalities,
    required this.gateAlias,
  });

  factory BiometricBindingRecord.fromJson(Map<String, dynamic> json) {
    return BiometricBindingRecord(
      boundAt: DateTime.parse(json['boundAt'] as String).toUtc(),
      modalities: (json['modalities'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      gateAlias: json['gateAlias'] as String? ?? '',
    );
  }

  final DateTime boundAt;
  final List<String> modalities;
  final String gateAlias;

  bool get hasGateAlias => gateAlias.isNotEmpty;

  String get modalitiesLabel =>
      modalities.isEmpty ? 'BIOMETRIC' : modalities.join(' / ');

  Map<String, dynamic> toJson() {
    return {
      'boundAt': boundAt.toIso8601String(),
      'modalities': modalities,
      'gateAlias': gateAlias,
    };
  }
}

class BiometricGatePayload {
  const BiometricGatePayload({
    required this.ciphertextBase64,
    required this.ivBase64,
  });

  factory BiometricGatePayload.fromJson(Map<String, dynamic> json) {
    return BiometricGatePayload(
      ciphertextBase64: json['ciphertextBase64'] as String,
      ivBase64: json['ivBase64'] as String,
    );
  }

  final String ciphertextBase64;
  final String ivBase64;

  Map<String, dynamic> toJson() {
    return {'ciphertextBase64': ciphertextBase64, 'ivBase64': ivBase64};
  }
}

class SessionRecord {
  const SessionRecord({required this.startedAt, required this.expiresAt});

  factory SessionRecord.fromJson(Map<String, dynamic> json) {
    return SessionRecord(
      startedAt: DateTime.parse(json['startedAt'] as String).toUtc(),
      expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
    );
  }

  final DateTime startedAt;
  final DateTime expiresAt;

  bool get isActive => expiresAt.isAfter(DateTime.now().toUtc());

  Map<String, dynamic> toJson() {
    return {
      'startedAt': startedAt.toIso8601String(),
      'expiresAt': expiresAt.toIso8601String(),
    };
  }
}

enum AttestationAssetType { photo, file }

enum AttestationPreviewKind { image, document, binary }

class AttestationProofPayload {
  const AttestationProofPayload({required this.values});

  factory AttestationProofPayload.fromJson(Map<String, dynamic> json) {
    return AttestationProofPayload(values: Map<String, dynamic>.from(json));
  }

  final Map<String, dynamic> values;

  String? readString(String key) {
    final value = values[key];
    if (value is! String) {
      return null;
    }

    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? readStringAny(List<String> keys) {
    for (final key in keys) {
      final value = readString(key);
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  double? readNumberAny(List<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value is num) {
        return value.toDouble();
      }
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(values);
}

enum AttestationChainVerificationState { pending, verified, mismatched, failed }

class AttestationChainVerificationRecord {
  const AttestationChainVerificationRecord({
    required this.state,
    required this.checkedAt,
    this.transactionDigest,
    this.transactionStatus,
    this.photoHashMatches = false,
    this.senderMatches = false,
    this.gpsMatches = false,
    this.altitudeMatches = false,
    this.projectIdMatches = false,
    this.fileIdMatches = false,
    this.timestampWithinTolerance = false,
    this.chainTimestamp,
    this.failureReason,
  });

  final AttestationChainVerificationState state;
  final DateTime checkedAt;
  final String? transactionDigest;
  final String? transactionStatus;
  final bool photoHashMatches;
  final bool senderMatches;
  final bool gpsMatches;
  final bool altitudeMatches;
  final bool projectIdMatches;
  final bool fileIdMatches;
  final bool timestampWithinTolerance;
  final DateTime? chainTimestamp;
  final String? failureReason;

  bool get isVerified => state == AttestationChainVerificationState.verified;
  bool get isPending => state == AttestationChainVerificationState.pending;
  bool get contentHashMatches => photoHashMatches;
  bool get isFailed =>
      state == AttestationChainVerificationState.failed ||
      state == AttestationChainVerificationState.mismatched;

  String get label {
    return switch (state) {
      AttestationChainVerificationState.pending => 'PENDING',
      AttestationChainVerificationState.verified => 'ANCHORED',
      AttestationChainVerificationState.mismatched => 'MISMATCH',
      AttestationChainVerificationState.failed => 'FAILED',
    };
  }
}

class AttestationRecord {
  const AttestationRecord({
    required this.captureId,
    required this.capturedAt,
    this.submittedAt,
    required this.imagePath,
    required this.imageSha256,
    required this.signatureBase64,
    required this.walletAddress,
    required this.publicKeyHex,
    required this.proofPayload,
    required this.suiTxDigest,
    required this.suiObjectId,
    required this.suiSubmissionStatus,
    required this.suiErrorMessage,
    this.projectId,
    this.tags = const <String>[],
    this.note,
    this.assetType = AttestationAssetType.photo,
    this.fileName,
    this.mimeType,
    this.fileSizeBytes,
    this.fileExtension,
    this.previewKind = AttestationPreviewKind.image,
    this.storageMode = 'LOCAL_ONLY',
  });

  factory AttestationRecord.fromJson(Map<String, dynamic> json) {
    final proofPayload = Map<String, dynamic>.from(
      json['proofPayload'] as Map<String, dynamic>? ??
          const <String, dynamic>{},
    );
    final assetType = _assetTypeFromValue(
      json['assetType'] ?? proofPayload['assetType'],
    );
    final fileName =
        _readStringValue(json['fileName']) ??
        _readStringValue(proofPayload['fileName']);
    final mimeType =
        _readStringValue(json['mimeType']) ??
        _readStringValue(proofPayload['mimeType']);
    final fileExtension =
        _readStringValue(json['fileExtension']) ??
        _readStringValue(proofPayload['fileExtension']);
    final fileSizeBytes =
        _readIntValue(json['fileSizeBytes']) ??
        _readIntValue(proofPayload['fileSizeBytes']);
    final previewKind = _previewKindFromValue(
      json['previewKind'] ?? proofPayload['previewKind'],
      mimeType: mimeType,
      fileName: fileName,
      assetType: assetType,
    );

    return AttestationRecord(
      captureId: json['captureId'] as String,
      capturedAt: DateTime.parse(json['capturedAt'] as String).toUtc(),
      submittedAt: _parseOptionalTimestamp(
        json['submittedAt'],
        fallbackValue: proofPayload['submittedAt'] ?? json['capturedAt'],
      ),
      imagePath: json['imagePath'] as String,
      imageSha256: json['imageSha256'] as String,
      signatureBase64: json['signatureBase64'] as String,
      walletAddress: json['walletAddress'] as String? ?? 'UNKNOWN',
      publicKeyHex: json['publicKeyHex'] as String,
      proofPayload: AttestationProofPayload.fromJson(proofPayload),
      suiTxDigest: json['suiTxDigest'] as String? ?? '',
      suiObjectId: json['suiObjectId'] as String? ?? '',
      suiSubmissionStatus:
          json['suiSubmissionStatus'] as String? ?? 'PENDING_SUBMISSION',
      suiErrorMessage: json['suiErrorMessage'] as String? ?? '',
      projectId: json['projectId'] as String?,
      tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      note: json['note'] as String?,
      assetType: assetType,
      fileName: fileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      fileExtension: fileExtension,
      previewKind: previewKind,
      storageMode:
          _readStringValue(json['storageMode']) ??
          _readStringValue(proofPayload['storageMode']) ??
          'LOCAL_ONLY',
    );
  }

  final String captureId;
  final DateTime capturedAt;
  final DateTime? submittedAt;
  final String imagePath;
  final String imageSha256;
  final String signatureBase64;
  final String walletAddress;
  final String publicKeyHex;
  final AttestationProofPayload proofPayload;
  final String suiTxDigest;
  final String suiObjectId;
  final String suiSubmissionStatus;
  final String suiErrorMessage;
  final String? projectId;
  final List<String> tags;
  final String? note;
  final AttestationAssetType assetType;
  final String? fileName;
  final String? mimeType;
  final int? fileSizeBytes;
  final String? fileExtension;
  final AttestationPreviewKind previewKind;
  final String storageMode;

  bool get isPhoto => assetType == AttestationAssetType.photo;

  bool get isFile => assetType == AttestationAssetType.file;

  String get normalizedSuiSubmissionStatus =>
      suiSubmissionStatus.trim().toUpperCase();

  bool get hasSuiTransactionDigest => suiTxDigest.trim().isNotEmpty;

  bool get hasSuiObjectReference => suiObjectId.trim().isNotEmpty;

  bool get isAttestationAnchored {
    final status = normalizedSuiSubmissionStatus;
    final isSuccessfulStatus =
        status == 'SUCCESS' ||
        status == 'CONFIRMED' ||
        status == 'FINALIZED' ||
        status == 'EXECUTED' ||
        status == 'SUBMITTED';
    return hasSuiTransactionDigest && isSuccessfulStatus;
  }

  bool get isAttestationPending {
    final status = normalizedSuiSubmissionStatus;
    return !isAttestationAnchored &&
        (status == 'PENDING_SUBMISSION' ||
            status == 'PENDING' ||
            status == 'SUBMITTING');
  }

  bool get isAttestationFailed =>
      !isAttestationAnchored && !isAttestationPending;

  String? get attestationErrorLabel {
    final normalized = suiErrorMessage.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final lower = normalized.toLowerCase();
    if (lower.contains('movelocation') &&
        lower.contains('photo_attestation') &&
        (lower.contains('function: 6') ||
            lower.contains('function: 7') ||
            lower.contains('attest_photo') ||
            lower.contains('attest_file') ||
            lower.contains('function_name: some("attest_photo")'))) {
      return 'The attestation contract rejected this request while validating your on-chain authorization. This usually means the claimed UserCap, linked wallet, or user status no longer matches the contract state.';
    }

    return normalized;
  }

  String get verificationLabel {
    if (isAttestationAnchored) {
      return 'ANCHORED';
    }
    if (isAttestationPending) {
      return 'PENDING';
    }
    return 'FAILED';
  }

  String? get capturedGpsLabel => proofPayload.readString('gpsLabel');

  String? get capturedAltitudeLabel => proofPayload.readString('altitudeLabel');

  DateTime get effectiveSubmittedAt => submittedAt ?? capturedAt;

  String get localAssetPath => imagePath;

  String get contentSha256 => imageSha256;

  String get fileId => proofPayload.readString('fileId') ?? captureId;

  String get assetTypeLabel => isFile ? 'FILE' : 'PHOTO';

  String get assetName {
    final explicitName = fileName?.trim();
    if (explicitName != null && explicitName.isNotEmpty) {
      return explicitName;
    }
    final basename = path.basename(imagePath).trim();
    if (basename.isNotEmpty) {
      return basename;
    }
    return isFile ? 'uploaded_asset' : 'capture.jpg';
  }

  String get normalizedMimeType => (mimeType ?? '').trim().toLowerCase();

  String get mimeTypeLabel => normalizedMimeType.isEmpty
      ? isPhoto
            ? 'image/jpeg'
            : 'application/octet-stream'
      : normalizedMimeType;

  String get extensionLabel {
    final explicit = fileExtension?.trim().toLowerCase();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit.startsWith('.') ? explicit : '.$explicit';
    }
    final derived = path.extension(assetName).trim().toLowerCase();
    return derived.isEmpty ? (isPhoto ? '.jpg' : '') : derived;
  }

  String get formattedFileSize {
    final bytes = fileSizeBytes;
    if (bytes == null || bytes <= 0) {
      return 'Unknown size';
    }
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  bool get hasVisualPreview => previewKind == AttestationPreviewKind.image;

  String get storageModeLabel {
    final normalized = storageMode.trim();
    return normalized.isEmpty ? 'LOCAL_ONLY' : normalized.toUpperCase();
  }

  int get onChainFileType {
    if (normalizedMimeType == 'application/pdf') {
      return 0;
    }
    if (hasVisualPreview) {
      return 1;
    }
    return 2;
  }

  String get domainLabel =>
      proofPayload.readString('domain') ?? 'UNASSIGNED_DOMAIN';

  String? get attestedProjectId =>
      proofPayload.readString('projectId') ?? projectId?.trim();

  String get displayProject =>
      projectId?.trim().isNotEmpty == true ? projectId! : 'UNASSIGNED';

  String get displayTitle {
    final note = this.note?.trim();
    if (note != null && note.isNotEmpty) {
      return note;
    }

    if (isFile) {
      return assetName;
    }

    if (tags.isNotEmpty) {
      return tags.join(' • ');
    }

    return 'Capture $captureId';
  }

  String get shortHash {
    if (imageSha256.length <= 24) {
      return imageSha256.toUpperCase();
    }

    return '${imageSha256.substring(0, 12).toUpperCase()}...${imageSha256.substring(imageSha256.length - 12).toUpperCase()}';
  }

  Map<String, dynamic> toJson() {
    return {
      'captureId': captureId,
      'capturedAt': capturedAt.toIso8601String(),
      'submittedAt': submittedAt?.toIso8601String(),
      'imagePath': imagePath,
      'imageSha256': imageSha256,
      'signatureBase64': signatureBase64,
      'walletAddress': walletAddress,
      'publicKeyHex': publicKeyHex,
      'proofPayload': proofPayload.toJson(),
      'suiTxDigest': suiTxDigest,
      'suiObjectId': suiObjectId,
      'suiSubmissionStatus': suiSubmissionStatus,
      'suiErrorMessage': suiErrorMessage,
      'projectId': projectId,
      'tags': tags,
      'note': note,
      'assetType': assetType.name,
      'fileName': fileName,
      'mimeType': mimeType,
      'fileSizeBytes': fileSizeBytes,
      'fileExtension': fileExtension,
      'previewKind': previewKind.name,
      'storageMode': storageMode,
    };
  }

  static DateTime? _parseOptionalTimestamp(
    Object? value, {
    Object? fallbackValue,
  }) {
    final raw = value ?? fallbackValue;
    if (raw is! String || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.parse(raw).toUtc();
  }

  static String? _readStringValue(Object? value) {
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _readIntValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static AttestationAssetType _assetTypeFromValue(Object? value) {
    if (value is String && value.trim().toLowerCase() == 'file') {
      return AttestationAssetType.file;
    }
    return AttestationAssetType.photo;
  }

  static AttestationPreviewKind _previewKindFromValue(
    Object? value, {
    required String? mimeType,
    required String? fileName,
    required AttestationAssetType assetType,
  }) {
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'image') {
        return AttestationPreviewKind.image;
      }
      if (normalized == 'document') {
        return AttestationPreviewKind.document;
      }
      if (normalized == 'binary') {
        return AttestationPreviewKind.binary;
      }
    }

    if (assetType == AttestationAssetType.photo) {
      return AttestationPreviewKind.image;
    }

    final normalizedMime = (mimeType ?? '').trim().toLowerCase();
    if (normalizedMime.startsWith('image/')) {
      return AttestationPreviewKind.image;
    }
    if (normalizedMime == 'application/pdf' ||
        normalizedMime.contains('document') ||
        normalizedMime.contains('officedocument')) {
      return AttestationPreviewKind.document;
    }

    final extension = path.extension(fileName ?? '').trim().toLowerCase();
    if ({
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.bmp',
      '.heic',
    }.contains(extension)) {
      return AttestationPreviewKind.image;
    }
    if ({
      '.pdf',
      '.doc',
      '.docx',
      '.xls',
      '.xlsx',
      '.ppt',
      '.pptx',
      '.txt',
      '.csv',
    }.contains(extension)) {
      return AttestationPreviewKind.document;
    }
    return AttestationPreviewKind.binary;
  }
}

class PhotoCaptureRecord {
  const PhotoCaptureRecord({
    required this.photoCaptureId,
    required this.capturedAt,
    this.submittedAt,
    required this.imagePath,
    required this.imageSha256,
    required this.signatureBase64,
    required this.walletAddress,
    required this.publicKeyHex,
    required this.proofPayload,
    required this.suiTxDigest,
    required this.suiObjectId,
    required this.suiSubmissionStatus,
    required this.suiErrorMessage,
    this.projectId,
    this.tags = const <String>[],
    this.note,
    this.previewKind = AttestationPreviewKind.image,
    this.storageMode = 'LOCAL_ONLY',
  });

  factory PhotoCaptureRecord.fromJson(Map<String, dynamic> json) {
    return PhotoCaptureRecord(
      photoCaptureId: json['photoCaptureId'] as String,
      capturedAt: DateTime.parse(json['capturedAt'] as String).toUtc(),
      submittedAt: AttestationRecord._parseOptionalTimestamp(
        json['submittedAt'],
        fallbackValue: json['capturedAt'],
      ),
      imagePath: json['imagePath'] as String,
      imageSha256: json['imageSha256'] as String,
      signatureBase64: json['signatureBase64'] as String,
      walletAddress: json['walletAddress'] as String? ?? 'UNKNOWN',
      publicKeyHex: json['publicKeyHex'] as String,
      proofPayload: AttestationProofPayload.fromJson(
        Map<String, dynamic>.from(
          json['proofPayload'] as Map<String, dynamic>? ??
              const <String, dynamic>{},
        ),
      ),
      suiTxDigest: json['suiTxDigest'] as String? ?? '',
      suiObjectId: json['suiObjectId'] as String? ?? '',
      suiSubmissionStatus:
          json['suiSubmissionStatus'] as String? ?? 'PENDING_SUBMISSION',
      suiErrorMessage: json['suiErrorMessage'] as String? ?? '',
      projectId: json['projectId'] as String?,
      tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      note: json['note'] as String?,
      previewKind: AttestationRecord._previewKindFromValue(
        json['previewKind'],
        mimeType: 'image/jpeg',
        fileName: 'capture.jpg',
        assetType: AttestationAssetType.photo,
      ),
      storageMode: json['storageMode'] as String? ?? 'LOCAL_ONLY',
    );
  }

  factory PhotoCaptureRecord.fromAttestationRecord(AttestationRecord record) {
    return PhotoCaptureRecord(
      photoCaptureId: record.captureId,
      capturedAt: record.capturedAt,
      submittedAt: record.submittedAt,
      imagePath: record.imagePath,
      imageSha256: record.imageSha256,
      signatureBase64: record.signatureBase64,
      walletAddress: record.walletAddress,
      publicKeyHex: record.publicKeyHex,
      proofPayload: record.proofPayload,
      suiTxDigest: record.suiTxDigest,
      suiObjectId: record.suiObjectId,
      suiSubmissionStatus: record.suiSubmissionStatus,
      suiErrorMessage: record.suiErrorMessage,
      projectId: record.projectId,
      tags: record.tags,
      note: record.note,
      previewKind: record.previewKind,
      storageMode: record.storageMode,
    );
  }

  final String photoCaptureId;
  final DateTime capturedAt;
  final DateTime? submittedAt;
  final String imagePath;
  final String imageSha256;
  final String signatureBase64;
  final String walletAddress;
  final String publicKeyHex;
  final AttestationProofPayload proofPayload;
  final String suiTxDigest;
  final String suiObjectId;
  final String suiSubmissionStatus;
  final String suiErrorMessage;
  final String? projectId;
  final List<String> tags;
  final String? note;
  final AttestationPreviewKind previewKind;
  final String storageMode;

  AttestationRecord toAttestationRecord() {
    return AttestationRecord(
      captureId: photoCaptureId,
      capturedAt: capturedAt,
      submittedAt: submittedAt,
      imagePath: imagePath,
      imageSha256: imageSha256,
      signatureBase64: signatureBase64,
      walletAddress: walletAddress,
      publicKeyHex: publicKeyHex,
      proofPayload: proofPayload,
      suiTxDigest: suiTxDigest,
      suiObjectId: suiObjectId,
      suiSubmissionStatus: suiSubmissionStatus,
      suiErrorMessage: suiErrorMessage,
      projectId: projectId,
      tags: tags,
      note: note,
      assetType: AttestationAssetType.photo,
      previewKind: previewKind,
      storageMode: storageMode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'photoCaptureId': photoCaptureId,
      'capturedAt': capturedAt.toIso8601String(),
      'submittedAt': submittedAt?.toIso8601String(),
      'imagePath': imagePath,
      'imageSha256': imageSha256,
      'signatureBase64': signatureBase64,
      'walletAddress': walletAddress,
      'publicKeyHex': publicKeyHex,
      'proofPayload': proofPayload.toJson(),
      'suiTxDigest': suiTxDigest,
      'suiObjectId': suiObjectId,
      'suiSubmissionStatus': suiSubmissionStatus,
      'suiErrorMessage': suiErrorMessage,
      'projectId': projectId,
      'tags': tags,
      'note': note,
      'previewKind': previewKind.name,
      'storageMode': storageMode,
    };
  }
}

class UploadedFileRecord {
  const UploadedFileRecord({
    required this.uploadedFileId,
    required this.capturedAt,
    this.submittedAt,
    required this.filePath,
    required this.fileSha256,
    required this.signatureBase64,
    required this.walletAddress,
    required this.publicKeyHex,
    required this.proofPayload,
    required this.suiTxDigest,
    required this.suiObjectId,
    required this.suiSubmissionStatus,
    required this.suiErrorMessage,
    this.projectId,
    this.tags = const <String>[],
    this.note,
    required this.fileName,
    this.mimeType,
    this.fileSizeBytes,
    this.fileExtension,
    this.previewKind = AttestationPreviewKind.document,
    this.storageMode = 'LOCAL_ONLY',
  });

  factory UploadedFileRecord.fromJson(Map<String, dynamic> json) {
    return UploadedFileRecord(
      uploadedFileId: json['uploadedFileId'] as String,
      capturedAt: DateTime.parse(json['capturedAt'] as String).toUtc(),
      submittedAt: AttestationRecord._parseOptionalTimestamp(
        json['submittedAt'],
        fallbackValue: json['capturedAt'],
      ),
      filePath: json['filePath'] as String,
      fileSha256: json['fileSha256'] as String,
      signatureBase64: json['signatureBase64'] as String,
      walletAddress: json['walletAddress'] as String? ?? 'UNKNOWN',
      publicKeyHex: json['publicKeyHex'] as String,
      proofPayload: AttestationProofPayload.fromJson(
        Map<String, dynamic>.from(
          json['proofPayload'] as Map<String, dynamic>? ??
              const <String, dynamic>{},
        ),
      ),
      suiTxDigest: json['suiTxDigest'] as String? ?? '',
      suiObjectId: json['suiObjectId'] as String? ?? '',
      suiSubmissionStatus:
          json['suiSubmissionStatus'] as String? ?? 'PENDING_SUBMISSION',
      suiErrorMessage: json['suiErrorMessage'] as String? ?? '',
      projectId: json['projectId'] as String?,
      tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      note: json['note'] as String?,
      fileName: json['fileName'] as String? ?? 'uploaded_asset',
      mimeType: json['mimeType'] as String?,
      fileSizeBytes: AttestationRecord._readIntValue(json['fileSizeBytes']),
      fileExtension: json['fileExtension'] as String?,
      previewKind: AttestationRecord._previewKindFromValue(
        json['previewKind'],
        mimeType: json['mimeType'] as String?,
        fileName: json['fileName'] as String?,
        assetType: AttestationAssetType.file,
      ),
      storageMode: json['storageMode'] as String? ?? 'LOCAL_ONLY',
    );
  }

  factory UploadedFileRecord.fromAttestationRecord(AttestationRecord record) {
    return UploadedFileRecord(
      uploadedFileId: record.fileId,
      capturedAt: record.capturedAt,
      submittedAt: record.submittedAt,
      filePath: record.imagePath,
      fileSha256: record.imageSha256,
      signatureBase64: record.signatureBase64,
      walletAddress: record.walletAddress,
      publicKeyHex: record.publicKeyHex,
      proofPayload: record.proofPayload,
      suiTxDigest: record.suiTxDigest,
      suiObjectId: record.suiObjectId,
      suiSubmissionStatus: record.suiSubmissionStatus,
      suiErrorMessage: record.suiErrorMessage,
      projectId: record.projectId,
      tags: record.tags,
      note: record.note,
      fileName: record.fileName ?? record.assetName,
      mimeType: record.mimeType,
      fileSizeBytes: record.fileSizeBytes,
      fileExtension: record.fileExtension,
      previewKind: record.previewKind,
      storageMode: record.storageMode,
    );
  }

  final String uploadedFileId;
  final DateTime capturedAt;
  final DateTime? submittedAt;
  final String filePath;
  final String fileSha256;
  final String signatureBase64;
  final String walletAddress;
  final String publicKeyHex;
  final AttestationProofPayload proofPayload;
  final String suiTxDigest;
  final String suiObjectId;
  final String suiSubmissionStatus;
  final String suiErrorMessage;
  final String? projectId;
  final List<String> tags;
  final String? note;
  final String fileName;
  final String? mimeType;
  final int? fileSizeBytes;
  final String? fileExtension;
  final AttestationPreviewKind previewKind;
  final String storageMode;

  AttestationRecord toAttestationRecord() {
    return AttestationRecord(
      captureId: uploadedFileId,
      capturedAt: capturedAt,
      submittedAt: submittedAt,
      imagePath: filePath,
      imageSha256: fileSha256,
      signatureBase64: signatureBase64,
      walletAddress: walletAddress,
      publicKeyHex: publicKeyHex,
      proofPayload: proofPayload,
      suiTxDigest: suiTxDigest,
      suiObjectId: suiObjectId,
      suiSubmissionStatus: suiSubmissionStatus,
      suiErrorMessage: suiErrorMessage,
      projectId: projectId,
      tags: tags,
      note: note,
      assetType: AttestationAssetType.file,
      fileName: fileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      fileExtension: fileExtension,
      previewKind: previewKind,
      storageMode: storageMode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uploadedFileId': uploadedFileId,
      'capturedAt': capturedAt.toIso8601String(),
      'submittedAt': submittedAt?.toIso8601String(),
      'filePath': filePath,
      'fileSha256': fileSha256,
      'signatureBase64': signatureBase64,
      'walletAddress': walletAddress,
      'publicKeyHex': publicKeyHex,
      'proofPayload': proofPayload.toJson(),
      'suiTxDigest': suiTxDigest,
      'suiObjectId': suiObjectId,
      'suiSubmissionStatus': suiSubmissionStatus,
      'suiErrorMessage': suiErrorMessage,
      'projectId': projectId,
      'tags': tags,
      'note': note,
      'fileName': fileName,
      'mimeType': mimeType,
      'fileSizeBytes': fileSizeBytes,
      'fileExtension': fileExtension,
      'previewKind': previewKind.name,
      'storageMode': storageMode,
    };
  }
}

class ProjectRecord {
  const ProjectRecord({
    required this.projectId,
    required this.title,
    required this.createdAt,
  });

  factory ProjectRecord.fromJson(Map<String, dynamic> json) {
    return ProjectRecord(
      projectId: json['projectId'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    );
  }

  final String projectId;
  final String title;
  final DateTime createdAt;

  String get displayLabel => '$projectId // $title';

  Map<String, dynamic> toJson() {
    return {
      'projectId': projectId,
      'title': title,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}

class EmployeeRecord {
  const EmployeeRecord({
    required this.employeeId,
    required this.fullName,
    required this.role,
    required this.tenantName,
    required this.companyDomain,
    required this.initials,
    required this.createdAt,
    required this.updatedAt,
    required this.isPlaceholder,
    required this.walletAddress,
  });

  factory EmployeeRecord.fromJson(Map<String, dynamic> json) {
    return EmployeeRecord(
      employeeId: json['employeeId'] as String,
      fullName: json['fullName'] as String,
      role: json['role'] as String,
      tenantName: json['tenantName'] as String,
      companyDomain: json['companyDomain'] as String? ?? '',
      initials: json['initials'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
      isPlaceholder: json['isPlaceholder'] as bool? ?? false,
      walletAddress: json['walletAddress'] as String? ?? '',
    );
  }

  final String employeeId;
  final String fullName;
  final String role;
  final String tenantName;
  final String companyDomain;
  final String initials;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isPlaceholder;
  final String walletAddress;
}

class DeviceRegistrationRecord {
  const DeviceRegistrationRecord({
    required this.registeredAt,
    required this.model,
    required this.manufacturer,
    required this.platform,
    required this.osVersion,
  });

  factory DeviceRegistrationRecord.fromJson(Map<String, dynamic> json) {
    return DeviceRegistrationRecord(
      registeredAt: DateTime.parse(json['registeredAt'] as String).toUtc(),
      model: json['model'] as String? ?? '',
      manufacturer: json['manufacturer'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      osVersion: json['osVersion'] as String? ?? '',
    );
  }

  final DateTime registeredAt;
  final String model;
  final String manufacturer;
  final String platform;
  final String osVersion;

  String get displayModel {
    final normalizedModel = model.trim();
    final normalizedManufacturer = manufacturer.trim();
    if (normalizedManufacturer.isEmpty) {
      return normalizedModel.isEmpty ? 'UNKNOWN_DEVICE' : normalizedModel;
    }
    if (normalizedModel.isEmpty) {
      return normalizedManufacturer;
    }
    if (normalizedModel.toLowerCase().startsWith(
      normalizedManufacturer.toLowerCase(),
    )) {
      return normalizedModel;
    }
    return '$normalizedManufacturer $normalizedModel';
  }

  String get platformLabel {
    final normalizedPlatform = platform.trim();
    final normalizedVersion = osVersion.trim();
    if (normalizedPlatform.isEmpty) {
      return normalizedVersion.isEmpty ? 'UNKNOWN' : normalizedVersion;
    }
    if (normalizedVersion.isEmpty) {
      return normalizedPlatform.toUpperCase();
    }
    return '${normalizedPlatform.toUpperCase()} // $normalizedVersion';
  }

  Map<String, dynamic> toJson() {
    return {
      'registeredAt': registeredAt.toIso8601String(),
      'model': model,
      'manufacturer': manufacturer,
      'platform': platform,
      'osVersion': osVersion,
    };
  }
}
