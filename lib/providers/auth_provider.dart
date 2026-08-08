import 'dart:async';

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
import 'write_queue_provider.dart';

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

    // Scope the cache from the STORED id, before any network call. On a cold
    // start with no connection me() fails, and scoping only on its success would
    // leave the cache unreadable in exactly the situation it exists for.
    final storedId = await storage.getUserId();
    if (storedId != null && storedId.isNotEmpty) _scopeCache(storedId);

    try {
      final user = await _ref.read(authRepositoryProvider).me();
      _scopeCache(user.id);
      await storage.setUserId(user.id);
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

  /// Point the on-disk cache at this user, so one account can never read
  /// another's cached responses off disk — the same leak resetSession() closes
  /// in memory.
  void _scopeCache(String? userId) {
    _ref.read(responseCacheProvider).setScope(userId);
    _ref.read(servingCacheProvider.notifier).state = false;
    // The write queue is scoped in the SAME place, and from the same stored id,
    // so a queue built on a plane is readable the moment the app reopens — which
    // is the only situation it exists for.
    unawaited(_ref.read(queueFlusherProvider).setScope(userId));
  }

  Future<void> login(String email, String password) async {
    final session = await _ref.read(authRepositoryProvider).login(email, password);
    await _ref
        .read(tokenStorageProvider)
        .saveTokens(access: session.tokens.accessToken, refresh: session.tokens.refreshToken);
    await _ref.read(tokenStorageProvider).setUserId(session.user.id);
    resetSession();
    _scopeCache(session.user.id);
    state = AuthState(status: AuthStatus.authenticated, user: session.user);
  }

  Future<void> register(String email, String password, {String? name}) async {
    final session = await _ref.read(authRepositoryProvider).register(email, password, name: name);
    await _ref
        .read(tokenStorageProvider)
        .saveTokens(access: session.tokens.accessToken, refresh: session.tokens.refreshToken);
    await _ref.read(tokenStorageProvider).setUserId(session.user.id);
    resetSession();
    _scopeCache(session.user.id);
    state = AuthState(status: AuthStatus.authenticated, user: session.user);
  }

  /// Unsent writes that would be lost by signing out. The caller MUST show
  /// these to the user before calling [logout] with `discardUnsent: true`.
  int get unsentCount => _ref.read(unsentCountProvider);

  Future<void> logout({bool discardUnsent = false}) async {
    // Guarded: a throw from secure storage used to abort sign-out silently,
    // leaving the user apparently logged in.
    try {
      await _ref.read(tokenStorageProvider).clearTokens();
    } catch (_) {
      // Best effort — sign out locally regardless.
    }
    // The write queue is RETAINED unless the user explicitly chose to drop it.
    // It is their own unsent work, not the server's cached data, and the two
    // must not share a retention policy: the file stays under this account's
    // scope, unreadable by any other, and flushes when they sign back in.
    if (discardUnsent) {
      // Before unscoping, for the same reason the cache is: clearScope() is
      // scope-aware, so dropping the scope first would strand the file on disk.
      await _ref.read(queueFlusherProvider).discardAllForSignOut();
    }
    // Wipe the cache BEFORE unscoping: clear() is scope-aware, so dropping the
    // scope first would leave the files on disk for the next account to inherit.
    await _ref.read(responseCacheProvider).clear();
    _scopeCache(null);
    resetSession();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Invoked by the API client when a token refresh fails mid-session.
  void onSessionExpired() {
    if (state.status != AuthStatus.unauthenticated) {
      // PAUSE, never discard. This can fire while the app is backgrounded, so it
      // is not a decision the user made — and we genuinely do not know whether
      // the in-flight write committed. Its idempotency key is intact, so signing
      // back in replays it and the server resolves it either way.
      _ref.read(queueFlusherProvider).pauseForAuth();
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
