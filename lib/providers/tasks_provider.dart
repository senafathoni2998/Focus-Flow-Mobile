import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/queue_flusher.dart';
import '../core/offline/queue_op.dart';
import '../data/task_repository.dart';
import '../models/task.dart';
import 'providers.dart';
import 'write_queue_provider.dart';

/// Holds exactly what `GET /tasks` last returned — SERVER TRUTH, nothing else.
///
/// Pending writes are folded on top downstream, in `allTasksProvider`. Keeping
/// them out of here is what makes a refresh landing mid-write harmless: it
/// replaces the layer UNDER the overlay, so it cannot erase an optimistic row.
/// It also makes rollback free — a failed op leaves the queue, the overlay is
/// recomputed, and nothing has to remember a snapshot to restore.
class TasksController extends StateNotifier<AsyncValue<List<Task>>> {
  TasksController(this._ref) : super(const AsyncValue.loading()) {
    load();
  }

  final Ref _ref;
  TaskRepository get _repo => _ref.read(taskRepositoryProvider);
  QueueFlusher get _queue => _ref.read(queueFlusherProvider);
  List<Task> get _current => state.value ?? const <Task>[];

  /// Bumped by every refresh AND every server write. A list response is only
  /// applied if no newer one happened while it was in flight.
  ///
  /// Without this, tapping the Tasks tab fires a fire-and-forget GET; ticking a
  /// task off before it lands meant the stale snapshot overwrote the result, the
  /// checkbox popped back to unchecked, and tapping again completed the task a
  /// SECOND time — rolling a recurring task two occurrences forward and
  /// double-incrementing recurrence.completedCount on the server.
  int _gen = 0;

  Future<void> load() async {
    state = const AsyncValue.loading();
    await refresh();
  }

  Future<void> refresh() async {
    final int gen = ++_gen;
    try {
      final List<Task> tasks = await _repo.list();
      if (gen != _gen) return; // superseded
      state = AsyncValue.data(tasks);
    } catch (e, st) {
      if (gen != _gen) return;
      // Keep whatever list we already had: replacing it with a bare error state
      // collapsed `_current` to [], so a subsequent create looked like it had
      // wiped every task.
      state = state.hasValue
          ? AsyncValue<List<Task>>.error(e, st).copyWithPrevious(state)
          : AsyncValue.error(e, st);
    }
  }

  /// Fold one authoritative task into server truth.
  ///
  /// Called by the flusher the instant an op is acked, in the same turn that op
  /// leaves the queue — so the row is never missing from both layers at once.
  void upsertFromServer(Map<String, dynamic> json) {
    final Task t = Task.fromJson(json);
    final List<Task> list = <Task>[..._current];
    final int i = list.indexWhere((Task x) => x.id == t.id);
    if (i >= 0) {
      list[i] = t;
    } else {
      list.add(t);
    }
    _gen++;
    state = AsyncValue.data(list);
  }

  String _titleOf(String id) {
    for (final Task t in _current) {
      if (t.id == id) return t.title;
    }
    return '';
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  List<String> _depsFor(String target, Map<String, dynamic>? body) {
    final List<String> deps = <String>[];
    if (target.isNotEmpty && isLocalId(target)) deps.add(target);
    final Object? parent = body == null ? null : body['parentTaskId'];
    if (parent is String && isLocalId(parent) && !deps.contains(parent)) {
      deps.add(parent);
    }
    return deps;
  }

  /// Create a task. Returns [SubmitOutcome.deferred] when it was safely queued
  /// rather than sent, so the caller can say so instead of implying it saved.
  Future<SubmitOutcome> create(Map<String, dynamic> body) async {
    final String localId = newLocalId();
    final QueuedOp op = QueuedOp(
      id: newOpId(),
      seq: 0, // assigned by the flusher
      kind: OpKind.createTask,
      target: '',
      assigns: localId,
      deps: _depsFor('', body),
      body: body,
      // MANDATORY here. Creating a row is the one thing that is inherently not
      // idempotent, so a send whose response is lost would otherwise create the
      // task twice on retry.
      key: newIdempotencyKey(),
      summary: summaryFor(OpKind.createTask, body, ''),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }

  Future<SubmitOutcome> update(String id, Map<String, dynamic> body) async {
    final QueuedOp op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.updateTask,
      target: id,
      deps: _depsFor(id, body),
      body: body,
      // No key: PATCH /tasks/:id does not opt into idempotency and does not need
      // to. Every field is an absolute assignment, tags and reminders are full
      // replacements, and completedAt is `existing ?? now` — so replaying the
      // same body converges on the same row.
      summary: summaryFor(OpKind.updateTask, body, _titleOf(id)),
      createdAtMs: _now,
    );
    return (await _queue.submit(op)).outcome;
  }

  /// Complete (or roll a recurring task forward).
  ///
  /// `recurred` is only known when the write actually reached the server. Queued
  /// offline it is false and no "moved to its next date" notice appears — the
  /// honest answer, since the next occurrence is computed server-side from the
  /// rule's anchorMode and completedCount and cannot be guessed here.
  Future<({SubmitOutcome outcome, bool recurred})> complete(String id) async {
    final QueuedOp op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.completeTask,
      target: id,
      deps: _depsFor(id, null),
      // MANDATORY. For a recurring task the server rolls the row forward AND
      // increments completedCount, so a bare retry would skip an occurrence the
      // user never did.
      key: newIdempotencyKey(),
      summary: summaryFor(OpKind.completeTask, null, _titleOf(id)),
      createdAtMs: _now,
    );
    final ({SubmitOutcome outcome, Map<String, dynamic>? response}) r =
        await _queue.submit(op);
    final Object? recurred = r.response?['recurred'];
    return (outcome: r.outcome, recurred: recurred is bool && recurred);
  }

  Future<SubmitOutcome> delete(String id) async {
    final QueuedOp op = QueuedOp(
      id: newOpId(),
      seq: 0,
      kind: OpKind.deleteTask,
      target: id,
      deps: _depsFor(id, null),
      // No key. deleteTask 404s when the row is gone and the queue treats that
      // as success: ids are server cuids and are never reused, so a 404 can only
      // mean "already deleted".
      summary: summaryFor(OpKind.deleteTask, null, _titleOf(id)),
      createdAtMs: _now,
    );
    final SubmitOutcome outcome = (await _queue.submit(op)).outcome;
    if (outcome == SubmitOutcome.sent) {
      // The server cascades subtasks and the row is genuinely gone, so drop it
      // from server truth now rather than waiting for the next refresh.
      _gen++;
      state = AsyncValue.data(_current
          .where((Task t) => t.id != id && t.parentTaskId != id)
          .toList());
    }
    return outcome;
  }
}

final tasksControllerProvider =
    StateNotifierProvider<TasksController, AsyncValue<List<Task>>>(
        (ref) => TasksController(ref));
