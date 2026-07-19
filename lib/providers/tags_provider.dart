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
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> delete(String id) async {
    await _repo.delete(id);
    state = AsyncValue.data(_current.where((t) => t.id != id).toList());
  }
}

final tagsControllerProvider =
    StateNotifierProvider<TagsController, AsyncValue<List<Tag>>>((ref) => TagsController(ref));
