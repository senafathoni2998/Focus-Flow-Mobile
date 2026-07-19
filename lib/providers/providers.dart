import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/token_storage.dart';
import '../data/analytics_repository.dart';
import '../data/auth_repository.dart';
import '../data/goal_repository.dart';
import '../data/habit_repository.dart';
import '../data/list_repository.dart';
import '../data/reminder_repository.dart';
import '../data/tag_repository.dart';
import '../data/task_repository.dart';
import 'auth_provider.dart';

/// Secure on-device storage for tokens + the base-URL override.
final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

/// The API origin (scheme+host+port). Seeded from the compile-time default and
/// overridden at startup (from storage) or via Settings.
final apiBaseProvider = StateProvider<String>((ref) => AppConfig.fallbackBaseUrl);

/// The Dio-backed client. Rebuilds whenever the base URL changes. On a refresh
/// failure it flips auth to unauthenticated via the auth controller.
final apiClientProvider = Provider<ApiClient>((ref) {
  final storage = ref.watch(tokenStorageProvider);
  final base = ref.watch(apiBaseProvider);
  return ApiClient(
    storage: storage,
    apiBase: AppConfig(baseUrl: base).apiBase,
    onSessionExpired: () => ref.read(authControllerProvider.notifier).onSessionExpired(),
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
