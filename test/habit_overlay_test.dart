import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/offline/habit_overlay.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';
import 'package:focusflow_mobile/models/habit.dart';

/// Habits are the entity where a naive overlay does the most visible damage:
/// the model substitutes HabitStats.empty() when `stats` is missing, so any fold
/// that drops it blanks every streak and month rate to zero — the numbers the
/// whole screen exists to show.

QueuedOp op({
  required String id,
  required int seq,
  required OpKind kind,
  String target = '',
  String? assigns,
  Map<String, dynamic>? body,
  DeadReason? reason,
}) =>
    QueuedOp(
      id: id,
      seq: seq,
      kind: kind,
      target: target,
      assigns: assigns,
      body: body,
      summary: 's',
      createdAtMs: 0,
      reason: reason,
    );

Habit habit(
  String id, {
  String name = 'Drink water',
  int streak = 12,
  bool archived = false,
}) =>
    Habit.fromJson(<String, dynamic>{
      'id': id,
      'name': name,
      'goalType': 'amount',
      'targetAmount': 8,
      'unit': 'glasses',
      'archived': archived,
      'stats': <String, dynamic>{
        'currentStreak': streak,
        'bestStreak': 30,
        'totalDays': 84,
        'monthlyRate': 71,
        'todayDone': true,
        'todayAmount': 6,
        'streakUnit': 'day',
        'weeklyProgress': 4,
      },
    });

void main() {
  group('Habit.toJson', () {
    test('carries the server-computed stats through a round trip', () {
      // If it did not, every habit on screen would read a 0-day streak the
      // moment ANY habit write was pending — Habit.fromJson falls back to
      // HabitStats.empty().
      final Habit back = Habit.fromJson(habit('h1').toJson());
      expect(back.stats.currentStreak, 12);
      expect(back.stats.monthlyRate, 71);
      expect(back.stats.todayDone, isTrue);
      expect(back.stats.todayAmount, 6);
      expect(back.targetAmount, 8);
      expect(back.unit, 'glasses');
    });
  });

  group('applyHabitQueue', () {
    test('a queued create appears under its local id, honestly at zero', () {
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('srv1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.createHabit, assigns: 'local_h',
              body: <String, dynamic>{'name': 'Read 20 pages', 'icon': '📚'})
        ],
        const <String, String>{},
      );
      expect(out.length, 2);
      expect(out.last.id, 'local_h');
      expect(out.last.name, 'Read 20 pages');
      expect(out.last.icon, '📚');
      // A zero streak is the truth for a habit the server has never scored.
      expect(out.last.stats.currentStreak, 0);
      // The server's own default, mirrored rather than guessed.
      expect(out.last.targetAmount, 1);
      expect(out.last.archived, isFalse);
    });

    test('an edit does not disturb the server-computed streak', () {
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('srv1', streak: 12)],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.updateHabit, target: 'srv1',
              body: <String, dynamic>{'name': 'Drink MORE water'})
        ],
        const <String, String>{},
      );
      expect(out.single.name, 'Drink MORE water');
      expect(out.single.stats.currentStreak, 12);
      expect(out.single.stats.monthlyRate, 71);
      // Absent from the body, so untouched — the server's key-presence rule.
      expect(out.single.unit, 'glasses');
    });

    test('a queued archive hides it, and a FAILED archive brings it back', () {
      final QueuedOp arch = op(id: 'o1', seq: 1, kind: OpKind.setHabitArchived,
          target: 'srv1', body: <String, dynamic>{'archived': true});
      expect(
        applyHabitQueue(<Habit>[habit('srv1')], <QueuedOp>[arch], const <String, String>{}),
        isEmpty,
      );

      final QueuedOp failed = op(id: 'o1', seq: 1, kind: OpKind.setHabitArchived,
          target: 'srv1', body: <String, dynamic>{'archived': true},
          reason: DeadReason.rejected);
      expect(
        applyHabitQueue(<Habit>[habit('srv1')], <QueuedOp>[failed], const <String, String>{})
            .single
            .id,
        'srv1',
      );
    });

    test('archiving then restoring, both queued, leaves the habit visible', () {
      // The reason setHabitArchived sets a FLAG instead of removing the row. If
      // it removed, the restore would find nothing to flip back and the habit
      // would stay hidden until the queue drained — despite the user having
      // undone the archive before either op left the phone.
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('srv1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.setHabitArchived, target: 'srv1',
              body: <String, dynamic>{'archived': true}),
          op(id: 'o2', seq: 2, kind: OpKind.setHabitArchived, target: 'srv1',
              body: <String, dynamic>{'archived': false}),
        ],
        const <String, String>{},
      );
      expect(out.single.id, 'srv1');
      expect(out.single.stats.currentStreak, 12);
    });

    test('a delete removes it, and a FAILED delete brings it back', () {
      final QueuedOp del =
          op(id: 'o1', seq: 1, kind: OpKind.deleteHabit, target: 'srv1');
      expect(
        applyHabitQueue(<Habit>[habit('srv1')], <QueuedOp>[del], const <String, String>{}),
        isEmpty,
      );

      final QueuedOp failed = op(id: 'o1', seq: 1, kind: OpKind.deleteHabit,
          target: 'srv1', reason: DeadReason.rejected);
      expect(
        applyHabitQueue(<Habit>[habit('srv1')], <QueuedOp>[failed], const <String, String>{})
            .single
            .id,
        'srv1',
      );
    });

    test('an edit reaches a habit through its resolved server id', () {
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('srvH', name: 'old')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.updateHabit, target: 'local_h',
              body: <String, dynamic>{'name': 'new'})
        ],
        <String, String>{'local_h': 'srvH'},
      );
      expect(out.single.name, 'new');
    });

    test('ops for other entities are ignored, not folded through', () {
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('srv1')],
        <QueuedOp>[op(id: 'o1', seq: 1, kind: OpKind.deleteGoal, target: 'srv1')],
        const <String, String>{},
      );
      expect(out.single.id, 'srv1');
    });
  });

  group('routing', () {
    test('every habit op hits its own endpoint and verb', () {
      final Map<OpKind, List<String>> expected = <OpKind, List<String>>{
        OpKind.createHabit: <String>['POST', '/habits'],
        OpKind.updateHabit: <String>['PATCH', '/habits/srvH'],
        OpKind.deleteHabit: <String>['DELETE', '/habits/srvH'],
        OpKind.setHabitArchived: <String>['POST', '/habits/srvH/archive'],
      };
      expected.forEach((OpKind kind, List<String> want) {
        final Resolution r = resolve(
          op(id: 'o', seq: 1, kind: kind, target: kind == OpKind.createHabit ? '' : 'srvH'),
          const <String, String>{},
        );
        expect(r.op!.method, want[0], reason: '$kind verb');
        expect(r.op!.path, want[1], reason: '$kind path');
      });
    });

    test('a create reads its new id from the habit envelope', () {
      final Resolution r = resolve(
        op(id: 'o', seq: 1, kind: OpKind.createHabit, assigns: 'local_h'),
        const <String, String>{},
      );
      // Wrong here and the local id never resolves: every dependent op is
      // dead-lettered as orphaned, for a create that actually succeeded.
      expect(r.op!.idPath, 'habit.id');
    });

    test('a 404 on a habit delete counts as success, like every other delete', () {
      expect(classify(kind: OpKind.deleteHabit, status: 404, hadResponse: true),
          OpOutcome.succeeded);
      expect(classify(kind: OpKind.updateHabit, status: 404, hadResponse: true),
          OpOutcome.terminal);
      // An archive is NOT a delete: a 404 means the flag was never written.
      expect(classify(kind: OpKind.setHabitArchived, status: 404, hadResponse: true),
          OpOutcome.terminal);
    });

    test('a habit op is routed to the habit entity', () {
      for (final OpKind kind in <OpKind>[
        OpKind.createHabit,
        OpKind.updateHabit,
        OpKind.deleteHabit,
        OpKind.setHabitArchived,
      ]) {
        expect(op(id: 'o', seq: 1, kind: kind).entity, OpEntity.habit);
      }
    });
  });

  group('summaries', () {
    test('the two directions of one op kind read differently', () {
      // Unsent changes is the only place a queued archive is ever described,
      // and by then the habit may not exist anywhere the UI can look it up.
      expect(
        summaryFor(OpKind.setHabitArchived,
            <String, dynamic>{'archived': true}, 'Drink water'),
        'Archive habit "Drink water"',
      );
      expect(
        summaryFor(OpKind.setHabitArchived,
            <String, dynamic>{'archived': false}, 'Drink water'),
        'Restore habit "Drink water"',
      );
    });

    test('a habit create is described by its name, not a title it lacks', () {
      // Habits carry `name`; tasks and goals carry `title`. Reading only
      // `title` rendered every queued list op as 'New task "a task"' once
      // before — the same trap, one entity along.
      expect(
        summaryFor(OpKind.createHabit,
            <String, dynamic>{'name': 'Read 20 pages'}, ''),
        'New habit "Read 20 pages"',
      );
    });
  });
}
