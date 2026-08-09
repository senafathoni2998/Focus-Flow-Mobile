import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../data/goal_repository.dart';
import '../models/goal.dart';
import '../core/offline/queue_flusher.dart';
import '../core/offline/queue_op.dart';
import 'providers.dart';
import 'write_queue_provider.dart';

class GoalsController extends StateNotifier<AsyncValue<List<Goal>>> {
  GoalsController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  GoalRepository get _repo => _ref.read(goalRepositoryProvider);
  QueueFlusher get _queue => _ref.read(queueFlusherProvider);
  List<Goal> get _current => state.value ?? const <Goal>[];

  /// The same staleness guard TasksController carries: a slow GET landing after
  /// an acked write would otherwise drop a goal the user just made.
  int _gen = 0;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await refresh();
  }

  Future<void> refresh() async {
    final gen = ++_gen;
    try {
      final fetched = await _repo.list();
      if (gen != _gen) return;
      state = AsyncValue.data(fetched);
    } catch (e, st) {
      if (gen != _gen) return;
      // Keep the cached list alongside the error. Replacing it outright collapsed
      // the collection to [], so a mutation whose follow-up refresh failed (a POST
      // that succeeded, then a Wi-Fi -> LTE handover) blanked the whole screen and
      // read as "save failed" — inviting a duplicate.
      state = state.hasValue
          ? AsyncValue<List<Goal>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  /// Like [refresh] but RETHROWS, so a mutation's caller can surface the failure
  /// instead of it being swallowed into the state and the mutation looking fine.
  Future<void> reload() async {
    final gen = ++_gen;
    final fetched = await _repo.list();
    if (gen != _gen) return;
    state = AsyncValue.data(fetched);
  }

  String _titleOf(String id) {
    for (final g in _current) {
      if (g.id == id) return g.title;
    }
    return '';
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Merge one delta-sync batch into server truth. Only reached after a drain,
  /// where the rows carry proper `progress` — the goal LIST endpoint serialises
  /// it and, since the sync-shape fix, so does the delta.
  void applyServerDelta(
    List<Map<String, dynamic>> rows,
    Set<String> deletedIds, {
    required bool full,
  }) {
    if (full) {
      _gen++;
      // `/sync` returns EVERY goal, where `getGoals` filters `status != archived`
      // — the list this controller holds. Without the filter a full sync would
      // resurrect archived goals onto the Goals tab.
      state = AsyncValue.data(
          rows.map(Goal.fromJson).where((g) => g.status != 'archived').toList());
      return;
    }
    if (rows.isEmpty && deletedIds.isEmpty) return;
    final list = [..._current];
    for (final row in rows) {
      final g = Goal.fromJson(row);
      final i = list.indexWhere((x) => x.id == g.id);
      // Archiving is a REMOVAL from this list, not an update to it. The row is
      // still alive on the server so it gets no tombstone, and upserting it
      // would leave an archived goal sitting on the board as a ghost.
      if (g.status == 'archived') {
        if (i >= 0) list.removeAt(i);
        continue;
      }
      if (i >= 0) {
        list[i] = g;
      } else {
        list.add(g);
      }
    }
    if (deletedIds.isNotEmpty) list.removeWhere((g) => deletedIds.contains(g.id));
    _gen++;
    state = AsyncValue.data(list);
  }

  Future<SubmitOutcome> create(Map<String, dynamic> body) async {
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.createGoal,
      target: '',
      assigns: newLocalId(),
      body: body,
      // Mandatory: POST /goals is idempotency-wrapped and creating a row is the
      // one inherently non-idempotent act.
      key: newIdempotencyKey(),
      summary: summaryFor(OpKind.createGoal, body, ''),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }

  Future<SubmitOutcome> update(String id, Map<String, dynamic> body) async {
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.updateGoal,
      target: id,
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      body: body,
      // No key and none needed: goalService writes `patch[k] = v[k]` over a
      // fixed allowlist — every field an absolute assignment, no delta anywhere,
      // so replaying the same body converges.
      summary: summaryFor(OpKind.updateGoal, body, _titleOf(id)),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }

  Future<SubmitOutcome> delete(String id) async {
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.deleteGoal,
      target: id,
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      summary: summaryFor(OpKind.deleteGoal, null, _titleOf(id)),
      createdAtMs: _now,
    );
    final outcome = (await _queue.submit(op)).outcome;
    if (outcome == SubmitOutcome.sent) {
      _gen++;
      state = AsyncValue.data(_current.where((g) => g.id != id).toList());
    }
    return outcome;
  }

  /// ONLINE-ONLY, still. See DECISIONS.md F7: the wire is safe, but offline the
  /// card would not move, so the user taps again and produces two ops with two
  /// different keys. An idempotency key defends against retry duplication, never
  /// against duplicate intent our own UI manufactured. The overlay now exists;
  /// what is still missing is a "+2 pending" badge on the card.
  Future<void> adjustProgress(String id, num delta) async {
    // A goal created offline has no server row yet, so its id is still a
    // `local_` placeholder and this would POST to /goals/local_…/progress — a
    // 404 the user could do nothing about. The id map resolves it once the
    // create has landed; until then, say so plainly instead.
    final resolved = _ref.read(queueIdMapProvider)[id] ?? id;
    if (isLocalId(resolved)) {
      throw ApiException(
          "This goal hasn't been saved to the server yet — adjust it once it syncs.");
    }
    await _repo.adjustProgress(resolved, delta);
    await reload();
  }

  Future<SubmitOutcome> setStatus(String id, String status) async {
    final body = <String, dynamic>{'status': status};
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.setGoalStatus,
      target: id,
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      body: body,
      // An absolute SET against a validated allowlist — replaying it is a no-op
      // by construction, so no key is needed.
      summary: summaryFor(OpKind.setGoalStatus, null, _titleOf(id)),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }
}

final goalsControllerProvider =
    StateNotifierProvider<GoalsController, AsyncValue<List<Goal>>>((ref) => GoalsController(ref));

/// Archived goals, fetched on demand (Settings / "show archived").
final archivedGoalsProvider = FutureProvider.autoDispose<List<Goal>>((ref) {
  return ref.watch(goalRepositoryProvider).archived();
});
