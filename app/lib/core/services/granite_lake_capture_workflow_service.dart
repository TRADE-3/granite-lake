import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:on_chain/sui/sui.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import '../database/controllers/photo_capture_data_controller.dart';
import '../database/controllers/uploaded_file_data_controller.dart';
import '../state/granite_lake_models.dart';
import 'capture_encryption_service.dart';

class GraniteLakeCaptureWorkflowService {
  GraniteLakeCaptureWorkflowService({
    Sha256? sha256,
    CaptureEncryptionService? captureEncryptionService,
  }) : _sha256 = sha256 ?? Sha256(),
       _captureEncryptionService =
           captureEncryptionService ?? CaptureEncryptionService();

  final Sha256 _sha256;
  final CaptureEncryptionService _captureEncryptionService;

  // Same native channel MainActivity.kt already exposes for capture-time
  // Keystore work (see CaptureEncryptionService) - `stripGpsExif` lives
  // there too since it needs androidx.exifinterface, a native dependency.
  static const MethodChannel _nativeChannel = MethodChannel(
    'granite_lake/biometric_gate',
  );

  Future<AttestationActionResult> persistCapture({
    required PhotoCaptureDataController photoCaptureDataController,
    required IdentityRecord identity,
    required SessionRecord session,
    required SuiED25519PrivateKey sessionSigningKey,
    required String temporaryImagePath,
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
    var currentStage = AttestationSubmissionStage.signing;
    try {
      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.signing,
          state: AttestationSubmissionStageState.active,
          message: 'Hashing the image and signing the proof bundle.',
        ),
      );

      final attestation = await _buildAttestationRecord(
        identity: identity,
        session: session,
        sessionSigningKey: sessionSigningKey,
        sourcePath: temporaryImagePath,
        sourceFileName: 'capture.jpg',
        assetType: AttestationAssetType.photo,
        mimeType: 'image/jpeg',
        fileExtension: '.jpg',
        deleteSourceFile: true,
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
        isOnline: isOnline,
        isForcedOffline: isForcedOffline,
        internetNullReason: internetNullReason,
        hasGps: hasGps,
        isGpsForcedNull: isGpsForcedNull,
        gpsNullReason: gpsNullReason,
      );

      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.signing,
          state: AttestationSubmissionStageState.completed,
          message: 'Photo capture proof bundle signed.',
        ),
      );
      currentStage = AttestationSubmissionStage.savingLocalRecord;
      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.savingLocalRecord,
          state: AttestationSubmissionStageState.active,
          message: 'Saving the photo capture record on this device.',
        ),
      );
      await photoCaptureDataController.savePhotoCapture(
        PhotoCaptureRecord.fromAttestationRecord(attestation).toJson(),
      );
      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.savingLocalRecord,
          state: AttestationSubmissionStageState.completed,
          message: 'Local photo capture record saved.',
        ),
      );
      return AttestationActionResult.success(attestation);
    } catch (error) {
      onProgress?.call(
        AttestationSubmissionProgress(
          stage: currentStage,
          state: AttestationSubmissionStageState.failed,
          message: 'Photo capture persistence failed: $error',
        ),
      );
      return AttestationActionResult.failure(
        'Photo capture persistence failed: $error',
      );
    }
  }

  Future<AttestationActionResult> persistFile({
    required UploadedFileDataController uploadedFileDataController,
    required IdentityRecord identity,
    required SessionRecord session,
    required SuiED25519PrivateKey sessionSigningKey,
    required String sourceFilePath,
    required String sourceFileName,
    required String mimeType,
    required int fileSizeBytes,
    String? projectId,
    List<String> tags = const <String>[],
    String? note,
    DateTime? capturedAtUtc,
    DateTime? submittedAtUtc,
    String? buildLabel,
    String? domain,
    void Function(AttestationSubmissionProgress progress)? onProgress,
    bool isOnline = true,
    bool isForcedOffline = false,
    String? internetNullReason,
  }) async {
    var currentStage = AttestationSubmissionStage.signing;
    try {
      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.signing,
          state: AttestationSubmissionStageState.active,
          message: 'Hashing the file and signing the proof bundle.',
        ),
      );

      final provisionalId =
          '${(capturedAtUtc?.toUtc() ?? DateTime.now().toUtc()).microsecondsSinceEpoch}';
      final attestation = await _buildAttestationRecord(
        identity: identity,
        session: session,
        sessionSigningKey: sessionSigningKey,
        sourcePath: sourceFilePath,
        sourceFileName: sourceFileName,
        assetType: AttestationAssetType.file,
        mimeType: mimeType,
        fileExtension: path.extension(sourceFileName),
        deleteSourceFile: false,
        projectId: projectId,
        tags: tags,
        note: note,
        capturedAtUtc: capturedAtUtc,
        submittedAtUtc: submittedAtUtc,
        buildLabel: buildLabel,
        forcedRecordId: provisionalId,
        isOnline: isOnline,
        isForcedOffline: isForcedOffline,
        internetNullReason: internetNullReason,
        extraProofPayload: <String, dynamic>{
          'domain': domain,
          'fileSizeBytes': fileSizeBytes,
          'fileId': provisionalId,
        },
      );

      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.signing,
          state: AttestationSubmissionStageState.completed,
          message: 'Uploaded file proof bundle signed.',
        ),
      );
      currentStage = AttestationSubmissionStage.savingLocalRecord;
      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.savingLocalRecord,
          state: AttestationSubmissionStageState.active,
          message: 'Saving the uploaded file record on this device.',
        ),
      );
      await uploadedFileDataController.saveUploadedFile(
        UploadedFileRecord.fromAttestationRecord(attestation).toJson(),
      );
      onProgress?.call(
        const AttestationSubmissionProgress(
          stage: AttestationSubmissionStage.savingLocalRecord,
          state: AttestationSubmissionStageState.completed,
          message: 'Local uploaded file record saved.',
        ),
      );
      return AttestationActionResult.success(attestation);
    } catch (error) {
      onProgress?.call(
        AttestationSubmissionProgress(
          stage: currentStage,
          state: AttestationSubmissionStageState.failed,
          message: 'Uploaded file persistence failed: $error',
        ),
      );
      return AttestationActionResult.failure(
        'Uploaded file persistence failed: $error',
      );
    }
  }

  Future<AttestationRecord> _buildAttestationRecord({
    required IdentityRecord identity,
    required SessionRecord session,
    required SuiED25519PrivateKey sessionSigningKey,
    required String sourcePath,
    required String sourceFileName,
    required AttestationAssetType assetType,
    required String mimeType,
    required String fileExtension,
    required bool deleteSourceFile,
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
    String? forcedRecordId,
    Map<String, dynamic>? extraProofPayload,
    bool isOnline = true,
    bool isForcedOffline = false,
    String? internetNullReason,
    bool hasGps = true,
    bool isGpsForcedNull = false,
    String? gpsNullReason,
  }) async {
    final capturedAt = capturedAtUtc?.toUtc() ?? DateTime.now().toUtc();
    final captureId = forcedRecordId ?? '${capturedAt.microsecondsSinceEpoch}';
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final captureDirectory = Directory(
      '${documentsDirectory.path}/${AppConstants.captureDirectoryName}/$captureId',
    );
    await captureDirectory.create(recursive: true);

    final safeFileName = _safeFileName(sourceFileName, assetType: assetType);
    final destinationImagePath = '${captureDirectory.path}/$safeFileName';
    final destinationImageFile = await File(
      sourcePath,
    ).copy(destinationImagePath);

    if (assetType == AttestationAssetType.photo) {
      // Must happen before hashing: GPS proof comes from Geolocator (passed
      // in separately as gpsLabel/proofPayload below), never from this
      // EXIF tag, so stripping it here costs nothing. Leaving it in would
      // mean Android's MediaProvider location redaction (silently zeroing
      // those EXIF bytes for any reader without ACCESS_MEDIA_LOCATION -
      // hash apps, share sheets, uploads) could change this file's hash
      // after it's already attested, on a copy nothing actually tampered
      // with.
      await _stripGpsExif(destinationImagePath);
    }

    final imageBytes = await destinationImageFile.readAsBytes();
    final imageHash = await _sha256.hash(imageBytes);
    final imageSha256 = _hex(imageHash.bytes);
    // Computed once, here, at the same moment as imageSha256 - not deferred
    // to whenever the transaction actually gets submitted (which, for a
    // queued offline capture, could be much later). Folding this into
    // signedMetadata below locks it into the same signature that already
    // covers photo_hash/gpsLabel/etc., so a later edit to the plaintext
    // reason column is detectable against what was actually signed at
    // capture time.
    final internetNullReasonHash = internetNullReason == null
        ? null
        : _hex((await _sha256.hash(utf8.encode(internetNullReason))).bytes);
    final gpsNullReasonHash = gpsNullReason == null
        ? null
        : _hex((await _sha256.hash(utf8.encode(gpsNullReason))).bytes);
    final submittedAt = submittedAtUtc?.toUtc();
    final fileSizeBytes = imageBytes.length;
    final previewKind = _previewKindFor(
      assetType: assetType,
      mimeType: mimeType,
      fileName: safeFileName,
    );

    final signedMetadata = <String, dynamic>{
      'captureId': captureId,
      'fileId': captureId,
      'capturedAt': capturedAt.toIso8601String(),
      if (submittedAt != null) 'submittedAt': submittedAt.toIso8601String(),
      'imagePath': destinationImagePath,
      'imageSha256': imageSha256,
      'assetType': assetType.name,
      'fileName': safeFileName,
      'mimeType': mimeType,
      'fileSizeBytes': fileSizeBytes,
      'fileExtension': fileExtension,
      'previewKind': previewKind.name,
      'storageMode': 'LOCAL_ONLY',
      'walletAddress': identity.walletAddress,
      'publicKeyHex': identity.publicKeyHex,
      'sessionStartedAt': session.startedAt.toIso8601String(),
      'sessionExpiresAt': session.expiresAt.toIso8601String(),
      'signatureAlgorithm': 'SUI_ED25519',
      'signatureIntent': 'PERSONAL_MESSAGE',
      'appName': AppConstants.appTitle,
      'appVersion': AppConstants.appVersion,
      ...?buildLabel == null ? null : {'buildLabel': buildLabel},
      ...?gpsLabel == null ? null : {'gpsLabel': gpsLabel},
      ...?altitudeLabel == null ? null : {'altitudeLabel': altitudeLabel},
      ...?cameraLabel == null ? null : {'cameraLabel': cameraLabel},
      ...?cameraDetailsLabel == null
          ? null
          : {'cameraDetailsLabel': cameraDetailsLabel},
      'projectId': projectId,
      'tags': tags,
      'note': note,
      // Offline-capture design doc §8's narrative provenance: folded into
      // the signed bundle the same way gpsLabel/altitudeLabel already are,
      // so the raw connectivity/GPS state at capture time is part of the
      // cryptographic signature too, not just a plain DB column.
      'isOnline': isOnline,
      'isForcedOffline': isForcedOffline,
      ...?internetNullReason == null
          ? null
          : {
              'internetNullReason': internetNullReason,
              'internetNullReasonHash': internetNullReasonHash,
            },
      if (assetType == AttestationAssetType.photo) ...{
        'hasGps': hasGps,
        'isGpsForcedNull': isGpsForcedNull,
        ...?gpsNullReason == null
            ? null
            : {
                'gpsNullReason': gpsNullReason,
                'gpsNullReasonHash': gpsNullReasonHash,
              },
      },
      ...?extraProofPayload,
    };

    final account = SuiEd25519Account(sessionSigningKey);
    final signature = account.signPersonalMessage(
      utf8.encode(jsonEncode(signedMetadata)),
    );
    final signatureBase64Value = base64Encode(signature.signature.signature);
    final isPhotoAsset = assetType == AttestationAssetType.photo;
    final effectiveHasGps = isPhotoAsset ? hasGps : true;
    final effectiveIsGpsForcedNull = isPhotoAsset ? isGpsForcedNull : false;
    final effectiveGpsNullReason = isPhotoAsset ? gpsNullReason : null;
    final effectiveGpsNullReasonHash = isPhotoAsset ? gpsNullReasonHash : null;

    // Offline-queue at-rest encryption (offline-capture design doc §7.3): a
    // row taking the offline/forced-offline path can sit in
    // PENDING_SUBMISSION for the length of a whole field trip, so its
    // submission-relevant fields are encrypted the instant they're written
    // instead of left in plaintext columns for that entire window. A row
    // that submits immediately while online doesn't sit at rest long
    // enough to matter, so it keeps writing the plaintext columns directly.
    final isQueuedOffline = !isOnline || isForcedOffline;
    String? encryptedPayloadBase64;
    String? payloadIvBase64;
    String? wrappedDataKeyBase64;
    if (isQueuedOffline) {
      final encrypted = await _captureEncryptionService.encryptPayload(
        captureId: captureId,
        payload: <String, dynamic>{
          'imageSha256': imageSha256,
          'signatureBase64': signatureBase64Value,
          'proofPayload': signedMetadata,
          'isOnline': isOnline,
          'isForcedOffline': isForcedOffline,
          'internetNullReason': internetNullReason,
          'internetNullReasonHash': internetNullReasonHash,
          'hasGps': effectiveHasGps,
          'isGpsForcedNull': effectiveIsGpsForcedNull,
          'gpsNullReason': effectiveGpsNullReason,
          'gpsNullReasonHash': effectiveGpsNullReasonHash,
        },
      );
      encryptedPayloadBase64 = encrypted.ciphertextBase64;
      payloadIvBase64 = encrypted.ivBase64;
      wrappedDataKeyBase64 = encrypted.wrappedDataKeyBase64;
    }

    final record = AttestationRecord(
      captureId: captureId,
      capturedAt: capturedAt,
      submittedAt: submittedAt,
      imagePath: destinationImagePath,
      imageSha256: isQueuedOffline ? '' : imageSha256,
      signatureBase64: isQueuedOffline ? '' : signatureBase64Value,
      walletAddress: identity.walletAddress,
      publicKeyHex: identity.publicKeyHex,
      proofPayload: isQueuedOffline
          ? AttestationProofPayload.fromJson(const <String, dynamic>{})
          : AttestationProofPayload.fromJson(
              Map<String, dynamic>.from(signedMetadata),
            ),
      suiTxDigest: '',
      suiObjectId: '',
      suiSubmissionStatus: 'PENDING_SUBMISSION',
      suiErrorMessage: '',
      projectId: projectId,
      tags: tags,
      note: note,
      assetType: assetType,
      fileName: safeFileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      fileExtension: fileExtension,
      previewKind: previewKind,
      storageMode: 'LOCAL_ONLY',
      isOnline: isQueuedOffline ? true : isOnline,
      isForcedOffline: isQueuedOffline ? false : isForcedOffline,
      internetNullReason: isQueuedOffline ? null : internetNullReason,
      internetNullReasonHash: isQueuedOffline ? null : internetNullReasonHash,
      hasGps: isQueuedOffline ? true : effectiveHasGps,
      isGpsForcedNull: isQueuedOffline ? false : effectiveIsGpsForcedNull,
      gpsNullReason: isQueuedOffline ? null : effectiveGpsNullReason,
      gpsNullReasonHash: isQueuedOffline ? null : effectiveGpsNullReasonHash,
      encryptedPayload: encryptedPayloadBase64,
      payloadIv: payloadIvBase64,
      wrappedDataKey: wrappedDataKeyBase64,
    );

    final sourceFile = File(sourcePath);
    if (deleteSourceFile && await sourceFile.exists()) {
      await sourceFile.delete();
    }
    return record;
  }

  Future<void> clearCaptureArtifacts() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final captureDirectory = Directory(
      '${documentsDirectory.path}/${AppConstants.captureDirectoryName}',
    );
    if (await captureDirectory.exists()) {
      await captureDirectory.delete(recursive: true);
    }
  }

  Future<void> _stripGpsExif(String imagePath) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _nativeChannel.invokeMethod<void>('stripGpsExif', {
        'path': imagePath,
      });
    } on PlatformException catch (error) {
      // Best-effort: a capture with GPS EXIF still intact is strictly
      // better than losing the capture outright over a stripping failure.
      debugPrint('stripGpsExif failed: ${error.message}');
    }
  }

  String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  String _safeFileName(
    String fileName, {
    required AttestationAssetType assetType,
  }) {
    final sanitized = path
        .basename(fileName)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    if (sanitized.isNotEmpty) {
      return sanitized;
    }
    return assetType == AttestationAssetType.file
        ? 'uploaded_asset'
        : 'capture.jpg';
  }

  AttestationPreviewKind _previewKindFor({
    required AttestationAssetType assetType,
    required String mimeType,
    required String fileName,
  }) {
    if (assetType == AttestationAssetType.photo) {
      return AttestationPreviewKind.image;
    }

    final normalizedMime = mimeType.trim().toLowerCase();
    if (normalizedMime.startsWith('image/')) {
      return AttestationPreviewKind.image;
    }
    if (normalizedMime == 'application/pdf' ||
        normalizedMime.contains('document') ||
        normalizedMime.contains('officedocument')) {
      return AttestationPreviewKind.document;
    }

    final extension = path.extension(fileName).trim().toLowerCase();
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
