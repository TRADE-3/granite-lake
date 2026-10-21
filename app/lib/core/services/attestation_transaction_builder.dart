import 'dart:convert';

import 'package:on_chain/on_chain.dart';

/// The values an `attest_photo` call carries, encoded exactly as the
/// contract (and the verification portal) expect them.
class PhotoAttestationTxArgs {
  const PhotoAttestationTxArgs({
    required this.imageSha256,
    required this.gps,
    required this.altitude,
    required this.projectId,
    required this.capturedAtMs,
    required this.isOnline,
    required this.isForcedOffline,
    required this.internetNullReasonHashHex,
    required this.hasGps,
    required this.isGpsForcedNull,
    required this.gpsNullReasonHashHex,
  });

  final String imageSha256;
  final String gps;
  final String altitude;
  final String projectId;
  final int capturedAtMs;
  final bool isOnline;
  final bool isForcedOffline;
  final String? internetNullReasonHashHex;
  final bool hasGps;
  final bool isGpsForcedNull;
  final String? gpsNullReasonHashHex;
}

/// The values an `attest_file` call carries.
class FileAttestationTxArgs {
  const FileAttestationTxArgs({
    required this.contentSha256,
    required this.fileId,
    required this.projectId,
    required this.capturedAtMs,
    required this.isOnline,
    required this.isForcedOffline,
    required this.internetNullReasonHashHex,
  });

  final String contentSha256;
  final String fileId;
  final String projectId;
  final int capturedAtMs;
  final bool isOnline;
  final bool isForcedOffline;
  final String? internetNullReasonHashHex;
}

/// Builds the single-MoveCall attestation transaction. Shared by the
/// self-paid path (photo_attestation_service.dart) and the sponsored path's
/// pre-signing verification (sponsor_attestation_service.dart), which
/// rebuilds the server's bytes from the app's own capture values - so any
/// change here must stay byte-identical with the server's
/// buildAttestationTransaction (pinned by the cross-SDK fixture test).
///
/// Input order matches the contract signature: UserCap, Registry, the
/// values, then Clock. `hash`/`gps`/`altitude`/`projectId`/`fileId` are the
/// UTF-8 bytes of the string (for the hash, the 64-char hex text); the
/// null-reason hashes are hex-decoded raw bytes, or empty.
class AttestationTransactionBuilder {
  const AttestationTransactionBuilder._();

  static SuiTransactionDataV1 photo({
    required SuiAddress sender,
    required SuiGasData gasData,
    required SuiObjectRef userCap,
    required SuiObjectArg registry,
    required SuiObjectArg clock,
    required String packageId,
    required String moduleName,
    required PhotoAttestationTxArgs args,
  }) {
    return _build(
      sender: sender,
      gasData: gasData,
      packageId: packageId,
      moduleName: moduleName,
      function: 'attest_photo',
      inputs: [
        SuiCallArgObject(SuiObjectArgImmOrOwnedObject(userCap)),
        SuiCallArgObject(registry),
        SuiCallArgPure.bytes(utf8.encode(args.imageSha256)),
        SuiCallArgPure.bytes(utf8.encode(args.gps)),
        SuiCallArgPure.bytes(utf8.encode(args.altitude)),
        SuiCallArgPure.bytes(utf8.encode(args.projectId)),
        SuiCallArgPure.u64(BigInt.from(args.capturedAtMs)),
        SuiCallArgPure.boolean(args.isOnline),
        SuiCallArgPure.boolean(args.isForcedOffline),
        SuiCallArgPure.bytes(hexToBytes(args.internetNullReasonHashHex)),
        SuiCallArgPure.boolean(args.hasGps),
        SuiCallArgPure.boolean(args.isGpsForcedNull),
        SuiCallArgPure.bytes(hexToBytes(args.gpsNullReasonHashHex)),
        SuiCallArgObject(clock),
      ],
    );
  }

  static SuiTransactionDataV1 file({
    required SuiAddress sender,
    required SuiGasData gasData,
    required SuiObjectRef userCap,
    required SuiObjectArg registry,
    required SuiObjectArg clock,
    required String packageId,
    required String moduleName,
    required FileAttestationTxArgs args,
  }) {
    return _build(
      sender: sender,
      gasData: gasData,
      packageId: packageId,
      moduleName: moduleName,
      function: 'attest_file',
      inputs: [
        SuiCallArgObject(SuiObjectArgImmOrOwnedObject(userCap)),
        SuiCallArgObject(registry),
        SuiCallArgPure.bytes(utf8.encode(args.contentSha256)),
        SuiCallArgPure.bytes(utf8.encode(args.fileId)),
        SuiCallArgPure.bytes(utf8.encode(args.projectId)),
        SuiCallArgPure.u64(BigInt.from(args.capturedAtMs)),
        SuiCallArgPure.boolean(args.isOnline),
        SuiCallArgPure.boolean(args.isForcedOffline),
        SuiCallArgPure.bytes(hexToBytes(args.internetNullReasonHashHex)),
        SuiCallArgObject(clock),
      ],
    );
  }

  static SuiTransactionDataV1 _build({
    required SuiAddress sender,
    required SuiGasData gasData,
    required String packageId,
    required String moduleName,
    required String function,
    required List<SuiCallArg> inputs,
  }) {
    return SuiTransactionDataV1(
      expiration: const SuiTransactionExpirationNone(),
      sender: sender,
      gasData: gasData,
      kind: SuiTransactionKindProgrammableTransaction(
        SuiProgrammableTransaction(
          inputs: inputs,
          commands: [
            SuiCommandMoveCall(
              SuiProgrammableMoveCall(
                package: SuiAddress(packageId),
                module: moduleName,
                function: function,
                arguments: [
                  for (var i = 0; i < inputs.length; i++) SuiArgumentInput(i),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Decodes a hex-encoded hash (as persisted in `*_null_reason_hash`
  /// columns) back to raw bytes for a `vector<u8>` transaction argument. A
  /// null/empty input becomes an empty vector, matching what the contract's
  /// `is_empty()` check expects in the one no-reason-needed state per axis.
  static List<int> hexToBytes(String? hex) {
    final normalized = hex?.trim() ?? '';
    if (normalized.isEmpty) {
      return const <int>[];
    }
    final bytes = <int>[];
    for (var i = 0; i + 1 < normalized.length; i += 2) {
      bytes.add(int.parse(normalized.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }
}
