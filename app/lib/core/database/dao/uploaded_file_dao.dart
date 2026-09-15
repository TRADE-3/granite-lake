import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../granite_lake_database_service.dart';

class UploadedFileDao {
  UploadedFileDao(this._databaseService);

  final GraniteLakeDatabaseService _databaseService;

  Future<List<Map<String, dynamic>>> listUploadedFiles() async {
    final database = await _databaseService.database;
    final rows = await database.query(
      GraniteLakeDatabaseService.uploadedFilesTable,
      orderBy: 'captured_at DESC',
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> upsert(Map<String, dynamic> uploadedFile) async {
    final database = await _databaseService.database;
    await database.insert(
      GraniteLakeDatabaseService.uploadedFilesTable,
      <String, dynamic>{
        'uploaded_file_id': uploadedFile['uploadedFileId'],
        'captured_at': uploadedFile['capturedAt'],
        'submitted_at': uploadedFile['submittedAt'],
        'file_path': uploadedFile['filePath'],
        'file_sha256': uploadedFile['fileSha256'],
        'signature_base64': uploadedFile['signatureBase64'],
        'wallet_address': uploadedFile['walletAddress'] ?? 'UNKNOWN',
        'public_key_hex': uploadedFile['publicKeyHex'],
        'proof_payload_json': jsonEncode(
          uploadedFile['proofPayload'] ?? const <String, dynamic>{},
        ),
        'sui_tx_digest': uploadedFile['suiTxDigest'] ?? '',
        'sui_object_id': uploadedFile['suiObjectId'] ?? '',
        'sui_submission_status':
            uploadedFile['suiSubmissionStatus'] ?? 'PENDING_SUBMISSION',
        'sui_error_message': uploadedFile['suiErrorMessage'] ?? '',
        'project_id': uploadedFile['projectId'],
        'tags_json': jsonEncode(uploadedFile['tags'] ?? const <String>[]),
        'note': uploadedFile['note'],
        'file_name': uploadedFile['fileName'],
        'mime_type': uploadedFile['mimeType'],
        'file_size_bytes': uploadedFile['fileSizeBytes'],
        'file_extension': uploadedFile['fileExtension'],
        'preview_kind': uploadedFile['previewKind'] ?? 'document',
        'storage_mode': uploadedFile['storageMode'] ?? 'LOCAL_ONLY',
        'is_online': (uploadedFile['isOnline'] as bool? ?? true) ? 1 : 0,
        'is_forced_offline': (uploadedFile['isForcedOffline'] as bool? ?? false)
            ? 1
            : 0,
        'internet_null_reason': uploadedFile['internetNullReason'],
        'internet_null_reason_hash': uploadedFile['internetNullReasonHash'],
        'submission_attempt_count':
            uploadedFile['submissionAttemptCount'] as int? ?? 0,
        'last_attempt_at': uploadedFile['lastAttemptAt'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    final database = await _databaseService.database;
    await database.delete(GraniteLakeDatabaseService.uploadedFilesTable);
  }
}
