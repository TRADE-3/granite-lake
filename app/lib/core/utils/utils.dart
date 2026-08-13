import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';

/// Resolves the OTP/UTC backend for a given company domain.
///
/// Behaviour:
///   * Release builds trust a single configured domain: `GL_OTP_BACKEND_CONFIG`.
///     Any other domain is refused. If unset, the resolver throws for every
///     domain.
///   * Debug builds (`kDebugMode`) may opt in to localhost probes by passing
///     `--dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true`, paired with
///     `--dart-define=GL_OTP_BACKEND_DEV_API_KEY=<key>` matching the local
///     server's `APP_API_KEY`.
///   * The resolved config is cached in memory, per domain.
class AppUtils {
  AppUtils._();

  static const String _backendBuildVersionKey = 'otp_backend_build_version';
  static const Duration _clockSkewTolerance = Duration(seconds: 60);

  static final FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: const AndroidOptions(encryptedSharedPreferences: true),
  );

  static final Map<String, DomainBackendConfig> _resolvedConfigs = {};
  static final Map<String, DateTime> _resolvedAtByDomain = {};

  /// Header used to authenticate app-originated calls to the OTP/UTC backend.
  static const String appApiKeyHeader = 'x-app-api-key';

  /// Backend candidates for [domain], in probe order. Exposed for
  /// diagnostics only; do not branch on this list in feature code.
  static List<DomainBackendConfig> otpBackendCandidatesForDomain(
    String domain,
  ) {
    final normalizedDomain = domain.trim().toLowerCase();
    final candidates = <DomainBackendConfig>[];

    final configured = AppConstants.otpBackendConfig;
    if (configured != null &&
        AppConstants.otpBackendDomain == normalizedDomain) {
      candidates.add(configured);
    }

    final allowDevFallbacks =
        kDebugMode && AppConstants.otpBackendDevFallbacksEnabled;
    if (allowDevFallbacks) {
      final devApiKey = AppConstants.otpBackendDevApiKey;
      if (!kIsWeb && Platform.isAndroid) {
        candidates.add(
          DomainBackendConfig(url: 'http://10.0.2.2:8080', apiKey: devApiKey),
        );
      }
      candidates.add(
        DomainBackendConfig(url: 'http://127.0.0.1:8080', apiKey: devApiKey),
      );
    }

    final seenUrls = <String>{};
    final unique = <DomainBackendConfig>[];
    for (final candidate in candidates) {
      final cleanedUrl = candidate.url.trim().replaceAll(
        RegExp(r'["}\s​﻿]+$'),
        '',
      );
      if (cleanedUrl.isEmpty || seenUrls.contains(cleanedUrl)) {
        continue;
      }
      seenUrls.add(cleanedUrl);
      unique.add(
        DomainBackendConfig(url: cleanedUrl, apiKey: candidate.apiKey),
      );
    }
    return unique;
  }

  static Uri otpBackendUri(String baseUrl, String endpointPath) {
    final parsedBaseUrl = Uri.parse(baseUrl.trim());
    final basePath = parsedBaseUrl.path;
    final normalizedBaseUrl = parsedBaseUrl.replace(
      path: basePath.isEmpty || basePath.endsWith('/')
          ? basePath
          : '$basePath/',
      query: null,
      fragment: null,
    );
    final normalizedEndpointPath = endpointPath.replaceFirst(
      RegExp(r'^/+'),
      '',
    );

    return normalizedBaseUrl.resolve(normalizedEndpointPath);
  }

  /// Resolves the OTP backend config for [domain] by probing candidates.
  /// Throws if the domain is not configured, or no candidate responds.
  static Future<DomainBackendConfig> resolveOtpBackendConfig({
    required String domain,
    Duration timeout = const Duration(seconds: 3),
    bool forceRefresh = false,
  }) async {
    final sw = Stopwatch()..start();
    debugPrint(
      '[NET] resolveOtpBackendConfig start domain=$domain forceRefresh=$forceRefresh timeout=$timeout',
    );

    await _invalidateCacheIfBuildChanged();
    debugPrint(
      '[NET] resolveOtpBackendConfig after cache-invalidation-check elapsed=${sw.elapsedMilliseconds}ms',
    );

    final normalizedDomain = domain.trim().toLowerCase();

    if (!forceRefresh) {
      final cached = _resolvedConfigs[normalizedDomain];
      final resolvedAt = _resolvedAtByDomain[normalizedDomain];
      if (cached != null &&
          resolvedAt != null &&
          DateTime.now().toUtc().difference(resolvedAt) < _clockSkewTolerance) {
        debugPrint(
          '[NET] resolveOtpBackendConfig cache HIT url=${cached.url} elapsed=${sw.elapsedMilliseconds}ms',
        );
        return cached;
      }
    }

    final candidates = otpBackendCandidatesForDomain(normalizedDomain);
    debugPrint(
      '[NET] resolveOtpBackendConfig candidates=${candidates.map((c) => c.url).toList()} elapsed=${sw.elapsedMilliseconds}ms',
    );
    if (candidates.isEmpty) {
      debugPrint(
        '[NET] resolveOtpBackendConfig NO CANDIDATES for domain="$domain" elapsed=${sw.elapsedMilliseconds}ms',
      );
      throw StateError(
        'No backend configured for domain "$domain". Refusing to talk to any '
        'backend. Set --dart-define=GL_OTP_BACKEND_CONFIG for this domain '
        'at build time.',
      );
    }

    Object? lastError;
    for (final candidate in candidates) {
      final attemptSw = Stopwatch()..start();
      try {
        final uri = otpBackendUri(candidate.url, 'utc');
        debugPrint('[NET] attempt GET $uri (timeout=$timeout)');
        final response = await http
            .get(
              uri,
              headers: {
                'Cache-Control': 'no-cache',
                appApiKeyHeader: candidate.apiKey,
              },
            )
            .timeout(timeout);
        debugPrint(
          '[NET] attempt GET $uri -> status=${response.statusCode} attemptElapsed=${attemptSw.elapsedMilliseconds}ms totalElapsed=${sw.elapsedMilliseconds}ms',
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _resolvedConfigs[normalizedDomain] = candidate;
          _resolvedAtByDomain[normalizedDomain] = DateTime.now().toUtc();
          await _persistBuildVersion();
          debugPrint(
            '[NET] resolveOtpBackendConfig SUCCESS url=${candidate.url} totalElapsed=${sw.elapsedMilliseconds}ms',
          );
          return candidate;
        }
        lastError = 'HTTP ${response.statusCode} from $uri';
      } catch (error) {
        debugPrint(
          '[NET] attempt GET ${candidate.url} FAILED error=$error (${error.runtimeType}) attemptElapsed=${attemptSw.elapsedMilliseconds}ms totalElapsed=${sw.elapsedMilliseconds}ms',
        );
        lastError = error;
      }
    }

    final targetSummary = candidates
        .map((candidate) => candidate.url)
        .join(', ');
    final message =
        'Could not reach OTP backend for domain "$domain". Tried: '
                '$targetSummary. ${lastError ?? ''}'
            .trim();
    debugPrint(
      '[NET] resolveOtpBackendConfig FAILED totalElapsed=${sw.elapsedMilliseconds}ms $message',
    );
    throw SocketException(message);
  }

  /// Fetches the UTC timestamp from the backend configured for [domain].
  /// Note: Security is provided by TLS (HTTPS), not by HMAC.
  static Future<DateTime> fetchBackendUtcTimestamp({
    required String domain,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resolvedConfig = await resolveOtpBackendConfig(
      domain: domain,
      timeout: timeout,
    );

    final uri = otpBackendUri(resolvedConfig.url, 'utc');
    final response = await http
        .get(
          uri,
          headers: {
            'Cache-Control': 'no-cache',
            appApiKeyHeader: resolvedConfig.apiKey,
          },
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('UTC endpoint returned ${response.statusCode}');
    }

    final payload = jsonDecode(response.body);
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('UTC payload must be a JSON object.');
    }

    final utc = payload['utc'];
    if (utc is! String || utc.trim().isEmpty) {
      throw const FormatException('UTC payload is missing the `utc` field.');
    }

    return DateTime.parse(utc).toUtc();
  }

  /// Checks if the backend configured for [domain] is reachable.
  static Future<bool> hasBackendConnectivity({
    required String domain,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final sw = Stopwatch()..start();
    debugPrint('[NET] hasBackendConnectivity start domain=$domain');
    try {
      await resolveOtpBackendConfig(
        domain: domain,
        timeout: timeout,
        forceRefresh: true,
      );
      debugPrint(
        '[NET] hasBackendConnectivity -> true elapsed=${sw.elapsedMilliseconds}ms',
      );
      return true;
    } catch (error) {
      debugPrint(
        '[NET] hasBackendConnectivity -> false error=$error elapsed=${sw.elapsedMilliseconds}ms',
      );
      return false;
    }
  }

  // ── internals ─────────────────────────────────────────────────────────────

  static Future<void> _invalidateCacheIfBuildChanged() async {
    final sw = Stopwatch()..start();
    try {
      final stored = await _secureStorage.read(key: _backendBuildVersionKey);
      debugPrint(
        '[NET] secureStorage.read($_backendBuildVersionKey) -> "$stored" elapsed=${sw.elapsedMilliseconds}ms',
      );
      final expected = AppConstants.otpBackendAppBuildVersion.toString();
      if (stored != expected) {
        _resolvedConfigs.clear();
        _resolvedAtByDomain.clear();
        debugPrint(
          '[NET] cache invalidated: stored="$stored" expected="$expected"',
        );
      }
    } catch (error) {
      debugPrint(
        '[NET] secureStorage.read FAILED error=$error elapsed=${sw.elapsedMilliseconds}ms (falling through, cache kept)',
      );
      // Secure storage unavailable (e.g. running in a unit test). Fall through
      // and let the in-memory cache handle re-resolution normally.
    }
  }

  static Future<void> _persistBuildVersion() async {
    final sw = Stopwatch()..start();
    try {
      await _secureStorage.write(
        key: _backendBuildVersionKey,
        value: AppConstants.otpBackendAppBuildVersion.toString(),
      );
      debugPrint(
        '[NET] secureStorage.write($_backendBuildVersionKey) done elapsed=${sw.elapsedMilliseconds}ms',
      );
    } catch (error) {
      debugPrint(
        '[NET] secureStorage.write FAILED error=$error elapsed=${sw.elapsedMilliseconds}ms',
      );
      // Best-effort. A failure here just means the next launch may have to
      // re-resolve once, which is harmless.
    }
  }

  // Exposed for tests.
  @visibleForTesting
  static void resetForTest() {
    _resolvedConfigs.clear();
    _resolvedAtByDomain.clear();
  }
}
