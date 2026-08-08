import '../../models/task.dart';
import 'queue_op.dart';

/// Folds pending writes over the last thing the server said.
///
/// Pure — this file imports the Task model and the op model, nothing else.
///
/// WHY AN OVERLAY RATHER THAN MUTATING THE CONTROLLER'S LIST. `TasksController`
/// keeps holding exactly what `GET /tasks` returned; the queue is folded on top
/// on every read. That makes "a refresh landing while a write is pending wipes
/// the optimistic row" structurally impossible instead of merely guarded against
/// — server truth is written *below* the overlay, so it cannot overwrite it. It
/// also makes rollback free: a failed op leaves the queue, the overlay is
/// recomputed, and the row reverts with no snapshot to restore and no chance of
/// discarding an unrelated write that landed in the meantime.

/// What the row badge shows.
enum PendingState { queued, sending, failed }

/// Build the task JSON the server would have returned for a create body.
///
/// Server-side values are deliberately NOT guessed: `order` (the server assigns
/// `max(order)+10`), `priorityRank`, generated tag ids and reminder ids. Guessing
/// them would put a made-up value on screen that the real response then silently
/// contradicts.
Map<String, dynamic> taskJsonFromCreateBody(
  String localId,
  Map<String, dynamic> body,
) {
  final Object? rawTags = body['tags'];
  final Object? rawReminders = body['reminders'];
  final Object? rawRecurrence = body['recurrence'];

  return <String, dynamic>{
    'id': localId,
    'title': body['title'] is String ? body['title'] as String : '',
    'description': body['description'],
    'status': 'todo',
    'priority': body['priority'] is String ? body['priority'] as String : 'medium',
    'dueDate': body['dueDate'],
    'startDate': body['startDate'],
    'isAllDay': true,
    'completedAt': null,
    'order': null,
    'priorityRank': null,
    'timeEstimateMin': body['timeEstimateMin'],
    'estimatedPomos': body['estimatedPomos'],
    'actualMin': 0,
    'parentTaskId': body['parentTaskId'],
    'listId': body['listId'],
    'goalId': body['goalId'],
    // Names only — the server mints the ids. Using the name as the id would put
    // a fake id on screen; using the name for BOTH keeps the chip rendering and
    // is replaced wholesale the moment the real task arrives.
    'tags': rawTags is List
        ? rawTags
            .whereType<String>()
            .map((String n) => <String, dynamic>{'id': n, 'name': n, 'color': null})
            .toList()
        : <Map<String, dynamic>>[],
    'recurrence': rawRecurrence is String
        ? <String, dynamic>{'freq': rawRecurrence, 'interval': null}
        : null,
    'reminders': rawReminders is List
        ? rawReminders
            .whereType<String>()
            .map((String iso) => <String, dynamic>{'id': iso, 'triggerAt': iso})
            .toList()
        : <Map<String, dynamic>>[],
  };
}

/// Apply a PATCH body to a serialized task, mirroring the server's `updateTask`.
///
/// Only keys PRESENT in the body change anything — that is what makes a partial
/// edit partial. The special cases below are the server's, not ours:
///   * `dueDate: ''` / `startDate: ''` clears the date (the editor sends `''`,
///     not null, precisely because null would mean "leave it alone").
///   * `description` / `listId` / `goalId` set to null clears the field.
///   * `tags` and `reminders` are FULL REPLACEMENTS, never merges.
///   * `recurrence: null` removes the rule.
Map<String, dynamic> applyPatchToTaskJson(
  Map<String, dynamic> task,
  Map<String, dynamic> body,
) {
  final Map<String, dynamic> out = Map<String, dynamic>.from(task);

  if (body.containsKey('title') && body['title'] is String) {
    out['title'] = body['title'];
  }
  if (body.containsKey('description')) out['description'] = body['description'];
  if (body.containsKey('priority') && body['priority'] is String) {
    out['priority'] = body['priority'];
  }
  if (body.containsKey('status') && body['status'] is String) {
    out['status'] = body['status'];
  }
  if (body.containsKey('listId')) out['listId'] = body['listId'];
  if (body.containsKey('goalId')) out['goalId'] = body['goalId'];
  if (body.containsKey('parentTaskId')) out['parentTaskId'] = body['parentTaskId'];
  if (body.containsKey('timeEstimateMin')) {
    out['timeEstimateMin'] = body['timeEstimateMin'];
  }
  if (body.containsKey('estimatedPomos')) {
    out['estimatedPomos'] = body['estimatedPomos'];
  }

  for (final String dateKey in const <String>['dueDate', 'startDate']) {
    if (!body.containsKey(dateKey)) continue;
    final Object? v = body[dateKey];
    out[dateKey] = (v is String && v.isEmpty) ? null : v;
  }

  if (body.containsKey('tags')) {
    final Object? raw = body['tags'];
    out['tags'] = raw is List
        ? raw
            .whereType<String>()
            .map((String n) => <String, dynamic>{'id': n, 'name': n, 'color': null})
            .toList()
        : <Map<String, dynamic>>[];
  }

  if (body.containsKey('reminders')) {
    final Object? raw = body['reminders'];
    out['reminders'] = raw is List
        ? raw
            .whereType<String>()
            .map((String iso) => <String, dynamic>{'id': iso, 'triggerAt': iso})
            .toList()
        : <Map<String, dynamic>>[];
  }

  if (body.containsKey('recurrence')) {
    final Object? raw = body['recurrence'];
    out['recurrence'] = raw is String
        ? <String, dynamic>{'freq': raw, 'interval': null}
        : null;
  }

  return out;
}

/// Fold the queue over the server's list, in `seq` order.
///
/// An op naming an id that is not in the list is a NO-OP, never a throw: the
/// task may have been deleted from another device, and a crash here would take
/// out the whole task screen for a bookkeeping mismatch.
List<Task> applyQueue(
  List<Task> server,
  List<QueuedOp> ops,
  Map<String, String> idMap,
) {
  // Ops for other entities are filtered out rather than defaulted past. A list
  // op folded through here would find no matching row and quietly do nothing,
  // which reads as working; dropping it explicitly says what is happening.
  final List<QueuedOp> ordered = ops
      .where((QueuedOp o) => o.entity == OpEntity.task)
      .toList()
    ..sort((QueuedOp a, QueuedOp b) => a.seq.compareTo(b.seq));
  if (ordered.isEmpty) return server;

  // Work in JSON so a PATCH body can be applied with the server's own semantics
  // rather than a hand-written 20-field copyWith.
  final List<Map<String, dynamic>> rows =
      server.map((Task t) => t.toJson()).toList();

  int indexOf(String id) {
    final String mapped = idMap[id] ?? id;
    for (int i = 0; i < rows.length; i++) {
      final Object? rowId = rows[i]['id'];
      if (rowId == id || rowId == mapped) return i;
    }
    return -1;
  }

  // Each case body is braced: Dart gives all cases of one switch a SHARED
  // scope, so two cases declaring `body` would collide.
  for (final QueuedOp op in ordered) {
    // A DEAD op is folded for what the user TYPED, never for a server state
    // change that did not happen.
    //
    // Dead ops are in this list on purpose: a task someone wrote offline whose
    // create the server then rejected must not vanish from the screen. But the
    // same blanket fold made a FAILED delete keep the row hidden and a FAILED
    // complete keep it ticked — the app asserting two things about the server
    // that are simply false, with the row's own badge the only hint. A create
    // or an edit still shows, because that is the user's own text; a removal or
    // a status change does not, because there is nothing of theirs to preserve
    // and the claim is wrong.
    final bool isDead = op.reason != null;

    switch (op.kind) {
      case OpKind.createTask:
        {
          final String? localId = op.assigns;
          final Map<String, dynamic>? body = op.body;
          if (localId == null || body == null) break;
          // If the create already landed and a refresh brought back the real
          // row, adding the shadow again would show the task twice.
          if (indexOf(localId) >= 0) break;
          rows.add(taskJsonFromCreateBody(localId, body));
        }

      case OpKind.updateTask:
        {
          final int i = indexOf(op.target);
          final Map<String, dynamic>? body = op.body;
          if (i < 0 || body == null) break;
          rows[i] = applyPatchToTaskJson(rows[i], body);
        }

      case OpKind.completeTask:
        {
          if (isDead) break; // the server never recorded it
          final int i = indexOf(op.target);
          if (i < 0) break;
          final Map<String, dynamic> row = Map<String, dynamic>.from(rows[i]);
          row['status'] = 'completed';
          // Recurrence roll-forward is deliberately NOT simulated — the rule
          // lives server-side with its anchorMode and completedCount, so the
          // next due date cannot be computed here. The row shows completed;
          // when the server answers it comes back at its next date and the
          // existing "moved to its next date" notice fires.
          row['completedAt'] ??= DateTime.now().toIso8601String();
          rows[i] = row;
        }

      case OpKind.deleteTask:
        {
          if (isDead) break; // the row is still on the server; show it again
          final int i = indexOf(op.target);
          if (i < 0) break;
          final Object? goneId = rows[i]['id'];
          rows.removeAt(i);
          // The server cascades subtasks; drop direct children locally too —
          // the same rule the old optimistic delete used.
          rows.removeWhere(
              (Map<String, dynamic> r) => r['parentTaskId'] == goneId);
        }

      case OpKind.createList:
      case OpKind.deleteList:
      case OpKind.createSession:
      case OpKind.completeSession:
      case OpKind.cancelSession:
        // Filtered out above; listed so a new entity cannot be added without
        // the compiler asking what this overlay should do about it.
        break;
    }
  }

  return rows.map(Task.fromJson).toList();
}

/// Which rows get which badge.
///
/// Dead ops are included by the caller, so a task the user typed offline and the
/// server then rejected keeps its row and turns amber instead of vanishing.
Map<String, PendingState> pendingStateByEntityId(
  OpEntity entity,
  List<QueuedOp> pending,
  List<QueuedOp> dead,
  String? inFlightOpId,
  Map<String, String> idMap,
) {
  final Map<String, PendingState> out = <String, PendingState>{};

  void mark(QueuedOp op, PendingState state) {
    // One map per entity. Tasks and lists have separate id namespaces, so a
    // single flat map would put a list id where a task lookup could find it.
    if (op.entity != entity) return;
    final String id = op.assigns ?? op.target;
    if (id.isEmpty) return;
    // `failed` outranks `sending`, which outranks `queued`: a row with one dead
    // op and one waiting op is a problem the user needs to see.
    final PendingState? existing = out[id];
    if (existing == PendingState.failed) return;
    if (existing == PendingState.sending && state == PendingState.queued) return;
    out[id] = state;
    final String? mapped = idMap[id];
    if (mapped != null) out[mapped] = state;
  }

  for (final QueuedOp op in pending) {
    mark(op, op.id == inFlightOpId ? PendingState.sending : PendingState.queued);
  }
  for (final QueuedOp op in dead) {
    mark(op, PendingState.failed);
  }
  return out;
}
