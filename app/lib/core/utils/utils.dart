import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';

class AppUtils {
  static String? _resolvedOtpBackendBaseUrl;

  static List<String> get otpBackendBaseUrlCandidates {
    final configured = AppConstants.otpBackendBaseUrl;
    final candidates = <String>[];

    if (configured.isNotEmpty) {
      candidates.add(configured);
    }

    if (kIsWeb) {
      candidates.addAll(const [
        'http://localhost:8080',
        'http://127.0.0.1:8080',
      ]);
    } else {
      if (Platform.isAndroid) {
        candidates.addAll(const [
          'http://10.0.2.2:8080',
          'http://172.26.0.3:8080',
        ]);
      }
      if (Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isWindows) {
        candidates.addAll(const [
          'http://127.0.0.1:8080',
          'http://localhost:8080',
        ]);
      }
    }

    candidates.add('https://zoey-glorious-chanda.ngrok-free.dev');

    final unique = <String>[];
    for (final raw in candidates) {
      final cleaned = raw.trim().replaceAll(
        RegExp(r'["}\s\u2060\uFEFF]+$'),
        '',
      );
      if (cleaned.isEmpty || unique.contains(cleaned)) {
        continue;
      }
      unique.add(cleaned);
    }
    return unique;
  }

  static String get otpBackendTargetsSummary =>
      otpBackendBaseUrlCandidates.join(', ');

  static Future<String> resolveOtpBackendBaseUrl({
    Duration timeout = const Duration(seconds: 3),
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _resolvedOtpBackendBaseUrl != null) {
      return _resolvedOtpBackendBaseUrl!;
    }

    for (final baseUrl in otpBackendBaseUrlCandidates) {
      try {
        final uri = Uri.parse(baseUrl).resolve('/utc');
        final response = await http
            .get(uri, headers: const {'Cache-Control': 'no-cache'})
            .timeout(timeout);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          _resolvedOtpBackendBaseUrl = baseUrl;
          return baseUrl;
        }
      } catch (_) {
        // Try the next candidate endpoint.
      }
    }

    throw SocketException(
      'Could not reach OTP backend. Tried: ${otpBackendBaseUrlCandidates.join(', ')}',
    );
  }

  static Future<DateTime> fetchBackendUtcTimestamp({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resolvedBaseUrl = await resolveOtpBackendBaseUrl(timeout: timeout);
    final uri = Uri.parse(resolvedBaseUrl).resolve('/utc');
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

    final rawUtc = payload['utc'];
    if (rawUtc is! String || rawUtc.trim().isEmpty) {
      throw const FormatException('UTC payload is missing the `utc` field.');
    }

    return DateTime.parse(rawUtc).toUtc();
  }

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
}
