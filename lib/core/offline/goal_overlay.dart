import '../../models/goal.dart';
import 'queue_op.dart';

/// The goals overlay — same shape and same reason as the task and list ones:
/// server truth lives underneath, so a refresh cannot erase a pending write.
///
/// WHAT IS NOT PROJECTED. `progress`, `taskTotal` and `taskCompleted` are
/// computed server-side and are carried through UNCHANGED by every fold here.
/// Recomputing a percent locally would mean reimplementing goalStats.ts, and a
/// tasks-derived goal's percent additionally depends on tasks the goal overlay
/// cannot see. Showing the last known figure while an edit is pending is
/// honest; showing a guessed one is not.
///
/// `POST /goals/:id/progress` is still NOT queued — see DECISIONS.md F7. It is a
/// DELTA, and the reason it is refused was never the wire: offline the card
/// would not move, so the user taps again and produces two ops with two
/// different keys. That needs a pending-delta badge, not just this overlay.

/// Build the goal JSON the server would have returned for a create body.
Map<String, dynamic> goalJsonFromCreateBody(
  String localId,
  Map<String, dynamic> body,
) {
  return <String, dynamic>{
    'id': localId,
    'title': body['title'] is String ? body['title'] as String : '',
    'description': body['description'],
    'icon': body['icon'] ?? '🎯',
    'color': body['color'] ?? 'primary',
    'progressType': body['progressType'] ?? 'manual',
    'targetValue': body['targetValue'],
    'currentValue': body['currentValue'] ?? 0,
    'unit': body['unit'],
    'manualProgress': body['manualProgress'] ?? 0,
    'targetDate': body['targetDate'],
    'status': 'active',
    // Server-assigned; guessing would put a number on screen the real response
    // then contradicts.
    'order': null,
    'taskTotal': null,
    'taskCompleted': null,
    // Deliberately absent: Goal.fromJson substitutes GoalProgress.empty(), and
    // 0% is the honest reading for a goal the server has never seen.
    'progress': null,
  };
}

/// Apply a PATCH body, mirroring goalService's absolute-assignment allowlist.
Map<String, dynamic> applyPatchToGoalJson(
  Map<String, dynamic> goal,
  Map<String, dynamic> body,
) {
  final Map<String, dynamic> out = Map<String, dynamic>.from(goal);
  // The server writes `patch[k] = v[k]` over exactly these keys, so the overlay
  // does the same — no delta, no counter, no append anywhere in the goal path.
  for (final String k in const <String>[
    'title',
    'description',
    'icon',
    'color',
    'progressType',
    'targetValue',
    'currentValue',
    'unit',
    'manualProgress',
    'status',
    'targetDate',
  ]) {
    if (body.containsKey(k)) out[k] = body[k];
  }
  return out;
}

List<Goal> applyGoalQueue(
  List<Goal> server,
  List<QueuedOp> ops,
  Map<String, String> idMap,
) {
  final List<QueuedOp> ordered = ops
      .where((QueuedOp o) => o.entity == OpEntity.goal)
      .toList()
    ..sort((QueuedOp a, QueuedOp b) => a.seq.compareTo(b.seq));
  if (ordered.isEmpty) return server;

  final List<Map<String, dynamic>> rows =
      server.map((Goal g) => g.toJson()).toList();

  int indexOf(String id) {
    final String mapped = idMap[id] ?? id;
    for (int i = 0; i < rows.length; i++) {
      final Object? rowId = rows[i]['id'];
      if (rowId == id || rowId == mapped) return i;
    }
    return -1;
  }

  for (final QueuedOp op in ordered) {
    // A dead op is folded for what the user TYPED, never for a server state
    // change that did not happen. See the note in task_overlay.dart.
    final bool isDead = op.reason != null;

    switch (op.kind) {
      case OpKind.createGoal:
        {
          final String? localId = op.assigns;
          final Map<String, dynamic>? body = op.body;
          if (localId == null || body == null) break;
          if (indexOf(localId) >= 0) break;
          rows.add(goalJsonFromCreateBody(localId, body));
        }

      case OpKind.updateGoal:
        {
          final int i = indexOf(op.target);
          final Map<String, dynamic>? body = op.body;
          if (i < 0 || body == null) break;
          rows[i] = applyPatchToGoalJson(rows[i], body);
        }

      case OpKind.setGoalStatus:
        {
          if (isDead) break; // the server never recorded it
          final int i = indexOf(op.target);
          final Object? status = op.body?['status'];
          if (i < 0 || status is! String) break;
          final Map<String, dynamic> row = Map<String, dynamic>.from(rows[i]);
          row['status'] = status;
          rows[i] = row;
        }

      case OpKind.deleteGoal:
        {
          if (isDead) break; // still on the server; show it again
          final int i = indexOf(op.target);
          if (i < 0) break;
          rows.removeAt(i);
        }

      case OpKind.createTask:
      case OpKind.updateTask:
      case OpKind.completeTask:
      case OpKind.deleteTask:
      case OpKind.createList:
      case OpKind.deleteList:
      case OpKind.createSession:
      case OpKind.completeSession:
      case OpKind.cancelSession:
      case OpKind.createHabit:
      case OpKind.updateHabit:
      case OpKind.deleteHabit:
      case OpKind.setHabitArchived:
        // Filtered out above; enumerated so a new entity cannot be added
        // without the compiler asking what this overlay should do about it.
        break;
    }
  }

  return rows.map(Goal.fromJson).toList();
}
