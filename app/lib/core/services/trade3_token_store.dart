import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Trade3 session tokens issued by EP-01 (pairing) and rotated by EP-02
/// (refresh), stored together — a response never carries just one of them.
class Trade3Tokens {
  const Trade3Tokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

/// Device-side storage for the paired Trade3 account's session tokens
/// (design/mobile_integration.md).
///
/// The refresh token is the durable link to the paired account: deleting it
/// via [clear] is what "unlink account" means locally — no refresh token, no
/// new access token, and no authenticated Trade3 calls until the user pairs
/// again.
class Trade3TokenStore {
  Trade3TokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const String _accessTokenKey = 'trade3_access_token';
  static const String _refreshTokenKey = 'trade3_refresh_token';

  final FlutterSecureStorage _storage;

  /// The stored token pair, or null when no account is paired (or the pair
  /// is incomplete, which is treated the same way).
  Future<Trade3Tokens?> read() async {
    final accessToken = await _storage.read(key: _accessTokenKey);
    final refreshToken = await _storage.read(key: _refreshTokenKey);
    if (accessToken == null ||
        refreshToken == null ||
        accessToken.isEmpty ||
        refreshToken.isEmpty) {
      return null;
    }
    return Trade3Tokens(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<void> save(Trade3Tokens tokens) async {
    await _storage.write(key: _accessTokenKey, value: tokens.accessToken);
    await _storage.write(key: _refreshTokenKey, value: tokens.refreshToken);
  }

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }
}
