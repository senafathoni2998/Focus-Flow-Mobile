import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/saved_filter_repository.dart';
import '../models/saved_filter.dart';
import 'providers.dart';

class SavedFiltersController extends StateNotifier<AsyncValue<List<SavedFilter>>> {
  SavedFiltersController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  SavedFilterRepository get _repo => _ref.read(savedFilterRepositoryProvider);
  List<SavedFilter> get _current => state.value ?? const [];

  Future<void> load() async {
    state = const AsyncValue.loading();
    await refresh();
  }

  Future<void> refresh() async {
    try {
      state = AsyncValue.data(await _repo.list());
    } catch (e, st) {
      // Preserve the cached list alongside the error, like every other
      // controller — a failed refresh must not look like "you have none".
      state = state.hasValue
          ? AsyncValue<List<SavedFilter>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  /// Rethrows so the caller can surface a duplicate-name 409 rather than it
  /// disappearing into the state.
  Future<SavedFilter> create({required String name, required String query}) async {
    final created = await _repo.create(name: name, query: query);
    if (state.hasValue) state = AsyncValue.data([..._current, created]);
    return created;
  }

  Future<void> delete(String id) async {
    final removed = _current.where((f) => f.id == id).toList();
    state = AsyncValue.data(_current.where((f) => f.id != id).toList());
    try {
      await _repo.delete(id);
    } catch (e) {
      // Re-insert only what was removed, so a mutation that landed meanwhile
      // is not discarded along with the rollback.
      final ids = {for (final f in _current) f.id};
      state = AsyncValue.data([..._current, ...removed.where((f) => !ids.contains(f.id))]);
      rethrow;
    }
  }
}

final savedFiltersControllerProvider =
    StateNotifierProvider<SavedFiltersController, AsyncValue<List<SavedFilter>>>(
        (ref) => SavedFiltersController(ref));
