import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_exception.dart';
import '../core/offline/queue_flusher.dart';
import '../core/offline/queue_op.dart';
import '../data/habit_repository.dart';
import '../models/habit.dart';
import 'providers.dart';
import 'write_queue_provider.dart';

/// Server truth for habits. Pending writes are folded on top in
/// [allHabitsProvider] — every habit reader watches that, never this directly.
class HabitsController extends StateNotifier<AsyncValue<List<Habit>>> {
  HabitsController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  HabitRepository get _repo => _ref.read(habitRepositoryProvider);
  QueueFlusher get _queue => _ref.read(queueFlusherProvider);
  List<Habit> get _current => state.value ?? const <Habit>[];

  /// The same staleness guard TasksController and GoalsController carry: a slow
  /// GET landing after an acked write would otherwise drop a habit just made.
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
          ? AsyncValue<List<Habit>>.error(e, st).copyWithPrevious(state)
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

  String _nameOf(String id) {
    for (final h in _current) {
      if (h.id == id) return h.name;
    }
    return '';
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  /// Merge one delta-sync batch into server truth.
  ///
  /// Only reached after a drain, where the rows carry a proper `stats` — the
  /// habit LIST endpoint attaches it and, since the sync-shape fix, so does the
  /// delta. That is precisely why an individual ack is NOT folded: see the habit
  /// case in write_queue_provider's onServerRow.
  void applyServerDelta(
    List<Map<String, dynamic>> rows,
    Set<String> deletedIds, {
    required bool full,
  }) {
    if (full) {
      _gen++;
      // `/sync` returns EVERY habit including archived ones, where `GET /habits`
      // returns only the active list this controller holds. Without the filter a
      // full sync would resurrect archived habits onto the Habits tab.
      state = AsyncValue.data(rows
          .map(Habit.fromJson)
          .where((h) => !h.archived)
          .toList());
      return;
    }
    if (rows.isEmpty && deletedIds.isEmpty) return;
    final list = [..._current];
    for (final row in rows) {
      final h = Habit.fromJson(row);
      final i = list.indexWhere((x) => x.id == h.id);
      // An archived habit is a REMOVAL from this list, not an update to it. It
      // is still a live row on the server, so it gets no tombstone and would
      // otherwise sit here as a ghost until the next full fetch.
      if (h.archived) {
        if (i >= 0) list.removeAt(i);
        continue;
      }
      if (i >= 0) {
        list[i] = h;
      } else {
        list.add(h);
      }
    }
    if (deletedIds.isNotEmpty) list.removeWhere((h) => deletedIds.contains(h.id));
    _gen++;
    state = AsyncValue.data(list);
  }

  Future<SubmitOutcome> create(Map<String, dynamic> body) async {
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.createHabit,
      target: '',
      assigns: newLocalId(),
      body: body,
      // Mandatory: POST /habits is idempotency-wrapped and creating a row is the
      // one inherently non-idempotent act.
      key: newIdempotencyKey(),
      summary: summaryFor(OpKind.createHabit, body, ''),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }

  Future<SubmitOutcome> update(String id, Map<String, dynamic> body) async {
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.updateHabit,
      target: id,
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      body: body,
      // No key and none needed: habitService parses with `habitSchema.partial()`
      // and writes exactly the keys present, every one an absolute assignment —
      // no delta, no counter, no append anywhere in the habit edit path.
      summary: summaryFor(OpKind.updateHabit, body, _nameOf(id)),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }

  Future<SubmitOutcome> delete(String id) async {
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.deleteHabit,
      target: id,
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      summary: summaryFor(OpKind.deleteHabit, null, _nameOf(id)),
      createdAtMs: _now,
    );
    final outcome = (await _queue.submit(op)).outcome;
    if (outcome == SubmitOutcome.sent) {
      _gen++;
      state = AsyncValue.data(_current.where((h) => h.id != id).toList());
    }
    return outcome;
  }

  Future<SubmitOutcome> archive(String id) => _setArchived(id, true);

  /// Bring an archived habit back. `archive(id, false)` was always supported by
  /// the API; there was simply no way to reach it, because nothing could list an
  /// archived habit in the first place.
  Future<SubmitOutcome> unarchive(String id) => _setArchived(id, false);

  /// One op kind for both directions, because the endpoint is one absolute SET.
  ///
  /// Replaying it is a no-op by construction, so it carries no idempotency key.
  Future<SubmitOutcome> _setArchived(String id, bool archived) async {
    final body = <String, dynamic>{'archived': archived};
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.setHabitArchived,
      target: id,
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      body: body,
      summary: summaryFor(OpKind.setHabitArchived, body, _nameOf(id)),
      createdAtMs: _now,
    );
    final outcome = (await _queue.submit(op)).outcome;
    if (outcome == SubmitOutcome.sent && archived) {
      _gen++;
      state = AsyncValue.data(_current.where((h) => h.id != id).toList());
    }
    return outcome;
  }

  /// Check in [delta] (default +1) today. ONLINE-ONLY, still — see DECISIONS.md
  /// F7. The wire is safe (the route is key-wrapped), but offline the tile would
  /// not move, so the user taps again and produces two ops with two DIFFERENT
  /// keys. An idempotency key defends against retry duplication, never against
  /// duplicate intent our own UI manufactured. What is still missing is a
  /// "+2 pending" badge on the card.
  Future<void> checkIn(String id, {int delta = 1}) async {
    // A habit created offline has no server row yet, so its id is still a
    // `local_` placeholder and this would POST to /habits/local_…/checkin — a
    // 404 the user could not act on. The id map resolves it once the create has
    // landed; until then, say so plainly.
    final resolved = _ref.read(queueIdMapProvider)[id] ?? id;
    if (isLocalId(resolved)) {
      throw ApiException(
          "This habit hasn't been saved to the server yet — check in once it syncs.");
    }
    final h = await _repo.checkIn(resolved, delta: delta);
    _gen++;
    state = AsyncValue.data(
        [for (final x in _current) if (x.id == resolved) h else x]);
  }
}

final habitsControllerProvider =
    StateNotifierProvider<HabitsController, AsyncValue<List<Habit>>>((ref) => HabitsController(ref));

/// Archived habits, fetched on demand by the Archived screen.
final archivedHabitsProvider = FutureProvider.autoDispose<List<Habit>>((ref) {
  return ref.watch(habitRepositoryProvider).archived();
});
