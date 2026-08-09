import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/date_format.dart';
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

  /// Fold one acked row into server truth, leaving the overlay to be recomputed.
  ///
  /// Only a CHECK-IN reaches this — see the habit case in write_queue_provider.
  void upsertFromServer(Map<String, dynamic> row) {
    final h = Habit.fromJson(row);
    if (h.id.isEmpty) return;
    final list = [..._current];
    final i = list.indexWhere((x) => x.id == h.id);
    if (i >= 0) {
      list[i] = h;
    } else if (!h.archived) {
      list.add(h);
    }
    _gen++;
    state = AsyncValue.data(list);
  }

  /// Check in [delta] (default +1) for today.
  ///
  /// QUEUED, finally. The refusal was never about the wire — the route is
  /// key-wrapped — it was that offline the tile did not move, so the user tapped
  /// again and produced two ops with two DIFFERENT keys. The overlay now moves
  /// it, and consecutive taps merge into one op, so that second tap cannot
  /// happen for the reason it used to.
  Future<SubmitOutcome> checkIn(String id, {int delta = 1}) async {
    // THE DAY IS FROZEN HERE, and it is the whole reason this needed care. The
    // server defaults an absent `date` to ITS today, so a tap at 23:50 that
    // sends at 00:05 would be recorded against tomorrow — Monday goes unchecked
    // and Tuesday counts twice, quietly breaking a streak the user did earn.
    // Same defect the focus timer's frozen startTime exists to prevent.
    final body = <String, dynamic>{
      'delta': delta,
      'date': Dates.ymd(DateTime.now()),
    };
    final op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.checkInHabit,
      target: id,
      // A habit created in this same offline stretch is checkable in: the queue
      // blocks this op until the create resolves and then substitutes the real
      // id. That is why the card no longer disables the control.
      deps: isLocalId(id) ? <String>[id] : const <String>[],
      body: body,
      // MANDATORY. This is a delta: a replayed +1 is a check-in the user never
      // made, and it feeds streaks and the month rate from there on.
      key: newIdempotencyKey(),
      summary: summaryFor(OpKind.checkInHabit, body, _nameOf(id)),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }
}

final habitsControllerProvider =
    StateNotifierProvider<HabitsController, AsyncValue<List<Habit>>>((ref) => HabitsController(ref));

/// Archived habits, fetched on demand by the Archived screen.
final archivedHabitsProvider = FutureProvider.autoDispose<List<Habit>>((ref) {
  return ref.watch(habitRepositoryProvider).archived();
});
