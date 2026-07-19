import '../core/json.dart';

class User {
  User({required this.id, required this.email, this.name});

  final String id;
  final String email;
  final String? name;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: asString(j['id']),
        email: asString(j['email']),
        name: asStringOrNull(j['name']),
      );

  String get displayName => (name != null && name!.isNotEmpty) ? name! : email;
}

class AuthTokens {
  AuthTokens({required this.accessToken, required this.refreshToken});
  final String accessToken;
  final String refreshToken;
}

/// The register/login/refresh response: a user plus a bearer token pair.
class AuthSession {
  AuthSession({required this.user, required this.tokens});
  final User user;
  final AuthTokens tokens;

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
        user: User.fromJson(asMap(j['user'])),
        tokens: AuthTokens(
          accessToken: asString(j['accessToken']),
          refreshToken: asString(j['refreshToken']),
        ),
      );
}
