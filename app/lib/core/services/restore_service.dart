import 'dart:convert';

import 'package:path/path.dart' as path;

import '../constants/app_constants.dart';
import '../state/granite_lake_models.dart';
import 'trade3_api_service.dart';

/// One `PhotoAttested` / `FileAttested` event as read from the chain.
class AttestationEvent {
  const AttestationEvent({
    required this.type,
    required this.txDigest,
    required this.json,
  });

  /// The Move type, e.g. `0x…::photo_attestation::PhotoAttested`.
  final String type;
  final String txDigest;
  final Map<String, dynamic> json;
}

class RestorePlan {
  const RestorePlan({
    required this.records,
    required this.projects,
    required this.alreadyOnDevice,
    required this.notAttestedByThisWallet,
  });

  /// History entries to add, one per file hash.
  final List<AttestationRecord> records;

  /// Projects those entries belong to (captures reference them).
  final List<ProjectRecord> projects;
  final int alreadyOnDevice;
  final int notAttestedByThisWallet;
}

class _Document {
  const _Document(this.target, this.document);

  final Trade3TargetSelection target;
  final Trade3HierarchyDocument document;
}

/// Rebuilds history after a wallet import. Trade3 says which hashes were
/// pinned through Granite; only those this wallet attested on-chain are the
/// user's own. The chain supplies what was attested and Trade3 the file's name
/// and place in the hierarchy. The files themselves cannot be downloaded.
RestorePlan buildRestorePlan({
  required List<Trade3MasterContract> contracts,
  required List<AttestationEvent> events,
  required String walletAddress,
  required String publicKeyHex,
  required Set<String> existingHashes,
  required DateTime now,
}) {
  final documents = <String, List<_Document>>{};
  for (final contract in contracts) {
    for (final transaction in contract.transactions) {
      for (final schedule in transaction.paymentSchedules) {
        for (final document in schedule.documents) {
          final hash = _normalizeHash(document.documentHash);
          if (!document.isVerifiedByGranite || hash == null) {
            continue;
          }
          documents
              .putIfAbsent(hash, () => [])
              .add(
                _Document(
                  Trade3TargetSelection(
                    masterContractId: contract.id,
                    masterContractTitle: contract.title,
                    transactionId: transaction.id,
                    transactionTitle: transaction.title,
                    paymentScheduleId: schedule.id,
                    paymentScheduleTitle: schedule.title,
                  ),
                  document,
                ),
              );
        }
      }
    }
  }

  // The same hash can be attested twice: keep the first, the original proof.
  final attested = <String, AttestationEvent>{};
  final wallet = walletAddress.toLowerCase();
  for (final event in events) {
    final isFile = event.type.endsWith('::FileAttested');
    if (!isFile && !event.type.endsWith('::PhotoAttested')) {
      continue;
    }
    if ('${event.json['user_wallet']}'.toLowerCase() != wallet) {
      continue;
    }
    final hash = _normalizeHash(
      _text(event.json[isFile ? 'file_hash' : 'photo_hash']),
    );
    if (hash == null) {
      continue;
    }
    final previous = attested[hash];
    if (previous == null ||
        _millis(event.json['attested_at']) <
            _millis(previous.json['attested_at'])) {
      attested[hash] = event;
    }
  }

  final records = <AttestationRecord>[];
  final projects = <String, ProjectRecord>{};
  final present = existingHashes.map((hash) => hash.toLowerCase()).toSet();
  var alreadyOnDevice = 0;
  var notAttestedByThisWallet = 0;

  for (final MapEntry(key: hash, value: matches) in documents.entries) {
    if (present.contains(hash)) {
      alreadyOnDevice++;
      continue;
    }
    final event = attested[hash];
    if (event == null) {
      notAttestedByThisWallet++;
      continue;
    }

    // Prefer the document filed where the chain says it was attested.
    final projectId = _text(event.json['project_id']);
    final match = matches.firstWhere(
      (candidate) => candidate.target.projectId == projectId,
      orElse: () => matches.first,
    );
    final record = _record(
      hash: hash,
      event: event,
      match: match,
      walletAddress: walletAddress,
      publicKeyHex: publicKeyHex,
      now: now,
    );
    records.add(record);

    final recordProject = record.projectId;
    if (recordProject != null) {
      projects.putIfAbsent(
        recordProject,
        () => ProjectRecord(
          projectId: recordProject,
          title: recordProject == match.target.projectId
              ? match.target.projectTitle
              : recordProject,
          createdAt: record.capturedAt,
        ),
      );
    }
  }

  return RestorePlan(
    records: records,
    projects: projects.values.toList(growable: false),
    alreadyOnDevice: alreadyOnDevice,
    notAttestedByThisWallet: notAttestedByThisWallet,
  );
}

AttestationRecord _record({
  required String hash,
  required AttestationEvent event,
  required _Document match,
  required String walletAddress,
  required String publicKeyHex,
  required DateTime now,
}) {
  final json = event.json;
  final isFile = event.type.endsWith('::FileAttested');
  final document = match.document;
  final capturedAt = _time(json['captured_at']);
  final attestedAt = _time(json['attested_at']);
  final projectId = _text(json['project_id']);
  final fileName = _fileName(document, isFile: isFile);
  final extension = path.extension(fileName).toLowerCase();
  final mimeType = _mimeTypes[extension] ?? (isFile ? null : 'image/jpeg');
  final fileId = isFile ? _text(json['file_id']) : '';
  final id = fileId.isNotEmpty ? fileId : 'restored_${hash.substring(0, 32)}';
  final hasGps = json['has_gps'] != false;
  final gps = _text(json['gps']);
  final altitude = _text(json['altitude']);

  return AttestationRecord(
    captureId: id,
    capturedAt: capturedAt,
    submittedAt: attestedAt,
    // Not a real path: the file is not on this device.
    imagePath: fileName,
    imageSha256: hash,
    // The original local signature cannot be recreated.
    signatureBase64: '',
    walletAddress: walletAddress,
    publicKeyHex: publicKeyHex,
    proofPayload: AttestationProofPayload(
      values: {
        'assetType': isFile ? 'file' : 'photo',
        'fileName': fileName,
        if (isFile) 'fileId': id,
        'projectId': projectId,
        'domain': _text(json['domain']),
        if (!isFile) 'gpsLabel': gps,
        if (!isFile) 'altitudeLabel': altitude,
        'submittedAt': attestedAt.toIso8601String(),
        'attestedAt': attestedAt.toIso8601String(),
        'restoredAt': now.toIso8601String(),
        'trade3DocumentType': document.documentType,
        'trade3MasterContract': match.target.masterContractTitle,
        'trade3Transaction': match.target.transactionTitle,
        'trade3PaymentSchedule': match.target.paymentScheduleTitle,
      },
    ),
    suiTxDigest: event.txDigest,
    suiObjectId: '',
    suiSubmissionStatus: 'SUCCESS',
    suiErrorMessage: '',
    projectId: projectId.isEmpty || projectId == _unassigned ? null : projectId,
    assetType: isFile ? AttestationAssetType.file : AttestationAssetType.photo,
    fileName: fileName,
    mimeType: mimeType,
    fileExtension: extension.isEmpty ? null : extension,
    previewKind: !isFile || (mimeType ?? '').startsWith('image/')
        ? AttestationPreviewKind.image
        : mimeType == 'application/pdf'
        ? AttestationPreviewKind.document
        : AttestationPreviewKind.binary,
    isOnline: json['is_online'] != false,
    isForcedOffline: json['is_forced_offline'] == true,
    internetNullReasonHash: _hex(json['internet_null_reason_hash']),
    hasGps: isFile || hasGps,
    isGpsForcedNull: json['is_gps_forced_null'] == true,
    gpsNullReasonHash: _hex(json['gps_null_reason_hash']),
    // Already on Trade3, so it is never uploaded again.
    trade3TransactionId: match.target.transactionId,
    trade3PaymentScheduleId: match.target.paymentScheduleId,
    trade3UploadStatus: 'UPLOADED',
    trade3ErrorMessage: '',
    trade3DocumentId: document.id,
    isRestored: true,
  );
}

const _unassigned = AppConstants.attestationUnassignedLabel;

const _mimeTypes = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.pdf': 'application/pdf',
};

/// Trade3 sometimes has no file name, only a `supporting_<name>` type.
String _fileName(Trade3HierarchyDocument document, {required bool isFile}) {
  for (final candidate in [
    document.fileName,
    document.documentType.replaceFirst(RegExp(r'^supporting_'), ''),
  ]) {
    final name = path.basename(candidate.trim());
    if (name.isNotEmpty && name != '.') {
      return name;
    }
  }
  return isFile ? 'restored_file' : 'capture.jpg';
}

String? _normalizeHash(String value) {
  var hash = value.trim().toLowerCase();
  if (hash.startsWith('0x')) {
    hash = hash.substring(2);
  }
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ? hash : null;
}

/// Move `vector<u8>` text fields arrive base64 encoded.
String _text(Object? value) {
  if (value is! String || value.isEmpty) {
    return '';
  }
  try {
    return utf8.decode(base64.decode(value)).trim();
  } on FormatException {
    return value.trim();
  }
}

/// Reason hashes are raw bytes on-chain and hex in the app.
String? _hex(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  try {
    return base64
        .decode(value)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  } on FormatException {
    return null;
  }
}

int _millis(Object? value) => int.tryParse('$value') ?? 0;

DateTime _time(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(_millis(value), isUtc: true);
