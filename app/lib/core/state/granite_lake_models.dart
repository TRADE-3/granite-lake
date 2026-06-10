import 'package:on_chain/sui/sui.dart';

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

class CaptureActionResult extends ActionResult {
  const CaptureActionResult.success(this.record) : super._(isSuccess: true);

  const CaptureActionResult.failure(String message)
    : record = null,
      super._(isSuccess: false, message: message);

  final CaptureRecord? record;
}

enum CaptureSubmissionStage {
  signing,
  savingLocalRecord,
  submittingToChain,
  refreshingHistory,
}

enum CaptureSubmissionStageState { pending, active, completed, failed }

class CaptureSubmissionProgress {
  const CaptureSubmissionProgress({
    required this.stage,
    required this.state,
    this.message,
  });

  final CaptureSubmissionStage stage;
  final CaptureSubmissionStageState state;
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

class CaptureProofPayload {
  const CaptureProofPayload({required this.values});

  factory CaptureProofPayload.fromJson(Map<String, dynamic> json) {
    return CaptureProofPayload(values: Map<String, dynamic>.from(json));
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

enum CaptureChainVerificationState { pending, verified, mismatched, failed }

class CaptureChainVerificationRecord {
  const CaptureChainVerificationRecord({
    required this.state,
    required this.checkedAt,
    this.transactionDigest,
    this.transactionStatus,
    this.photoHashMatches = false,
    this.senderMatches = false,
    this.gpsMatches = false,
    this.altitudeMatches = false,
    this.projectIdMatches = false,
    this.timestampWithinTolerance = false,
    this.chainTimestamp,
    this.failureReason,
  });

  final CaptureChainVerificationState state;
  final DateTime checkedAt;
  final String? transactionDigest;
  final String? transactionStatus;
  final bool photoHashMatches;
  final bool senderMatches;
  final bool gpsMatches;
  final bool altitudeMatches;
  final bool projectIdMatches;
  final bool timestampWithinTolerance;
  final DateTime? chainTimestamp;
  final String? failureReason;

  bool get isVerified => state == CaptureChainVerificationState.verified;
  bool get isPending => state == CaptureChainVerificationState.pending;
  bool get isFailed =>
      state == CaptureChainVerificationState.failed ||
      state == CaptureChainVerificationState.mismatched;

  String get label {
    return switch (state) {
      CaptureChainVerificationState.pending => 'PENDING',
      CaptureChainVerificationState.verified => 'ANCHORED',
      CaptureChainVerificationState.mismatched => 'MISMATCH',
      CaptureChainVerificationState.failed => 'FAILED',
    };
  }
}

class CaptureRecord {
  const CaptureRecord({
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
  });

  factory CaptureRecord.fromJson(Map<String, dynamic> json) {
    return CaptureRecord(
      captureId: json['captureId'] as String,
      capturedAt: DateTime.parse(json['capturedAt'] as String).toUtc(),
      submittedAt: _parseOptionalTimestamp(
        json['submittedAt'],
        fallbackValue:
            (json['proofPayload'] as Map<String, dynamic>?)?['submittedAt'] ??
            json['capturedAt'],
      ),
      imagePath: json['imagePath'] as String,
      imageSha256: json['imageSha256'] as String,
      signatureBase64: json['signatureBase64'] as String,
      walletAddress: json['walletAddress'] as String? ?? 'UNKNOWN',
      publicKeyHex: json['publicKeyHex'] as String,
      proofPayload: CaptureProofPayload.fromJson(
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
  final CaptureProofPayload proofPayload;
  final String suiTxDigest;
  final String suiObjectId;
  final String suiSubmissionStatus;
  final String suiErrorMessage;
  final String? projectId;
  final List<String> tags;
  final String? note;

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
            lower.contains('attest_photo') ||
            lower.contains('function_name: some("attest_photo")'))) {
      return 'The photo attestation contract rejected this request while validating your on-chain authorization. This usually means the claimed UserCap, linked wallet, or user status no longer matches the contract state.';
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

  String? get attestedProjectId =>
      proofPayload.readString('projectId') ?? projectId?.trim();

  String get displayProject =>
      projectId?.trim().isNotEmpty == true ? projectId! : 'UNASSIGNED';

  String get displayTitle {
    final note = this.note?.trim();
    if (note != null && note.isNotEmpty) {
      return note;
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
