import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/date_format.dart';
import 'package:focusflow_mobile/core/offline/goal_overlay.dart';
import 'package:focusflow_mobile/core/offline/habit_overlay.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';
import 'package:focusflow_mobile/models/goal.dart';
import 'package:focusflow_mobile/models/habit.dart';

/// The two DELTA ops — habit check-in and goal progress — and the three things
/// that make them different from every other queued write: they must be
/// projected arithmetically, they may be merged, and one of them carries a day
/// that has to be frozen at the moment the user tapped.

QueuedOp op({
  required String id,
  required int seq,
  required OpKind kind,
  String target = '',
  Map<String, dynamic>? body,
  int attempts = 0,
  String summary = 's',
  String? key,
  DeadReason? reason,
}) =>
    QueuedOp(
      id: id,
      seq: seq,
      kind: kind,
      target: target,
      body: body,
      key: key,
      summary: summary,
      createdAtMs: 0,
      attempts: attempts,
      reason: reason,
    );

String today() => Dates.ymd(DateTime.now());

Map<String, dynamic> checkInBody(num delta, [String? date]) =>
    <String, dynamic>{'delta': delta, 'date': date ?? today()};

Habit habit(String id, {String goalType = 'achieve', double? target, double todayAmount = 0}) =>
    Habit.fromJson(<String, dynamic>{
      'id': id,
      'name': 'Drink water',
      'goalType': goalType,
      'targetAmount': target,
      'stats': <String, dynamic>{
        'currentStreak': 12,
        'bestStreak': 30,
        'monthlyRate': 71,
        'todayAmount': todayAmount,
        'todayDone': false,
      },
    });

Goal goal(String id, {String type = 'manual', int manual = 40, double current = 0, double? targetValue}) =>
    Goal.fromJson(<String, dynamic>{
      'id': id,
      'title': 'Read 12 books',
      'progressType': type,
      'manualProgress': manual,
      'currentValue': current,
      'targetValue': targetValue,
      'status': 'active',
      'progress': <String, dynamic>{
        'percent': type == 'manual' ? manual : 0,
        'isAchieved': false,
        'daysRemaining': 5,
        'isOverdue': false,
      },
    });

void main() {
  group('habit check-in projection', () {
    test('an achieve habit ticks the moment it is tapped', () {
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('h1')],
        <QueuedOp>[op(id: 'o1', seq: 1, kind: OpKind.checkInHabit, target: 'h1', body: checkInBody(1))],
        const <String, String>{},
      );
      expect(out.single.stats.todayDone, isTrue);
      expect(out.single.stats.todayAmount, 1);
      // Untouched: a streak walks the whole history, and whether today extends
      // it depends on yesterday — which this device was never sent.
      expect(out.single.stats.currentStreak, 12);
      expect(out.single.stats.monthlyRate, 71);
    });

    test('an amount habit is not done until it reaches its target', () {
      List<Habit> fold(num delta) => applyHabitQueue(
            <Habit>[habit('h1', goalType: 'amount', target: 8, todayAmount: 6)],
            <QueuedOp>[
              op(id: 'o1', seq: 1, kind: OpKind.checkInHabit, target: 'h1', body: checkInBody(delta))
            ],
            const <String, String>{},
          );
      expect(fold(1).single.stats.todayAmount, 7);
      expect(fold(1).single.stats.todayDone, isFalse);
      expect(fold(2).single.stats.todayDone, isTrue);
    });

    test('it cannot be driven below zero, exactly like the server', () {
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('h1', goalType: 'amount', target: 8, todayAmount: 1)],
        <QueuedOp>[op(id: 'o1', seq: 1, kind: OpKind.checkInHabit, target: 'h1', body: checkInBody(-5))],
        const <String, String>{},
      );
      expect(out.single.stats.todayAmount, 0);
      expect(out.single.stats.todayDone, isFalse);
    });

    test("YESTERDAY's unsent check-in does not tick TODAY's box", () {
      // The op freezes its day at enqueue. One made at 23:50 and still unsent at
      // 00:05 belongs to yesterday — folding it onto today would credit a day
      // the user has not touched, and then the server would disagree.
      final DateTime now = DateTime(2026, 8, 10, 0, 5);
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('h1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.checkInHabit, target: 'h1',
              body: checkInBody(1, '2026-08-09'))
        ],
        const <String, String>{},
        now: now,
      );
      expect(out.single.stats.todayDone, isFalse);
      expect(out.single.stats.todayAmount, 0);
    });

    test('a FAILED check-in does not claim the server recorded it', () {
      final List<Habit> out = applyHabitQueue(
        <Habit>[habit('h1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.checkInHabit, target: 'h1',
              body: checkInBody(1), reason: DeadReason.rejected)
        ],
        const <String, String>{},
      );
      expect(out.single.stats.todayDone, isFalse);
    });

    test('a habit created in the same offline stretch can be checked in', () {
      final List<Habit> out = applyHabitQueue(
        const <Habit>[],
        <QueuedOp>[
          QueuedOp(
            id: 'o1', seq: 1, kind: OpKind.createHabit, target: '',
            assigns: 'local_h', body: <String, dynamic>{'name': 'Stretch'},
            summary: 's', createdAtMs: 0,
          ),
          op(id: 'o2', seq: 2, kind: OpKind.checkInHabit, target: 'local_h',
              body: checkInBody(1)),
        ],
        const <String, String>{},
      );
      // No stats at all on a create row — starting from zero is right, because
      // every other figure genuinely IS zero for a habit never scored.
      expect(out.single.stats.todayDone, isTrue);
      expect(out.single.stats.todayAmount, 1);
      expect(out.single.stats.currentStreak, 0);
    });
  });

  group('goal progress projection', () {
    test('a manual nudge moves the percent the card actually renders', () {
      // Carrying `progress` through was the shipped behaviour and it meant the
      // bar sat still while the number under it moved.
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('g1', manual: 40)],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.adjustGoalProgress, target: 'g1',
              body: <String, dynamic>{'delta': 10})
        ],
        const <String, String>{},
      );
      expect(out.single.manualProgress, 50);
      expect(out.single.progress.percent, 50);
    });

    test('a numeric nudge divides by the target, and 100% reads as achieved', () {
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('g1', type: 'numeric', current: 9, targetValue: 10)],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.adjustGoalProgress, target: 'g1',
              body: <String, dynamic>{'delta': 1})
        ],
        const <String, String>{},
      );
      expect(out.single.currentValue, 10);
      expect(out.single.progress.percent, 100);
      expect(out.single.progress.isAchieved, isTrue);
      // Defined as `daysRemaining < 0 && !isAchieved`, so finishing clears it.
      expect(out.single.progress.isOverdue, isFalse);
    });

    test('a tasks-derived goal does not move, because the server returns early', () {
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('g1', type: 'tasks')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.adjustGoalProgress, target: 'g1',
              body: <String, dynamic>{'delta': 10})
        ],
        const <String, String>{},
      );
      expect(out.single.manualProgress, 40);
      expect(out.single.progress.percent, 0);
    });

    test('the manual clamp is the server clamp', () {
      List<Goal> fold(num delta, int from) => applyGoalQueue(
            <Goal>[goal('g1', manual: from)],
            <QueuedOp>[
              op(id: 'o1', seq: 1, kind: OpKind.adjustGoalProgress, target: 'g1',
                  body: <String, dynamic>{'delta': delta})
            ],
            const <String, String>{},
          );
      expect(fold(30, 90).single.manualProgress, 100);
      expect(fold(-30, 10).single.manualProgress, 0);
    });

    test('an EDIT that changes manualProgress moves the bar too', () {
      // Not a new feature — a gap. The editor's slider is part of the PATCH
      // body, so editing a goal to 80% offline used to still read 40%.
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('g1', manual: 40)],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.updateGoal, target: 'g1',
              body: <String, dynamic>{'manualProgress': 80})
        ],
        const <String, String>{},
      );
      expect(out.single.progress.percent, 80);
    });

    test('an untouched goal keeps the SERVER percent, even if ours would differ', () {
      // The point of recomputing only touched rows. Both goals below carry a
      // server percent that goalPercentOf would not derive — a stand-in for the
      // server's scoring drifting ahead of this file's copy of it. The one an
      // op touched has to be recomputed (there is no other way to move the bar);
      // the one nothing touched must keep the server's answer rather than being
      // silently overwritten by ours.
      Goal odd(String id) => Goal.fromJson(<String, dynamic>{
            'id': id,
            'title': 't',
            'progressType': 'manual',
            'manualProgress': 10,
            'status': 'active',
            'progress': <String, dynamic>{'percent': 99, 'daysRemaining': 5},
          });

      final List<Goal> out = applyGoalQueue(
        <Goal>[odd('touched'), odd('untouched')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.adjustGoalProgress, target: 'touched',
              body: <String, dynamic>{'delta': 10})
        ],
        const <String, String>{},
      );
      expect(out.firstWhere((Goal g) => g.id == 'touched').progress.percent, 20);
      expect(out.firstWhere((Goal g) => g.id == 'untouched').progress.percent, 99);
      expect(out.firstWhere((Goal g) => g.id == 'untouched').progress.daysRemaining, 5);
    });

    test('goalPercentOf matches goalStats.ts at every branch', () {
      // A deliberate duplicate of server logic, pinned so drift is a red test.
      expect(goalPercentOf(<String, dynamic>{'progressType': 'manual', 'manualProgress': 37}), 37);
      expect(goalPercentOf(<String, dynamic>{'progressType': 'manual', 'manualProgress': 140}), 100);
      expect(goalPercentOf(<String, dynamic>{'progressType': 'manual'}), 0);
      // A zero or missing target is 0%, never a division by zero.
      expect(goalPercentOf(<String, dynamic>{'progressType': 'numeric', 'currentValue': 5}), 0);
      expect(
          goalPercentOf(<String, dynamic>{
            'progressType': 'numeric', 'currentValue': 1, 'targetValue': 3,
          }),
          33);
      expect(goalPercentOf(<String, dynamic>{'progressType': 'tasks', 'taskTotal': 0}), 0);
      expect(
          goalPercentOf(<String, dynamic>{
            'progressType': 'tasks', 'taskTotal': 4, 'taskCompleted': 3,
          }),
          75);
    });
  });

  group('coalescing', () {
    QueuedOp checkIn(String id, int seq, num delta, {int attempts = 0, String? date}) => op(
          id: id, seq: seq, kind: OpKind.checkInHabit, target: 'h1',
          body: checkInBody(delta, date), attempts: attempts, key: 'k$id',
          summary: 'Check in +$delta on habit "Drink water"',
        );

    test('two taps become one request that says +2', () {
      final QueuedOp b = checkIn('o2', 2, 1);
      final List<QueuedOp>? out =
          coalesceDelta(<QueuedOp>[checkIn('o1', 1, 1), b], b);
      expect(out!.length, 1);
      expect(out.single.body!['delta'], 2);
      // The EARLIER op's place in the queue, so a merge cannot jump the FIFO
      // order ahead of writes the user made in between.
      expect(out.single.id, 'o1');
      expect(out.single.seq, 1);
      // A fresh key: reusing one under a changed body is the 422 that wedges a
      // write permanently. Neither original key was ever sent, so both are free
      // to abandon.
      expect(out.single.key, isNot('ko1'));
      expect(out.single.key, isNot('ko2'));
      // The amount is in the text, because one dead letter now stands for two
      // taps and "Discard" would drop both.
      expect(out.single.summary, 'Check in +2 on habit "Drink water"');
    });

    test('plus then minus never reaches the network at all', () {
      final QueuedOp b = checkIn('o2', 2, -1);
      expect(coalesceDelta(<QueuedOp>[checkIn('o1', 1, 1), b], b), isEmpty);
    });

    test('it refuses an op that has already been on the wire', () {
      // After even an unanswered send the server may hold that check-in, so
      // rewriting the op would either lose it or double it.
      final QueuedOp b = checkIn('o2', 2, 1);
      expect(coalesceDelta(<QueuedOp>[checkIn('o1', 1, 1, attempts: 1), b], b), isNull);
    });

    test('it refuses the op currently in flight', () {
      // `attempts` does not cover this: it is incremented when a send FAILS, so
      // an op awaiting its answer still reads 0.
      final QueuedOp b = checkIn('o2', 2, 1);
      expect(
        coalesceDelta(<QueuedOp>[checkIn('o1', 1, 1), b], b, inFlightOpId: 'o1'),
        isNull,
      );
    });

    test('it refuses across a day boundary', () {
      final QueuedOp b = checkIn('o2', 2, 1, date: '2026-08-10');
      expect(
        coalesceDelta(<QueuedOp>[checkIn('o1', 1, 1, date: '2026-08-09'), b], b),
        isNull,
      );
    });

    test('it refuses a different habit, and anything in between', () {
      final QueuedOp b = checkIn('o2', 2, 1);
      final QueuedOp other = op(
          id: 'o1', seq: 1, kind: OpKind.checkInHabit, target: 'h2',
          body: checkInBody(1), summary: 's');
      expect(coalesceDelta(<QueuedOp>[other, b], b), isNull);

      final QueuedOp unrelated =
          op(id: 'ox', seq: 2, kind: OpKind.deleteTask, target: 't1');
      final QueuedOp c = checkIn('o3', 3, 1);
      expect(coalesceDelta(<QueuedOp>[checkIn('o1', 1, 1), unrelated, c], c), isNull);
    });

    test('only a delta kind is ever merged', () {
      final QueuedOp b = op(id: 'o2', seq: 2, kind: OpKind.setGoalStatus,
          target: 'g1', body: <String, dynamic>{'status': 'active'});
      final QueuedOp a = op(id: 'o1', seq: 1, kind: OpKind.setGoalStatus,
          target: 'g1', body: <String, dynamic>{'status': 'active'});
      expect(coalesceDelta(<QueuedOp>[a, b], b), isNull);
    });

    test('a habit called "Read on the train" still merges its name intact', () {
      // The merged summary is rebuilt from the earlier op's tail, split at the
      // FIRST " on " — which is the separator, never part of the name.
      final QueuedOp a = op(
          id: 'o1', seq: 1, kind: OpKind.checkInHabit, target: 'h1',
          body: checkInBody(1), summary: 'Check in +1 on habit "Read on the train"');
      final QueuedOp b = op(
          id: 'o2', seq: 2, kind: OpKind.checkInHabit, target: 'h1',
          body: checkInBody(1), summary: 'Check in +1 on habit "Read on the train"');
      expect(coalesceDelta(<QueuedOp>[a, b], b)!.single.summary,
          'Check in +2 on habit "Read on the train"');
    });
  });

  group('routing and policy', () {
    test('both deltas hit their own endpoint', () {
      expect(
        resolve(op(id: 'o', seq: 1, kind: OpKind.checkInHabit, target: 'h1'),
                const <String, String>{})
            .op!
            .path,
        '/habits/h1/checkin',
      );
      expect(
        resolve(op(id: 'o', seq: 1, kind: OpKind.adjustGoalProgress, target: 'g1'),
                const <String, String>{})
            .op!
            .path,
        '/goals/g1/progress',
      );
    });

    test('a delta is never a delete, so a 404 is terminal', () {
      // Forgiving a 404 here would drop the op, drop its projection, and untick
      // the box on the next refresh with nothing said anywhere.
      expect(isDeleteKind(OpKind.checkInHabit), isFalse);
      expect(classify(kind: OpKind.checkInHabit, status: 404, hadResponse: true),
          OpOutcome.terminal);
      expect(classify(kind: OpKind.adjustGoalProgress, status: 404, hadResponse: true),
          OpOutcome.terminal);
    });

    test('exactly two kinds are deltas', () {
      final Set<OpKind> deltas =
          OpKind.values.where(isDeltaKind).toSet();
      expect(deltas, <OpKind>{OpKind.checkInHabit, OpKind.adjustGoalProgress});
    });
  });
}
