import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:on_chain/on_chain.dart';

import '../utils/utils.dart';
import 'attestation_transaction_builder.dart';

/// What the domain backend reports at `GET /sponsor/status`.
class SponsorStatus {
  const SponsorStatus({
    required this.enabled,
    this.sponsorWallet = '',
    this.maxGasBudgetMist,
    this.maxGasPriceMist,
  });

  static const SponsorStatus disabled = SponsorStatus(enabled: false);

  final bool enabled;
  final String sponsorWallet;
  final BigInt? maxGasBudgetMist;
  final BigInt? maxGasPriceMist;
}

class SponsorObjectRef {
  const SponsorObjectRef({
    required this.objectId,
    required this.version,
    required this.digest,
  });

  final String objectId;
  final BigInt version;
  final String digest;
}

class SponsorSharedObjectRef {
  const SponsorSharedObjectRef({
    required this.objectId,
    required this.initialSharedVersion,
  });

  final String objectId;
  final BigInt initialSharedVersion;
}

/// The unsigned transaction returned by `POST /sponsor/prepare`. Nothing in
/// it is trusted until [SponsorAttestationService.verifyPreparedTransaction]
/// has rebuilt and matched the bytes.
class PreparedSponsorTransaction {
  const PreparedSponsorTransaction({
    required this.digest,
    required this.txBytes,
    required this.gasOwner,
    required this.gasPrice,
    required this.gasBudget,
    required this.userCap,
    required this.registry,
    required this.clock,
  });

  final String digest;
  final List<int> txBytes;
  final String gasOwner;
  final BigInt gasPrice;
  final BigInt gasBudget;
  final SponsorObjectRef userCap;
  final SponsorSharedObjectRef registry;
  final SponsorSharedObjectRef clock;
}

class SponsorSubmitResult {
  const SponsorSubmitResult({
    required this.digest,
    required this.status,
    this.gasUsedMist,
    this.error,
  });

  final String digest;

  /// `executed`, `failed`, `pending` (outcome not known yet) or `dropped`
  /// (never landed; re-prepare).
  final String status;
  final String? gasUsedMist;
  final String? error;
}

class SponsorAttestationException implements Exception {
  const SponsorAttestationException({
    required this.code,
    required this.userMessage,
    this.statusCode,
    this.rawMessage,
  });

  final int? statusCode;
  final String code;
  final String userMessage;
  final String? rawMessage;

  /// Only `503 sponsor_disabled` / `sponsor_unavailable` may fall back to
  /// the wallet paying its own fee. A capped (409) or rate-limited (429)
  /// user must never silently start spending their own funds.
  bool get allowsSelfPayFallback =>
      statusCode == 503 &&
      (code == 'sponsor_disabled' || code == 'sponsor_unavailable');

  /// Leave the capture `PENDING_SUBMISSION` for the regular retry sweep
  /// rather than failing it.
  bool get keepQueued =>
      code == 'quota_exceeded' ||
      code == 'rate_limit_exceeded' ||
      code == 'prepared_tx_not_found' ||
      code == 'sponsor_disabled' ||
      code == 'sponsor_unavailable' ||
      code == 'sui_rpc_failed' ||
      code == 'pending' ||
      code == 'dropped' ||
      code == 'stale_epoch' ||
      code == 'not_confirmed' ||
      (statusCode != null && statusCode! >= 500);

  @override
  String toString() => userMessage;
}

/// Domain-sponsored attestation gas (design doc
/// granite-lake-sponsored-transactions-design.md). The domain backend builds
/// the transaction with its sponsor wallet as gas owner; this service only
/// lets the device key sign it after verifying, byte for byte, that it is
/// exactly the attestation the app would have built itself.
class SponsorAttestationService {
  SponsorAttestationService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  static const String _clockObjectId = '0x6';

  Future<SponsorStatus> fetchStatus({required String domain}) async {
    final payload = await _send(domain: domain, path: 'sponsor/status');
    if (payload['enabled'] != true) {
      return SponsorStatus.disabled;
    }
    final sponsorWallet = (payload['sponsorWallet'] as String? ?? '').trim();
    if (sponsorWallet.isEmpty) {
      return SponsorStatus.disabled;
    }
    return SponsorStatus(
      enabled: true,
      sponsorWallet: sponsorWallet,
      maxGasBudgetMist: BigInt.parse('${payload['maxGasBudgetMist']}'),
      maxGasPriceMist: BigInt.parse('${payload['maxGasPriceMist']}'),
    );
  }

  Future<PreparedSponsorTransaction> preparePhoto({
    required String domain,
    required String userWallet,
    required PhotoAttestationTxArgs args,
  }) {
    return _prepare(
      domain: domain,
      body: {
        'userWallet': userWallet,
        'kind': 'photo',
        'args': {
          'hash': args.imageSha256,
          'gps': args.gps,
          'altitude': args.altitude,
          'projectId': args.projectId,
          'capturedAtMs': args.capturedAtMs,
          'isOnline': args.isOnline,
          'isForcedOffline': args.isForcedOffline,
          'internetNullReasonHash': args.internetNullReasonHashHex ?? '',
          'hasGps': args.hasGps,
          'isGpsForcedNull': args.isGpsForcedNull,
          'gpsNullReasonHash': args.gpsNullReasonHashHex ?? '',
        },
      },
    );
  }

  Future<PreparedSponsorTransaction> prepareFile({
    required String domain,
    required String userWallet,
    required FileAttestationTxArgs args,
  }) {
    return _prepare(
      domain: domain,
      body: {
        'userWallet': userWallet,
        'kind': 'file',
        'args': {
          'hash': args.contentSha256,
          'fileId': args.fileId,
          'projectId': args.projectId,
          'capturedAtMs': args.capturedAtMs,
          'isOnline': args.isOnline,
          'isForcedOffline': args.isForcedOffline,
          'internetNullReasonHash': args.internetNullReasonHashHex ?? '',
        },
      },
    );
  }

  Future<SponsorSubmitResult> submit({
    required String domain,
    required String userWallet,
    required String digest,
    required String userSignature,
  }) async {
    final payload = await _send(
      domain: domain,
      path: 'sponsor/submit',
      body: {
        'userWallet': userWallet,
        'digest': digest,
        'userSignature': userSignature,
      },
    );
    return SponsorSubmitResult(
      digest: (payload['digest'] as String? ?? digest).trim(),
      status: (payload['status'] as String? ?? '').trim(),
      gasUsedMist: payload['gasUsedMist'] as String?,
      error: payload['error'] as String?,
    );
  }

  /// The app's pre-signing check (design doc §8). Returns the bytes to sign
  /// only if every check passes; throws otherwise, and the key is never
  /// used on a mismatch.
  ///
  /// 1. Exact prefix: rebuild the expected transaction from the app's own
  ///    capture values ([expected]), the server's object refs (after
  ///    checking their ids) and its declared gas data, serialize it with a
  ///    `None` expiration, drop that trailing tag byte, and require
  ///    `txBytes` to start with exactly those bytes. That pins the package,
  ///    module, function, every argument, the sender and every gas field.
  /// 2. Expiration tail: what remains must be exactly one `ValidDuring` in
  ///    the layout `_bcsWithValidDuringExpiration` writes, for the current
  ///    epoch and chain, and nothing after it.
  /// 3. Gas sanity: the gas owner is the advertised sponsor and never the
  ///    user's own wallet (which would quietly make the user pay), and
  ///    budget/price are within the advertised caps.
  static List<int> verifyPreparedTransaction({
    required PreparedSponsorTransaction prepared,
    required SponsorStatus status,
    required String ownWallet,
    required String expectedUserCapObjectId,
    required String expectedRegistryId,
    required BigInt currentEpoch,
    required String chainDigest,
    required SuiTransactionDataV1 Function(
      SuiAddress sender,
      SuiGasData gasData,
      SuiObjectRef userCap,
      SuiObjectArg registry,
      SuiObjectArg clock,
    )
    expected,
  }) {
    final sender = SuiAddress(ownWallet);

    // 3. Gas sanity, checked first because the gas owner feeds the rebuild.
    if (!status.enabled || status.sponsorWallet.isEmpty) {
      _reject('sponsorship is not enabled');
    }
    final gasOwner = SuiAddress(prepared.gasOwner);
    if (gasOwner == sender) {
      _reject('gas owner is the user wallet');
    }
    if (gasOwner != SuiAddress(status.sponsorWallet)) {
      _reject('gas owner is not the advertised sponsor');
    }
    final maxBudget = status.maxGasBudgetMist;
    final maxPrice = status.maxGasPriceMist;
    if (maxBudget == null || prepared.gasBudget > maxBudget) {
      _reject('gas budget exceeds the sponsor cap');
    }
    if (maxPrice == null || prepared.gasPrice > maxPrice) {
      _reject('gas price exceeds the sponsor cap');
    }

    if (SuiAddress(prepared.userCap.objectId) !=
        SuiAddress(expectedUserCapObjectId)) {
      _reject('unexpected UserCap');
    }
    if (SuiAddress(prepared.registry.objectId) !=
        SuiAddress(expectedRegistryId)) {
      _reject('unexpected registry');
    }
    if (SuiAddress(prepared.clock.objectId) != SuiAddress(_clockObjectId)) {
      _reject('unexpected clock');
    }

    // 1. Exact prefix match.
    final rebuilt = expected(
      sender,
      SuiGasData(
        payment: const [],
        owner: gasOwner,
        price: prepared.gasPrice,
        budget: prepared.gasBudget,
      ),
      SuiObjectRef(
        address: SuiAddress(prepared.userCap.objectId),
        version: prepared.userCap.version,
        digest: SuiObjectDigest.fromBase58(prepared.userCap.digest),
      ),
      SuiObjectArgSharedObject(
        id: SuiAddress(prepared.registry.objectId),
        initialSharedVersion: prepared.registry.initialSharedVersion,
        mutable: false,
      ),
      SuiObjectArgSharedObject(
        id: SuiAddress(prepared.clock.objectId),
        initialSharedVersion: prepared.clock.initialSharedVersion,
        mutable: false,
      ),
    ).copyWith(expiration: const SuiTransactionExpirationNone());
    final withNone = rebuilt.toVariantBcs();
    // With a None expiration the final byte is its 0x00 variant tag.
    final prefix = withNone.sublist(0, withNone.length - 1);
    final bytes = prepared.txBytes;
    if (bytes.length < prefix.length) {
      _reject('transaction is shorter than expected');
    }
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) {
        _reject('transaction does not match this capture');
      }
    }

    // 2. ValidDuring tail: variant 2, Some(minEpoch), Some(maxEpoch), no
    // timestamp bounds, the 32-byte chain digest, a u32 nonce, nothing more.
    final chain = SuiObjectDigest.fromBase58(chainDigest).digest;
    final tail = bytes.sublist(prefix.length);
    const tailLength = 1 + 9 + 9 + 1 + 1 + 1 + 32 + 4;
    if (tail.length != tailLength) {
      _reject('unexpected expiration layout');
    }
    var offset = 0;
    int next() => tail[offset++];
    BigInt u64() {
      var value = BigInt.zero;
      for (var i = 0; i < 8; i++) {
        value |= BigInt.from(next()) << (8 * i);
      }
      return value;
    }

    if (next() != 2) _reject('expiration is not ValidDuring');
    if (next() != 1) _reject('missing min epoch');
    final minEpoch = u64();
    if (next() != 1) _reject('missing max epoch');
    final maxEpoch = u64();
    if (next() != 0 || next() != 0) _reject('unexpected timestamp bounds');
    if (next() != chain.length) _reject('unexpected chain id length');
    for (final byte in chain) {
      if (next() != byte) _reject('unexpected chain id');
    }
    if (maxEpoch < minEpoch || maxEpoch > minEpoch + BigInt.one) {
      _reject('validity window is too wide');
    }
    // The digest is what submit refers to and what the app later confirms
    // on-chain, so it must be the digest of exactly these bytes.
    if (SuiHelper.generateTransactionDigest(bytes) != prepared.digest) {
      _reject('digest does not match the transaction');
    }
    if (minEpoch != currentEpoch) {
      // Usually an epoch boundary between prepare and this check: harmless,
      // and a fresh prepare fixes it.
      throw const SponsorAttestationException(
        code: 'stale_epoch',
        userMessage:
            'The network moved on while preparing this submission. It will be retried automatically.',
      );
    }

    return bytes;
  }

  static Never _reject(String reason) {
    throw SponsorAttestationException(
      code: 'verification_failed',
      userMessage:
          'The submission prepared by your organisation did not match this capture, so it was not signed.',
      rawMessage: 'Sponsored transaction rejected before signing: $reason.',
    );
  }

  Future<PreparedSponsorTransaction> _prepare({
    required String domain,
    required Map<String, Object?> body,
  }) async {
    final payload = await _send(
      domain: domain,
      path: 'sponsor/prepare',
      body: body,
    );
    try {
      final gasData = payload['gasData'] as Map<String, dynamic>;
      final objectRefs = payload['objectRefs'] as Map<String, dynamic>;
      final userCap = objectRefs['userCap'] as Map<String, dynamic>;
      final registry = objectRefs['registry'] as Map<String, dynamic>;
      final clock = objectRefs['clock'] as Map<String, dynamic>;
      if ((gasData['payment'] as List).isNotEmpty) {
        _reject('gas payment is not the sponsor address balance');
      }
      return PreparedSponsorTransaction(
        digest: payload['digest'] as String,
        txBytes: base64Decode(payload['txBytes'] as String),
        gasOwner: gasData['owner'] as String,
        gasPrice: BigInt.parse(gasData['price'] as String),
        gasBudget: BigInt.parse(gasData['budget'] as String),
        userCap: SponsorObjectRef(
          objectId: userCap['objectId'] as String,
          version: BigInt.parse(userCap['version'] as String),
          digest: userCap['digest'] as String,
        ),
        registry: SponsorSharedObjectRef(
          objectId: registry['objectId'] as String,
          initialSharedVersion: BigInt.parse(
            registry['initialSharedVersion'] as String,
          ),
        ),
        clock: SponsorSharedObjectRef(
          objectId: clock['objectId'] as String,
          initialSharedVersion: BigInt.parse(
            clock['initialSharedVersion'] as String,
          ),
        ),
      );
    } on SponsorAttestationException {
      rethrow;
    } catch (error) {
      throw SponsorAttestationException(
        code: 'verification_failed',
        userMessage:
            'The submission prepared by your organisation could not be read, so it was not signed.',
        rawMessage: 'Malformed /sponsor/prepare response: $error',
      );
    }
  }

  Future<Map<String, dynamic>> _send({
    required String domain,
    required String path,
    Map<String, Object?>? body,
  }) async {
    final backendConfig = await AppUtils.resolveOtpBackendConfig(
      domain: domain,
    );
    final uri = AppUtils.otpBackendUri(backendConfig.url, path);
    final headers = {
      'Content-Type': 'application/json; charset=utf-8',
      AppUtils.appApiKeyHeader: backendConfig.apiKey,
    };
    final response = body == null
        ? await _httpClient.get(uri, headers: headers)
        : await _httpClient.post(uri, headers: headers, body: jsonEncode(body));

    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(response.body);
      payload = decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      payload = const {};
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = (payload['error'] as String? ?? '').trim();
      throw SponsorAttestationException(
        statusCode: response.statusCode,
        code: code.isEmpty ? 'http_${response.statusCode}' : code,
        userMessage: _userMessageFor(response.statusCode, code),
        rawMessage: payload['message'] as String?,
      );
    }
    return payload;
  }

  // Plain-language copy for field crews - no chain jargon.
  static String _userMessageFor(int statusCode, String code) {
    switch (code) {
      case 'quota_exceeded':
        return "You've reached today's submission limit. This capture is saved and will be submitted automatically later.";
      case 'rate_limit_exceeded':
        return 'Too many submissions at once. This capture is saved and will be retried shortly.';
      case 'user_not_active':
        return 'This account is no longer active, so the capture could not be submitted.';
      case 'simulation_failed':
        return 'This capture could not be verified with its current details.';
      case 'invalid_user_signature':
      case 'invalid_request':
        return 'The capture submission was rejected.';
      case 'sponsor_disabled':
      case 'sponsor_unavailable':
        return "Your organisation's network fee cover is unavailable right now. This capture is saved and will be submitted automatically.";
      case 'prepared_tx_not_found':
        return 'The submission expired before it was sent. It will be retried automatically.';
    }
    if (statusCode >= 500) {
      return 'The verification service is unavailable. This capture is saved and will be retried automatically.';
    }
    return 'The capture submission failed.';
  }
}
