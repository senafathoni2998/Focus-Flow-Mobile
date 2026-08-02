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
      // Keep the cached list alongside the error. Replacing it outright collapsed
      // the collection to [], so a mutation whose follow-up refresh failed (a POST
      // that succeeded, then a Wi-Fi -> LTE handover) blanked the whole screen and
      // read as "save failed" — inviting a duplicate.
      state = state.hasValue
          ? AsyncValue<List<TaskList>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  /// Like [refresh] but RETHROWS, so a mutation's caller can surface the failure
  /// instead of it being swallowed into the state and the mutation looking fine.
  Future<void> reload() async {
    state = AsyncValue.data(await _repo.list());
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
