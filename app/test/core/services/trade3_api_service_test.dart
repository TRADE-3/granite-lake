import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:granite_lake/core/services/trade3_api_service.dart';
import 'package:granite_lake/core/services/trade3_token_store.dart';

typedef _Handler =
    Future<http.StreamedResponse> Function(http.BaseRequest request);

http.StreamedResponse _jsonResponse(Object? body, {int status = 200}) {
  return http.StreamedResponse(
    http.ByteStream.fromBytes(
      utf8.encode(body == null ? '' : jsonEncode(body)),
    ),
    status,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this._handler);

  final _Handler _handler;
  final List<String> requestedPaths = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requestedPaths.add(request.url.path);
    return _handler(request);
  }
}

class _FakeTokenStore implements Trade3TokenStore {
  Trade3Tokens? tokens;
  int clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    tokens = null;
  }

  @override
  Future<Trade3Tokens?> read() async => tokens;

  @override
  Future<void> save(Trade3Tokens newTokens) async {
    tokens = newTokens;
  }
}

class _Harness {
  _Harness(this.service, this.store, this.client);

  final Trade3ApiService service;
  final _FakeTokenStore store;
  final _FakeClient client;
}

_Harness _harness(_Handler handler) {
  final client = _FakeClient(handler);
  final store = _FakeTokenStore();
  return _Harness(
    Trade3ApiService(httpClient: client, tokenStore: store),
    store,
    client,
  );
}

const Map<String, dynamic> _hierarchyPayload = {
  'message': 'Hierarchy synced successfully',
  'master_contracts': [
    {
      'id': '12',
      'title': 'Master Contract Title',
      'reference': 'mc-slug',
      'status': 'ACTIVE',
      'transactions': [
        {
          'id': '45',
          'title': 'Shipment #1',
          'status': 'IN_PROGRESS',
          'payment_schedules': [
            {
              'id': '101',
              'title': 'Customs Clearance',
              'status': 'PENDING',
              'documents': [
                {
                  'id': '502',
                  'file_name': 'bill_of_lading.pdf',
                  'document_type': 'BILL_OF_LADING',
                  'status': 'Pending',
                  'is_required': true,
                },
              ],
            },
          ],
        },
      ],
    },
  ],
};

void main() {
  group('pairWithCode (EP-01)', () {
    test('exchanges a pairing code for tokens and stores them', () async {
      http.BaseRequest? captured;
      final h = _harness((request) async {
        captured = request;
        // Confirmed EP-01 response shape - "token" is a deprecated extra.
        return _jsonResponse({
          'message': 'Appaired successfully',
          'token': 'deprecated-value',
          'access_token': 'a1',
          'refresh_token': 'r1',
        });
      });

      final tokens = await h.service.pairWithCode(
        ' bc35112c-4bdb-4aab-9c12-3456789abcde ',
      );

      expect(captured?.method, 'POST');
      expect(captured?.url.path, '/api/auth/pairing/consume');
      expect(jsonDecode((captured as http.Request).body), {
        'pairing_code': 'bc35112c-4bdb-4aab-9c12-3456789abcde',
      });
      expect(tokens.accessToken, 'a1');
      expect(tokens.refreshToken, 'r1');
      expect(h.store.tokens?.accessToken, 'a1');
    });

    test('includes the optional device_id when provided', () async {
      http.BaseRequest? captured;
      final h = _harness((request) async {
        captured = request;
        return _jsonResponse({'access_token': 'a1', 'refresh_token': 'r1'});
      });

      await h.service.pairWithCode(
        'bc35112c-4bdb-4aab-9c12-3456789abcde',
        deviceId: '0xwallet',
      );

      expect(jsonDecode((captured as http.Request).body), {
        'pairing_code': 'bc35112c-4bdb-4aab-9c12-3456789abcde',
        'device_id': '0xwallet',
      });
    });

    test(
      'surfaces the backend message and stores nothing on failure',
      () async {
        final h = _harness(
          (request) async =>
              _jsonResponse({'message': 'Invalid pairing code'}, status: 400),
        );

        try {
          await h.service.pairWithCode('nope');
          fail('expected a Trade3ApiException');
        } on Trade3ApiException catch (error) {
          expect(error.userMessage, 'Invalid pairing code');
          expect(error.statusCode, 400);
        }
        expect(h.store.tokens, isNull);
      },
    );

    test('rejects an empty code without calling the backend', () async {
      final h = _harness(
        (request) async =>
            _jsonResponse({'access_token': 'a1', 'refresh_token': 'r1'}),
      );

      await expectLater(
        h.service.pairWithCode('  '),
        throwsA(isA<Trade3ApiException>()),
      );
      expect(h.client.requestedPaths, isEmpty);
    });
  });

  group('syncHierarchy (EP-03)', () {
    test('throws unauthenticated without any request when unpaired', () async {
      final h = _harness((request) async => _jsonResponse({}));

      await expectLater(
        h.service.syncHierarchy(),
        throwsA(isA<Trade3UnauthenticatedException>()),
      );
      expect(h.client.requestedPaths, isEmpty);
    });

    test(
      'syncs and parses the hierarchy with the stored access token',
      () async {
        http.BaseRequest? captured;
        final h = _harness((request) async {
          captured = request;
          return _jsonResponse(_hierarchyPayload);
        });
        h.store.tokens = const Trade3Tokens(
          accessToken: 'a1',
          refreshToken: 'r1',
        );

        final contracts = await h.service.syncHierarchy();

        expect(captured?.method, 'GET');
        expect(captured?.url.path, '/api/granite/sync/hierarchy');
        expect(captured?.headers['Authorization'], 'Bearer a1');

        expect(contracts, hasLength(1));
        final masterContract = contracts.first;
        expect(masterContract.id, '12');
        expect(masterContract.title, 'Master Contract Title');
        expect(masterContract.reference, 'mc-slug');
        final transaction = masterContract.transactions.single;
        expect(transaction.id, '45');
        final paymentSchedule = transaction.paymentSchedules.single;
        expect(paymentSchedule.id, '101');
        expect(paymentSchedule.documents.single.fileName, 'bill_of_lading.pdf');
        expect(paymentSchedule.documents.single.isRequired, isTrue);
      },
    );

    test('reads the hierarchy when it is nested under a data key', () async {
      final h = _harness(
        (request) async =>
            _jsonResponse({'status': 'success', 'data': _hierarchyPayload}),
      );
      h.store.tokens = const Trade3Tokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      expect(await h.service.syncHierarchy(), hasLength(1));
    });

    test('refreshes the access token and retries once on 401', () async {
      final h = _harness((request) async {
        if (request.url.path == '/api/auth/refresh') {
          // Confirmed EP-02: refresh token in the JSON body only - no
          // Authorization header.
          expect(request.method, 'POST');
          expect(request.headers.containsKey('Authorization'), isFalse);
          expect(jsonDecode((request as http.Request).body), {
            'refresh_token': 'r1',
          });
          return _jsonResponse({'access_token': 'a2', 'refresh_token': 'r2'});
        }
        if (request.headers['Authorization'] != 'Bearer a2') {
          return _jsonResponse({'message': 'Unauthorized'}, status: 401);
        }
        return _jsonResponse(_hierarchyPayload);
      });
      h.store.tokens = const Trade3Tokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      expect(await h.service.syncHierarchy(), hasLength(1));
      expect(h.store.tokens?.accessToken, 'a2');
      expect(h.store.tokens?.refreshToken, 'r2');
    });

    test(
      'clears tokens and throws unauthenticated when refresh is rejected',
      () async {
        final h = _harness((request) async {
          if (request.url.path == '/api/auth/refresh') {
            return _jsonResponse({'message': 'expired'}, status: 401);
          }
          return _jsonResponse({'message': 'Unauthorized'}, status: 401);
        });
        h.store.tokens = const Trade3Tokens(
          accessToken: 'a1',
          refreshToken: 'r1',
        );

        await expectLater(
          h.service.syncHierarchy(),
          throwsA(isA<Trade3UnauthenticatedException>()),
        );
        expect(h.store.tokens, isNull);
        expect(h.store.clearCalls, greaterThanOrEqualTo(1));
      },
    );

    test('concurrent 401s share a single refresh (single-flight)', () async {
      var refreshCalls = 0;
      final h = _harness((request) async {
        if (request.url.path == '/api/auth/refresh') {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _jsonResponse({'access_token': 'a2', 'refresh_token': 'r2'});
        }
        if (request.headers['Authorization'] != 'Bearer a2') {
          return _jsonResponse({'message': 'Unauthorized'}, status: 401);
        }
        return _jsonResponse(_hierarchyPayload);
      });
      h.store.tokens = const Trade3Tokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      final results = await Future.wait([
        h.service.syncHierarchy(),
        h.service.syncHierarchy(),
      ]);

      expect(results, hasLength(2));
      expect(refreshCalls, 1);
    });
  });

  group('uploadDocuments (EP-04)', () {
    test(
      'rejects an upload with no files before calling the backend',
      () async {
        final h = _harness((request) async => _jsonResponse({}));
        h.store.tokens = const Trade3Tokens(
          accessToken: 'a1',
          refreshToken: 'r1',
        );

        await expectLater(
          h.service.uploadDocuments(
            transactionId: '45',
            paymentScheduleId: '101',
            files: const [],
          ),
          throwsA(isA<Trade3ApiException>()),
        );
        expect(h.client.requestedPaths, isEmpty);
      },
    );

    test('uploads with the target ids and parses the pinned documents', () async {
      final h = _harness((request) async {
        final multipart = request as http.MultipartRequest;
        expect(multipart.url.path, '/api/granite/pin/bonus');
        expect(multipart.files, hasLength(2));
        expect(multipart.files.every((f) => f.field == 'documents'), isTrue);
        expect(multipart.fields['transaction_id'], '45');
        expect(multipart.fields['payment_schedule_id'], '101');
        expect(multipart.headers['Authorization'], 'Bearer a1');
        // Confirmed EP-04 response: only the inserted-record essentials
        // come back; the rest of Trade3PinnedDocument's fields default.
        return _jsonResponse({
          'documents': [
            {
              'id': 610,
              'payment_schedule_id': 101,
              'document_hash':
                  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            },
          ],
        });
      });
      h.store.tokens = const Trade3Tokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      final pinned = await h.service.uploadDocuments(
        transactionId: '45',
        paymentScheduleId: '101',
        files: const [
          Trade3UploadFile(filename: 'photo_01.jpg', bytes: [1, 2, 3]),
          Trade3UploadFile(filename: 'photo_02.jpg', bytes: [4, 5, 6]),
        ],
      );

      expect(pinned, hasLength(1));
      expect(pinned.single.id, '610');
      expect(pinned.single.paymentScheduleId, '101');
      expect(
        pinned.single.documentHash,
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test(
      'splits uploads of more than 10 files into chunked requests',
      () async {
        final uploads = <http.MultipartRequest>[];
        final h = _harness((request) async {
          final multipart = request as http.MultipartRequest;
          uploads.add(multipart);
          return _jsonResponse({
            'documents': [
              for (var i = 0; i < multipart.files.length; i++)
                {
                  'id': '${uploads.length * 10 + i}',
                  'payment_schedule_id':
                      multipart.fields['payment_schedule_id'],
                  'file_name': 'p$i.jpg',
                  'is_verified_by_granite': true,
                },
            ],
          });
        });
        h.store.tokens = const Trade3Tokens(
          accessToken: 'a1',
          refreshToken: 'r1',
        );

        final files = [
          for (var i = 1; i <= 25; i++)
            Trade3UploadFile(filename: 'photo_$i.jpg', bytes: [i]),
        ];

        final pinned = await h.service.uploadDocuments(
          transactionId: '45',
          paymentScheduleId: '101',
          files: files,
        );

        expect(uploads, hasLength(3));
        expect(uploads.map((r) => r.files.length).toList(), [10, 10, 5]);
        expect(
          uploads.every(
            (r) =>
                r.fields['transaction_id'] == '45' &&
                r.fields['payment_schedule_id'] == '101',
          ),
          isTrue,
        );
        expect(pinned, hasLength(25));
        expect(pinned.first.isVerifiedByGranite, isTrue);
      },
    );
  });

  group('disconnect (EP-05)', () {
    test('clears tokens after a successful logout', () async {
      final h = _harness(
        (request) async => _jsonResponse({'message': 'Logged out'}),
      );
      h.store.tokens = const Trade3Tokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      await h.service.disconnect();

      expect(h.client.requestedPaths, ['/api/auth/logout']);
      expect(h.store.tokens, isNull);
    });

    test('treats an already-dead session as unlinked locally', () async {
      final h = _harness((request) async {
        if (request.url.path == '/api/auth/refresh') {
          return _jsonResponse({'message': 'expired'}, status: 401);
        }
        return _jsonResponse({'message': 'Unauthorized'}, status: 401);
      });
      h.store.tokens = const Trade3Tokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      await expectLater(
        h.service.disconnect(),
        throwsA(isA<Trade3UnauthenticatedException>()),
      );
      expect(h.store.tokens, isNull);
    });

    test('keeps tokens when logout fails at the network level', () async {
      final h = _harness(
        (request) async => throw http.ClientException('offline'),
      );
      h.store.tokens = const Trade3Tokens(
        accessToken: 'a1',
        refreshToken: 'r1',
      );

      await expectLater(
        h.service.disconnect(),
        throwsA(isA<Trade3ApiException>()),
      );
      expect(h.store.tokens, isNotNull);
    });
  });
}
