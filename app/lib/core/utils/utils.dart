import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';

/// Resolves the OTP/UTC backend URL.
///
/// Behaviour:
///   * Release builds trust a single URL: `GL_OTP_BACKEND_URL`. If unset, the
///     resolver throws synchronously when first called.
///   * Debug builds (`kDebugMode`) may opt in to localhost probes by passing
///     `--dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true`.
///   * The resolved URL is cached in memory.
class AppUtils {
  AppUtils._();

  static const String _backendBuildVersionKey = 'otp_backend_build_version';
  static const Duration _clockSkewTolerance = Duration(seconds: 60);

  static final FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: const AndroidOptions(encryptedSharedPreferences: true),
  );

  static String? _resolvedOtpBackendBaseUrl;
  static DateTime? _resolvedAt;

  /// URLs the resolver will probe, in order. Exposed for diagnostics only;
  /// do not branch on this list in feature code.
  static List<String> get otpBackendBaseUrlCandidates {
    final configured = AppConstants.otpBackendBaseUrl;
    final candidates = <String>[];

    if (configured.isNotEmpty) {
      candidates.add(configured);
    }

    final allowDevFallbacks =
        kDebugMode && AppConstants.otpBackendDevFallbacksEnabled;
    if (allowDevFallbacks) {
      if (!kIsWeb && Platform.isAndroid) {
        candidates.add('http://10.0.2.2:8080');
      }
      candidates.add('http://127.0.0.1:8080');
    }

    final unique = <String>[];
    for (final raw in candidates) {
      final cleaned = raw.trim().replaceAll(RegExp(r'["}\s​﻿]+$'), '');
      if (cleaned.isEmpty || unique.contains(cleaned)) {
        continue;
      }
      unique.add(cleaned);
    }
    return unique;
  }

  /// Human-readable description of the candidates. Hidden in release when no
  /// dev fallback is enabled, since leaking the configured tenant URL in error
  /// messages has limited value and can confuse the user.
  static String get otpBackendTargetsSummary {
    if (!kDebugMode) {
      return '<configured backend>';
    }
    return otpBackendBaseUrlCandidates.join(', ');
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

  /// Resolves the OTP backend URL by probing candidates.
  /// Throws if no candidate responds successfully.
  static Future<String> resolveOtpBackendBaseUrl({
    Duration timeout = const Duration(seconds: 3),
    bool forceRefresh = false,
  }) async {
    await _invalidateCacheIfBuildChanged();

    if (!forceRefresh &&
        _resolvedOtpBackendBaseUrl != null &&
        _resolvedAt != null &&
        DateTime.now().toUtc().difference(_resolvedAt!) < _clockSkewTolerance) {
      return _resolvedOtpBackendBaseUrl!;
    }

    final candidates = otpBackendBaseUrlCandidates;
    if (candidates.isEmpty) {
      throw StateError(
        'GL_OTP_BACKEND_URL is not configured. Refusing to talk to any backend. '
        'Set --dart-define=GL_OTP_BACKEND_URL=<your-api-url> at build time.',
      );
    }

    Object? lastError;
    for (final baseUrl in candidates) {
      try {
        final uri = otpBackendUri(baseUrl, 'utc');
        final response = await http
            .get(uri, headers: const {'Cache-Control': 'no-cache'})
            .timeout(timeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _resolvedOtpBackendBaseUrl = baseUrl;
          _resolvedAt = DateTime.now().toUtc();
          await _persistBuildVersion();
          return baseUrl;
        }
      } catch (error) {
        lastError = error;
      }
    }

    final targetSummary = otpBackendBaseUrlCandidates.join(', ');
    throw SocketException(
      'Could not reach OTP backend. Tried: $targetSummary. ${lastError ?? ''}'
          .trim(),
    );
  }

  /// Fetches the UTC timestamp from the backend.
  /// Note: Security is provided by TLS (HTTPS), not by HMAC.
  static Future<DateTime> fetchBackendUtcTimestamp({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resolvedBaseUrl = await resolveOtpBackendBaseUrl(timeout: timeout);

    final uri = otpBackendUri(resolvedBaseUrl, 'utc');
    final response = await http
        .get(uri, headers: const {'Cache-Control': 'no-cache'})
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

  /// Checks if the backend is reachable.
  static Future<bool> hasBackendConnectivity({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      await resolveOtpBackendBaseUrl(timeout: timeout, forceRefresh: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── internals ─────────────────────────────────────────────────────────────

  static Future<void> _invalidateCacheIfBuildChanged() async {
    try {
      final stored = await _secureStorage.read(key: _backendBuildVersionKey);
      final expected = AppConstants.otpBackendAppBuildVersion.toString();
      if (stored != expected) {
        _resolvedOtpBackendBaseUrl = null;
        _resolvedAt = null;
      }
    } catch (_) {
      // Secure storage unavailable (e.g. running in a unit test). Fall through
      // and let the in-memory cache handle re-resolution normally.
    }
  }

  static Future<void> _persistBuildVersion() async {
    try {
      await _secureStorage.write(
        key: _backendBuildVersionKey,
        value: AppConstants.otpBackendAppBuildVersion.toString(),
      );
    } catch (_) {
      // Best-effort. A failure here just means the next launch may have to
      // re-resolve once, which is harmless.
    }
  }

  // Exposed for tests.
  @visibleForTesting
  static void resetForTest() {
    _resolvedOtpBackendBaseUrl = null;
    _resolvedAt = null;
  }
}
