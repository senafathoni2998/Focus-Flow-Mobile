import '../../models/goal.dart';
import 'queue_op.dart';

/// The goals overlay — same shape and same reason as the task and list ones:
/// server truth lives underneath, so a refresh cannot erase a pending write.
///
/// WHAT IS PROJECTED, AND THE LINE BETWEEN THE TWO. `taskTotal` and
/// `taskCompleted` are counted server-side over tasks this overlay cannot see,
/// so they are carried through untouched. `percent` is NOT in that category, and
/// treating it as though it were was a real gap: `goalPercent` is a pure
/// function of `progressType` + those counts + `targetValue`/`currentValue` +
/// `manualProgress`, every one of which is already in hand. Carrying it meant a
/// manual goal edited from 40% to 80% offline still showed 40%, and a goal
/// created offline at 60% showed 0%. It is now recomputed — but ONLY for rows a
/// pending op actually touched, so an untouched goal keeps the server's own
/// figure rather than one derived from a device clock.
///
/// `daysRemaining` stays as the server sent it. Recomputing it would mean
/// comparing a deadline against the phone's clock, which near midnight disagrees
/// with the server by a whole day for no benefit. `isOverdue` IS recomputed from
/// it, because it is defined as `daysRemaining < 0 && !isAchieved` and
/// `isAchieved` can change under a pending edit.

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
    // Left absent here and filled in by the recompute at the end of the fold. A
    // manual goal created at 60% really is at 60% the instant the server sees
    // it, so showing 0% until then was not caution — it was wrong.
    'progress': null,
  };
}

/// `goalStats.ts:goalPercent`, in Dart.
///
/// A DUPLICATE, and one worth naming as such. It exists because the alternative
/// is worse: without it a pending progress tap cannot move the bar it exists to
/// move, and every projection in this file would be a percent the card ignores.
/// It is pinned by a test that walks the same clamps and the same zero-target
/// branches, so drift shows up as a red test rather than a wrong number.
int goalPercentOf(Map<String, dynamic> g) {
  int clampPct(double n) => n.isNaN || n.isInfinite ? 0 : n.round().clamp(0, 100);
  double num0(Object? v) => v is num ? v.toDouble() : 0;

  switch (g['progressType']) {
    case 'tasks':
      final double total = num0(g['taskTotal']);
      if (total <= 0) return 0;
      return clampPct(num0(g['taskCompleted']) / total * 100);
    case 'numeric':
      final double target = num0(g['targetValue']);
      if (target <= 0) return 0;
      return clampPct(num0(g['currentValue']) / target * 100);
    default:
      return clampPct(num0(g['manualProgress']));
  }
}

/// Rebuild `progress` for one row after a fold changed something it derives from.
Map<String, dynamic> withRecomputedProgress(Map<String, dynamic> g) {
  final Map<String, dynamic> out = Map<String, dynamic>.from(g);
  final Object? prev = out['progress'];
  final Map<String, dynamic> old =
      prev is Map ? Map<String, dynamic>.from(prev) : <String, dynamic>{};

  final int percent = goalPercentOf(out);
  final bool isAchieved = out['status'] == 'achieved' || percent >= 100;
  final Object? days = old['daysRemaining'];

  out['progress'] = <String, dynamic>{
    'percent': percent,
    'isAchieved': isAchieved,
    // Carried, not recomputed — see the note at the top of this file.
    'daysRemaining': days,
    'isOverdue': days is num && days < 0 && !isAchieved,
  };
  return out;
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

  // Rows whose derived `progress` has to be rebuilt. Tracked by ID rather than
  // index because a delete shifts every index after it — and recomputing rows
  // NOTHING touched would replace the server's own figures with locally derived
  // ones for no reason.
  final Set<String> dirty = <String>{};
  void markDirty(int i) {
    final Object? id = rows[i]['id'];
    if (id is String) dirty.add(id);
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
          markDirty(rows.length - 1);
        }

      case OpKind.updateGoal:
        {
          final int i = indexOf(op.target);
          final Map<String, dynamic>? body = op.body;
          if (i < 0 || body == null) break;
          rows[i] = applyPatchToGoalJson(rows[i], body);
          // An edit can move manualProgress, targetValue or progressType, all of
          // which the percent is derived from.
          markDirty(i);
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
          // isAchieved is `status == 'achieved' || percent >= 100`.
          markDirty(i);
        }

      case OpKind.adjustGoalProgress:
        {
          if (isDead) break; // the server never recorded it
          final int i = indexOf(op.target);
          final num? delta = deltaOf(op);
          if (i < 0 || delta == null) break;
          final Map<String, dynamic> row = Map<String, dynamic>.from(rows[i]);
          // The three branches of goalService.adjustGoalProgress, including its
          // clamps — a tasks-derived goal returns early there and must here too,
          // or the card would move for a request that changes nothing.
          switch (row['progressType']) {
            case 'tasks':
              break;
            case 'numeric':
              final num cur = row['currentValue'] is num ? row['currentValue'] as num : 0;
              row['currentValue'] = (cur + delta).clamp(0, 1000000).toDouble();
              rows[i] = row;
              markDirty(i);
            default:
              final num cur =
                  row['manualProgress'] is num ? row['manualProgress'] as num : 0;
              row['manualProgress'] = (cur + delta).round().clamp(0, 100);
              rows[i] = row;
              markDirty(i);
          }
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
      case OpKind.checkInHabit:
        // Filtered out above; enumerated so a new entity cannot be added
        // without the compiler asking what this overlay should do about it.
        break;
    }
  }

  if (dirty.isNotEmpty) {
    for (int i = 0; i < rows.length; i++) {
      if (dirty.contains(rows[i]['id'])) rows[i] = withRecomputedProgress(rows[i]);
    }
  }

  return rows.map(Goal.fromJson).toList();
}
