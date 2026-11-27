import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/services/restore_service.dart';
import 'package:granite_lake/core/services/trade3_api_service.dart';
import 'package:granite_lake/core/state/granite_lake_models.dart';

const _wallet = '0x2b97';
final _hashA = 'a' * 64;
final _hashB = 'b' * 64;

String _b64(String value) => base64.encode(utf8.encode(value));

AttestationEvent _event(
  String hash, {
  bool file = false,
  String wallet = _wallet,
  String projectId = 't3:51:56:279',
  int attestedAt = 2000,
  String digest = 'digest-1',
}) {
  return AttestationEvent(
    type: '0xd0::photo_attestation::${file ? 'File' : 'Photo'}Attested',
    txDigest: digest,
    json: {
      file ? 'file_hash' : 'photo_hash': _b64(hash),
      if (file) 'file_id': _b64('file-7'),
      'user_wallet': wallet,
      'project_id': _b64(projectId),
      'domain': _b64('tr3.io'),
      if (!file) 'gps': _b64('6.66, 79.93 (20m)'),
      if (!file) 'altitude': _b64('-88.1 m'),
      'captured_at': '1000',
      'attested_at': '$attestedAt',
      'is_online': false,
      'is_forced_offline': true,
      'internet_null_reason_hash': base64.encode([0xab, 0x01]),
      if (!file) 'has_gps': true,
      if (!file) 'is_gps_forced_null': false,
    },
  );
}

Trade3HierarchyDocument _document(
  String id,
  String hash, {
  bool verified = true,
  String? name = 'capture.jpg',
}) {
  return Trade3HierarchyDocument.fromJson({
    'id': id,
    'file_name': name,
    'document_type': 'supporting_report.pdf',
    'status': null,
    'hash': hash,
    'is_verified_by_granite': verified,
    'is_required': false,
  });
}

List<Trade3MasterContract> _contracts(List<Trade3HierarchyDocument> documents) {
  final parsed = Trade3MasterContract.listFromJson([
    {
      'id': '51',
      'title': 'Master',
      'transactions': [
        {
          'id': '56',
          'title': 'Shipment',
          'payment_schedules': [
            {
              'id': '279',
              'title': 'Customs',
              'documents': [for (final d in documents) d.toJson()],
            },
          ],
        },
      ],
    },
  ]);
  return parsed;
}

RestorePlan _plan(
  List<Trade3HierarchyDocument> documents,
  List<AttestationEvent> events, {
  Set<String> existing = const {},
}) {
  return buildRestorePlan(
    contracts: _contracts(documents),
    events: events,
    walletAddress: _wallet,
    publicKeyHex: 'pk',
    existingHashes: existing,
    now: DateTime.utc(2026, 11, 27),
  );
}

void main() {
  test('rebuilds a photo from the chain and Trade3', () {
    final plan = _plan([_document('588', _hashA)], [_event(_hashA)]);
    final record = plan.records.single;

    expect(record.isRestored, isTrue);
    expect(record.isPhoto, isTrue);
    expect(record.contentSha256, _hashA);
    expect(record.assetName, 'capture.jpg');
    expect(record.suiTxDigest, 'digest-1');
    expect(record.isAttestationAnchored, isTrue);
    expect(record.capturedAt.millisecondsSinceEpoch, 1000);
    expect(record.capturedGpsLabel, '6.66, 79.93 (20m)');
    expect(record.capturedAltitudeLabel, '-88.1 m');
    expect(record.domainLabel, 'tr3.io');
    expect(record.isOnline, isFalse);
    expect(record.isForcedOffline, isTrue);
    expect(record.internetNullReasonHash, 'ab01');
    expect(record.trade3DocumentId, '588');
    expect(record.trade3PaymentScheduleId, '279');
    // Already on Trade3: it must never be queued for upload again.
    expect(record.isTrade3UploadPending, isFalse);
    expect(plan.projects.single.projectId, 't3:51:56:279');
    expect(record.projectId, plan.projects.single.projectId);
  });

  test('rebuilds a file, keeping its on-chain file id', () {
    final plan = _plan(
      [_document('9', _hashA, name: null)],
      [_event(_hashA, file: true)],
    );
    final record = plan.records.single;

    expect(record.isFile, isTrue);
    expect(record.fileId, 'file-7');
    expect(record.assetName, 'report.pdf');
    expect(record.mimeType, 'application/pdf');
    expect(UploadedFileRecord.fromAttestationRecord(record).isRestored, isTrue);
  });

  test('ignores documents Granite did not verify or without a hash', () {
    final plan = _plan(
      [_document('1', _hashA, verified: false), _document('2', '')],
      [_event(_hashA)],
    );

    expect(plan.records, isEmpty);
    expect(plan.notAttestedByThisWallet, 0);
  });

  test("leaves out other people's files", () {
    final plan = _plan(
      [_document('1', _hashA), _document('2', _hashB)],
      [_event(_hashA, wallet: '0xsomeone')],
    );

    expect(plan.records, isEmpty);
    expect(plan.notAttestedByThisWallet, 2);
  });

  test('restores a repeated hash once, from its first attestation', () {
    final plan = _plan(
      [_document('572', _hashA), _document('576', _hashA.toUpperCase())],
      [
        _event(_hashA, attestedAt: 9000, digest: 'later'),
        _event(_hashA, attestedAt: 2000, digest: 'first'),
      ],
    );

    expect(plan.records.single.suiTxDigest, 'first');
  });

  test('skips what is already on the phone, so it can be run again', () {
    final plan = _plan(
      [_document('1', _hashA)],
      [_event(_hashA)],
      existing: {_hashA},
    );

    expect(plan.records, isEmpty);
    expect(plan.alreadyOnDevice, 1);
  });

  test('nothing to restore is an empty plan, not an error', () {
    for (final plan in [
      _plan([], []),
      _plan([_document('1', _hashA)], []),
      buildRestorePlan(
        contracts: const [],
        events: const [],
        walletAddress: _wallet,
        publicKeyHex: 'pk',
        existingHashes: const {},
        now: DateTime.utc(2026),
      ),
    ]) {
      expect(plan.records, isEmpty);
      expect(plan.projects, isEmpty);
    }
  });

  test('the restored flag survives storage', () {
    final record = _plan(
      [_document('1', _hashA)],
      [_event(_hashA)],
    ).records.single;
    final photo = PhotoCaptureRecord.fromAttestationRecord(record);

    final reloaded = PhotoCaptureRecord.fromJson(photo.toJson());

    expect(reloaded.isRestored, isTrue);
    expect(reloaded.toAttestationRecord().isRestored, isTrue);
  });
}
