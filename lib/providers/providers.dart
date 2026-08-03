import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/response_cache.dart';
import '../core/token_storage.dart';
import '../data/analytics_repository.dart';
import '../data/auth_repository.dart';
import '../data/goal_repository.dart';
import '../data/habit_repository.dart';
import '../data/list_repository.dart';
import '../data/reminder_repository.dart';
import '../data/chat_repository.dart';
import '../data/saved_filter_repository.dart';
import '../data/session_repository.dart';
import '../data/tag_repository.dart';
import '../data/task_repository.dart';
import 'auth_provider.dart';
import 'write_queue_provider.dart';

/// Secure on-device storage for tokens + the base-URL override.
final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

/// The API origin (scheme+host+port). Seeded from the compile-time default and
/// overridden at startup (from storage) or via Settings.
final apiBaseProvider = StateProvider<String>((ref) => AppConfig.fallbackBaseUrl);

/// The Dio-backed client. Rebuilds whenever the base URL changes. On a refresh
/// failure it flips auth to unauthenticated via the auth controller.
final responseCacheProvider = Provider<ResponseCache>((ref) => ResponseCache());

/// True while the app is showing data read from disk because the server could
/// not be reached. Surfaced in the UI so "everything looks normal but is hours
/// old" is never a silent state.
final servingCacheProvider = StateProvider<bool>((ref) => false);

// The variable type is written out because `onNetworkOk` reads the flusher,
// which reads this provider — a cycle for Dart's TYPE INFERENCE, though not at
// runtime: the read happens inside the callback, long after both are built.
final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(tokenStorageProvider);
  final base = ref.watch(apiBaseProvider);
  return ApiClient(
    storage: storage,
    apiBase: AppConfig(baseUrl: base).apiBase,
    onSessionExpired: () => ref.read(authControllerProvider.notifier).onSessionExpired(),
    cache: ref.watch(responseCacheProvider),
    onServingCache: (serving) {
      final notifier = ref.read(servingCacheProvider.notifier);
      if (notifier.state != serving) notifier.state = serving;
    },
    // Any 2xx from any verb means there is a network again. Read lazily inside
    // the callback, not captured: the flusher depends on this client, so
    // resolving it here would be a provider cycle.
    onNetworkOk: () => ref.read(queueFlusherProvider).kick(),
  );
});

// ---- Repositories (rebuild with the client) ----------------------------------

final authRepositoryProvider = Provider((ref) => AuthRepository(ref.watch(apiClientProvider)));
final taskRepositoryProvider = Provider((ref) => TaskRepository(ref.watch(apiClientProvider)));
final listRepositoryProvider = Provider((ref) => ListRepository(ref.watch(apiClientProvider)));
final tagRepositoryProvider = Provider((ref) => TagRepository(ref.watch(apiClientProvider)));
final habitRepositoryProvider = Provider((ref) => HabitRepository(ref.watch(apiClientProvider)));
final goalRepositoryProvider = Provider((ref) => GoalRepository(ref.watch(apiClientProvider)));
final reminderRepositoryProvider = Provider((ref) => ReminderRepository(ref.watch(apiClientProvider)));
final analyticsRepositoryProvider = Provider((ref) => AnalyticsRepository(ref.watch(apiClientProvider)));
final sessionRepositoryProvider = Provider((ref) => SessionRepository(ref.watch(apiClientProvider)));
final savedFilterRepositoryProvider = Provider((ref) => SavedFilterRepository(ref.watch(apiClientProvider)));
final chatRepositoryProvider = Provider((ref) => ChatRepository(ref.watch(apiClientProvider)));
