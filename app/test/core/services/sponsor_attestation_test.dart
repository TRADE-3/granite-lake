import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/services/attestation_transaction_builder.dart';
import 'package:granite_lake/core/services/sponsor_attestation_service.dart';
import 'package:on_chain/on_chain.dart';

// Shared with server/tests/sponsor.test.ts: the server's @mysten/sui builder
// and this app's on_chain builder must produce identical bytes, or the
// pre-signing verification (design doc §8) rejects every prepared
// transaction.
final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            '../server/tests/fixtures/sponsor_attestation_fixture.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> get _common => _fixture['common'] as Map<String, dynamic>;

List<Map<String, dynamic>> get _cases =>
    (_fixture['cases'] as List).cast<Map<String, dynamic>>();

List<int> _hex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];

SuiTransactionDataV1 Function(
  SuiAddress,
  SuiGasData,
  SuiObjectRef,
  SuiObjectArg,
  SuiObjectArg,
)
_builderFor(Map<String, dynamic> request) {
  final args = request['args'] as Map<String, dynamic>;
  final packageId = _common['packageId'] as String;
  final moduleName = _common['moduleName'] as String;

  if (request['kind'] == 'photo') {
    final photoArgs = PhotoAttestationTxArgs(
      imageSha256: args['hash'] as String,
      gps: args['gps'] as String,
      altitude: args['altitude'] as String,
      projectId: args['projectId'] as String,
      capturedAtMs: args['capturedAtMs'] as int,
      isOnline: args['isOnline'] as bool,
      isForcedOffline: args['isForcedOffline'] as bool,
      internetNullReasonHashHex: args['internetNullReasonHash'] as String,
      hasGps: args['hasGps'] as bool,
      isGpsForcedNull: args['isGpsForcedNull'] as bool,
      gpsNullReasonHashHex: args['gpsNullReasonHash'] as String,
    );
    return (sender, gasData, userCap, registry, clock) =>
        AttestationTransactionBuilder.photo(
          sender: sender,
          gasData: gasData,
          userCap: userCap,
          registry: registry,
          clock: clock,
          packageId: packageId,
          moduleName: moduleName,
          args: photoArgs,
        );
  }

  final fileArgs = FileAttestationTxArgs(
    contentSha256: args['hash'] as String,
    fileId: args['fileId'] as String,
    projectId: args['projectId'] as String,
    capturedAtMs: args['capturedAtMs'] as int,
    isOnline: args['isOnline'] as bool,
    isForcedOffline: args['isForcedOffline'] as bool,
    internetNullReasonHashHex: args['internetNullReasonHash'] as String,
  );
  return (sender, gasData, userCap, registry, clock) =>
      AttestationTransactionBuilder.file(
        sender: sender,
        gasData: gasData,
        userCap: userCap,
        registry: registry,
        clock: clock,
        packageId: packageId,
        moduleName: moduleName,
        args: fileArgs,
      );
}

PreparedSponsorTransaction _prepared(
  List<int> txBytes, {
  String? digest,
  String? gasOwner,
  BigInt? gasBudget,
  BigInt? gasPrice,
  String? userCapId,
  String? registryId,
  String? clockId,
}) {
  final userCap = _common['userCap'] as Map<String, dynamic>;
  final registry = _common['registry'] as Map<String, dynamic>;
  final clock = _common['clock'] as Map<String, dynamic>;
  return PreparedSponsorTransaction(
    // Tampered-byte tests fail on an earlier check; the digest only has to
    // match for the untampered fixture bytes.
    digest: digest ?? SuiHelper.generateTransactionDigest(txBytes),
    txBytes: txBytes,
    gasOwner: gasOwner ?? _common['sponsorWallet'] as String,
    gasPrice: gasPrice ?? BigInt.parse(_common['gasPrice'] as String),
    gasBudget: gasBudget ?? BigInt.parse(_common['gasBudget'] as String),
    userCap: SponsorObjectRef(
      objectId: userCapId ?? userCap['objectId'] as String,
      version: BigInt.parse(userCap['version'] as String),
      digest: userCap['digest'] as String,
    ),
    registry: SponsorSharedObjectRef(
      objectId: registryId ?? registry['objectId'] as String,
      initialSharedVersion: BigInt.parse(
        registry['initialSharedVersion'] as String,
      ),
    ),
    clock: SponsorSharedObjectRef(
      objectId: clockId ?? clock['objectId'] as String,
      initialSharedVersion: BigInt.parse(
        clock['initialSharedVersion'] as String,
      ),
    ),
  );
}

SponsorStatus _status({String? sponsorWallet}) => SponsorStatus(
  enabled: true,
  sponsorWallet: sponsorWallet ?? _common['sponsorWallet'] as String,
  maxGasBudgetMist: BigInt.from(50000000),
  maxGasPriceMist: BigInt.from(1000),
);

String get _chain =>
    (_common['validDuring'] as Map<String, dynamic>)['chain'] as String;

BigInt get _epoch => BigInt.parse(
  (_common['validDuring'] as Map<String, dynamic>)['minEpoch'] as String,
);

List<int> _verify(
  Map<String, dynamic> fixtureCase, {
  PreparedSponsorTransaction? prepared,
  SponsorStatus? status,
  String? ownWallet,
  Map<String, dynamic>? request,
  BigInt? currentEpoch,
}) {
  return SponsorAttestationService.verifyPreparedTransaction(
    prepared: prepared ?? _prepared(_hex(fixtureCase['txBytesHex'] as String)),
    status: status ?? _status(),
    ownWallet: ownWallet ?? _common['userWallet'] as String,
    expectedUserCapObjectId:
        (_common['userCap'] as Map<String, dynamic>)['objectId'] as String,
    expectedRegistryId:
        (_common['registry'] as Map<String, dynamic>)['objectId'] as String,
    currentEpoch: currentEpoch ?? _epoch,
    chainDigest: _chain,
    expected: _builderFor(
      request ?? fixtureCase['request'] as Map<String, dynamic>,
    ),
  );
}

Matcher _rejectedWith(String code) => throwsA(
  isA<SponsorAttestationException>().having((e) => e.code, 'code', code),
);

void main() {
  group('cross-SDK fixture', () {
    for (final fixtureCase in _cases) {
      test('${fixtureCase['name']}: app accepts the server bytes', () {
        final bytes = _hex(fixtureCase['txBytesHex'] as String);
        expect(
          _verify(
            fixtureCase,
            prepared: _prepared(bytes, digest: fixtureCase['digest'] as String),
          ),
          bytes,
        );
        expect(
          SuiHelper.generateTransactionDigest(bytes),
          fixtureCase['digest'],
        );
      });
    }
  });

  group('verifyPreparedTransaction rejects', () {
    final photoCase = _cases.first;
    final photoBytes = _hex(photoCase['txBytesHex'] as String);

    test('a changed argument', () {
      final request = jsonDecode(jsonEncode(photoCase['request'])) as Map;
      (request['args'] as Map)['gps'] = '0,0';
      expect(
        () => _verify(photoCase, request: request.cast<String, dynamic>()),
        _rejectedWith('verification_failed'),
      );
    });

    test('a flipped byte inside the transaction', () {
      final tampered = [...photoBytes];
      tampered[200] ^= 0x01;
      expect(
        () => _verify(photoCase, prepared: _prepared(tampered)),
        _rejectedWith('verification_failed'),
      );
    });

    test('a different UserCap or registry', () {
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(photoBytes, userCapId: '0x${'ee' * 32}'),
        ),
        _rejectedWith('verification_failed'),
      );
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(photoBytes, registryId: '0x${'ee' * 32}'),
        ),
        _rejectedWith('verification_failed'),
      );
      expect(
        () =>
            _verify(photoCase, prepared: _prepared(photoBytes, clockId: '0x7')),
        _rejectedWith('verification_failed'),
      );
    });

    test('the user wallet as gas owner', () {
      final userWallet = _common['userWallet'] as String;
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(photoBytes, gasOwner: userWallet),
          status: _status(sponsorWallet: userWallet),
        ),
        _rejectedWith('verification_failed'),
      );
    });

    test('a gas owner other than the advertised sponsor', () {
      expect(
        () => _verify(
          photoCase,
          status: _status(sponsorWallet: '0x${'33' * 32}'),
        ),
        _rejectedWith('verification_failed'),
      );
    });

    test('a declared gas owner that differs from the bytes', () {
      // Advertised and declared agree, but the bytes were built for 0x22..
      final other = '0x${'33' * 32}';
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(photoBytes, gasOwner: other),
          status: _status(sponsorWallet: other),
        ),
        _rejectedWith('verification_failed'),
      );
    });

    test('a budget or price over its cap', () {
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(photoBytes, gasBudget: BigInt.from(50000001)),
        ),
        _rejectedWith('verification_failed'),
      );
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(photoBytes, gasPrice: BigInt.from(1001)),
        ),
        _rejectedWith('verification_failed'),
      );
    });

    test('a declared budget that differs from the bytes', () {
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(photoBytes, gasBudget: BigInt.from(5000000)),
        ),
        _rejectedWith('verification_failed'),
      );
    });

    test('a different sender', () {
      expect(
        () => _verify(photoCase, ownWallet: '0x${'44' * 32}'),
        _rejectedWith('verification_failed'),
      );
    });

    test('a wrong epoch', () {
      expect(
        () => _verify(photoCase, currentEpoch: _epoch + BigInt.one),
        _rejectedWith('stale_epoch'),
      );
    });

    test('a wrong chain id', () {
      final tampered = [...photoBytes];
      // The chain digest sits just before the trailing 4-byte nonce.
      tampered[tampered.length - 5] ^= 0x01;
      expect(
        () => _verify(photoCase, prepared: _prepared(tampered)),
        _rejectedWith('verification_failed'),
      );
    });

    test('a validity window wider than one epoch', () {
      final tampered = [...photoBytes];
      // max_epoch's low byte: tail = [2][1][min u64][1][max u64]...
      final maxEpochOffset = tampered.length - 58 + 1 + 9 + 1;
      tampered[maxEpochOffset] += 1;
      expect(
        () => _verify(photoCase, prepared: _prepared(tampered)),
        _rejectedWith('verification_failed'),
      );
    });

    test('a digest that is not the digest of the bytes', () {
      expect(
        () => _verify(
          photoCase,
          prepared: _prepared(
            photoBytes,
            digest: _cases[1]['digest'] as String,
          ),
        ),
        _rejectedWith('verification_failed'),
      );
    });

    test('trailing bytes', () {
      expect(
        () => _verify(photoCase, prepared: _prepared([...photoBytes, 0])),
        _rejectedWith('verification_failed'),
      );
    });

    test('a non-ValidDuring expiration', () {
      final tampered = [...photoBytes];
      tampered[tampered.length - 58] = 1;
      expect(
        () => _verify(photoCase, prepared: _prepared(tampered)),
        _rejectedWith('verification_failed'),
      );
    });
  });

  group('SponsorAttestationException', () {
    test('only 503 sponsor errors allow the self-pay fallback', () {
      const unavailable = SponsorAttestationException(
        statusCode: 503,
        code: 'sponsor_unavailable',
        userMessage: '',
      );
      const quota = SponsorAttestationException(
        statusCode: 409,
        code: 'quota_exceeded',
        userMessage: '',
      );
      const rateLimited = SponsorAttestationException(
        statusCode: 429,
        code: 'rate_limit_exceeded',
        userMessage: '',
      );
      const inactive = SponsorAttestationException(
        statusCode: 403,
        code: 'user_not_active',
        userMessage: '',
      );
      expect(unavailable.allowsSelfPayFallback, isTrue);
      expect(quota.allowsSelfPayFallback, isFalse);
      expect(rateLimited.allowsSelfPayFallback, isFalse);
      expect(quota.keepQueued, isTrue);
      expect(rateLimited.keepQueued, isTrue);
      expect(unavailable.keepQueued, isTrue);
      expect(inactive.keepQueued, isFalse);
    });
  });
}
