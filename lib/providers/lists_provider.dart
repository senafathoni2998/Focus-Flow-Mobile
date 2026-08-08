import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/queue_flusher.dart';
import '../core/offline/queue_op.dart';
import '../data/list_repository.dart';
import '../models/task_list.dart';
import 'providers.dart';
import 'write_queue_provider.dart';

/// Holds exactly what `GET /lists` last returned — SERVER TRUTH, nothing else.
/// Pending creates and deletes are folded on top in [allListsProvider].
class ListsController extends StateNotifier<AsyncValue<List<TaskList>>> {
  ListsController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  ListRepository get _repo => _ref.read(listRepositoryProvider);
  QueueFlusher get _queue => _ref.read(queueFlusherProvider);
  List<TaskList> get _current => state.value ?? const [];

  /// Bumped by every refresh AND every server write, so a list response is only
  /// applied if nothing newer happened while it was in flight.
  ///
  /// TasksController has carried this from the start; lists did not, and once
  /// the queue began acking rows into `upsertFromServer` the gap became real: a
  /// GET /lists fired on the Tasks tab could land AFTER an acked create and
  /// overwrite it, dropping a list the user had just made back out of the
  /// drawer until the next refresh.
  int _gen = 0;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await refresh();
  }

  Future<void> refresh() async {
    final int gen = ++_gen;
    try {
      final List<TaskList> fetched = await _repo.list();
      if (gen != _gen) return; // superseded
      state = AsyncValue.data(fetched);
    } catch (e, st) {
      if (gen != _gen) return;
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
    final int gen = ++_gen;
    final List<TaskList> fetched = await _repo.list();
    if (gen != _gen) return;
    state = AsyncValue.data(fetched);
  }

  /// Fold one authoritative list row into server truth, in the same turn the op
  /// leaves the queue — so the row is never missing from both layers at once.
  void upsertFromServer(Map<String, dynamic> json) {
    final l = TaskList.fromJson(json);
    final list = [..._current];
    final i = list.indexWhere((x) => x.id == l.id);
    if (i >= 0) {
      list[i] = l;
    } else {
      list.add(l);
    }
    _gen++;
    state = AsyncValue.data(list);
  }

  /// Merge one delta-sync batch into server truth. See the note on the task
  /// equivalent — same rules, same reason it sits under the overlay.
  void applyServerDelta(
    List<Map<String, dynamic>> rows,
    Set<String> deletedIds, {
    required bool full,
  }) {
    if (full) {
      _gen++;
      state = AsyncValue.data(rows.map(TaskList.fromJson).toList());
      return;
    }
    if (rows.isEmpty && deletedIds.isEmpty) return;

    final list = [..._current];
    for (final row in rows) {
      final l = TaskList.fromJson(row);
      final i = list.indexWhere((x) => x.id == l.id);
      if (i >= 0) {
        list[i] = l;
      } else {
        list.add(l);
      }
    }
    if (deletedIds.isNotEmpty) {
      list.removeWhere((l) => deletedIds.contains(l.id));
    }
    _gen++;
    state = AsyncValue.data(list);
  }

  String _nameOf(String id) {
    for (final l in _current) {
      if (l.id == id) return l.name;
    }
    return '';
  }

  /// Create a list. Returns [SubmitOutcome.deferred] when it was safely queued
  /// rather than sent, so the caller can say so instead of implying it saved.
  ///
  /// The body is built HERE, at the UI layer, rather than in the repository —
  /// the repository's `create` drops a null colour entirely, and the queue's
  /// rule is that a persisted body is stored verbatim as the UI built it.
  Future<SubmitOutcome> create(String name, {String? color}) async {
    final body = <String, dynamic>{
      'name': name,
      if (color != null) 'color': color,
    };
    final op = QueuedOp(
      id: newOpId(),
      seq: 0, // assigned by the flusher
      kind: OpKind.createList,
      target: '',
      assigns: newLocalId(),
      body: body,
      // MANDATORY, same as createTask: creating a row is the one inherently
      // non-idempotent act, so a lost response would otherwise make two lists.
      key: newIdempotencyKey(),
      summary: summaryFor(OpKind.createList, body, ''),
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    return (await _queue.submit(op)).outcome;
  }

  /// ONLINE-ONLY, and it has no caller anywhere in the app — see DECISIONS.md
  /// F7. Kept because the endpoint exists; queueing it would build an offline
  /// path for something the UI cannot do online either.
  Future<void> update(String id, {String? name, String? color}) async {
    final l = await _repo.update(id, name: name, color: color);
    state = AsyncValue.data([for (final x in _current) if (x.id == id) l else x]);
  }

  Future<SubmitOutcome> delete(String id) async {
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.deleteList,
      target: id,
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      // No key. The queue treats a 404 on any delete as success: ids are server
      // cuids and are never reused, so it can only mean "already deleted".
      summary: summaryFor(OpKind.deleteList, null, _nameOf(id)),
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final outcome = (await _queue.submit(op)).outcome;
    if (outcome == SubmitOutcome.sent) {
      _gen++;
      state = AsyncValue.data(_current.where((l) => l.id != id).toList());
    }
    return outcome;
  }
}

final listsControllerProvider =
    StateNotifierProvider<ListsController, AsyncValue<List<TaskList>>>((ref) => ListsController(ref));
