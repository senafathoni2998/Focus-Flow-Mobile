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

  Future<Task> create(Map<String, dynamic> body) async {
    final t = await _repo.create(body);
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
    // Optimistic: remove synchronously (so swipe-to-dismiss is safe), roll back
    // on failure. The server cascades subtasks; drop direct children locally too.
    final prev = _current;
    state = AsyncValue.data(
      _current.where((t) => t.id != id && t.parentTaskId != id).toList(),
    );
    try {
      await _repo.delete(id);
    } catch (e) {
      state = AsyncValue.data(prev);
      rethrow;
    }
  }

  void _replace(Task t) {
    state = AsyncValue.data([
      for (final x in _current) if (x.id == t.id) t else x,
    ]);
  }
}

final tasksControllerProvider =
    StateNotifierProvider<TasksController, AsyncValue<List<Task>>>((ref) => TasksController(ref));
