import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/task_repository.dart';
import '../models/task.dart';
import 'providers.dart';

/// Holds ALL of the user's tasks (top-level + subtasks). Filtering into smart
/// lists happens downstream in [visibleTasksProvider] / the UI.
class TasksController extends StateNotifier<AsyncValue<List<Task>>> {
  TasksController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  TaskRepository get _repo => _ref.read(taskRepositoryProvider);
  List<Task> get _current => state.value ?? const [];

  /// Bumped by every refresh AND every mutation. A list response is only applied
  /// if no newer write happened while it was in flight.
  ///
  /// Without this, tapping the Tasks tab fires a fire-and-forget GET; ticking a
  /// task off before it lands meant the stale snapshot overwrote the result, the
  /// checkbox popped back to unchecked, and tapping again completed the task a
  /// SECOND time — rolling a recurring task two occurrences forward and
  /// double-incrementing recurrence.completedCount on the server.
  int _gen = 0;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await refresh();
  }

  Future<void> refresh() async {
    final gen = ++_gen;
    try {
      final tasks = await _repo.list();
      if (gen != _gen) return; // superseded by a newer refresh or a mutation
      state = AsyncValue.data(tasks);
    } catch (e, st) {
      if (gen != _gen) return;
      // Keep whatever list we already had: replacing it with a bare error state
      // collapsed `_current` to [], so a subsequent create looked like it had
      // wiped every task.
      state = state.hasValue
          ? AsyncValue<List<Task>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  Future<Task> create(Map<String, dynamic> body) async {
    final t = await _repo.create(body);
    _gen++;
    state = AsyncValue.data([..._current, t]);
    return t;
  }

  Future<Task> update(String id, Map<String, dynamic> body) async {
    final t = await _repo.update(id, body);
    _replace(t);
    return t;
  }

  /// Complete (or roll a recurring task forward). Returns true if it recurred.
  Future<bool> complete(String id) async {
    final res = await _repo.complete(id);
    _replace(res.task);
    return res.recurred;
  }

  Future<void> delete(String id) async {
    // Optimistic: remove synchronously (so swipe-to-dismiss is safe), restoring
    // only the removed rows on failure. The server cascades subtasks; drop direct
    // children locally too.
    //
    // Rolling back to a whole-list snapshot used to discard any OTHER mutation
    // that landed while the DELETE was in flight — completing a task during a
    // delete that then 404'd silently un-completed it on screen while the server
    // had already recorded it, setting up a double-complete.
    final removed = _current.where((t) => t.id == id || t.parentTaskId == id).toList();
    state = AsyncValue.data(
      _current.where((t) => t.id != id && t.parentTaskId != id).toList(),
    );
    _gen++;
    try {
      await _repo.delete(id);
    } catch (e) {
      final byId = {for (final t in _current) t.id};
      state = AsyncValue.data([
        ..._current,
        ...removed.where((t) => !byId.contains(t.id)),
      ]);
      _gen++;
      rethrow;
    }
  }

  void _replace(Task t) {
    _gen++;
    state = AsyncValue.data([
      for (final x in _current) if (x.id == t.id) t else x,
    ]);
  }
}

final tasksControllerProvider =
    StateNotifierProvider<TasksController, AsyncValue<List<Task>>>((ref) => TasksController(ref));
