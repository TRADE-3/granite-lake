import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:on_chain/on_chain.dart';

import '../constants/app_constants.dart';
import '../state/granite_lake_models.dart';
import '../utils/network_error_classifier.dart';
import '../utils/utils.dart';
import 'sui_graphql_service.dart';

class _GraphQlCoin {
  const _GraphQlCoin({required this.object, required this.balance});

  final SuiGraphQlObject object;
  final BigInt balance;
}

class PhotoAttestationClaimInput {
  const PhotoAttestationClaimInput({
    required this.domain,
    required this.userId,
    required this.otp,
    required this.walletNonce,
  });

  final String domain;
  final String userId;
  final String otp;

  // Server-issued nonce this claim's wallet must sign to prove possession of
  // its private key before the backend binds it to the OTP session.
  final String walletNonce;
}

class PhotoAttestationOtpRequestResult {
  const PhotoAttestationOtpRequestResult({
    required this.userId,
    required this.domain,
    required this.userEmail,
    required this.expiresAt,
    required this.walletNonce,
  });

  final String userId;
  final String domain;
  final String userEmail;
  final DateTime expiresAt;
  final String walletNonce;
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

class FileAttestationSubmissionResult {
  const FileAttestationSubmissionResult({
    required this.transactionDigest,
    required this.status,
    this.verification,
  });

  final String transactionDigest;
  final String status;
  final FileAttestationVerificationResult? verification;
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
      return "Couldn't reach the verification server. Check your internet "
          'connection and try again. If this keeps happening, contact your '
          'administrator.';
    }

    return "Couldn't connect to the network. Check your internet connection "
        'and try again.';
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
    if (looksLikeObjectVersionRaceFailure(lower)) {
      return 'A recently-used wallet object was still updating on the network. '
          "This resolves on its own - it's queued and will retry automatically.";
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
            lower.contains('function: 7') ||
            lower.contains('attest_photo') ||
            lower.contains('attest_file') ||
            lower.contains('function_name: some("attest_photo")'))) {
      return 'The attestation contract rejected this request while validating your on-chain authorization. This usually means the claimed UserCap, linked wallet, or user status no longer matches the contract state.';
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
        return 'The contract rejected this attestation: $summarizedRaw';
      }
      return 'The attestation failed on-chain: $summarizedRaw';
    }

    return operation == 'claim'
        ? 'The wallet registration step did not complete. Please check the claim inputs and try again.'
        : 'The attestation transaction did not complete on-chain. Please try again.';
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

class FileAttestationVerificationResult {
  const FileAttestationVerificationResult({
    required this.transactionDigest,
    required this.transactionStatus,
    required this.fileHashMatches,
    required this.senderMatches,
    required this.fileIdMatches,
    required this.projectIdMatches,
    required this.timestampWithinTolerance,
    this.chainTimestamp,
    this.failureReason,
  });

  final String transactionDigest;
  final String transactionStatus;
  final bool fileHashMatches;
  final bool senderMatches;
  final bool fileIdMatches;
  final bool projectIdMatches;
  final bool timestampWithinTolerance;
  final DateTime? chainTimestamp;
  final String? failureReason;

  bool get isVerified =>
      fileHashMatches &&
      senderMatches &&
      fileIdMatches &&
      projectIdMatches &&
      timestampWithinTolerance &&
      failureReason == null;
}

class PhotoAttestationService {
  PhotoAttestationService({
    http.Client? httpClient,
    SuiGraphQlService? graphQlService,
  }) : _httpClient = httpClient ?? http.Client(),
       _graphQlService = graphQlService ?? SuiGraphQlService();

  final http.Client _httpClient;
  final SuiGraphQlService _graphQlService;

  // Well-known shared Clock object every Sui network exposes at this fixed
  // address (sui::clock::Clock, id 0x6).
  static const String _suiClockObjectId = '0x6';

  Future<BigInt> getWalletSuiBalanceMist({
    required PhotoAttestationContractConfig config,
    required String walletAddress,
  }) async {
    return _graphQlService.getSuiBalance(
      config.rpcUrl,
      ownerAddress: walletAddress,
    );
  }

  Future<PhotoAttestationOtpRequestResult> requestUserOtp({
    required String domain,
    required String userEmail,
  }) async {
    try {
      final backendConfig = await AppUtils.resolveOtpBackendConfig(
        domain: domain,
      );

      final uri = AppUtils.otpBackendUri(backendConfig.url, 'otp/request');
      final response = await _httpClient.post(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          AppUtils.appApiKeyHeader: backendConfig.apiKey,
        },
        body: jsonEncode({'domain': domain, 'user_email': userEmail}),
      );
      final payload = _decodeJsonPayload(response.body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = _readBackendMessage(payload) ?? 'OTP request failed.';
        throw PhotoAttestationException(
          userMessage: message,
          rawMessage: message,
        );
      }

      final userId = (payload['userId'] as String? ?? '').trim();
      final expiresAt = (payload['expiresAt'] as String? ?? '').trim();
      final walletNonce = (payload['walletNonce'] as String? ?? '').trim();
      if (userId.isEmpty || expiresAt.isEmpty || walletNonce.isEmpty) {
        throw const FormatException(
          'OTP request response is missing userId, expiresAt, or walletNonce.',
        );
      }

      return PhotoAttestationOtpRequestResult(
        userId: userId,
        domain: (payload['domain'] as String? ?? domain).trim(),
        userEmail: (payload['userEmail'] as String? ?? userEmail).trim(),
        expiresAt: DateTime.parse(expiresAt).toUtc(),
        walletNonce: walletNonce,
      );
    } catch (error) {
      throw PhotoAttestationException.fromError(error, operation: 'claim');
    }
  }

  Future<PhotoAttestationClaimRecord> claimUserWithOtp({
    required IdentityRecord identity,
    required SuiED25519PrivateKey signingKey,
    required PhotoAttestationContractConfig config,
    required PhotoAttestationClaimInput input,
  }) async {
    try {
      final backendConfig = await AppUtils.resolveOtpBackendConfig(
        domain: input.domain,
      );

      // Prove possession of the wallet's private key by signing the
      // server-issued nonce for this OTP session (see F-03). Without this,
      // the backend has nothing binding the claimed userWallet to whoever
      // is making the request. identity.privateKey is unavailable here:
      // biometrics are bound before registration runs (see F-09), which
      // strips the raw key from the in-memory identity, so the caller must
      // supply an unlocked session signing key instead.
      final account = SuiEd25519Account(signingKey);
      final nonceBytes = base64Decode(input.walletNonce);
      final walletSignature = account
          .signPersonalMessage(nonceBytes)
          .toVariantBcsBase64();

      final uri = AppUtils.otpBackendUri(backendConfig.url, 'otp/verify');
      final response = await _httpClient.post(
        uri,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          AppUtils.appApiKeyHeader: backendConfig.apiKey,
        },
        body: jsonEncode({
          'userId': input.userId,
          'otp': input.otp,
          'domain': input.domain,
          'userWallet': identity.walletAddress,
          'userWalletSignature': walletSignature,
        }),
      );
      final payload = _decodeJsonPayload(response.body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = _otpVerifyFailureMessage(
          payload,
          statusCode: response.statusCode,
          uri: uri,
        );
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

  /// Tells the backend that this device deleted its local account, so the
  /// server (and the on-chain enabled flag) stop listing the user as
  /// active. Best-effort by design: the caller should not block local
  /// account deletion on this succeeding, since deletion is something the
  /// user can always do to their own device regardless of connectivity.
  Future<void> deactivateUser({
    required String domain,
    required String userId,
  }) async {
    final backendConfig = await AppUtils.resolveOtpBackendConfig(
      domain: domain,
    );
    final uri = AppUtils.otpBackendUri(
      backendConfig.url,
      'otp/$userId/deactivate',
    );
    final response = await _httpClient.patch(
      uri,
      headers: {AppUtils.appApiKeyHeader: backendConfig.apiKey},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = _decodeJsonPayload(response.body);
      final message = _readBackendMessage(payload) ?? 'Deactivation failed.';
      throw PhotoAttestationException(
        userMessage: message,
        rawMessage: message,
      );
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
    required int capturedAtMs,
    required bool isOnline,
    required bool isForcedOffline,
    String? internetNullReasonHashHex,
    required bool hasGps,
    required bool isGpsForcedNull,
    String? gpsNullReasonHashHex,
  }) async {
    try {
      final owner = SuiAddress(identity.walletAddress);
      final userCap = await _loadOwnedObject(
        config.rpcUrl,
        claim.userCapObjectId,
      );
      final registry = await _loadSharedObjectArg(
        config.rpcUrl,
        config.registryId,
      );
      final clock = await _loadSharedObjectArg(
        config.rpcUrl,
        _suiClockObjectId,
      );

      var tx = SuiTransactionDataV1(
        expiration: const SuiTransactionExpirationNone(),
        sender: owner,
        gasData: SuiGasData(
          payment: const [],
          owner: owner,
          price: await _graphQlService.getReferenceGasPrice(config.rpcUrl),
          budget: BigInt.from(50000000),
        ),
        kind: SuiTransactionKindProgrammableTransaction(
          SuiProgrammableTransaction(
            inputs: [
              SuiCallArgObject(
                SuiObjectArgImmOrOwnedObject(userCap.toObjectRef()),
              ),
              SuiCallArgObject(registry),
              SuiCallArgPure.bytes(utf8.encode(imageSha256)),
              SuiCallArgPure.bytes(utf8.encode(gps)),
              SuiCallArgPure.bytes(utf8.encode(altitude)),
              SuiCallArgPure.bytes(utf8.encode(projectId)),
              SuiCallArgPure.u64(BigInt.from(capturedAtMs)),
              SuiCallArgPure.boolean(isOnline),
              SuiCallArgPure.boolean(isForcedOffline),
              SuiCallArgPure.bytes(_hexToBytes(internetNullReasonHashHex)),
              SuiCallArgPure.boolean(hasGps),
              SuiCallArgPure.boolean(isGpsForcedNull),
              SuiCallArgPure.bytes(_hexToBytes(gpsNullReasonHashHex)),
              SuiCallArgObject(clock),
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
                    SuiArgumentInput(6),
                    SuiArgumentInput(7),
                    SuiArgumentInput(8),
                    SuiArgumentInput(9),
                    SuiArgumentInput(10),
                    SuiArgumentInput(11),
                    SuiArgumentInput(12),
                    SuiArgumentInput(13),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      final response = await _prepareAndExecuteWithRetry(
        config.rpcUrl,
        tx,
        signingKey,
      );
      return PhotoAttestationSubmissionResult(
        transactionDigest: response.digest,
        status: response.status,
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
    required AttestationRecord capture,
  }) async {
    final digest = capture.suiTxDigest.trim();
    if (digest.isEmpty) {
      throw StateError('Capture does not have a Sui transaction digest yet.');
    }

    final response = await _graphQlService.getTransaction(
      config.rpcUrl,
      digest: digest,
    );

    final transactionStatus = response.status;
    if (transactionStatus != 'SUCCESS') {
      return PhotoAttestationVerificationResult(
        transactionDigest: digest,
        transactionStatus: transactionStatus,
        photoHashMatches: false,
        senderMatches: false,
        gpsMatches: false,
        altitudeMatches: false,
        projectIdMatches: false,
        timestampWithinTolerance: false,
        failureReason: response.error ?? 'On-chain transaction failed.',
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

    final eventJson = event.parsedJson;
    if (eventJson == null) {
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
    final photoHash = _decodeMoveBytesValue(eventJson['photo_hash']);
    final gps = _decodeMoveBytesValue(eventJson['gps']);
    final altitude = _decodeMoveBytesValue(eventJson['altitude']);
    final projectId = _decodeMoveBytesValue(eventJson['project_id']);

    final photoHashMatches = photoHash == capture.imageSha256;
    final senderMatches =
        (response.sender == null ||
            _addressesMatch(response.sender, capture.walletAddress)) &&
        _addressesMatch(event.sender, capture.walletAddress);
    final gpsMatches = gps == (capture.capturedGpsLabel?.trim() ?? '');
    final altitudeMatches =
        altitude == (capture.capturedAltitudeLabel?.trim() ?? '');
    final projectIdMatches =
        projectId == (capture.attestedProjectId?.trim() ?? '');
    final chainTimestamp = _resolveChainTimestamp(response, event);
    final timestampWithinTolerance = _isTimestampWithinTolerance(
      capture: capture,
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

  Future<FileAttestationSubmissionResult> attestFile({
    required IdentityRecord identity,
    required SuiED25519PrivateKey signingKey,
    required PhotoAttestationContractConfig config,
    required PhotoAttestationClaimRecord claim,
    required AttestationRecord record,
    required String projectId,
    required int capturedAtMs,
    required bool isOnline,
    required bool isForcedOffline,
    String? internetNullReasonHashHex,
  }) async {
    try {
      final owner = SuiAddress(identity.walletAddress);
      final userCap = await _loadOwnedObject(
        config.rpcUrl,
        claim.userCapObjectId,
      );
      final registry = await _loadSharedObjectArg(
        config.rpcUrl,
        config.registryId,
      );
      final clock = await _loadSharedObjectArg(
        config.rpcUrl,
        _suiClockObjectId,
      );

      var tx = SuiTransactionDataV1(
        expiration: const SuiTransactionExpirationNone(),
        sender: owner,
        gasData: SuiGasData(
          payment: const [],
          owner: owner,
          price: await _graphQlService.getReferenceGasPrice(config.rpcUrl),
          budget: BigInt.from(50000000),
        ),
        kind: SuiTransactionKindProgrammableTransaction(
          SuiProgrammableTransaction(
            inputs: [
              SuiCallArgObject(
                SuiObjectArgImmOrOwnedObject(userCap.toObjectRef()),
              ),
              SuiCallArgObject(registry),
              SuiCallArgPure.bytes(utf8.encode(record.contentSha256)),
              SuiCallArgPure.bytes(utf8.encode(record.fileId)),
              SuiCallArgPure.bytes(utf8.encode(projectId)),
              SuiCallArgPure.u64(BigInt.from(capturedAtMs)),
              SuiCallArgPure.boolean(isOnline),
              SuiCallArgPure.boolean(isForcedOffline),
              SuiCallArgPure.bytes(_hexToBytes(internetNullReasonHashHex)),
              SuiCallArgObject(clock),
            ],
            commands: [
              SuiCommandMoveCall(
                SuiProgrammableMoveCall(
                  package: SuiAddress(config.packageId),
                  module: config.moduleName,
                  function: 'attest_file',
                  arguments: [
                    SuiArgumentInput(0),
                    SuiArgumentInput(1),
                    SuiArgumentInput(2),
                    SuiArgumentInput(3),
                    SuiArgumentInput(4),
                    SuiArgumentInput(5),
                    SuiArgumentInput(6),
                    SuiArgumentInput(7),
                    SuiArgumentInput(8),
                    SuiArgumentInput(9),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      final response = await _prepareAndExecuteWithRetry(
        config.rpcUrl,
        tx,
        signingKey,
      );
      return FileAttestationSubmissionResult(
        transactionDigest: response.digest,
        status: response.status,
        verification: _buildImmediateFileVerificationResult(
          response: response,
          config: config,
          walletAddress: identity.walletAddress,
          record: record,
          projectId: projectId,
        ),
      );
    } catch (error) {
      throw PhotoAttestationException.fromError(error, operation: 'attest');
    }
  }

  Future<FileAttestationVerificationResult> verifyFileAttestation({
    required PhotoAttestationContractConfig config,
    required AttestationRecord capture,
  }) async {
    final digest = capture.suiTxDigest.trim();
    if (digest.isEmpty) {
      throw StateError('Capture does not have a Sui transaction digest yet.');
    }

    final response = await _graphQlService.getTransaction(
      config.rpcUrl,
      digest: digest,
    );

    final transactionStatus = response.status;
    if (transactionStatus != 'SUCCESS') {
      return FileAttestationVerificationResult(
        transactionDigest: digest,
        transactionStatus: transactionStatus,
        fileHashMatches: false,
        senderMatches: false,
        fileIdMatches: false,
        projectIdMatches: false,
        timestampWithinTolerance: false,
        failureReason: response.error ?? 'On-chain transaction failed.',
      );
    }

    final event = _findFileAttestedEvent(response.events, config);
    if (event == null) {
      return FileAttestationVerificationResult(
        transactionDigest: digest,
        transactionStatus: transactionStatus,
        fileHashMatches: false,
        senderMatches: false,
        fileIdMatches: false,
        projectIdMatches: false,
        timestampWithinTolerance: false,
        failureReason: 'FileAttested event was not found in the transaction.',
      );
    }

    final eventJson = event.parsedJson;
    if (eventJson == null) {
      return FileAttestationVerificationResult(
        transactionDigest: digest,
        transactionStatus: transactionStatus,
        fileHashMatches: false,
        senderMatches: false,
        fileIdMatches: false,
        projectIdMatches: false,
        timestampWithinTolerance: false,
        failureReason: 'FileAttested event payload could not be parsed.',
      );
    }
    final fileHash = _decodeMoveBytesValue(eventJson['file_hash']);
    final userWallet = _decodeMoveAddressValue(eventJson['user_wallet']);
    final fileId = _decodeMoveBytesValue(eventJson['file_id']);
    final projectId = _decodeMoveBytesValue(eventJson['project_id']);
    final chainTimestamp = _resolveChainTimestamp(response, event);

    final fileHashMatches = fileHash == capture.contentSha256;
    final senderMatches =
        (response.sender == null ||
            _addressesMatch(response.sender, capture.walletAddress)) &&
        _addressesMatch(event.sender, capture.walletAddress) &&
        _addressesMatch(userWallet, capture.walletAddress);
    final fileIdMatches = fileId == capture.fileId;
    final projectIdMatches =
        projectId == (capture.attestedProjectId?.trim() ?? '');
    final timestampWithinTolerance = _isTimestampWithinTolerance(
      capture: capture,
      chainTimestamp: chainTimestamp,
    );

    return FileAttestationVerificationResult(
      transactionDigest: digest,
      transactionStatus: transactionStatus,
      fileHashMatches: fileHashMatches,
      senderMatches: senderMatches,
      fileIdMatches: fileIdMatches,
      projectIdMatches: projectIdMatches,
      timestampWithinTolerance: timestampWithinTolerance,
      chainTimestamp: chainTimestamp,
      failureReason: _fileVerificationFailureReason(
        fileHashMatches: fileHashMatches,
        senderMatches: senderMatches,
        fileIdMatches: fileIdMatches,
        projectIdMatches: projectIdMatches,
        timestampWithinTolerance: timestampWithinTolerance,
      ),
    );
  }

  Future<SuiGraphQlObject> _loadOwnedObject(
    String graphqlUrl,
    String objectId,
  ) async {
    final response = await _graphQlService.getObject(
      graphqlUrl,
      objectId: objectId,
    );
    if (response == null) {
      throw StateError('Owned object $objectId was not found on-chain.');
    }
    return response;
  }

  /// Loads any shared object (the Registry, or the well-known Clock at
  /// [_suiClockObjectId]) as a transaction argument, resolving its current
  /// `initialSharedVersion` from chain state rather than assuming a fixed
  /// value.
  Future<SuiObjectArg> _loadSharedObjectArg(
    String graphqlUrl,
    String objectId,
  ) async {
    final normalizedObjectId = objectId.trim();
    if (normalizedObjectId.isEmpty) {
      throw StateError('Contract registry id is missing.');
    }

    final data = await _graphQlService.getObject(
      graphqlUrl,
      objectId: normalizedObjectId,
    );
    if (data == null) {
      throw StateError(
        'Configured registry object $normalizedObjectId was not found on-chain.',
      );
    }

    if (data.ownerKind == 'Shared' && data.initialSharedVersion != null) {
      return SuiObjectArgSharedObject(
        id: SuiAddress(data.objectId),
        initialSharedVersion: data.initialSharedVersion!,
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
    final expectedType = '${config.packageId}::${config.moduleName}::UserCap';
    final normalizedPreferredObjectId = preferredObjectId.trim();

    if (normalizedPreferredObjectId.isNotEmpty) {
      final preferred = await _loadUserCapFromObjectId(
        config.rpcUrl,
        objectId: normalizedPreferredObjectId,
        expectedType: expectedType,
      );
      if (preferred != null) {
        return preferred.objectId;
      }
    }

    var ownedCaps = const <SuiGraphQlObject>[];
    try {
      for (var attempt = 0; attempt < 5; attempt++) {
        ownedCaps = await _graphQlService.listOwnedObjectsByType(
          config.rpcUrl,
          ownerAddress: walletAddress,
          type: expectedType,
        );

        if (ownedCaps.isNotEmpty) {
          break;
        }
        if (attempt < 4) {
          await Future<void>.delayed(
            Duration(milliseconds: 350 * (attempt + 1)),
          );
        }
      }
    } catch (_) {
      // Fall through to the preferredObjectId fallback below.
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
          return cap.objectId;
        }
      }
    }

    if (normalizedPreferredObjectId.isNotEmpty) {
      for (final cap in ownedCaps) {
        if (cap.objectId.toLowerCase() ==
            normalizedPreferredObjectId.toLowerCase()) {
          return cap.objectId;
        }
      }
    }

    final newestCap = ownedCaps.reduce(
      (left, right) => left.version >= right.version ? left : right,
    );
    return newestCap.objectId;
  }

  Future<SuiGraphQlObject?> _loadUserCapFromObjectId(
    String graphqlUrl, {
    required String objectId,
    required String expectedType,
  }) async {
    try {
      final data = await _graphQlService.getObject(
        graphqlUrl,
        objectId: objectId,
      );
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
    String graphqlUrl,
    SuiTransactionDataV1 tx,
  ) async {
    BigInt availableBalance = BigInt.zero;
    if (tx.gasData.payment.isEmpty) {
      availableBalance = await _graphQlService.getSuiBalance(
        graphqlUrl,
        ownerAddress: tx.gasData.owner.address,
      );
      // Always cap the budget to available balance before dryRun.
      // This ensures dryRun doesn't calculate a budget higher than we can pay.
      if (availableBalance > BigInt.zero &&
          availableBalance < tx.gasData.budget) {
        tx = tx.copyWith(
          gasData: tx.gasData.copyWith(budget: availableBalance),
        );
      }
    }

    final dryRunReady = await _dryRun(graphqlUrl, tx);
    return _fillGasPayment(graphqlUrl, dryRunReady);
  }

  Future<SuiTransactionDataV1> _dryRun(
    String graphqlUrl,
    SuiTransactionDataV1 tx,
  ) async {
    final response = await _graphQlService.simulateTransaction(
      graphqlUrl,
      transactionDataBcs: tx.toVariantBcsBase64(),
    );
    if (response.status != 'SUCCESS') {
      throw StateError(response.error ?? 'Dry run failed for Sui transaction.');
    }
    final gasSummary = response.gasSummary;
    if (gasSummary == null) {
      throw StateError('Dry run completed without a gas summary.');
    }

    final safeOverhead = BigInt.from(1000) * tx.gasData.price;
    final baseOverhead = gasSummary.computationCost + safeOverhead;
    var gasBudget =
        baseOverhead + gasSummary.storageCost - gasSummary.storageRebate;
    if (gasBudget < baseOverhead) {
      gasBudget = baseOverhead;
    }

    return tx.copyWith(gasData: tx.gasData.copyWith(budget: gasBudget));
  }

  Future<SuiTransactionDataV1> _fillGasPayment(
    String graphqlUrl,
    SuiTransactionDataV1 tx,
  ) async {
    final ownedCoins = await _graphQlService.listOwnedObjectsByType(
      graphqlUrl,
      ownerAddress: tx.gasData.owner.address,
      type: '0x2::coin::Coin<${SuiTransactionConst.suiTypeArgs}>',
    );

    // Also get the total balance - the sum of individual coins might be less
    // than totalBalance if some coins are pending/locked.
    final totalBalance = await _graphQlService.getSuiBalance(
      graphqlUrl,
      ownerAddress: tx.gasData.owner.address,
    );

    final kind = tx.kind.cast<SuiTransactionKindProgrammableTransaction>();
    final usedObjectIds = kind.transaction.inputs
        .whereType<SuiCallArgObject>()
        .map((arg) => arg.object)
        .whereType<SuiObjectArgImmOrOwnedObject>()
        .map((arg) => arg.immOrOwnedObject.address.address)
        .toSet();

    final gasCoins = ownedCoins
        .map(
          (object) =>
              _GraphQlCoin(object: object, balance: _coinBalance(object)),
        )
        .where((coin) => !usedObjectIds.contains(coin.object.objectId))
        .toList(growable: false);

    if (gasCoins.isEmpty) {
      throw StateError('No SUI gas coins are available for this wallet.');
    }

    // Use totalBalance as the ceiling since some coins might be locked/pending.
    final confirmedBalance = _sumCoinBalances(gasCoins);
    final availableForGas = totalBalance < confirmedBalance
        ? totalBalance
        : confirmedBalance;

    if (availableForGas < tx.gasData.budget) {
      // If we have total balance that would cover it (just pending), proceed anyway.
      // The actual execution will use whatever is available at that time.
      if (totalBalance >= tx.gasData.budget) {
        // Proceed with confirmed coins - some are pending but should be available soon
      } else {
        throw StateError(
          'Insufficient SUI balance to pay gas. Required '
          '${tx.gasData.budget} MIST but only found $confirmedBalance MIST.',
        );
      }
    }

    // Collect coins to cover the budget, preferring larger coins first.
    gasCoins.sort((a, b) => b.balance.compareTo(a.balance));

    BigInt total = BigInt.zero;
    final payment = <SuiObjectRef>[];
    for (final coin in gasCoins) {
      payment.add(coin.object.toObjectRef());
      total += coin.balance;
      if (total >= tx.gasData.budget) {
        break;
      }
    }

    return tx.copyWith(gasData: tx.gasData.copyWith(payment: payment));
  }

  BigInt _sumCoinBalances(List<_GraphQlCoin> coins) {
    return coins.fold<BigInt>(BigInt.zero, (sum, coin) => sum + coin.balance);
  }

  /// Prepares (dry-runs + fills gas payment) and executes [tx], retrying
  /// the whole prepare+execute cycle from scratch when the failure is a
  /// transient object-version race: `_fillGasPayment` queries the wallet's
  /// gas coins fresh via GraphQL every call, but right after a transaction
  /// executes, the indexer that query reads from can briefly lag before
  /// reflecting that coin's new version - so a transaction submitted
  /// immediately after (e.g. the next row in retryPendingAttestations'
  /// sequential sweep) can pick a coin reference that's already stale by
  /// the time it reaches consensus. Re-preparing re-queries everything
  /// fresh, which is enough once the indexer catches up - not retried for
  /// any other failure class, since those are genuine rejections.
  Future<SuiGraphQlTransactionResult> _prepareAndExecuteWithRetry(
    String graphqlUrl,
    SuiTransactionDataV1 tx,
    SuiED25519PrivateKey signingKey,
  ) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // _prepareTransaction's dry-run can itself reject a stale gas-coin
        // reference (the same race _fillGasPayment is exposed to) before
        // _execute is ever reached - both steps must be inside the retry,
        // not just the final execute call, or a version mismatch caught at
        // dry-run time would skip the retry entirely and fail on attempt 1.
        final prepared = await _prepareTransaction(graphqlUrl, tx);
        return await _execute(graphqlUrl, prepared, signingKey);
      } catch (error) {
        if (attempt == maxAttempts || !_isObjectVersionRaceError(error)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt));
      }
    }
    throw StateError('Unreachable: retry loop exited without returning.');
  }

  bool _isObjectVersionRaceError(Object error) =>
      looksLikeObjectVersionRaceFailure('$error');

  Future<SuiGraphQlTransactionResult> _execute(
    String graphqlUrl,
    SuiTransactionDataV1 tx,
    SuiED25519PrivateKey privateKey,
  ) async {
    final account = SuiEd25519Account(privateKey);
    final signature = account.signTransaction(tx.serializeSign());
    final response = await _graphQlService.executeTransaction(
      graphqlUrl,
      transactionDataBcs: tx.toVariantBcsBase64(),
      signatures: [signature.toVariantBcsBase64()],
    );
    if (response.status != 'SUCCESS') {
      throw StateError(response.error ?? 'Sui transaction failed.');
    }
    return response;
  }

  PhotoAttestationVerificationResult? _buildImmediateVerificationResult({
    required SuiGraphQlTransactionResult response,
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

    final eventJson = event.parsedJson;
    if (eventJson == null) {
      return null;
    }
    final photoHash = _decodeMoveBytesValue(eventJson['photo_hash']);
    final eventGps = _decodeMoveBytesValue(eventJson['gps']);
    final eventAltitude = _decodeMoveBytesValue(eventJson['altitude']);
    final eventProjectId = _decodeMoveBytesValue(eventJson['project_id']);
    final chainTimestamp = _resolveChainTimestamp(response, event);

    final photoHashMatches = photoHash == imageSha256;
    final senderMatches =
        (response.sender == null ||
            _addressesMatch(response.sender, walletAddress)) &&
        _addressesMatch(event.sender, walletAddress);
    final gpsMatches = eventGps == gps;
    final altitudeMatches = eventAltitude == altitude;
    final projectIdMatches = eventProjectId == projectId;

    return PhotoAttestationVerificationResult(
      transactionDigest: response.digest,
      transactionStatus: response.status,
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

  FileAttestationVerificationResult? _buildImmediateFileVerificationResult({
    required SuiGraphQlTransactionResult response,
    required PhotoAttestationContractConfig config,
    required String walletAddress,
    required AttestationRecord record,
    required String projectId,
  }) {
    final event = _findFileAttestedEvent(response.events, config);
    if (event == null) {
      return null;
    }

    final eventJson = event.parsedJson;
    if (eventJson == null) {
      return null;
    }
    final fileHash = _decodeMoveBytesValue(eventJson['file_hash']);
    final userWallet = _decodeMoveAddressValue(eventJson['user_wallet']);
    final fileId = _decodeMoveBytesValue(eventJson['file_id']);
    final eventProjectId = _decodeMoveBytesValue(eventJson['project_id']);
    final chainTimestamp = _resolveChainTimestamp(response, event);

    final fileHashMatches = fileHash == record.contentSha256;
    final senderMatches =
        (response.sender == null ||
            _addressesMatch(response.sender, walletAddress)) &&
        _addressesMatch(event.sender, walletAddress) &&
        _addressesMatch(userWallet, walletAddress);
    final fileIdMatches = fileId == record.fileId;
    final projectIdMatches = eventProjectId == projectId;
    // Always within tolerance here - this result is built immediately after
    // a transaction we just executed (whether the original attempt or a
    // later queue retry), so chainTimestamp is definitionally "now."
    // Matches _buildImmediateVerificationResult's (photo) same treatment;
    // the meaningful captured_at/attested_at check belongs to the later,
    // standalone verifyFileAttestation pass instead.
    const timestampWithinTolerance = true;

    return FileAttestationVerificationResult(
      transactionDigest: response.digest,
      transactionStatus: response.status,
      fileHashMatches: fileHashMatches,
      senderMatches: senderMatches,
      fileIdMatches: fileIdMatches,
      projectIdMatches: projectIdMatches,
      timestampWithinTolerance: timestampWithinTolerance,
      chainTimestamp: chainTimestamp,
      failureReason: _fileVerificationFailureReason(
        fileHashMatches: fileHashMatches,
        senderMatches: senderMatches,
        fileIdMatches: fileIdMatches,
        projectIdMatches: projectIdMatches,
        timestampWithinTolerance: timestampWithinTolerance,
      ),
    );
  }

  SuiGraphQlEvent? _findPhotoAttestedEvent(
    List<SuiGraphQlEvent>? events,
    PhotoAttestationContractConfig config,
  ) {
    for (final event in events ?? const <SuiGraphQlEvent>[]) {
      if (_matchesEventType(
        event,
        config: config,
        eventName: 'PhotoAttested',
      )) {
        return event;
      }
    }
    return null;
  }

  SuiGraphQlEvent? _findFileAttestedEvent(
    List<SuiGraphQlEvent>? events,
    PhotoAttestationContractConfig config,
  ) {
    for (final event in events ?? const <SuiGraphQlEvent>[]) {
      if (_matchesEventType(event, config: config, eventName: 'FileAttested')) {
        return event;
      }
    }
    return null;
  }

  bool _matchesEventType(
    SuiGraphQlEvent event, {
    required PhotoAttestationContractConfig config,
    required String eventName,
  }) {
    final parts = event.type.trim().toLowerCase().split('::');
    if (parts.length < 3) {
      return false;
    }

    final eventPackageFromType = _normalizeSuiAddress(parts[0]);
    final eventPackageFromField = _normalizeSuiAddress(event.packageId);
    final expectedPackage = _normalizeSuiAddress(config.packageId);
    final eventModuleFromType = parts[1];
    final eventModuleFromField = event.transactionModule.trim().toLowerCase();
    final eventStruct = parts[2];

    final packageMatches =
        eventPackageFromType == expectedPackage ||
        eventPackageFromField == expectedPackage;
    final moduleMatches =
        eventModuleFromType == config.moduleName.trim().toLowerCase() ||
        eventModuleFromField == config.moduleName.trim().toLowerCase();

    return packageMatches &&
        moduleMatches &&
        eventStruct == eventName.toLowerCase();
  }

  String _normalizeSuiAddress(String value) {
    final raw = value.trim().toLowerCase();
    final noPrefix = raw.startsWith('0x') ? raw.substring(2) : raw;
    final dePadded = noPrefix.replaceFirst(RegExp(r'^0+'), '');
    final normalized = dePadded.isEmpty ? '0' : dePadded;
    return '0x$normalized';
  }

  /// Decodes a hex-encoded hash (as persisted in `*_null_reason_hash`
  /// columns) back to raw bytes for a `vector<u8>` transaction argument. A
  /// null/empty input becomes an empty vector, matching what the contract's
  /// `is_empty()` check expects in the one no-reason-needed state per axis.
  List<int> _hexToBytes(String? hex) {
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

  String _decodeMoveBytesValue(Object? value) {
    if (value is String) {
      final normalized = value.trim();
      if (normalized.isEmpty) {
        return normalized;
      }

      final decoded = _tryDecodeBase64Utf8(normalized);
      return decoded ?? normalized;
    }
    if (value is List) {
      final bytes = value.whereType<num>().map((item) => item.toInt()).toList();
      return utf8.decode(bytes).trim();
    }
    return '';
  }

  String? _tryDecodeBase64Utf8(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty || compact.length % 4 != 0) {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(compact)) {
      return null;
    }

    try {
      final decodedBytes = base64.decode(compact);
      final decoded = utf8.decode(decodedBytes, allowMalformed: false).trim();
      if (decoded.isEmpty) {
        return null;
      }
      final printable = decoded.runes.every(
        (rune) =>
            rune == 9 ||
            rune == 10 ||
            rune == 13 ||
            (rune >= 32 && rune <= 126),
      );
      return printable ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  String _decodeMoveAddressValue(Object? value) {
    if (value is String) {
      return value.trim();
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

  String? _readBackendMessage(Map<String, dynamic> payload) {
    final message = (payload['message'] as String?)?.trim();
    if (message != null && message.isNotEmpty) {
      return message;
    }
    return null;
  }

  String _otpVerifyFailureMessage(
    Map<String, dynamic> payload, {
    required int statusCode,
    required Uri uri,
  }) {
    final backendMessage = _readBackendMessage(payload);
    final backendError = (payload['error'] as String?)?.trim();

    if (statusCode == 404) {
      if (backendError == 'not_found' && backendMessage != null) {
        return 'OTP session was not found. Request a new OTP and try again.';
      }

      final targetHint = kDebugMode ? ' URL: $uri' : '';
      return 'The OTP verification endpoint was not found on the configured backend. Check that GL_OTP_BACKEND_CONFIG points to the Trade3 API for this domain and that the latest API is deployed.$targetHint';
    }

    return backendMessage ?? 'OTP verification failed.';
  }

  bool _addressesMatch(String? left, String? right) {
    if (left == null || right == null) {
      return false;
    }
    return left.trim().toLowerCase() == right.trim().toLowerCase();
  }

  DateTime? _resolveChainTimestamp(
    SuiGraphQlTransactionResult response,
    SuiGraphQlEvent event,
  ) {
    return response.timestamp ?? event.timestamp;
  }

  BigInt _coinBalance(SuiGraphQlObject object) {
    final balance = object.json?['balance'];
    if (balance == null) {
      return BigInt.zero;
    }
    return BigInt.parse(balance.toString());
  }

  /// Compares the on-chain `attested_at` (execution time, via
  /// [chainTimestamp]) against [capture]'s own `captured_at` - never the
  /// local `submittedAt` field, which is frozen at the moment a capture was
  /// first queued and never updated on a later retry (see
  /// GraniteLakeController), so comparing against it would flag every
  /// delayed offline resubmission as a false mismatch.
  ///
  /// Offline and forced-offline captures are exempt entirely: they can
  /// legitimately sit queued for an arbitrary length of time before
  /// connectivity returns and the transaction actually executes, so a large
  /// captured_at/attested_at gap there is expected by design, not a sign of
  /// tampering. The tolerance window only means something for a capture
  /// that was online at capture time and should have submitted promptly.
  bool _isTimestampWithinTolerance({
    required AttestationRecord capture,
    required DateTime? chainTimestamp,
  }) {
    if (chainTimestamp == null) {
      return false;
    }
    if (!capture.isOnline || capture.isForcedOffline) {
      return true;
    }

    final difference = chainTimestamp.difference(capture.capturedAt).abs();
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

  String? _fileVerificationFailureReason({
    required bool fileHashMatches,
    required bool senderMatches,
    required bool fileIdMatches,
    required bool projectIdMatches,
    required bool timestampWithinTolerance,
  }) {
    if (fileHashMatches &&
        senderMatches &&
        fileIdMatches &&
        projectIdMatches &&
        timestampWithinTolerance) {
      return null;
    }

    final failures = <String>[];
    if (!fileHashMatches) {
      failures.add('File hash mismatch');
    }
    if (!senderMatches) {
      failures.add('Wallet sender mismatch');
    }
    if (!fileIdMatches) {
      failures.add('File id mismatch');
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
