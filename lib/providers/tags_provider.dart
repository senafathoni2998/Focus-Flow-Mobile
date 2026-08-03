import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/tag_repository.dart';
import '../models/task.dart';
import 'providers.dart';

class TagsController extends StateNotifier<AsyncValue<List<Tag>>> {
  TagsController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  TagRepository get _repo => _ref.read(tagRepositoryProvider);
  List<Tag> get _current => state.value ?? const [];

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
          ? AsyncValue<List<Tag>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  /// Like [refresh] but RETHROWS, so a mutation's caller can surface the failure
  /// instead of it being swallowed into the state and the mutation looking fine.
  Future<void> reload() async {
    state = AsyncValue.data(await _repo.list());
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = AsyncValue.data(_current.where((t) => t.id != id).toList());
  }
}

final tagsControllerProvider =
    StateNotifierProvider<TagsController, AsyncValue<List<Tag>>>((ref) => TagsController(ref));
