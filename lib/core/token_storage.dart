import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// On-device secure storage for the auth token pair and the (overridable) API
/// base URL. Backed by the Android Keystore via flutter_secure_storage.
class TokenStorage {
  TokenStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kBaseUrl = 'base_url';
  // Stored alongside the tokens so the offline cache can be scoped to the right
  // account on a cold start where `me()` cannot be reached. Without it, opening
  // the app with no network leaves the cache unscoped and therefore unreadable —
  // the exact case it exists for.
  static const _kUserId = 'user_id';

  Future<String?> getAccessToken() => _storage.read(key: _kAccess);
  Future<String?> getRefreshToken() => _storage.read(key: _kRefresh);
  Future<String?> getUserId() => _storage.read(key: _kUserId);
  Future<void> setUserId(String id) => _storage.write(key: _kUserId, value: id);

  Future<void> saveTokens({required String access, required String refresh}) async {
    await _storage.write(key: _kAccess, value: access);
    await _storage.write(key: _kRefresh, value: refresh);
  }

  Future<void> clearTokens() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
  }

  Future<String?> getBaseUrl() => _storage.read(key: _kBaseUrl);
  Future<void> setBaseUrl(String url) => _storage.write(key: _kBaseUrl, value: url);
}
