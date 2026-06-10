import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:on_chain/on_chain.dart';

import '../constants/app_constants.dart';
import '../state/granite_lake_models.dart';
import '../utils/utils.dart';
import 'sui_http_service.dart';

class PhotoAttestationClaimInput {
  const PhotoAttestationClaimInput({
    required this.domain,
    required this.userId,
    required this.otp,
  });

  final String domain;
  final String userId;
  final String otp;
}

class PhotoAttestationOtpRequestResult {
  const PhotoAttestationOtpRequestResult({
    required this.userId,
    required this.domain,
    required this.userEmail,
    required this.expiresAt,
  });

  final String userId;
  final String domain;
  final String userEmail;
  final DateTime expiresAt;
}

class PhotoAttestationSubmissionResult {
  const PhotoAttestationSubmissionResult({
    required this.transactionDigest,
    required this.status,
    this.verification,
  });

  final String transactionDigest;
  final String status;
  final PhotoAttestationVerificationResult? verification;
}

class PhotoAttestationException implements Exception {
  const PhotoAttestationException({
    required this.userMessage,
    required this.rawMessage,
    this.abortCode,
  });

  final String userMessage;
  final String rawMessage;
  final int? abortCode;

  static PhotoAttestationException fromError(
    Object error, {
    required String operation,
  }) {
    if (error is PhotoAttestationException) {
      return error;
    }

    final networkMessage = _networkErrorMessage(error, operation: operation);
    if (networkMessage != null) {
      return PhotoAttestationException(
        userMessage: networkMessage,
        rawMessage: '$error',
      );
    }

    final rawMessage = _normalizeRawMessage('$error');
    final abortCode = _extractAbortCode(rawMessage);
    final userMessage = _translateMessage(
      rawMessage,
      operation: operation,
      abortCode: abortCode,
    );
    return PhotoAttestationException(
      userMessage: userMessage,
      rawMessage: rawMessage,
      abortCode: abortCode,
    );
  }

  static String _normalizeRawMessage(String raw) {
    return raw
        .replaceFirst(RegExp(r'^Bad state:\s*'), '')
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .trim();
  }

  static int? _extractAbortCode(String raw) {
    final patterns = <RegExp>[
      RegExp(r'abort code[:=]\s*(\d+)', caseSensitive: false),
      RegExp(r'code[:=]\s*(\d+)', caseSensitive: false),
      RegExp(r'MoveAbort\([^)]*,\s*(\d+)\)'),
      RegExp(r'Abort\([^)]*,\s*(\d+)\)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(raw);
      if (match != null) {
        return int.tryParse(match.group(1)!);
      }
    }
    return null;
  }

  static String? _networkErrorMessage(
    Object error, {
    required String operation,
  }) {
    if (error is! http.ClientException &&
        error is! SocketException &&
        error is! TimeoutException &&
        error is! HandshakeException) {
      return null;
    }

    if (operation == 'claim') {
      return 'Could not reach the OTP backend. Tried: ${AppUtils.otpBackendTargetsSummary}. Check that the API is running and build with --dart-define=GL_OTP_BACKEND_URL=<reachable_url> when needed.';
    }

    return 'Network access failed. Check your connection and try again.';
  }

  static String _translateMessage(
    String raw, {
    required String operation,
    required int? abortCode,
  }) {
    final lower = raw.toLowerCase();

    if (lower.contains('no sui gas coins are available')) {
      return 'This wallet does not have any SUI gas coins yet. Fund it from the Sui testnet faucet and try again.';
    }
    if (lower.contains('insufficient sui balance')) {
      return 'This wallet does not have enough SUI to pay gas on testnet. Add more testnet SUI and try again.';
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return 'The Sui request timed out. Check your network connection and try again.';
    }
    if (lower.contains('registry object') && lower.contains('not found')) {
      return 'The configured contract registry was not found on-chain. This app build may be pointing at an outdated contract.';
    }
    if (lower.contains('owned object') && lower.contains('not found')) {
      return 'Your claimed UserCap could not be found on-chain. Try claiming the user again.';
    }
    if (lower.contains('usercap object was not found')) {
      return 'The claim transaction completed, but the UserCap object could not be located afterward. Please try claiming again.';
    }
    if (lower.contains('movelocation') &&
        lower.contains('photo_attestation') &&
        (lower.contains('function: 6') ||
            lower.contains('attest_photo') ||
            lower.contains('function_name: some("attest_photo")'))) {
      return 'The photo attestation contract rejected this request while validating your on-chain authorization. This usually means the claimed UserCap, linked wallet, or user status no longer matches the contract state.';
    }

    final contractMessage = _contractAbortMessage(
      abortCode,
      operation: operation,
    );
    if (contractMessage != null) {
      return contractMessage;
    }

    final summarizedRaw = _summarizeRawMessage(raw);
    if (summarizedRaw.isNotEmpty) {
      if (operation == 'claim') {
        return 'The wallet registration step failed: $summarizedRaw';
      }
      if (lower.contains('abort') || lower.contains('moveabort')) {
        return 'The contract rejected this photo attestation: $summarizedRaw';
      }
      return 'The photo attestation failed on-chain: $summarizedRaw';
    }

    return operation == 'claim'
        ? 'The wallet registration step did not complete. Please check the claim inputs and try again.'
        : 'The photo attestation transaction did not complete on-chain. Please try again.';
  }

  static String _summarizeRawMessage(String raw) {
    var summarized = raw
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'command \d+', caseSensitive: false), 'command')
        .replaceAll(
          RegExp(r'vmverificationormeteringerror', caseSensitive: false),
          'verification or metering error',
        )
        .trim();
    summarized = summarized.replaceFirst(
      RegExp(r'^moveabort[:\s-]*', caseSensitive: false),
      '',
    );
    summarized = summarized.replaceFirst(
      RegExp(r'^abort[:\s-]*', caseSensitive: false),
      '',
    );
    if (summarized.length > 180) {
      summarized = '${summarized.substring(0, 177)}...';
    }
    return summarized;
  }

  static String? _contractAbortMessage(
    int? abortCode, {
    required String operation,
  }) {
    if (abortCode == null) {
      return null;
    }

    if (operation == 'claim') {
      return switch (abortCode) {
        2 =>
          'The company domain was not found in the registry. Check the domain and try again.',
        5 => 'This user id was not found under the selected company domain.',
        6 => 'The OTP is invalid. Check the code and try again.',
        7 => 'This OTP has already been used. Request a new OTP.',
        9 =>
          'This user has been disabled for attestation. Contact your administrator.',
        10 =>
          'This wallet does not match the wallet already associated with this user.',
        _ => null,
      };
    }

    return switch (abortCode) {
      2 =>
        'The company domain was not found on-chain. The contract registry may have changed.',
      5 => 'This user record was not found on-chain for the selected domain.',
      8 =>
        'This wallet is not authorized to attest for this user. Claim the correct UserCap first.',
      9 =>
        'This user has been disabled for photo attestation. Contact your administrator.',
      10 =>
        'This wallet no longer matches the wallet that claimed this UserCap.',
      _ => null,
    };
  }

  @override
  String toString() => userMessage;
}

class PhotoAttestationVerificationResult {
  const PhotoAttestationVerificationResult({
    required this.transactionDigest,
    required this.transactionStatus,
    required this.photoHashMatches,
    required this.senderMatches,
    required this.gpsMatches,
    required this.altitudeMatches,
    required this.projectIdMatches,
    required this.timestampWithinTolerance,
    this.chainTimestamp,
    this.failureReason,
  });

  final String transactionDigest;
  final String transactionStatus;
  final bool photoHashMatches;
  final bool senderMatches;
  final bool gpsMatches;
  final bool altitudeMatches;
  final bool projectIdMatches;
  final bool timestampWithinTolerance;
  final DateTime? chainTimestamp;
  final String? failureReason;

  bool get isVerified =>
      photoHashMatches &&
      senderMatches &&
      gpsMatches &&
      altitudeMatches &&
      projectIdMatches &&
      timestampWithinTolerance &&
      failureReason == null;
}

class PhotoAttestationService {
  PhotoAttestationService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  Future<BigInt> getWalletSuiBalanceMist({
    required PhotoAttestationContractConfig config,
    required String walletAddress,
  }) async {
    final provider = _provider(config.rpcUrl);
    final response = await provider.request(
      SuiRequestGetCoins(
        owner: SuiAddress(walletAddress),
        coinType: SuiTransactionConst.suiTypeArgs,
      ),
    );

    BigInt total = BigInt.zero;
    for (final coin in response.data) {
      total += coin.balance;
    }
    return total;
  }

  Future<PhotoAttestationOtpRequestResult> requestUserOtp({
    required String domain,
    required String userEmail,
  }) async {
    try {
      final baseUrl = await AppUtils.resolveOtpBackendBaseUrl();
      final uri = Uri.parse(baseUrl).resolve('/otp/request');
      final response = await _httpClient.post(
        uri,
        headers: const {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'domain': domain, 'user_email': userEmail}),
      );
      final payload = _decodeJsonPayload(response.body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message =
            (payload['message'] as String?)?.trim().isNotEmpty == true
            ? (payload['message'] as String).trim()
            : 'OTP request failed.';
        throw PhotoAttestationException(
          userMessage: message,
          rawMessage: message,
        );
      }

      final userId = (payload['userId'] as String? ?? '').trim();
      final expiresAt = (payload['expiresAt'] as String? ?? '').trim();
      if (userId.isEmpty || expiresAt.isEmpty) {
        throw const FormatException(
          'OTP request response is missing userId or expiresAt.',
        );
      }

      return PhotoAttestationOtpRequestResult(
        userId: userId,
        domain: (payload['domain'] as String? ?? domain).trim(),
        userEmail: (payload['userEmail'] as String? ?? userEmail).trim(),
        expiresAt: DateTime.parse(expiresAt).toUtc(),
      );
    } catch (error) {
      throw PhotoAttestationException.fromError(error, operation: 'claim');
    }
  }

  Future<PhotoAttestationClaimRecord> claimUserWithOtp({
    required IdentityRecord identity,
    required PhotoAttestationContractConfig config,
    required PhotoAttestationClaimInput input,
  }) async {
    try {
      final baseUrl = await AppUtils.resolveOtpBackendBaseUrl();
      final uri = Uri.parse(baseUrl).resolve('/otp/verify');
      final response = await _httpClient.post(
        uri,
        headers: const {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({
          'userId': input.userId,
          'otp': input.otp,
          'domain': input.domain,
          'userWallet': identity.walletAddress,
        }),
      );
      final payload = _decodeJsonPayload(response.body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message =
            (payload['message'] as String?)?.trim().isNotEmpty == true
            ? (payload['message'] as String).trim()
            : 'OTP verification failed.';
        throw PhotoAttestationException(
          userMessage: message,
          rawMessage: message,
        );
      }

      final status = (payload['status'] as String? ?? '').trim().toLowerCase();
      if (status.isNotEmpty && status != 'completed') {
        throw PhotoAttestationException(
          userMessage:
              'OTP verification is not complete yet. Current backend status: $status.',
          rawMessage: 'Unexpected backend OTP verification status: $status',
        );
      }

      final backendUserCapObjectId = _readStringPayloadField(payload, const [
        'userCapId',
        'user_cap_id',
        'userCapObjectId',
        'user_cap_object_id',
        'objectId',
        'object_id',
      ]);
      final claimTxDigest = _readStringPayloadField(payload, const [
        'txDigest',
        'tx_digest',
        'claimTxDigest',
        'claim_tx_digest',
        'digest',
      ]);
      final userCapObjectId = await _resolveOwnedUserCapObjectId(
        config: config,
        walletAddress: identity.walletAddress,
        preferredObjectId: backendUserCapObjectId,
        claimTxDigest: claimTxDigest,
      );

      return PhotoAttestationClaimRecord(
        domain: input.domain,
        userId: input.userId,
        userCapObjectId: userCapObjectId,
        claimTxDigest: claimTxDigest,
        claimedAt: DateTime.now().toUtc(),
      );
    } catch (error) {
      throw PhotoAttestationException.fromError(error, operation: 'claim');
    }
  }

  Future<PhotoAttestationSubmissionResult> attestPhoto({
    required IdentityRecord identity,
    required SuiED25519PrivateKey signingKey,
    required PhotoAttestationContractConfig config,
    required PhotoAttestationClaimRecord claim,
    required String imageSha256,
    required String gps,
    required String altitude,
    required String projectId,
  }) async {
    try {
      final provider = _provider(config.rpcUrl);
      final owner = SuiAddress(identity.walletAddress);
      final userCap = await _loadOwnedObject(provider, claim.userCapObjectId);
      final registry = await _loadRegistryObjectArg(
        provider,
        config.registryId,
      );

      var tx = SuiTransactionDataV1(
        expiration: const SuiTransactionExpirationNone(),
        sender: owner,
        gasData: SuiGasData(
          payment: const [],
          owner: owner,
          price: await provider.request(const SuiRequestGetReferenceGasPrice()),
          budget: BigInt.from(50000000),
        ),
        kind: SuiTransactionKindProgrammableTransaction(
          SuiProgrammableTransaction(
            inputs: [
              SuiCallArgObject(
                SuiObjectArgImmOrOwnedObject(userCap.data!.toObjectRef()),
              ),
              SuiCallArgObject(registry),
              SuiCallArgPure.bytes(utf8.encode(imageSha256)),
              SuiCallArgPure.bytes(utf8.encode(gps)),
              SuiCallArgPure.bytes(utf8.encode(altitude)),
              SuiCallArgPure.bytes(utf8.encode(projectId)),
            ],
            commands: [
              SuiCommandMoveCall(
                SuiProgrammableMoveCall(
                  package: SuiAddress(config.packageId),
                  module: config.moduleName,
                  function: 'attest_photo',
                  arguments: [
                    SuiArgumentInput(0),
                    SuiArgumentInput(1),
                    SuiArgumentInput(2),
                    SuiArgumentInput(3),
                    SuiArgumentInput(4),
                    SuiArgumentInput(5),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      tx = await _prepareTransaction(provider, tx);
      final response = await _execute(provider, tx, signingKey);
      return PhotoAttestationSubmissionResult(
        transactionDigest: response.digest,
        status:
            response.effects?.status.status.name.toUpperCase() ?? 'SUBMITTED',
        verification: _buildImmediateVerificationResult(
          response: response,
          config: config,
          walletAddress: identity.walletAddress,
          imageSha256: imageSha256,
          gps: gps,
          altitude: altitude,
          projectId: projectId,
        ),
      );
    } catch (error) {
      throw PhotoAttestationException.fromError(error, operation: 'attest');
    }
  }

  Future<PhotoAttestationVerificationResult> verifyPhotoAttestation({
    required PhotoAttestationContractConfig config,
    required CaptureRecord capture,
  }) async {
    final digest = capture.suiTxDigest.trim();
    if (digest.isEmpty) {
      throw StateError('Capture does not have a Sui transaction digest yet.');
    }

    final provider = _provider(config.rpcUrl);
    final response = await provider.request(
      SuiRequestGetTransactionBlock(
        transactionDigest: digest,
        options: const SuiApiTransactionBlockResponseOptions(
          showEvents: true,
          showEffects: true,
          showInput: true,
        ),
      ),
    );

    final transactionStatus =
        response.effects?.status.status.name.toUpperCase() ?? 'UNKNOWN';
    if (response.effects?.status.status != SuiApiExecutionStatusType.success) {
      return PhotoAttestationVerificationResult(
        transactionDigest: digest,
        transactionStatus: transactionStatus,
        photoHashMatches: false,
        senderMatches: false,
        gpsMatches: false,
        altitudeMatches: false,
        projectIdMatches: false,
        timestampWithinTolerance: false,
        failureReason:
            response.effects?.status.error ??
            response.errors?.join('\n') ??
            'On-chain transaction failed.',
      );
    }

    final event = _findPhotoAttestedEvent(response.events, config);
    if (event == null) {
      return PhotoAttestationVerificationResult(
        transactionDigest: digest,
        transactionStatus: transactionStatus,
        photoHashMatches: false,
        senderMatches: false,
        gpsMatches: false,
        altitudeMatches: false,
        projectIdMatches: false,
        timestampWithinTolerance: false,
        failureReason: 'PhotoAttested event was not found in the transaction.',
      );
    }

    final parsedJson = event.parsedJson;
    if (parsedJson is! Map) {
      return PhotoAttestationVerificationResult(
        transactionDigest: digest,
        transactionStatus: transactionStatus,
        photoHashMatches: false,
        senderMatches: false,
        gpsMatches: false,
        altitudeMatches: false,
        projectIdMatches: false,
        timestampWithinTolerance: false,
        failureReason: 'PhotoAttested event payload could not be parsed.',
      );
    }

    final eventJson = Map<String, dynamic>.from(parsedJson);
    final photoHash = _decodeMoveBytesValue(eventJson['photo_hash']);
    final gps = _decodeMoveBytesValue(eventJson['gps']);
    final altitude = _decodeMoveBytesValue(eventJson['altitude']);
    final projectId = _decodeMoveBytesValue(eventJson['project_id']);

    final photoHashMatches = photoHash == capture.imageSha256;
    final senderMatches =
        _addressesMatch(
          response.transaction?.data.sender,
          capture.walletAddress,
        ) &&
        _addressesMatch(event.sender, capture.walletAddress);
    final gpsMatches = gps == (capture.capturedGpsLabel?.trim() ?? '');
    final altitudeMatches =
        altitude == (capture.capturedAltitudeLabel?.trim() ?? '');
    final projectIdMatches =
        projectId == (capture.attestedProjectId?.trim() ?? '');
    final chainTimestamp = _resolveChainTimestamp(response, event);
    final timestampWithinTolerance = _isTimestampWithinTolerance(
      localTimestamp: capture.effectiveSubmittedAt,
      chainTimestamp: chainTimestamp,
    );

    return PhotoAttestationVerificationResult(
      transactionDigest: digest,
      transactionStatus: transactionStatus,
      photoHashMatches: photoHashMatches,
      senderMatches: senderMatches,
      gpsMatches: gpsMatches,
      altitudeMatches: altitudeMatches,
      projectIdMatches: projectIdMatches,
      timestampWithinTolerance: timestampWithinTolerance,
      chainTimestamp: chainTimestamp,
      failureReason: _verificationFailureReason(
        photoHashMatches: photoHashMatches,
        senderMatches: senderMatches,
        gpsMatches: gpsMatches,
        altitudeMatches: altitudeMatches,
        projectIdMatches: projectIdMatches,
        timestampWithinTolerance: timestampWithinTolerance,
      ),
    );
  }

  Future<SuiApiObjectResponse> _loadOwnedObject(
    SuiProvider provider,
    String objectId,
  ) async {
    final response = await provider.request(
      SuiRequestGetObject(
        objectId: objectId,
        options: const SuiApiObjectDataOptions(showOwner: true),
      ),
    );
    if (response.data == null) {
      throw StateError('Owned object $objectId was not found on-chain.');
    }
    return response;
  }

  Future<SuiObjectArg> _loadRegistryObjectArg(
    SuiProvider provider,
    String registryId,
  ) async {
    final normalizedRegistryId = registryId.trim();
    if (normalizedRegistryId.isEmpty) {
      throw StateError('Contract registry id is missing.');
    }

    final response = await provider.request(
      SuiRequestGetObject(
        objectId: normalizedRegistryId,
        options: const SuiApiObjectDataOptions(showOwner: true),
      ),
    );
    final data = response.data;
    if (data == null) {
      throw StateError(
        'Configured registry object $normalizedRegistryId was not found on-chain.',
      );
    }

    final owner = data.owner;
    if (owner is SuiApiObjectOwnerShared) {
      return SuiObjectArgSharedObject(
        id: data.objectId,
        initialSharedVersion: owner.shared.initialSharedVersion,
        mutable: false,
      );
    }

    return SuiObjectArgImmOrOwnedObject(data.toObjectRef());
  }

  Future<String> _resolveOwnedUserCapObjectId({
    required PhotoAttestationContractConfig config,
    required String walletAddress,
    required String preferredObjectId,
    required String claimTxDigest,
  }) async {
    final provider = _provider(config.rpcUrl);
    final expectedType = '${config.packageId}::${config.moduleName}::UserCap';
    final normalizedPreferredObjectId = preferredObjectId.trim();

    if (normalizedPreferredObjectId.isNotEmpty) {
      final preferred = await _loadUserCapFromObjectId(
        provider,
        objectId: normalizedPreferredObjectId,
        expectedType: expectedType,
      );
      if (preferred != null) {
        return preferred.objectId.address;
      }
    }

    var ownedCaps = const <SuiApiObjectData>[];
    for (var attempt = 0; attempt < 5; attempt++) {
      final response = await provider.request(
        SuiRequestGetOwnedObjects(
          address: SuiAddress(walletAddress),
          query: SuiApiObjectResponseQuery(
            filter: SuiApiObjectDataFilterStructType(expectedType),
            options: const SuiApiObjectDataOptions(
              showType: true,
              showPreviousTransaction: true,
              showOwner: true,
            ),
          ),
        ),
      );

      ownedCaps = response.data
          .map((item) => item.data)
          .whereType<SuiApiObjectData>()
          .where(
            (item) => item.type?.toLowerCase() == expectedType.toLowerCase(),
          )
          .toList(growable: false);

      if (ownedCaps.isNotEmpty) {
        break;
      }
      if (attempt < 4) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      }
    }

    if (ownedCaps.isEmpty) {
      if (normalizedPreferredObjectId.isNotEmpty) {
        return normalizedPreferredObjectId;
      }
      throw const PhotoAttestationException(
        userMessage:
            'OTP verification succeeded, but UserCap indexing is still pending. Please try again in a moment.',
        rawMessage:
            'No owned UserCap objects found for wallet after OTP verify (after retries).',
      );
    }

    if (claimTxDigest.isNotEmpty) {
      for (final cap in ownedCaps) {
        if ((cap.previousTransaction ?? '').trim().toLowerCase() ==
            claimTxDigest.toLowerCase()) {
          return cap.objectId.address;
        }
      }
    }

    if (normalizedPreferredObjectId.isNotEmpty) {
      for (final cap in ownedCaps) {
        if (cap.objectId.address.toLowerCase() ==
            normalizedPreferredObjectId.toLowerCase()) {
          return cap.objectId.address;
        }
      }
    }

    final newestCap = ownedCaps.reduce(
      (left, right) => left.version >= right.version ? left : right,
    );
    return newestCap.objectId.address;
  }

  Future<SuiApiObjectData?> _loadUserCapFromObjectId(
    SuiProvider provider, {
    required String objectId,
    required String expectedType,
  }) async {
    try {
      final response = await provider.request(
        SuiRequestGetObject(
          objectId: objectId,
          options: const SuiApiObjectDataOptions(
            showType: true,
            showOwner: true,
            showPreviousTransaction: true,
          ),
        ),
      );

      final data = response.data;
      if (data == null) {
        return null;
      }
      if ((data.type ?? '').toLowerCase() != expectedType.toLowerCase()) {
        return null;
      }

      // Accept the backend-provided UserCap once it resolves and matches type.
      // Ownership visibility can lag or serialize differently across RPC responses.
      return data;
    } catch (_) {
      return null;
    }
  }

  String _readStringPayloadField(
    Map<String, dynamic> payload,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = payload[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    final nested = payload['data'];
    if (nested is Map) {
      final nestedMap = Map<String, dynamic>.from(nested);
      for (final key in keys) {
        final value = nestedMap[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }

    return '';
  }

  Future<SuiTransactionDataV1> _prepareTransaction(
    SuiProvider provider,
    SuiTransactionDataV1 tx,
  ) async {
    final dryRunReady = await _dryRun(provider, tx);
    return _fillGasPayment(provider, dryRunReady);
  }

  Future<SuiTransactionDataV1> _dryRun(
    SuiProvider provider,
    SuiTransactionDataV1 tx,
  ) async {
    final response = await provider.request(
      SuiRequestDryRunTransactionBlock(txBytes: tx.toVariantBcsBase64()),
    );
    if (response.effects.status.status != SuiApiExecutionStatusType.success) {
      throw StateError(
        response.effects.status.error ?? 'Dry run failed for Sui transaction.',
      );
    }

    final safeOverhead = BigInt.from(1000) * tx.gasData.price;
    final baseOverhead =
        response.effects.gasUsed.computationCost + safeOverhead;
    var gasBudget =
        baseOverhead +
        response.effects.gasUsed.storageCost -
        response.effects.gasUsed.storageRebate;
    if (gasBudget < baseOverhead) {
      gasBudget = baseOverhead;
    }

    return tx.copyWith(gasData: tx.gasData.copyWith(budget: gasBudget));
  }

  Future<SuiTransactionDataV1> _fillGasPayment(
    SuiProvider provider,
    SuiTransactionDataV1 tx,
  ) async {
    final coinResponse = await provider.request(
      SuiRequestGetCoins(
        owner: tx.gasData.owner,
        coinType: SuiTransactionConst.suiTypeArgs,
      ),
    );
    final coins = coinResponse.data;
    final kind = tx.kind.cast<SuiTransactionKindProgrammableTransaction>();
    final usedObjectIds = kind.transaction.inputs
        .whereType<SuiCallArgObject>()
        .map((arg) => arg.object)
        .whereType<SuiObjectArgImmOrOwnedObject>()
        .map((arg) => arg.immOrOwnedObject.address.address)
        .toSet();

    final gasCoins = coins
        .where((coin) => !usedObjectIds.contains(coin.coinObjectId.address))
        .toList(growable: false);
    if (gasCoins.isEmpty) {
      throw StateError('No SUI gas coins are available for this wallet.');
    }

    BigInt total = BigInt.zero;
    final payment = <SuiObjectRef>[];
    for (final coin in gasCoins) {
      payment.add(coin.toObjectRef());
      total += coin.balance;
      if (total >= tx.gasData.budget) {
        break;
      }
    }

    if (total < tx.gasData.budget) {
      throw StateError('Insufficient SUI balance to pay gas on testnet.');
    }

    return tx.copyWith(gasData: tx.gasData.copyWith(payment: payment));
  }

  Future<SuiApiTransactionBlockResponse> _execute(
    SuiProvider provider,
    SuiTransactionDataV1 tx,
    SuiED25519PrivateKey privateKey,
  ) async {
    final account = SuiEd25519Account(privateKey);
    final signature = account.signTransaction(tx.serializeSign());
    final response = await provider.request(
      SuiRequestExecuteTransactionBlock(
        txBytes: tx.toVariantBcsBase64(),
        signatures: [signature.toVariantBcsBase64()],
        options: const SuiApiTransactionBlockResponseOptions(
          showEffects: true,
          showEvents: true,
          showInput: true,
          showObjectChanges: true,
        ),
      ),
    );
    if (response.effects?.status.status != SuiApiExecutionStatusType.success) {
      throw StateError(
        response.effects?.status.error ??
            response.errors?.join('\n') ??
            'Sui transaction failed.',
      );
    }
    return response;
  }

  PhotoAttestationVerificationResult? _buildImmediateVerificationResult({
    required SuiApiTransactionBlockResponse response,
    required PhotoAttestationContractConfig config,
    required String walletAddress,
    required String imageSha256,
    required String gps,
    required String altitude,
    required String projectId,
  }) {
    final event = _findPhotoAttestedEvent(response.events, config);
    if (event == null) {
      return null;
    }

    final parsedJson = event.parsedJson;
    if (parsedJson is! Map) {
      return null;
    }

    final eventJson = Map<String, dynamic>.from(parsedJson);
    final photoHash = _decodeMoveBytesValue(eventJson['photo_hash']);
    final eventGps = _decodeMoveBytesValue(eventJson['gps']);
    final eventAltitude = _decodeMoveBytesValue(eventJson['altitude']);
    final eventProjectId = _decodeMoveBytesValue(eventJson['project_id']);
    final chainTimestamp = _resolveChainTimestamp(response, event);

    final photoHashMatches = photoHash == imageSha256;
    final senderMatches =
        _addressesMatch(response.transaction?.data.sender, walletAddress) &&
        _addressesMatch(event.sender, walletAddress);
    final gpsMatches = eventGps == gps;
    final altitudeMatches = eventAltitude == altitude;
    final projectIdMatches = eventProjectId == projectId;

    return PhotoAttestationVerificationResult(
      transactionDigest: response.digest,
      transactionStatus:
          response.effects?.status.status.name.toUpperCase() ?? 'SUBMITTED',
      photoHashMatches: photoHashMatches,
      senderMatches: senderMatches,
      gpsMatches: gpsMatches,
      altitudeMatches: altitudeMatches,
      projectIdMatches: projectIdMatches,
      timestampWithinTolerance: true,
      chainTimestamp: chainTimestamp,
      failureReason: _verificationFailureReason(
        photoHashMatches: photoHashMatches,
        senderMatches: senderMatches,
        gpsMatches: gpsMatches,
        altitudeMatches: altitudeMatches,
        projectIdMatches: projectIdMatches,
        timestampWithinTolerance: true,
      ),
    );
  }

  SuiProvider _provider(String rpcUrl) {
    return SuiProvider(SuiHttpService(rpcUrl));
  }

  SuiApiEvent? _findPhotoAttestedEvent(
    List<SuiApiEvent>? events,
    PhotoAttestationContractConfig config,
  ) {
    final expectedType =
        '${config.packageId}::${config.moduleName}::PhotoAttested'
            .toLowerCase();
    for (final event in events ?? const <SuiApiEvent>[]) {
      if (event.type.toLowerCase() == expectedType) {
        return event;
      }
    }
    return null;
  }

  String _decodeMoveBytesValue(Object? value) {
    if (value is String) {
      return value.trim();
    }
    if (value is List) {
      final bytes = value.whereType<num>().map((item) => item.toInt()).toList();
      return utf8.decode(bytes).trim();
    }
    return '';
  }

  Map<String, dynamic> _decodeJsonPayload(String rawBody) {
    if (rawBody.trim().isEmpty) {
      return const <String, dynamic>{};
    }

    final decoded = jsonDecode(rawBody);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('Backend response body was not a JSON object.');
  }

  bool _addressesMatch(String? left, String? right) {
    if (left == null || right == null) {
      return false;
    }
    return left.trim().toLowerCase() == right.trim().toLowerCase();
  }

  DateTime? _resolveChainTimestamp(
    SuiApiTransactionBlockResponse response,
    SuiApiEvent event,
  ) {
    final timestampMs = response.timestampMs ?? event.timestampMs;
    if (timestampMs == null || timestampMs.trim().isEmpty) {
      return null;
    }

    final milliseconds = int.tryParse(timestampMs.trim());
    if (milliseconds == null) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  bool _isTimestampWithinTolerance({
    required DateTime localTimestamp,
    required DateTime? chainTimestamp,
  }) {
    if (chainTimestamp == null) {
      return false;
    }

    final difference = chainTimestamp.difference(localTimestamp).abs();
    return difference <=
        Duration(minutes: AppConstants.maximumAttestationTimeGapMinutes);
  }

  String? _verificationFailureReason({
    required bool photoHashMatches,
    required bool senderMatches,
    required bool gpsMatches,
    required bool altitudeMatches,
    required bool projectIdMatches,
    required bool timestampWithinTolerance,
  }) {
    if (photoHashMatches &&
        senderMatches &&
        gpsMatches &&
        altitudeMatches &&
        projectIdMatches &&
        timestampWithinTolerance) {
      return null;
    }

    final failures = <String>[];
    if (!photoHashMatches) {
      failures.add('Photo hash mismatch');
    }
    if (!senderMatches) {
      failures.add('Wallet sender mismatch');
    }
    if (!gpsMatches) {
      failures.add('GPS mismatch');
    }
    if (!altitudeMatches) {
      failures.add('Altitude mismatch');
    }
    if (!projectIdMatches) {
      failures.add('Project id mismatch');
    }
    if (!timestampWithinTolerance) {
      failures.add('Submitted time and chain time differ too much');
    }
    return '${failures.join('; ')}.';
  }
}
