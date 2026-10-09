import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';

import '../state/granite_lake_models.dart';

/// Opens the user's email app with a ready-to-send draft: the verified
/// photo/file attached, a subject, and a plain-language summary of the
/// verification. Nothing is sent — the user adds a recipient and hits send.
Future<void> composeVerifiedEmail(
  BuildContext context,
  AttestationRecord record, {
  String? location,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void notify(String message) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  final assetFile = File(record.localAssetPath);
  if (!await assetFile.exists()) {
    notify('Stored asset is unavailable');
    return;
  }

  final kind = record.isFile ? 'file' : 'photo';
  final hasLocation =
      location != null &&
      location.trim().isNotEmpty &&
      !location.toLowerCase().startsWith('not ');
  final note = record.note?.trim() ?? '';
  final body = [
    'Hello,',
    '',
    'Attached is a $kind that has been verified with Trade3. Its details are below.',
    '',
    'WHAT IT IS',
    '• Name: ${record.assetName}',
    '• Project: ${record.displayProject}',
    '• Captured on: ${_friendlyDate(record.capturedAt)}',
    if (hasLocation) '• Location: $location',
    if (note.isNotEmpty) '• Notes: $note',
    if (record.tags.isNotEmpty) '• Tags: ${record.tags.join(', ')}',
    '',
    'HOW IT WAS VERIFIED',
    '• Status: Verified and recorded on the blockchain',
    '• Verification ID: ${record.suiTxDigest}',
    '• Secure ID of sender: ${record.walletAddress}',
    '• File fingerprint (SHA-256): ${record.contentSha256}',
    '',
    'The file fingerprint is a unique code made from the $kind itself. If '
        'even one pixel or byte changes, the code changes, so a matching '
        'fingerprint shows this is the original, unaltered $kind.',
    '',
    'Sent from Trade3',
  ].join('\n');

  try {
    await FlutterEmailSender.send(
      Email(
        subject: 'Verified $kind: ${record.assetName}',
        body: body,
        attachmentPaths: [assetFile.path],
      ),
    );
  } catch (_) {
    notify('Could not open an email app. Make sure Gmail is installed.');
  }
}

String _friendlyDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${local.day} ${months[local.month - 1]} ${local.year}, '
      '$hour12:$minute $period';
}
