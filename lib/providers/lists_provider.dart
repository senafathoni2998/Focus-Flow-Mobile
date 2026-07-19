import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/list_repository.dart';
import '../models/task_list.dart';
import 'providers.dart';

class ListsController extends StateNotifier<AsyncValue<List<TaskList>>> {
  ListsController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  ListRepository get _repo => _ref.read(listRepositoryProvider);
  List<TaskList> get _current => state.value ?? const [];

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

  Future<TaskList> create(String name, {String? color}) async {
    final l = await _repo.create(name, color: color);
    state = AsyncValue.data([..._current, l]);
    return l;
  }

  Future<void> update(String id, {String? name, String? color}) async {
    final l = await _repo.update(id, name: name, color: color);
    state = AsyncValue.data([for (final x in _current) if (x.id == id) l else x]);
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = AsyncValue.data(_current.where((l) => l.id != id).toList());
  }
}

final listsControllerProvider =
    StateNotifierProvider<ListsController, AsyncValue<List<TaskList>>>((ref) => ListsController(ref));
