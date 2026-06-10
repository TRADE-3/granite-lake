import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../granite_lake_database_service.dart';

class CaptureDao {
  CaptureDao(this._databaseService);

  final GraniteLakeDatabaseService _databaseService;

  Future<List<Map<String, dynamic>>> listCaptures() async {
    final database = await _databaseService.database;
    final rows = await database.query(
      GraniteLakeDatabaseService.capturesTable,
      orderBy: 'captured_at DESC',
    );
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> upsert(Map<String, dynamic> capture) async {
    final database = await _databaseService.database;
    await database.insert(
      GraniteLakeDatabaseService.capturesTable,
      <String, dynamic>{
        'capture_id': capture['captureId'],
        'captured_at': capture['capturedAt'],
        'submitted_at': capture['submittedAt'],
        'image_path': capture['imagePath'],
        'image_sha256': capture['imageSha256'],
        'signature_base64': capture['signatureBase64'],
        'wallet_address': capture['walletAddress'] ?? 'UNKNOWN',
        'public_key_hex': capture['publicKeyHex'],
        'proof_payload_json': jsonEncode(
          capture['proofPayload'] ?? const <String, dynamic>{},
        ),
        'sui_tx_digest': capture['suiTxDigest'] ?? '',
        'sui_object_id': capture['suiObjectId'] ?? '',
        'sui_submission_status':
            capture['suiSubmissionStatus'] ?? 'PENDING_SUBMISSION',
        'sui_error_message': capture['suiErrorMessage'] ?? '',
        'project_id': capture['projectId'],
        'tags_json': jsonEncode(capture['tags'] ?? const <String>[]),
        'note': capture['note'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAll() async {
    final database = await _databaseService.database;
    await database.delete(GraniteLakeDatabaseService.capturesTable);
  }
}
