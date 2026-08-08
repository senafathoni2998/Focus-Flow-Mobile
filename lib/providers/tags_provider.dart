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

  /// Merge one delta-sync batch. Tags matter here because they are created as a
  /// SIDE EFFECT of writing a task's `tags` list — so draining the queue can
  /// mint tags the drawer has never seen, and the overlay only knows them by
  /// name until the real rows arrive.
  void applyServerDelta(
    List<Map<String, dynamic>> rows,
    Set<String> deletedIds, {
    required bool full,
  }) {
    if (full) {
      state = AsyncValue.data(rows.map(Tag.fromJson).toList());
      return;
    }
    if (rows.isEmpty && deletedIds.isEmpty) return;

    final list = [..._current];
    for (final row in rows) {
      final t = Tag.fromJson(row);
      final i = list.indexWhere((x) => x.id == t.id);
      if (i >= 0) {
        list[i] = t;
      } else {
        list.add(t);
      }
    }
    if (deletedIds.isNotEmpty) {
      list.removeWhere((t) => deletedIds.contains(t.id));
    }
    state = AsyncValue.data(list);
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = AsyncValue.data(_current.where((t) => t.id != id).toList());
  }
}

final tagsControllerProvider =
    StateNotifierProvider<TagsController, AsyncValue<List<Tag>>>((ref) => TagsController(ref));
