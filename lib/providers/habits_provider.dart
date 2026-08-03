import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/habit_repository.dart';
import '../models/habit.dart';
import 'providers.dart';

class HabitsController extends StateNotifier<AsyncValue<List<Habit>>> {
  HabitsController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  HabitRepository get _repo => _ref.read(habitRepositoryProvider);
  List<Habit> get _current => state.value ?? const [];

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
          ? AsyncValue<List<Habit>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  /// Like [refresh] but RETHROWS, so a mutation's caller can surface the failure
  /// instead of it being swallowed into the state and the mutation looking fine.
  Future<void> reload() async {
    state = AsyncValue.data(await _repo.list());
  }

  Future<void> create(Map<String, dynamic> body) async {
    await _repo.create(body);
    await reload(); // pick up server-computed stats; rethrows so the caller sees failure
  }

  Future<void> update(String id, Map<String, dynamic> body) async {
    await _repo.update(id, body);
    await reload();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = AsyncValue.data(_current.where((h) => h.id != id).toList());
  }

  Future<void> archive(String id) async {
    await _repo.archive(id, true);
    state = AsyncValue.data(_current.where((h) => h.id != id).toList());
  }

  /// Bring an archived habit back. `archive(id, false)` was always supported by
  /// the API; there was simply no way to reach it, because nothing could list an
  /// archived habit in the first place.
  Future<void> unarchive(String id) async {
    await _repo.archive(id, false);
    await reload();
  }

  /// Check in [delta] (default +1) today. Replaces the habit with the returned
  /// one (which carries recomputed stats).
  Future<void> checkIn(String id, {int delta = 1}) async {
    final h = await _repo.checkIn(id, delta: delta);
    state = AsyncValue.data([for (final x in _current) if (x.id == id) h else x]);
  }
}

final habitsControllerProvider =
    StateNotifierProvider<HabitsController, AsyncValue<List<Habit>>>((ref) => HabitsController(ref));

/// Archived habits, fetched on demand by the Archived screen.
final archivedHabitsProvider = FutureProvider.autoDispose<List<Habit>>((ref) {
  return ref.watch(habitRepositoryProvider).archived();
});
