import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import '../utils/utils.dart';

/// Whether this device is linked to the Granite Lake server through Trade3.
///
/// [never] covers installs registered by OTP that have not linked Trade3 since:
/// they keep working as before. Only the two unlinked states block attestation.
enum GlLinkState { never, linked, unlinkedByUser, expired }

extension GlLinkStateX on GlLinkState {
  bool get blocksAttestation =>
      this == GlLinkState.unlinkedByUser || this == GlLinkState.expired;
}

class GlSession {
  const GlSession({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
  });

  factory GlSession.fromJson(Map<String, dynamic> json) {
    return GlSession(
      accessToken: json['accessToken'] as String,
      accessExpiresAt: DateTime.parse(
        json['accessTokenExpiresAt'] as String,
      ).toUtc(),
      refreshToken: json['refreshToken'] as String,
      refreshExpiresAt: DateTime.parse(
        json['refreshTokenExpiresAt'] as String,
      ).toUtc(),
    );
  }

  final String accessToken;
  final DateTime accessExpiresAt;
  final String refreshToken;
  final DateTime refreshExpiresAt;

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'accessTokenExpiresAt': accessExpiresAt.toIso8601String(),
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': refreshExpiresAt.toIso8601String(),
  };
}

/// The user's Trade3 details as returned by `/auth/exchange`.
class Trade3Profile {
  const Trade3Profile({
    required this.userId,
    required this.name,
    required this.email,
    required this.position,
    required this.companyId,
    required this.companyName,
    required this.role,
    this.canDepositDocuments,
  });

  final String userId;
  final String name;
  final String email;
  final String position;
  final String companyId;
  final String companyName;
  final String role;

  /// Null when unknown, which never blocks anything.
  final bool? canDepositDocuments;
}

class GlExchangeResult {
  const GlExchangeResult({
    required this.userId,
    required this.domain,
    required this.userCapId,
    required this.txDigest,
    required this.userEmail,
    required this.profile,
  });

  final String userId;
  final String domain;
  final String userCapId;
  final String txDigest;
  final String userEmail;
  final Trade3Profile profile;
}

class GlSessionException implements Exception {
  const GlSessionException(this.userMessage, {this.code});

  final String userMessage;
  final String? code;

  @override
  String toString() => 'GlSessionException(${code ?? 'unknown'})';
}

/// Secure-storage persistence for the GL tokens and link state.
class GlSessionStore {
  GlSessionStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const _sessionKey = 'gl_session';
  static const _linkStateKey = 'gl_link_state';
  // A refresh token already given up locally that the server still has to
  // revoke (unlink while offline).
  static const _pendingRevokeKey = 'gl_pending_revoke';

  final FlutterSecureStorage _storage;

  Future<GlSession?> read() async {
    final raw = await _storage.read(key: _sessionKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return GlSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<GlLinkState> readLinkState() async {
    final raw = await _storage.read(key: _linkStateKey);
    return GlLinkState.values.asNameMap()[raw] ?? GlLinkState.never;
  }

  Future<void> save(GlSession session) async {
    await _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));
    await _storage.write(key: _linkStateKey, value: GlLinkState.linked.name);
  }

  /// Gives up the local session, keeping the refresh token only for revocation.
  Future<void> markUnlinked(GlLinkState state) async {
    final session = await read();
    await _storage.write(key: _linkStateKey, value: state.name);
    if (session != null) {
      await _storage.write(key: _pendingRevokeKey, value: session.refreshToken);
    }
    await _storage.delete(key: _sessionKey);
  }

  Future<String?> readPendingRevoke() => _storage.read(key: _pendingRevokeKey);

  Future<void> clearPendingRevoke() => _storage.delete(key: _pendingRevokeKey);

  Future<void> clear() async {
    await _storage.delete(key: _sessionKey);
    await _storage.delete(key: _linkStateKey);
    await _storage.delete(key: _pendingRevokeKey);
  }
}

typedef GlBackendResolver = Future<DomainBackendConfig> Function(String domain);

/// Client for the GL server's `/auth/*` routes, and the one place that attaches
/// the access token to other server calls.
class GlSessionService {
  GlSessionService({
    GlSessionStore? store,
    http.Client? httpClient,
    GlBackendResolver? resolveBackend,
  }) : store = store ?? GlSessionStore(),
       _httpClient = httpClient ?? http.Client(),
       _resolveBackend =
           resolveBackend ??
           ((domain) => AppUtils.resolveOtpBackendConfig(domain: domain));

  /// Shared, so every caller refreshes through the same single-flight future.
  static final GlSessionService shared = GlSessionService();

  static const _timeout = Duration(seconds: 15);
  // add_user runs on-chain inside the exchange.
  static const _exchangeTimeout = Duration(seconds: 60);
  static const _expiryMargin = Duration(seconds: 30);

  final GlSessionStore store;
  final http.Client _httpClient;
  final GlBackendResolver _resolveBackend;

  /// Called after the server definitively ends the session.
  Future<void> Function()? onSessionEnded;

  Future<bool>? _refreshInFlight;

  Future<String> requestChallenge({
    required String domain,
    required String userWallet,
  }) async {
    final payload = await _post(domain, 'auth/challenge', {
      'userWallet': userWallet,
    });
    final nonce = payload['nonce'];
    if (nonce is! String || nonce.isEmpty) {
      throw const GlSessionException('The server sent an unexpected reply.');
    }
    return nonce;
  }

  Future<GlExchangeResult> exchange({
    required String domain,
    required String userWallet,
    required String nonce,
    required String signature,
    required String trade3AccessToken,
  }) async {
    final payload = await _post(
      domain,
      'auth/exchange',
      {'userWallet': userWallet, 'nonce': nonce, 'signature': signature},
      headers: {'Authorization': 'Bearer $trade3AccessToken'},
      timeout: _exchangeTimeout,
    );

    try {
      final session = GlSession.fromJson(payload);
      final profile = payload['profile'] as Map<String, dynamic>;
      final result = GlExchangeResult(
        userId: payload['userId'] as String,
        domain: payload['domain'] as String,
        userCapId: payload['userCapId'] as String,
        txDigest: payload['txDigest'] as String? ?? '',
        userEmail: payload['userEmail'] as String? ?? '',
        profile: Trade3Profile(
          userId: '${profile['trade3UserId']}',
          name: profile['name'] as String? ?? '',
          email: profile['email'] as String? ?? '',
          position: profile['position'] as String? ?? '',
          companyId: '${profile['companyId']}',
          companyName: profile['companyName'] as String? ?? '',
          role: profile['role'] as String? ?? '',
        ),
      );
      await store.save(session);
      return result;
    } on GlSessionException {
      rethrow;
    } catch (error) {
      debugPrint(
        '[GL] malformed /auth/exchange response: ${error.runtimeType}',
      );
      throw const GlSessionException('The server sent an unexpected reply.');
    }
  }

  /// Runs a server request with the access token when there is a session,
  /// refreshing first if it has expired and retrying once if it is rejected.
  Future<http.Response> send({
    required String domain,
    required Future<http.Response> Function(Map<String, String> authHeaders)
    request,
  }) async {
    var session = await _readQuietly();
    if (session != null && _isExpired(session.accessExpiresAt)) {
      await refresh(domain: domain);
      session = await _readQuietly();
    }

    var response = await request(_authHeaders(session));
    if (session != null &&
        response.statusCode == 401 &&
        _errorCode(response.body) == 'invalid_token' &&
        await refresh(domain: domain)) {
      response = await request(_authHeaders(await _readQuietly()));
    }
    return response;
  }

  /// True when a new token pair was stored. Network trouble, timeouts and 5xx
  /// keep the session; only a definite rejection ends it.
  Future<bool> refresh({required String domain}) {
    return _refreshInFlight ??= _performRefresh(
      domain,
    ).whenComplete(() => _refreshInFlight = null);
  }

  Future<bool> _performRefresh(String domain) async {
    final session = await _readQuietly();
    if (session == null) {
      return false;
    }

    final http.Response response;
    try {
      final backend = await _resolveBackend(domain);
      response = await _httpClient
          .post(
            AppUtils.otpBackendUri(backend.url, 'auth/refresh'),
            headers: _headers(backend),
            body: jsonEncode({'refreshToken': session.refreshToken}),
          )
          .timeout(_timeout);
    } catch (error) {
      debugPrint('[GL] refresh unreachable: ${error.runtimeType}');
      return false;
    }

    // An unlink may have landed while the request was in flight.
    if ((await _readQuietly())?.refreshToken != session.refreshToken) {
      return false;
    }

    final code = _errorCode(response.body);
    final rejected =
        (response.statusCode == 401 && code == 'invalid_refresh_token') ||
        (response.statusCode == 403 && code == 'user_disabled');
    if (rejected) {
      await _endSession();
      return false;
    }
    if (response.statusCode != 200) {
      return false;
    }

    try {
      await store.save(
        GlSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>),
      );
      return true;
    } catch (error) {
      debugPrint('[GL] malformed refresh response: ${error.runtimeType}');
      return false;
    }
  }

  /// Ends a session whose fixed lifetime has passed.
  Future<bool> endIfExpired(DateTime nowUtc) async {
    final session = await _readQuietly();
    if (session == null || session.refreshExpiresAt.isAfter(nowUtc)) {
      return false;
    }
    await _endSession();
    return true;
  }

  /// Ends a session whose fixed lifetime has passed, else renews a stale
  /// access token so a revocation is noticed. [nowUtc] should be network
  /// synced, so changing the phone's clock does not extend a session.
  Future<void> checkSession({
    required String domain,
    required DateTime nowUtc,
  }) async {
    final session = await _readQuietly();
    if (session == null) {
      await flushPendingRevoke(domain: domain);
      return;
    }
    if (await endIfExpired(nowUtc)) {
      return;
    }
    if (_isExpired(session.accessExpiresAt)) {
      await refresh(domain: domain);
    }
  }

  /// Tells the server to revoke a given-up session. Safe to repeat.
  Future<void> flushPendingRevoke({required String domain}) async {
    try {
      final token = await store.readPendingRevoke();
      if (token == null || token.isEmpty) {
        return;
      }
      final backend = await _resolveBackend(domain);
      final response = await _httpClient
          .post(
            AppUtils.otpBackendUri(backend.url, 'auth/logout'),
            headers: _headers(backend),
            body: jsonEncode({'refreshToken': token}),
          )
          .timeout(_timeout);
      if (response.statusCode == 204) {
        await store.clearPendingRevoke();
      }
    } catch (error) {
      debugPrint('[GL] logout deferred: ${error.runtimeType}');
    }
  }

  Future<void> _endSession() async {
    await store.markUnlinked(GlLinkState.expired);
    await onSessionEnded?.call();
  }

  /// Storage trouble reads as "no session" rather than failing the request.
  Future<GlSession?> _readQuietly() async {
    try {
      return await store.read();
    } catch (error) {
      debugPrint('[GL] session read failed: ${error.runtimeType}');
      return null;
    }
  }

  bool _isExpired(DateTime expiresAt) =>
      !expiresAt.isAfter(DateTime.now().toUtc().add(_expiryMargin));

  Map<String, String> _authHeaders(GlSession? session) => session == null
      ? const {}
      : {'Authorization': 'Bearer ${session.accessToken}'};

  Map<String, String> _headers(DomainBackendConfig backend) => {
    'Content-Type': 'application/json; charset=utf-8',
    AppUtils.appApiKeyHeader: backend.apiKey,
  };

  Future<Map<String, dynamic>> _post(
    String domain,
    String path,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
    Duration timeout = _timeout,
  }) async {
    final http.Response response;
    try {
      final backend = await _resolveBackend(domain);
      response = await _httpClient
          .post(
            AppUtils.otpBackendUri(backend.url, path),
            headers: {..._headers(backend), ...headers},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (error) {
      debugPrint('[GL] $path unreachable: ${error.runtimeType}');
      throw const GlSessionException(
        "Couldn't reach your organisation's server. Check your connection and try again.",
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = _errorCode(response.body);
      throw GlSessionException(_messageFor(code), code: code);
    }

    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const GlSessionException('The server sent an unexpected reply.');
    }
  }

  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded['error'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  // Plain-language copy for field crews.
  static String _messageFor(String? code) {
    switch (code) {
      case 'not_eligible':
        return "Your Trade3 account doesn't have access. Ask your company admin.";
      case 'user_disabled':
        return 'This account has been disabled. Ask your company admin.';
      case 'wallet_mismatch':
        return 'This account was set up with a different secure ID. Use your recovery key to restore it.';
      case 'account_conflict':
        return 'This email or secure ID belongs to another account. Ask your company admin.';
      case 'trade3_unauthorized':
        return 'Trade3 did not accept the sign-in. Scan the QR code again.';
      case 'rate_limit_exceeded':
        return 'Too many attempts. Wait a minute and try again.';
    }
    return "Linking didn't complete. Try again in a moment.";
  }
}
