import '../core/api_client.dart';
import '../core/json.dart';
import '../models/user.dart';

class AuthRepository {
  AuthRepository(this._api);
  final ApiClient _api;

  Future<AuthSession> login(String email, String password) async {
    final data = await _api.postJson(
      '/auth/login',
      body: {'email': email, 'password': password},
      skipAuth: true,
    );
    return AuthSession.fromJson(asMap(data));
  }

  Future<AuthSession> register(String email, String password, {String? name}) async {
    final data = await _api.postJson(
      '/auth/register',
      body: {'email': email, 'password': password, if (name != null && name.isNotEmpty) 'name': name},
      skipAuth: true,
    );
    return AuthSession.fromJson(asMap(data));
  }

  Future<User> me() async {
    final data = await _api.getJson('/auth/me');
    return User.fromJson(asMap(asMap(data)['user']));
  }

  /// DELETE /auth/me — the account and everything it owns.
  ///
  /// The password is sent again on purpose: a bearer token alone, on a phone
  /// left unlocked, must not be enough to erase an account.
  Future<void> deleteAccount(String password) async {
    await _api.deleteJson('/auth/me', body: {'password': password});
  }
}
