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
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> create(Map<String, dynamic> body) async {
    await _repo.create(body);
    await refresh(); // pick up server-computed stats
  }

  Future<void> update(String id, Map<String, dynamic> body) async {
    await _repo.update(id, body);
    await refresh();
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = AsyncValue.data(_current.where((h) => h.id != id).toList());
  }

  Future<void> archive(String id) async {
    await _repo.archive(id, true);
    state = AsyncValue.data(_current.where((h) => h.id != id).toList());
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
