import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../granite_lake_database_service.dart';

class PhotoCaptureDao {
  PhotoCaptureDao(this._databaseService);

  final GraniteLakeDatabaseService _databaseService;

  Future<List<Map<String, dynamic>>> listPhotoCaptures() async {
    final database = await _databaseService.database;
    final rows = await database.query(
      GraniteLakeDatabaseService.photoCapturesTable,
      orderBy: 'captured_at DESC',
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> upsert(Map<String, dynamic> photoCapture) async {
    final database = await _databaseService.database;
    await database.insert(
      GraniteLakeDatabaseService.photoCapturesTable,
      <String, dynamic>{
        'photo_capture_id': photoCapture['photoCaptureId'],
        'captured_at': photoCapture['capturedAt'],
        'submitted_at': photoCapture['submittedAt'],
        'image_path': photoCapture['imagePath'],
        'image_sha256': photoCapture['imageSha256'],
        'signature_base64': photoCapture['signatureBase64'],
        'wallet_address': photoCapture['walletAddress'] ?? 'UNKNOWN',
        'public_key_hex': photoCapture['publicKeyHex'],
        'proof_payload_json': jsonEncode(
          photoCapture['proofPayload'] ?? const <String, dynamic>{},
        ),
        'sui_tx_digest': photoCapture['suiTxDigest'] ?? '',
        'sui_object_id': photoCapture['suiObjectId'] ?? '',
        'sui_submission_status':
            photoCapture['suiSubmissionStatus'] ?? 'PENDING_SUBMISSION',
        'sui_error_message': photoCapture['suiErrorMessage'] ?? '',
        'project_id': photoCapture['projectId'],
        'tags_json': jsonEncode(photoCapture['tags'] ?? const <String>[]),
        'note': photoCapture['note'],
        'preview_kind': photoCapture['previewKind'] ?? 'image',
        'storage_mode': photoCapture['storageMode'] ?? 'LOCAL_ONLY',
        'is_online': (photoCapture['isOnline'] as bool? ?? true) ? 1 : 0,
        'is_forced_offline': (photoCapture['isForcedOffline'] as bool? ?? false)
            ? 1
            : 0,
        'has_gps': (photoCapture['hasGps'] as bool? ?? true) ? 1 : 0,
        'is_gps_forced_null':
            (photoCapture['isGpsForcedNull'] as bool? ?? false) ? 1 : 0,
        'internet_null_reason': photoCapture['internetNullReason'],
        'internet_null_reason_hash': photoCapture['internetNullReasonHash'],
        'gps_null_reason': photoCapture['gpsNullReason'],
        'gps_null_reason_hash': photoCapture['gpsNullReasonHash'],
        'submission_attempt_count':
            photoCapture['submissionAttemptCount'] as int? ?? 0,
        'last_attempt_at': photoCapture['lastAttemptAt'],
        'encrypted_payload': photoCapture['encryptedPayload'],
        'payload_iv': photoCapture['payloadIv'],
        'wrapped_data_key': photoCapture['wrappedDataKey'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    final database = await _databaseService.database;
    await database.delete(GraniteLakeDatabaseService.photoCapturesTable);
  }

  /// Read-only count of rows still awaiting on-chain submission. Safe to
  /// call from a background isolate (reconnect_notification_service.dart) -
  /// touches no signing state, just a status column.
  Future<int> countPendingSubmissions() async {
    final database = await _databaseService.database;
    final result = await database.rawQuery(
      'SELECT COUNT(*) AS count FROM ${GraniteLakeDatabaseService.photoCapturesTable} '
      "WHERE sui_submission_status IN ('PENDING_SUBMISSION', 'PENDING', 'SUBMITTING')",
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
