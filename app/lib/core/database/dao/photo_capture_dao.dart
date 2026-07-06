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
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    final database = await _databaseService.database;
    await database.delete(GraniteLakeDatabaseService.photoCapturesTable);
  }
}
