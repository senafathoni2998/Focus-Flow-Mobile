import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/offline/goal_overlay.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';
import 'package:focusflow_mobile/models/goal.dart';

/// Goals are the entity where a naive overlay does visible damage: the model
/// substitutes GoalProgress.empty() when `progress` is missing, so any fold that
/// drops it shows every goal at 0%.

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

Goal goal(String id, {String title = 'Read 12 books', int percent = 40, String status = 'active'}) =>
    Goal.fromJson(<String, dynamic>{
      'id': id,
      'title': title,
      'progressType': 'manual',
      'manualProgress': percent,
      'status': status,
      'taskTotal': 5,
      'taskCompleted': 2,
      'progress': <String, dynamic>{
        'percent': percent,
        'isAchieved': false,
        'isOverdue': false,
      },
    });

void main() {
  group('Goal.toJson', () {
    test('carries the server-derived fields through a round trip', () {
      // If it did not, every overlaid goal would read 0% the moment any edit
      // was pending — Goal.fromJson falls back to GoalProgress.empty().
      final Goal back = Goal.fromJson(goal('g1').toJson());
      expect(back.progress.percent, 40);
      expect(back.taskTotal, 5);
      expect(back.taskCompleted, 2);
    });

    test('a target date survives as a calendar day, not an instant', () {
      final Goal g = Goal.fromJson(<String, dynamic>{
        'id': 'g1',
        'title': 'x',
        'targetDate': '2026-08-20T00:00:00.000Z',
      });
      final Goal back = Goal.fromJson(g.toJson());
      expect(back.targetDate!.year, 2026);
      expect(back.targetDate!.month, 8);
      expect(back.targetDate!.day, 20);
    });
  });

  group('applyGoalQueue', () {
    test('a queued create appears under its local id, honestly at 0%', () {
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('srv1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.createGoal, assigns: 'local_g',
              body: <String, dynamic>{'title': 'Run a marathon'})
        ],
        const <String, String>{},
      );
      expect(out.length, 2);
      expect(out.last.id, 'local_g');
      expect(out.last.title, 'Run a marathon');
      // 0% is the truth for a goal the server has never seen — the percent is
      // computed there, and inventing one would be contradicted on arrival.
      expect(out.last.progress.percent, 0);
    });

    test('an edit does not disturb the server-computed percent', () {
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('srv1', percent: 40)],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.updateGoal, target: 'srv1',
              body: <String, dynamic>{'title': 'renamed'})
        ],
        const <String, String>{},
      );
      expect(out.single.title, 'renamed');
      expect(out.single.progress.percent, 40);
      expect(out.single.taskTotal, 5);
    });

    test('a status change shows immediately', () {
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('srv1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.setGoalStatus, target: 'srv1',
              body: <String, dynamic>{'status': 'achieved'})
        ],
        const <String, String>{},
      );
      expect(out.single.status, 'achieved');
    });

    test('a delete removes it, and a FAILED delete brings it back', () {
      final QueuedOp del =
          op(id: 'o1', seq: 1, kind: OpKind.deleteGoal, target: 'srv1');
      expect(
        applyGoalQueue(<Goal>[goal('srv1')], <QueuedOp>[del], const <String, String>{}),
        isEmpty,
      );

      final QueuedOp failed = op(id: 'o1', seq: 1, kind: OpKind.deleteGoal,
          target: 'srv1', reason: DeadReason.rejected);
      expect(
        applyGoalQueue(<Goal>[goal('srv1')], <QueuedOp>[failed], const <String, String>{})
            .single
            .id,
        'srv1',
      );
    });

    test('ops for other entities are ignored, not folded through', () {
      final List<Goal> out = applyGoalQueue(
        <Goal>[goal('srv1')],
        <QueuedOp>[op(id: 'o1', seq: 1, kind: OpKind.deleteTask, target: 'srv1')],
        const <String, String>{},
      );
      expect(out.single.id, 'srv1');
    });
  });

  group('routing', () {
    test('every goal op hits its own endpoint and verb', () {
      final Map<OpKind, List<String>> expected = <OpKind, List<String>>{
        OpKind.createGoal: <String>['POST', '/goals'],
        OpKind.updateGoal: <String>['PATCH', '/goals/srvG'],
        OpKind.deleteGoal: <String>['DELETE', '/goals/srvG'],
        OpKind.setGoalStatus: <String>['POST', '/goals/srvG/status'],
      };
      expected.forEach((OpKind kind, List<String> want) {
        final Resolution r = resolve(
          op(id: 'o', seq: 1, kind: kind, target: kind == OpKind.createGoal ? '' : 'srvG'),
          const <String, String>{},
        );
        expect(r.op!.method, want[0], reason: '$kind verb');
        expect(r.op!.path, want[1], reason: '$kind path');
      });
    });

    test('a 404 on a goal delete counts as success, like every other delete', () {
      // Gating that rule on deleteTask alone dead-lettered a re-sent delete with
      // "Goal not found", for a goal that IS gone, behind a Retry that could
      // never work.
      expect(classify(kind: OpKind.deleteGoal, status: 404, hadResponse: true),
          OpOutcome.succeeded);
      expect(classify(kind: OpKind.updateGoal, status: 404, hadResponse: true),
          OpOutcome.terminal);
    });

    test('a task filed under an offline goal resolves its goalId', () {
      final Map<String, dynamic> body = <String, dynamic>{
        'title': 'Chapter one',
        'goalId': 'local_G',
      };
      final Resolution r = resolve(
        op(id: 'o1', seq: 2, kind: OpKind.createTask, assigns: 'local_t', body: body),
        <String, String>{'local_G': 'srvG'},
      );
      expect(r.op!.body!['goalId'], 'srvG');
      expect(body['goalId'], 'local_G');
    });
  });
}
