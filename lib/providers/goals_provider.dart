import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/goal_repository.dart';
import '../models/goal.dart';
import 'providers.dart';

class GoalsController extends StateNotifier<AsyncValue<List<Goal>>> {
  GoalsController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  GoalRepository get _repo => _ref.read(goalRepositoryProvider);

  Future<void> load() async {
    state = const AsyncValue.loading();
    await refresh();
  }

  Future<void> refresh() async {
    try {
      state = AsyncValue.data(await _repo.list());
    } catch (e, st) {
      // Keep the cached list alongside the error. Replacing it outright collapsed
      // the collection to [], so a mutation whose follow-up refresh failed (a POST
      // that succeeded, then a Wi-Fi -> LTE handover) blanked the whole screen and
      // read as "save failed" — inviting a duplicate.
      state = state.hasValue
          ? AsyncValue<List<Goal>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  /// Like [refresh] but RETHROWS, so a mutation's caller can surface the failure
  /// instead of it being swallowed into the state and the mutation looking fine.
  Future<void> reload() async {
    state = AsyncValue.data(await _repo.list());
  }

  // Progress + status are server-derived, so re-fetch to reflect them accurately.
  Future<void> create(Map<String, dynamic> body) async {
    await _repo.create(body);
    await reload();
  }

  Future<void> update(String id, Map<String, dynamic> body) async {
    await _repo.update(id, body);
    await reload();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    final cur = state.value ?? const [];
    state = AsyncValue.data(cur.where((g) => g.id != id).toList());
  }

  Future<void> adjustProgress(String id, num delta) async {
    await _repo.adjustProgress(id, delta);
    await reload();
  }

  Future<void> setStatus(String id, String status) async {
    await _repo.setStatus(id, status);
    await reload();
  }
}

final goalsControllerProvider =
    StateNotifierProvider<GoalsController, AsyncValue<List<Goal>>>((ref) => GoalsController(ref));

/// Archived goals, fetched on demand (Settings / "show archived").
final archivedGoalsProvider = FutureProvider.autoDispose<List<Goal>>((ref) {
  return ref.watch(goalRepositoryProvider).archived();
});
