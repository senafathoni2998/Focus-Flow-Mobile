import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../models/user.dart';
import 'providers.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState {
  const AuthState({required this.status, this.user});
  final AuthStatus status;
  final User? user;

  bool get isAuthenticated => status == AuthStatus.authenticated;

  AuthState copyWith({AuthStatus? status, User? user}) =>
      AuthState(status: status ?? this.status, user: user ?? this.user);
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._ref) : super(const AuthState(status: AuthStatus.unknown)) {
    _bootstrap();
  }

  final Ref _ref;

  /// On launch: apply any saved base-URL override, then validate a stored token.
  Future<void> _bootstrap() async {
    final storage = _ref.read(tokenStorageProvider);
    final savedBase = await storage.getBaseUrl();
    if (savedBase != null && savedBase.isNotEmpty) {
      _ref.read(apiBaseProvider.notifier).state = savedBase;
    }

    final token = await storage.getAccessToken();
    if (token == null || token.isEmpty) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }
    try {
      final user = await _ref.read(authRepositoryProvider).me();
      state = AuthState(status: AuthStatus.authenticated, user: user);
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // Token genuinely invalid and refresh failed → sign out.
        await storage.clearTokens();
        state = const AuthState(status: AuthStatus.unauthenticated);
      } else {
        // Transient (offline / server down / 5xx): keep the tokens and open the
        // app optimistically. Data screens will show a retry; a later request
        // refreshes or, if truly unauthorized, triggers sign-out then.
        state = const AuthState(status: AuthStatus.authenticated, user: null);
      }
    } catch (_) {
      // Non-HTTP failure — treat as transient, keep the session.
      state = const AuthState(status: AuthStatus.authenticated, user: null);
    }
  }

  Future<void> login(String email, String password) async {
    final session = await _ref.read(authRepositoryProvider).login(email, password);
    await _ref
        .read(tokenStorageProvider)
        .saveTokens(access: session.tokens.accessToken, refresh: session.tokens.refreshToken);
    state = AuthState(status: AuthStatus.authenticated, user: session.user);
  }

  Future<void> register(String email, String password, {String? name}) async {
    final session = await _ref.read(authRepositoryProvider).register(email, password, name: name);
    await _ref
        .read(tokenStorageProvider)
        .saveTokens(access: session.tokens.accessToken, refresh: session.tokens.refreshToken);
    state = AuthState(status: AuthStatus.authenticated, user: session.user);
  }

  Future<void> logout() async {
    await _ref.read(tokenStorageProvider).clearTokens();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Invoked by the API client when a token refresh fails mid-session.
  void onSessionExpired() {
    if (state.status != AuthStatus.unauthenticated) {
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));
