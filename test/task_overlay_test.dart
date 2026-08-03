import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';
import 'package:focusflow_mobile/core/offline/task_overlay.dart';
import 'package:focusflow_mobile/models/task.dart';

/// The overlay is what the user actually sees while a write is pending. If it is
/// wrong, a task appears twice, or vanishes, or silently reverts — so every case
/// below is something that would look like data loss on screen.

Task task(String id, {String title = 't', String status = 'todo', String? parent}) =>
    Task.fromJson(<String, dynamic>{
      'id': id,
      'title': title,
      'status': status,
      'priority': 'medium',
      'parentTaskId': parent,
    });

QueuedOp op({
  required String id,
  required int seq,
  required OpKind kind,
  String target = '',
  String? assigns,
  Map<String, dynamic>? body,
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
    );

void main() {
  group('Task.toJson', () {
    test('a fully populated task survives a round trip', () {
      final Task t = Task.fromJson(<String, dynamic>{
        'id': 'srv1',
        'title': 'Buy milk',
        'description': 'oat',
        'status': 'todo',
        'priority': 'high',
        'dueDate': '2026-08-04',
        'startDate': '2026-08-01',
        'isAllDay': true,
        'order': 30,
        'priorityRank': 2,
        'timeEstimateMin': 45,
        'estimatedPomos': 2,
        'actualMin': 12,
        'parentTaskId': null,
        'listId': 'l1',
        'goalId': 'g1',
        'tags': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'tag1', 'name': 'errands', 'color': '#fff'}
        ],
        'recurrence': <String, dynamic>{'freq': 'weekly', 'interval': 2},
        'reminders': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'r1', 'triggerAt': '2026-08-04T09:00:00.000Z'}
        ],
      });

      final Task back = Task.fromJson(t.toJson());
      expect(back.id, t.id);
      expect(back.title, t.title);
      expect(back.description, t.description);
      expect(back.status, t.status);
      expect(back.priority, t.priority);
      expect(back.dueDate, t.dueDate);
      expect(back.startDate, t.startDate);
      expect(back.isAllDay, t.isAllDay);
      expect(back.order, t.order);
      expect(back.priorityRank, t.priorityRank);
      expect(back.timeEstimateMin, t.timeEstimateMin);
      expect(back.estimatedPomos, t.estimatedPomos);
      expect(back.actualMin, t.actualMin);
      expect(back.listId, t.listId);
      expect(back.goalId, t.goalId);
      expect(back.tags.length, 1);
      expect(back.tags.first.name, 'errands');
      expect(back.recurrence!.freq, 'weekly');
      expect(back.recurrence!.interval, 2);
      expect(back.reminders.length, 1);
      expect(back.reminders.first.triggerAt, t.reminders.first.triggerAt);
    });
  });

  group('taskJsonFromCreateBody', () {
    test('maps every field the task editor actually sends', () {
      final Map<String, dynamic> j = taskJsonFromCreateBody('local_a', <String, dynamic>{
        'title': 'Buy milk',
        'description': 'oat',
        'priority': 'high',
        'dueDate': '2026-08-04',
        'listId': 'l1',
        'goalId': 'g1',
        'tags': <String>['errands'],
        'reminders': <String>['2026-08-04T09:00:00.000Z'],
        'recurrence': 'weekly',
        'parentTaskId': 'srv-parent',
      });
      final Task t = Task.fromJson(j);

      expect(t.id, 'local_a');
      expect(t.title, 'Buy milk');
      expect(t.description, 'oat');
      expect(t.priority, 'high');
      expect(t.status, 'todo');
      expect(t.listId, 'l1');
      expect(t.goalId, 'g1');
      expect(t.parentTaskId, 'srv-parent');
      expect(t.tags.single.name, 'errands');
      expect(t.recurrence!.freq, 'weekly');
      expect(t.reminders.length, 1);
    });

    test('server-assigned values are left null rather than guessed', () {
      // `order` is max(order)+10 server-side. Inventing one would put a number on
      // screen that the real response then silently contradicts.
      final Task t = Task.fromJson(
          taskJsonFromCreateBody('local_a', <String, dynamic>{'title': 'x'}));
      expect(t.order, isNull);
      expect(t.priorityRank, isNull);
      expect(t.completedAt, isNull);
      expect(t.actualMin, 0);
    });
  });

  group('applyPatchToTaskJson', () {
    Map<String, dynamic> base() => task('srv1', title: 'old').toJson();

    test('only keys present in the body change anything', () {
      final Map<String, dynamic> out =
          applyPatchToTaskJson(base(), <String, dynamic>{'title': 'new'});
      final Task t = Task.fromJson(out);
      expect(t.title, 'new');
      expect(t.priority, 'medium');
      expect(t.status, 'todo');
    });

    test('an empty-string date clears it, mirroring the server', () {
      final Map<String, dynamic> withDate =
          applyPatchToTaskJson(base(), <String, dynamic>{'dueDate': '2026-08-04'});
      expect(Task.fromJson(withDate).dueDate, isNotNull);

      final Map<String, dynamic> cleared =
          applyPatchToTaskJson(withDate, <String, dynamic>{'dueDate': ''});
      expect(Task.fromJson(cleared).dueDate, isNull);
    });

    test('null clears listId, goalId and description', () {
      final Map<String, dynamic> set = applyPatchToTaskJson(base(), <String, dynamic>{
        'listId': 'l1',
        'goalId': 'g1',
        'description': 'd',
      });
      expect(Task.fromJson(set).listId, 'l1');

      final Map<String, dynamic> cleared = applyPatchToTaskJson(set, <String, dynamic>{
        'listId': null,
        'goalId': null,
        'description': null,
      });
      final Task t = Task.fromJson(cleared);
      expect(t.listId, isNull);
      expect(t.goalId, isNull);
      expect(t.description, isNull);
    });

    test('tags are a full replacement, never a merge', () {
      final Map<String, dynamic> one =
          applyPatchToTaskJson(base(), <String, dynamic>{'tags': <String>['a', 'b']});
      expect(Task.fromJson(one).tags.map((Tag t) => t.name), <String>['a', 'b']);

      final Map<String, dynamic> two =
          applyPatchToTaskJson(one, <String, dynamic>{'tags': <String>['c']});
      expect(Task.fromJson(two).tags.map((Tag t) => t.name), <String>['c']);
    });

    test('a null recurrence removes the rule', () {
      final Map<String, dynamic> set =
          applyPatchToTaskJson(base(), <String, dynamic>{'recurrence': 'daily'});
      expect(Task.fromJson(set).recurrence, isNotNull);

      final Map<String, dynamic> removed =
          applyPatchToTaskJson(set, <String, dynamic>{'recurrence': null});
      expect(Task.fromJson(removed).recurrence, isNull);
    });
  });

  group('applyQueue', () {
    test('an empty queue returns the server list untouched', () {
      final List<Task> server = <Task>[task('srv1')];
      expect(applyQueue(server, const <QueuedOp>[], const <String, String>{}),
          same(server));
    });

    test('a queued create appears as a row under its local id', () {
      final List<Task> out = applyQueue(
        <Task>[task('srv1')],
        <QueuedOp>[
          op(
            id: 'o1',
            seq: 1,
            kind: OpKind.createTask,
            assigns: 'local_a',
            body: <String, dynamic>{'title': 'Buy milk'},
          )
        ],
        const <String, String>{},
      );
      expect(out.length, 2);
      expect(out.last.id, 'local_a');
      expect(out.last.title, 'Buy milk');
    });

    test('once the real row arrives the shadow is not added twice', () {
      // Otherwise the instant the create lands and a refresh brings back the real
      // task, the user sees the same task listed twice until the queue drains.
      final List<Task> out = applyQueue(
        <Task>[task('srv-new', title: 'Buy milk')],
        <QueuedOp>[
          op(
            id: 'o1',
            seq: 1,
            kind: OpKind.createTask,
            assigns: 'local_a',
            body: <String, dynamic>{'title': 'Buy milk'},
          )
        ],
        <String, String>{'local_a': 'srv-new'},
      );
      expect(out.length, 1);
      expect(out.single.id, 'srv-new');
    });

    test('an update matches by local id AND by mapped server id', () {
      final QueuedOp patch = op(
        id: 'o1',
        seq: 1,
        kind: OpKind.updateTask,
        target: 'local_a',
        body: <String, dynamic>{'title': 'renamed'},
      );

      final List<Task> byLocal =
          applyQueue(<Task>[task('local_a')], <QueuedOp>[patch], const <String, String>{});
      expect(byLocal.single.title, 'renamed');

      final List<Task> byMapped = applyQueue(
          <Task>[task('srv1')], <QueuedOp>[patch], <String, String>{'local_a': 'srv1'});
      expect(byMapped.single.title, 'renamed');
    });

    test('a queued complete marks the row completed', () {
      final List<Task> out = applyQueue(
        <Task>[task('srv1')],
        <QueuedOp>[op(id: 'o1', seq: 1, kind: OpKind.completeTask, target: 'srv1')],
        const <String, String>{},
      );
      expect(out.single.status, 'completed');
      expect(out.single.completedAt, isNotNull);
    });

    test('a delete removes the row and its direct children', () {
      final List<Task> out = applyQueue(
        <Task>[task('srv1'), task('srv2', parent: 'srv1'), task('srv3')],
        <QueuedOp>[op(id: 'o1', seq: 1, kind: OpKind.deleteTask, target: 'srv1')],
        const <String, String>{},
      );
      expect(out.map((Task t) => t.id), <String>['srv3']);
    });

    test('ops fold in seq order, so create then delete leaves nothing', () {
      final List<Task> out = applyQueue(
        const <Task>[],
        <QueuedOp>[
          op(id: 'o2', seq: 2, kind: OpKind.deleteTask, target: 'local_a'),
          op(
            id: 'o1',
            seq: 1,
            kind: OpKind.createTask,
            assigns: 'local_a',
            body: <String, dynamic>{'title': 'x'},
          ),
        ],
        const <String, String>{},
      );
      expect(out, isEmpty);
    });

    test('an op naming an unknown id is a no-op, never a throw', () {
      // The task may have been deleted from another device. Throwing here would
      // take out the whole task screen over a bookkeeping mismatch.
      final List<Task> out = applyQueue(
        <Task>[task('srv1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.updateTask, target: 'ghost', body: <String, dynamic>{'title': 'x'}),
          op(id: 'o2', seq: 2, kind: OpKind.completeTask, target: 'ghost'),
          op(id: 'o3', seq: 3, kind: OpKind.deleteTask, target: 'ghost'),
        ],
        const <String, String>{},
      );
      expect(out.length, 1);
      expect(out.single.title, 't');
    });
  });

  group('pendingStateByTaskId', () {
    test('failed outranks sending, which outranks queued', () {
      final Map<String, PendingState> s = pendingStateByEntityId(
        OpEntity.task,
        <QueuedOp>[
          op(id: 'a', seq: 1, kind: OpKind.updateTask, target: 'srv1'),
          op(id: 'b', seq: 2, kind: OpKind.completeTask, target: 'srv2'),
        ],
        <QueuedOp>[op(id: 'c', seq: 3, kind: OpKind.updateTask, target: 'srv3')],
        'b',
        const <String, String>{},
      );
      expect(s['srv1'], PendingState.queued);
      expect(s['srv2'], PendingState.sending);
      expect(s['srv3'], PendingState.failed);
    });

    test('a dead op on a row that also has a pending op still reads as failed', () {
      final Map<String, PendingState> s = pendingStateByEntityId(
        OpEntity.task,
        <QueuedOp>[op(id: 'a', seq: 1, kind: OpKind.updateTask, target: 'srv1')],
        <QueuedOp>[op(id: 'c', seq: 2, kind: OpKind.completeTask, target: 'srv1')],
        null,
        const <String, String>{},
      );
      expect(s['srv1'], PendingState.failed);
    });

    test('a create is keyed by the local id it assigns, and by its mapping', () {
      final Map<String, PendingState> s = pendingStateByEntityId(
        OpEntity.task,
        <QueuedOp>[
          op(id: 'a', seq: 1, kind: OpKind.createTask, assigns: 'local_a')
        ],
        const <QueuedOp>[],
        null,
        <String, String>{'local_a': 'srv1'},
      );
      expect(s['local_a'], PendingState.queued);
      expect(s['srv1'], PendingState.queued);
    });
  });
}
