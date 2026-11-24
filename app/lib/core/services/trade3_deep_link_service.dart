import 'package:app_links/app_links.dart';

/// Intake for `granite.trade3.io` pairing deep links
/// (design/mobile_integration.md §3).
///
/// The deep-link manager redirects QR/link taps to the app via an Android App
/// Link; this service turns those URIs into pairing codes for EP-01. Codes
/// can also be typed manually on the pairing screen when the link fails to
/// open the app.
class Trade3DeepLinkService {
  Trade3DeepLinkService({AppLinks? appLinks})
    : _appLinks = appLinks ?? AppLinks();

  static const String pairingLinkHost = 'granite.trade3.io';

  final AppLinks _appLinks;

  /// Extracts the pairing code from a deep-link URI.
  ///
  /// Accepts any path on [pairingLinkHost] — the design docs show both
  /// `/?code=…` and `/pair?code=…` — but nothing but https.
  static String? extractPairingCode(Uri uri) {
    if (uri.scheme != 'https' || uri.host.toLowerCase() != pairingLinkHost) {
      return null;
    }
    final code = uri.queryParameters['code']?.trim() ?? '';
    return code.isEmpty ? null : code;
  }

  /// The pairing code that launched the app (cold start), if any.
  Future<String?> initialPairingCode() async {
    final Uri? uri;
    try {
      uri = await _appLinks.getInitialLink();
    } catch (_) {
      return null;
    }
    return uri == null ? null : extractPairingCode(uri);
  }

  /// Pairing codes from links that arrive while the app is running.
  Stream<String> pairingCodeStream() {
    return _appLinks.uriLinkStream
        .map(extractPairingCode)
        .where((code) => code != null)
        .cast<String>();
  }
}
