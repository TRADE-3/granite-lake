import 'dart:convert';

import '../dao/uploaded_file_dao.dart';

class UploadedFileDataController {
  UploadedFileDataController(this._uploadedFileDao);

  final UploadedFileDao _uploadedFileDao;

  Future<List<Map<String, dynamic>>> loadUploadedFiles() async {
    final rows = await _uploadedFileDao.listUploadedFiles();
    return rows.map(_toAppShape).toList(growable: false);
  }

  Future<void> saveUploadedFile(Map<String, dynamic> uploadedFile) {
    return _uploadedFileDao.upsert(uploadedFile);
  }

  Future<void> clear() {
    return _uploadedFileDao.deleteAll();
  }

  Map<String, dynamic> _toAppShape(Map<String, dynamic> row) {
    return <String, dynamic>{
      'uploadedFileId': row['uploaded_file_id'],
      'capturedAt': row['captured_at'],
      'submittedAt': row['submitted_at'],
      'filePath': row['file_path'],
      'fileSha256': row['file_sha256'],
      'signatureBase64': row['signature_base64'],
      'walletAddress': row['wallet_address'],
      'publicKeyHex': row['public_key_hex'],
      'proofPayload': _decodeProofPayload(row['proof_payload_json']),
      'suiTxDigest': row['sui_tx_digest'],
      'suiObjectId': row['sui_object_id'],
      'suiSubmissionStatus': row['sui_submission_status'],
      'suiErrorMessage': row['sui_error_message'],
      'projectId': row['project_id'],
      'tags': _decodeTags(row['tags_json']),
      'note': row['note'],
      'fileName': row['file_name'],
      'mimeType': row['mime_type'],
      'fileSizeBytes': row['file_size_bytes'],
      'fileExtension': row['file_extension'],
      'previewKind': row['preview_kind'],
      'storageMode': row['storage_mode'],
      'isOnline': _readBool(row['is_online'], defaultValue: true),
      'isForcedOffline': _readBool(row['is_forced_offline']),
      'internetNullReason': row['internet_null_reason'],
      'internetNullReasonHash': row['internet_null_reason_hash'],
      'submissionAttemptCount': _readInt(row['submission_attempt_count']),
      'lastAttemptAt': row['last_attempt_at'],
    };
  }

  bool _readBool(Object? value, {bool defaultValue = false}) {
    if (value == null) return defaultValue;
    if (value is bool) return value;
    if (value is int) return value != 0;
    return defaultValue;
  }

  int _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  Map<String, dynamic> _decodeProofPayload(Object? value) {
    if (value is! String || value.isEmpty) {
      return const <String, dynamic>{};
    }

    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      return const <String, dynamic>{};
    }

    return Map<String, dynamic>.from(decoded);
  }

  List<String> _decodeTags(Object? value) {
    if (value is! String || value.isEmpty) {
      return const <String>[];
    }

    final decoded = jsonDecode(value) as List<dynamic>;
    return decoded.cast<String>();
  }
}
