import 'dart:convert';

import '../dao/capture_dao.dart';

class CaptureDataController {
  CaptureDataController(this._captureDao);

  final CaptureDao _captureDao;

  Future<List<Map<String, dynamic>>> loadCaptures() async {
    final rows = await _captureDao.listCaptures();
    return rows.map(_toAppShape).toList(growable: false);
  }

  Future<void> saveCapture(Map<String, dynamic> capture) {
    return _captureDao.upsert(capture);
  }

  Future<void> clear() {
    return _captureDao.deleteAll();
  }

  Map<String, dynamic> _toAppShape(Map<String, dynamic> row) {
    return <String, dynamic>{
      'captureId': row['capture_id'],
      'capturedAt': row['captured_at'],
      'submittedAt': row['submitted_at'],
      'imagePath': row['image_path'],
      'imageSha256': row['image_sha256'],
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
    };
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
