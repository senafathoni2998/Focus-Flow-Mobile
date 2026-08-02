import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../models/user.dart';
import 'dashboard_provider.dart';
import 'filter_provider.dart';
import 'goals_provider.dart';
import 'habits_provider.dart';
import 'lists_provider.dart';
import 'providers.dart';
import 'tags_provider.dart';
import 'tasks_provider.dart';

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
  ///
  /// The whole body is guarded: the two secure-storage reads used to sit OUTSIDE
  /// the try below, so a PlatformException from flutter_secure_storage (an entry
  /// that can't be decrypted after an Android backup is restored onto a different
  /// device) left `status` at AuthStatus.unknown forever. AuthGate renders the
  /// splash for `unknown`, so the app hung on its spinner with no error, no login
  /// screen, and no in-app way out.
  Future<void> _bootstrap() async {
    try {
      await _bootstrapInner();
    } catch (_) {
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  Future<void> _bootstrapInner() async {
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

  /// Drop every cached collection so one account never sees another's data.
  ///
  /// All the data controllers are root-scoped StateNotifierProviders that load in
  /// their constructor and are never rebuilt — there is a single ProviderScope and
  /// nothing invalidated them. Signing out and back in (or pointing the app at a
  /// different server) therefore left the previous session's tasks, lists, tags,
  /// habits, goals and dashboard on screen; lists and tags had no refresh path at
  /// all, so they persisted for the life of the process.
  void resetSession() {
    _ref.invalidate(tasksControllerProvider);
    _ref.invalidate(listsControllerProvider);
    _ref.invalidate(tagsControllerProvider);
    _ref.invalidate(habitsControllerProvider);
    _ref.invalidate(goalsControllerProvider);
    _ref.invalidate(dashboardControllerProvider);
    _ref.invalidate(taskFilterProvider);
  }

  Future<void> login(String email, String password) async {
    final session = await _ref.read(authRepositoryProvider).login(email, password);
    await _ref
        .read(tokenStorageProvider)
        .saveTokens(access: session.tokens.accessToken, refresh: session.tokens.refreshToken);
    resetSession();
    state = AuthState(status: AuthStatus.authenticated, user: session.user);
  }

  Future<void> register(String email, String password, {String? name}) async {
    final session = await _ref.read(authRepositoryProvider).register(email, password, name: name);
    await _ref
        .read(tokenStorageProvider)
        .saveTokens(access: session.tokens.accessToken, refresh: session.tokens.refreshToken);
    resetSession();
    state = AuthState(status: AuthStatus.authenticated, user: session.user);
  }

  Future<void> logout() async {
    // Guarded: a throw from secure storage used to abort sign-out silently,
    // leaving the user apparently logged in.
    try {
      await _ref.read(tokenStorageProvider).clearTokens();
    } catch (_) {
      // Best effort — sign out locally regardless.
    }
    resetSession();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Invoked by the API client when a token refresh fails mid-session.
  void onSessionExpired() {
    if (state.status != AuthStatus.unauthenticated) {
      resetSession();
      state = const AuthState(status: AuthStatus.unauthenticated);
    }
  }

  /// Re-fetch the profile when bootstrap opened the app optimistically without one.
  ///
  /// `me()` was only ever called from _bootstrap, so a backend that was restarting
  /// at cold start (502, not 401) left `user: null` for the whole process: Settings
  /// showed "FocusFlow user" with a blank email and the dashboard greeted "Hi 👋".
  Future<void> refreshUser() async {
    if (state.status != AuthStatus.authenticated || state.user != null) return;
    try {
      final user = await _ref.read(authRepositoryProvider).me();
      if (mounted) state = AuthState(status: AuthStatus.authenticated, user: user);
    } catch (_) {
      // Leave the optimistic session alone; a later call can try again.
    }
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));
