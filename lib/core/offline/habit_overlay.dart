import '../../models/habit.dart';
import '../date_format.dart';
import 'queue_op.dart';

/// The habits overlay — same shape and same reason as the task, list and goal
/// ones: server truth lives underneath, so a refresh cannot erase a pending
/// write.
///
/// WHAT IS PROJECTED, AND WHERE THE LINE IS. A queued check-in moves exactly two
/// numbers: `todayAmount` and `todayDone`. Both are functions of TODAY alone —
/// `max(0, amount + delta)` and `habitStats.ts:isSatisfied` — so they can be
/// computed here to the letter.
///
/// `currentStreak`, `bestStreak`, `totalDays`, `monthlyRate` and `weeklyProgress`
/// are NOT. Each walks the full check-in history, which this device is never
/// sent (the endpoints compute stats from up to 1200 rows and then strip them).
/// A streak "obviously" ticks up when today flips to done — unless yesterday was
/// missed, which is exactly what the client cannot know. They are carried
/// through. The tick moving is what the user needs to see; a fabricated 13-day
/// streak is not.

/// Build the habit JSON the server would have returned for a create body.
///
/// The defaults below are `habitService.createHabit`'s own, mirrored so the card
/// shows what the row will actually hold rather than a blank. `order` is the one
/// value NOT mirrored: the server assigns `max(order)+10`, which is unknowable
/// here, and a guess would be silently contradicted the moment the create lands.
Map<String, dynamic> habitJsonFromCreateBody(
  String localId,
  Map<String, dynamic> body,
) {
  return <String, dynamic>{
    'id': localId,
    'name': body['name'] is String ? body['name'] as String : '',
    'icon': body['icon'] ?? '✅',
    'color': body['color'] ?? 'primary',
    'frequencyType': body['frequencyType'] ?? 'daily',
    'weekdays': body['weekdays'] ?? <int>[],
    'weeklyTarget': body['weeklyTarget'] ?? 1,
    'goalType': body['goalType'] ?? 'achieve',
    // The server stores 1 when the field is absent, so an "achieve" habit really
    // does end up with targetAmount 1 — this is a schema default, not a guess at
    // something computed.
    'targetAmount': body['targetAmount'] ?? 1,
    'unit': body['unit'],
    'archived': false,
    'order': null,
    // Deliberately absent: Habit.fromJson substitutes HabitStats.empty(), and a
    // zero streak is the honest reading for a habit the server has never seen.
    'stats': null,
  };
}

/// Apply a PATCH body, mirroring `habitSchema.partial()` — which parses a body
/// and writes exactly the keys it contains, every one an absolute assignment.
///
/// Only keys PRESENT change anything. Note what that means for the habit editor:
/// switching a habit from "amount" back to "do it" OMITS `targetAmount` and
/// `unit`, so the server keeps the old values. That is not a queue artefact —
/// the same request from an online client behaves identically, and the fields
/// cannot be cleared from the phone at all because the Zod schema rejects null
/// for them. The overlay reproduces the server, including that.
Map<String, dynamic> applyPatchToHabitJson(
  Map<String, dynamic> habit,
  Map<String, dynamic> body,
) {
  final Map<String, dynamic> out = Map<String, dynamic>.from(habit);
  for (final String k in const <String>[
    'name',
    'icon',
    'color',
    'frequencyType',
    'weekdays',
    'weeklyTarget',
    'goalType',
    'targetAmount',
    'unit',
  ]) {
    if (body.containsKey(k)) out[k] = body[k];
  }
  return out;
}

/// Apply one check-in delta to a habit row's `stats`, mirroring
/// `checkInHabit` + `habitStats.ts:isSatisfied`.
Map<String, dynamic> applyCheckInToHabitJson(
  Map<String, dynamic> habit,
  num delta,
) {
  final Map<String, dynamic> out = Map<String, dynamic>.from(habit);
  final Object? raw = out['stats'];
  // A habit created in this same offline stretch has no stats at all. Starting
  // from empty is right: every other figure genuinely IS zero for a habit the
  // server has never scored.
  final Map<String, dynamic> stats =
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

  final double current =
      stats['todayAmount'] is num ? (stats['todayAmount'] as num).toDouble() : 0;
  // The server's own clamp: a check-in can never drive the day negative.
  final double next = (current + delta) < 0 ? 0 : current + delta;

  // isSatisfied: an `amount` habit needs its target, everything else needs one.
  final double target = out['goalType'] == 'amount'
      ? (out['targetAmount'] is num ? (out['targetAmount'] as num).toDouble() : 1)
      : 1;

  stats['todayAmount'] = next;
  stats['todayDone'] = next >= target;
  out['stats'] = stats;
  return out;
}

/// [now] is injectable only so the day-boundary rule can be tested; production
/// callers leave it null.
List<Habit> applyHabitQueue(
  List<Habit> server,
  List<QueuedOp> ops,
  Map<String, String> idMap, {
  DateTime? now,
}) {
  final List<QueuedOp> ordered = ops
      .where((QueuedOp o) => o.entity == OpEntity.habit)
      .toList()
    ..sort((QueuedOp a, QueuedOp b) => a.seq.compareTo(b.seq));
  if (ordered.isEmpty) return server;

  final List<Map<String, dynamic>> rows =
      server.map((Habit h) => h.toJson()).toList();

  // The same yyyy-MM-dd the controller freezes into a check-in body, so the two
  // are comparing the same notion of "today" — the device's local calendar day,
  // which is what the server converts to a UTC-midnight check-in date.
  final String today = Dates.ymd(now ?? DateTime.now());

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
      case OpKind.createHabit:
        {
          final String? localId = op.assigns;
          final Map<String, dynamic>? body = op.body;
          if (localId == null || body == null) break;
          if (indexOf(localId) >= 0) break;
          rows.add(habitJsonFromCreateBody(localId, body));
        }

      case OpKind.updateHabit:
        {
          final int i = indexOf(op.target);
          final Map<String, dynamic>? body = op.body;
          if (i < 0 || body == null) break;
          rows[i] = applyPatchToHabitJson(rows[i], body);
        }

      case OpKind.setHabitArchived:
        {
          if (isDead) break; // the server never recorded it
          final int i = indexOf(op.target);
          final Object? archived = op.body?['archived'];
          if (i < 0 || archived is! bool) break;
          // The FLAG is set, the row is not removed here — filtering happens
          // once at the end. Removing it would make a queued archive impossible
          // to undo by a later queued restore: there would be no row left to
          // flip back, and `archived: false` is an absolute SET like any other.
          final Map<String, dynamic> row = Map<String, dynamic>.from(rows[i]);
          row['archived'] = archived;
          rows[i] = row;
        }

      case OpKind.checkInHabit:
        {
          if (isDead) break; // the server never recorded it
          final int i = indexOf(op.target);
          final num? delta = deltaOf(op);
          if (i < 0 || delta == null) break;
          // ONLY today's tile. The op froze its day at enqueue, so one made last
          // night and still unsent this morning belongs to YESTERDAY — folding
          // it here would tick today's box for a day the user has not touched.
          if (op.body?['date'] != today) break;
          rows[i] = applyCheckInToHabitJson(rows[i], delta);
        }

      case OpKind.deleteHabit:
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
      case OpKind.createGoal:
      case OpKind.updateGoal:
      case OpKind.deleteGoal:
      case OpKind.setGoalStatus:
      case OpKind.adjustGoalProgress:
        // Filtered out above; enumerated so a new entity cannot be added
        // without the compiler asking what this overlay should do about it.
        break;
    }
  }

  // `GET /habits` only ever returns active habits, so this removes exactly the
  // rows a pending archive hid — nothing else can be true here.
  //
  // A queued RESTORE of a habit that is not in this list stays invisible until
  // the queue drains, and there is no honest alternative: the archived habits
  // live behind their own network fetch, so offline there is no row to bring
  // back. The op is still queued and the Archived screen still says so.
  rows.removeWhere((Map<String, dynamic> r) => r['archived'] == true);

  return rows.map(Habit.fromJson).toList();
}
