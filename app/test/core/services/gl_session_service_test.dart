import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:granite_lake/core/constants/app_constants.dart';
import 'package:granite_lake/core/services/gl_session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryStore extends GlSessionStore {
  GlSession? session;
  GlLinkState state = GlLinkState.never;
  String? pendingRevoke;

  @override
  Future<GlSession?> read() async => session;

  @override
  Future<GlLinkState> readLinkState() async => state;

  @override
  Future<void> save(GlSession value) async {
    session = value;
    state = GlLinkState.linked;
  }

  @override
  Future<void> markUnlinked(GlLinkState value) async {
    state = value;
    pendingRevoke = session?.refreshToken ?? pendingRevoke;
    session = null;
  }

  @override
  Future<String?> readPendingRevoke() async => pendingRevoke;

  @override
  Future<void> clearPendingRevoke() async => pendingRevoke = null;
}

GlSession _session({
  Duration access = const Duration(minutes: 10),
  Duration refresh = const Duration(days: 100),
}) {
  final now = DateTime.now().toUtc();
  return GlSession(
    accessToken: 'access-1',
    accessExpiresAt: now.add(access),
    refreshToken: 'refresh-1',
    refreshExpiresAt: now.add(refresh),
  );
}

http.Response _tokens() => http.Response(
  jsonEncode(
    GlSession(
      accessToken: 'access-2',
      accessExpiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      refreshToken: 'refresh-2',
      refreshExpiresAt: DateTime.now().toUtc().add(const Duration(days: 100)),
    ).toJson(),
  ),
  200,
);

http.Response _error(int status, String code) =>
    http.Response(jsonEncode({'error': code}), status);

void main() {
  late _MemoryStore store;
  late List<String> paths;
  late int endedCalls;

  GlSessionService service(
    Future<http.Response> Function(http.Request request) handler,
  ) {
    return GlSessionService(
      store: store,
      httpClient: MockClient((request) {
        paths.add(request.url.path);
        return handler(request);
      }),
      resolveBackend: (_) async =>
          const DomainBackendConfig(url: 'https://gl.test', apiKey: 'key'),
    )..onSessionEnded = () async => endedCalls++;
  }

  setUp(() {
    store = _MemoryStore()
      ..session = _session()
      ..state = GlLinkState.linked;
    paths = [];
    endedCalls = 0;
  });

  Future<http.Response> sendWith(
    GlSessionService gl,
    List<String?> seen,
    List<int> statuses,
  ) {
    var call = 0;
    return gl.send(
      domain: 'acme.com',
      request: (auth) async {
        seen.add(auth['Authorization']);
        return statuses[call++] == 200
            ? http.Response('{}', 200)
            : _error(401, 'invalid_token');
      },
    );
  }

  test('refreshes an expired access token before sending', () async {
    store.session = _session(access: const Duration(seconds: -1));
    final seen = <String?>[];

    await sendWith(service((_) async => _tokens()), seen, [200]);

    expect(seen, ['Bearer access-2']);
  });

  test('refreshes and retries once when the token is rejected', () async {
    final seen = <String?>[];

    final response = await sendWith(service((_) async => _tokens()), seen, [
      401,
      200,
    ]);

    expect(response.statusCode, 200);
    expect(seen, ['Bearer access-1', 'Bearer access-2']);
  });

  test('sends no token when there is no session', () async {
    store.session = null;
    final seen = <String?>[];

    await sendWith(service((_) async => _tokens()), seen, [200]);

    expect(seen, [null]);
    expect(paths, isEmpty);
  });

  test('concurrent refreshes share one request', () async {
    final gl = service((_) async => _tokens());

    await Future.wait([
      gl.refresh(domain: 'acme.com'),
      gl.refresh(domain: 'acme.com'),
    ]);

    expect(paths, ['/auth/refresh']);
  });

  for (final (status, code) in [
    (401, 'invalid_refresh_token'),
    (403, 'user_disabled'),
  ]) {
    test('ends the session on $status $code', () async {
      await service(
        (_) async => _error(status, code),
      ).refresh(domain: 'acme.com');

      expect(store.session, isNull);
      expect(store.state, GlLinkState.expired);
      expect(endedCalls, 1);
    });
  }

  for (final (name, handler)
      in <(String, Future<http.Response> Function(http.Request))>[
        ('a server error', (_) async => _error(502, 'sui_rpc_failed')),
        ('a rate limit', (_) async => _error(429, 'rate_limit_exceeded')),
        ('a wrong app key', (_) async => _error(401, 'unauthorized')),
        ('no network', (_) async => throw http.ClientException('offline')),
      ]) {
    test('keeps the session on $name', () async {
      await service(handler).refresh(domain: 'acme.com');

      expect(store.session?.refreshToken, 'refresh-1');
      expect(store.state, GlLinkState.linked);
      expect(endedCalls, 0);
    });
  }

  test('ends a session past its fixed lifetime without the network', () async {
    final gl = service((_) async => _tokens());

    expect(await gl.endIfExpired(DateTime.now().toUtc()), isFalse);
    expect(
      await gl.endIfExpired(
        DateTime.now().toUtc().add(const Duration(days: 101)),
      ),
      isTrue,
    );
    expect(store.state, GlLinkState.expired);
    expect(paths, isEmpty);
  });

  test('keeps the token to revoke until logout succeeds', () async {
    await store.markUnlinked(GlLinkState.unlinkedByUser);

    await service(
      (_) async => throw http.ClientException('offline'),
    ).flushPendingRevoke(domain: 'acme.com');
    expect(store.pendingRevoke, 'refresh-1');

    await service(
      (_) async => http.Response('', 204),
    ).flushPendingRevoke(domain: 'acme.com');
    expect(store.pendingRevoke, isNull);
  });

  test('only the unlinked states block attestation', () {
    expect(GlLinkState.values.where((state) => state.blocksAttestation), [
      GlLinkState.unlinkedByUser,
      GlLinkState.expired,
    ]);
  });
}
