import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:on_chain/sui/sui.dart';
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import '../database/controllers/capture_data_controller.dart';
import '../state/granite_lake_models.dart';

class GraniteLakeCaptureWorkflowService {
  GraniteLakeCaptureWorkflowService({Sha256? sha256})
    : _sha256 = sha256 ?? Sha256();

  final Sha256 _sha256;

  Future<CaptureActionResult> persistCapture({
    required CaptureDataController captureDataController,
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
    void Function(CaptureSubmissionProgress progress)? onProgress,
  }) async {
    var currentStage = CaptureSubmissionStage.signing;
    try {
      onProgress?.call(
        const CaptureSubmissionProgress(
          stage: CaptureSubmissionStage.signing,
          state: CaptureSubmissionStageState.active,
          message: 'Hashing the image and signing the proof bundle.',
        ),
      );
      final capturedAt = capturedAtUtc?.toUtc() ?? DateTime.now().toUtc();
      final captureId = '${capturedAt.microsecondsSinceEpoch}';
      final documentsDirectory = await getApplicationDocumentsDirectory();
      final captureDirectory = Directory(
        '${documentsDirectory.path}/${AppConstants.captureDirectoryName}/$captureId',
      );
      await captureDirectory.create(recursive: true);

      final destinationImagePath = '${captureDirectory.path}/capture.jpg';
      final destinationImageFile = await File(
        temporaryImagePath,
      ).copy(destinationImagePath);

      final imageBytes = await destinationImageFile.readAsBytes();
      final imageHash = await _sha256.hash(imageBytes);
      final imageSha256 = _hex(imageHash.bytes);
      final submittedAt = submittedAtUtc?.toUtc();

      final signedMetadata = <String, dynamic>{
        'captureId': captureId,
        'capturedAt': capturedAt.toIso8601String(),
        if (submittedAt != null) 'submittedAt': submittedAt.toIso8601String(),
        'imagePath': destinationImagePath,
        'imageSha256': imageSha256,
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
      };

      final account = SuiEd25519Account(sessionSigningKey);
      final signature = account.signPersonalMessage(
        utf8.encode(jsonEncode(signedMetadata)),
      );
      final record = CaptureRecord(
        captureId: captureId,
        capturedAt: capturedAt,
        submittedAt: submittedAt,
        imagePath: destinationImagePath,
        imageSha256: imageSha256,
        signatureBase64: base64Encode(signature.signature.signature),
        walletAddress: identity.walletAddress,
        publicKeyHex: identity.publicKeyHex,
        proofPayload: CaptureProofPayload.fromJson(
          Map<String, dynamic>.from(signedMetadata),
        ),
        suiTxDigest: '',
        suiObjectId: '',
        suiSubmissionStatus: 'PENDING_SUBMISSION',
        suiErrorMessage: '',
        projectId: projectId,
        tags: tags,
        note: note,
      );

      final sourceFile = File(temporaryImagePath);
      if (await sourceFile.exists()) {
        await sourceFile.delete();
      }

      onProgress?.call(
        const CaptureSubmissionProgress(
          stage: CaptureSubmissionStage.signing,
          state: CaptureSubmissionStageState.completed,
          message: 'Capture proof bundle signed.',
        ),
      );
      currentStage = CaptureSubmissionStage.savingLocalRecord;
      onProgress?.call(
        const CaptureSubmissionProgress(
          stage: CaptureSubmissionStage.savingLocalRecord,
          state: CaptureSubmissionStageState.active,
          message: 'Saving the capture manifest on this device.',
        ),
      );
      await captureDataController.saveCapture(record.toJson());
      onProgress?.call(
        const CaptureSubmissionProgress(
          stage: CaptureSubmissionStage.savingLocalRecord,
          state: CaptureSubmissionStageState.completed,
          message: 'Local capture record saved.',
        ),
      );
      return CaptureActionResult.success(record);
    } catch (error) {
      onProgress?.call(
        CaptureSubmissionProgress(
          stage: currentStage,
          state: CaptureSubmissionStageState.failed,
          message: 'Capture persistence failed: $error',
        ),
      );
      return CaptureActionResult.failure('Capture persistence failed: $error');
    }
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

  String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
