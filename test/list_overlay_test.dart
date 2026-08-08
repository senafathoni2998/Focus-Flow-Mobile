import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/offline/list_overlay.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';
import 'package:focusflow_mobile/core/offline/task_overlay.dart';
import 'package:focusflow_mobile/models/task.dart';
import 'package:focusflow_mobile/models/task_list.dart';

/// Lists are the second entity in the queue, and the first to cross id
/// namespaces: a task filed into a list created offline carries a `local_` list
/// id in its body. These cases are where that goes wrong if the wiring is not
/// exactly right.

QueuedOp op({
  required String id,
  required int seq,
  required OpKind kind,
  String target = '',
  String? assigns,
  List<String> deps = const <String>[],
  Map<String, dynamic>? body,
  DeadReason? reason,
}) =>
    QueuedOp(
      id: id,
      seq: seq,
      kind: kind,
      target: target,
      assigns: assigns,
      deps: deps,
      body: body,
      summary: 's',
      createdAtMs: 0,
      reason: reason,
    );

TaskList list(String id, {String name = 'Work'}) =>
    TaskList.fromJson(<String, dynamic>{'id': id, 'name': name});

void main() {
  group('TaskList.toJson', () {
    test('round-trips every field', () {
      final TaskList l = TaskList.fromJson(<String, dynamic>{
        'id': 'srv1',
        'name': 'Work',
        'color': '#abc',
        'order': 20,
      });
      final TaskList back = TaskList.fromJson(l.toJson());
      expect(back.id, 'srv1');
      expect(back.name, 'Work');
      expect(back.color, '#abc');
      expect(back.order, 20);
    });
  });

  group('applyListQueue', () {
    test('a queued create shows up under its local id', () {
      final List<TaskList> out = applyListQueue(
        <TaskList>[list('srv1')],
        <QueuedOp>[
          op(
            id: 'o1',
            seq: 1,
            kind: OpKind.createList,
            assigns: 'local_a',
            body: <String, dynamic>{'name': 'Holiday'},
          )
        ],
        const <String, String>{},
      );
      expect(out.length, 2);
      expect(out.last.id, 'local_a');
      expect(out.last.name, 'Holiday');
    });

    test('order is left null rather than guessed', () {
      // The server assigns it and the drawer does not sort on it, so inventing
      // a number would put a value on screen the real response contradicts.
      final List<TaskList> out = applyListQueue(
        const <TaskList>[],
        <QueuedOp>[
          op(
            id: 'o1',
            seq: 1,
            kind: OpKind.createList,
            assigns: 'local_a',
            body: <String, dynamic>{'name': 'x'},
          )
        ],
        const <String, String>{},
      );
      expect(out.single.order, isNull);
    });

    test('once the real row arrives the shadow is not added twice', () {
      final List<TaskList> out = applyListQueue(
        <TaskList>[list('srv-new', name: 'Holiday')],
        <QueuedOp>[
          op(
            id: 'o1',
            seq: 1,
            kind: OpKind.createList,
            assigns: 'local_a',
            body: <String, dynamic>{'name': 'Holiday'},
          )
        ],
        <String, String>{'local_a': 'srv-new'},
      );
      expect(out.length, 1);
      expect(out.single.id, 'srv-new');
    });

    test('a queued delete removes the row', () {
      final List<TaskList> out = applyListQueue(
        <TaskList>[list('srv1'), list('srv2', name: 'Home')],
        <QueuedOp>[op(id: 'o1', seq: 1, kind: OpKind.deleteList, target: 'srv1')],
        const <String, String>{},
      );
      expect(out.map((TaskList l) => l.id), <String>['srv2']);
    });

    test('create then delete offline leaves nothing', () {
      final List<TaskList> out = applyListQueue(
        const <TaskList>[],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.createList, assigns: 'local_a', body: <String, dynamic>{'name': 'x'}),
          op(id: 'o2', seq: 2, kind: OpKind.deleteList, target: 'local_a'),
        ],
        const <String, String>{},
      );
      expect(out, isEmpty);
    });

    test('a FAILED delete brings the list back', () {
      final List<TaskList> out = applyListQueue(
        <TaskList>[list('srv1')],
        <QueuedOp>[
          op(
            id: 'o1',
            seq: 1,
            kind: OpKind.deleteList,
            target: 'srv1',
            reason: DeadReason.rejected,
          )
        ],
        const <String, String>{},
      );
      expect(out.single.id, 'srv1');
    });

    test('task ops are ignored, not folded through', () {
      final List<TaskList> out = applyListQueue(
        <TaskList>[list('srv1')],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.createTask, assigns: 'local_t', body: <String, dynamic>{'title': 'x'}),
          op(id: 'o2', seq: 2, kind: OpKind.deleteTask, target: 'srv1'),
        ],
        const <String, String>{},
      );
      expect(out.single.id, 'srv1');
    });
  });

  group('the two overlays stay in their own lanes', () {
    test('a list op does not disturb the task overlay', () {
      final List<Task> out = applyQueue(
        <Task>[
          Task.fromJson(<String, dynamic>{'id': 'srv1', 'title': 't', 'status': 'todo'})
        ],
        <QueuedOp>[
          op(id: 'o1', seq: 1, kind: OpKind.deleteList, target: 'srv1'),
        ],
        const <String, String>{},
      );
      // The ids collide on purpose: without the entity filter, a list delete
      // would remove the identically-named TASK row.
      expect(out.length, 1);
    });

    test('badges are keyed per entity, not in one flat map', () {
      final List<QueuedOp> pending = <QueuedOp>[
        op(id: 'o1', seq: 1, kind: OpKind.createTask, assigns: 'shared_id'),
        op(id: 'o2', seq: 2, kind: OpKind.deleteList, target: 'other_id'),
      ];

      final Map<String, PendingState> tasks = pendingStateByEntityId(
          OpEntity.task, pending, const <QueuedOp>[], null, const <String, String>{});
      final Map<String, PendingState> lists = pendingStateByEntityId(
          OpEntity.list, pending, const <QueuedOp>[], null, const <String, String>{});

      expect(tasks.keys, <String>['shared_id']);
      expect(lists.keys, <String>['other_id']);
    });
  });

  group('cross-entity resolution', () {
    test('a task body carrying a local listId is substituted at dispatch', () {
      final Map<String, dynamic> body = <String, dynamic>{
        'title': 'Book flights',
        'listId': 'local_L',
      };
      final QueuedOp o = op(
        id: 'o1',
        seq: 2,
        kind: OpKind.createTask,
        assigns: 'local_t',
        deps: <String>['local_L'],
        body: body,
      );

      final Resolution r = resolve(o, <String, String>{'local_L': 'srvL'});
      expect(r.op!.body!['listId'], 'srvL');
      // The persisted body is untouched — that is what keeps the idempotency
      // body hash stable across retries.
      expect(body['listId'], 'local_L');
    });

    test('an unresolved local listId BLOCKS rather than shipping local_ upstream',
        () {
      final Resolution r = resolve(
        op(
          id: 'o1',
          seq: 2,
          kind: OpKind.createTask,
          assigns: 'local_t',
          deps: <String>['local_L'],
          body: <String, dynamic>{'title': 'x', 'listId': 'local_L'},
        ),
        const <String, String>{},
      );
      expect(r.isReady, isFalse);
      expect(r.missing, contains('local_L'));
    });

    test('a dead list create poisons the tasks filed into it', () {
      final List<QueuedOp> ops = <QueuedOp>[
        op(id: 'cl', seq: 1, kind: OpKind.createList, assigns: 'local_L', body: <String, dynamic>{'name': 'Holiday'}),
        op(id: 'ct', seq: 2, kind: OpKind.createTask, assigns: 'local_t', deps: <String>['local_L'], body: <String, dynamic>{'title': 'x', 'listId': 'local_L'}),
        op(id: 'up', seq: 3, kind: OpKind.updateTask, target: 'local_t', deps: <String>['local_t'], body: <String, dynamic>{'title': 'y'}),
        op(id: 'other', seq: 4, kind: OpKind.createTask, assigns: 'local_z', body: <String, dynamic>{'title': 'unrelated'}),
      ];
      final Set<String> doomed = cascadeFrom(ops, 'local_L');
      expect(doomed, containsAll(<String>['ct', 'up']));
      expect(doomed.contains('cl'), isFalse);
      expect(doomed.contains('other'), isFalse);
    });
  });

  group('list op routing', () {
    test('paths, verbs and the id path are entity-correct', () {
      final Resolution c = resolve(
        op(id: 'o1', seq: 1, kind: OpKind.createList, assigns: 'local_a', body: <String, dynamic>{'name': 'x'}),
        const <String, String>{},
      );
      expect(c.op!.path, '/lists');
      expect(c.op!.method, 'POST');
      // Reading 'task.id' for a list create would drop the new server id and
      // leave every task filed into it permanently unresolvable.
      expect(c.op!.idPath, 'list.id');

      final Resolution d = resolve(
        op(id: 'o2', seq: 2, kind: OpKind.deleteList, target: 'local_a', deps: <String>['local_a']),
        <String, String>{'local_a': 'srvL'},
      );
      expect(d.op!.path, '/lists/srvL');
      expect(d.op!.method, 'DELETE');
      expect(d.op!.idPath, isNull);
    });

    test('a focus session routes to its own three endpoints', () {
      final Resolution c = resolve(
        op(id: 'o1', seq: 1, kind: OpKind.createSession, assigns: 'local_s',
            body: <String, dynamic>{'type': 'pomodoro', 'duration': 1500}),
        const <String, String>{},
      );
      expect(c.op!.path, '/sessions');
      expect(c.op!.method, 'POST');
      expect(c.op!.idPath, 'session.id');

      final Resolution done = resolve(
        op(id: 'o2', seq: 2, kind: OpKind.completeSession, target: 'local_s',
            deps: <String>['local_s']),
        <String, String>{'local_s': 'srvS'},
      );
      expect(done.op!.path, '/sessions/srvS/complete');

      final Resolution stop = resolve(
        op(id: 'o3', seq: 3, kind: OpKind.cancelSession, target: 'local_s',
            deps: <String>['local_s']),
        <String, String>{'local_s': 'srvS'},
      );
      expect(stop.op!.path, '/sessions/srvS/cancel');
    });

    test('a session attributed to an offline task resolves its taskId', () {
      // A pomodoro can be started against a task created in the same offline
      // stretch, so the body carries a local task id — the THIRD cross-entity
      // reference, after parentTaskId and listId.
      final Map<String, dynamic> body = <String, dynamic>{
        'taskId': 'local_T',
        'type': 'pomodoro',
        'duration': 1500,
        'startTime': '2026-08-05T09:00:00.000Z',
      };
      final Resolution r = resolve(
        op(id: 'o1', seq: 2, kind: OpKind.createSession, assigns: 'local_s',
            deps: <String>['local_T'], body: body),
        <String, String>{'local_T': 'srvT'},
      );
      expect(r.op!.body!['taskId'], 'srvT');
      // The frozen start instant is untouched — it is what puts the session on
      // the right DAY once it finally reaches the server.
      expect(r.op!.body!['startTime'], '2026-08-05T09:00:00.000Z');
      expect(body['taskId'], 'local_T');
    });

    test('an unresolved local taskId blocks the session', () {
      final Resolution r = resolve(
        op(id: 'o1', seq: 2, kind: OpKind.createSession, assigns: 'local_s',
            deps: <String>['local_T'],
            body: <String, dynamic>{'taskId': 'local_T', 'duration': 1500}),
        const <String, String>{},
      );
      expect(r.isReady, isFalse);
      expect(r.missing, contains('local_T'));
    });

    test('summaries say "list", not "task"', () {
      expect(summaryFor(OpKind.createList, <String, dynamic>{'name': 'Holiday'}, ''),
          'New list "Holiday"');
      expect(summaryFor(OpKind.deleteList, null, 'Work'), 'Delete list "Work"');
      // Falls back to the right noun when there is nothing to name it by.
      expect(summaryFor(OpKind.createList, null, ''), 'New list a list');
    });

    test('entity and isDelete are derived from the kind', () {
      expect(op(id: 'a', seq: 1, kind: OpKind.createTask).entity, OpEntity.task);
      expect(op(id: 'a', seq: 1, kind: OpKind.deleteList).entity, OpEntity.list);
      expect(op(id: 'a', seq: 1, kind: OpKind.createSession).entity, OpEntity.session);
      expect(op(id: 'a', seq: 1, kind: OpKind.cancelSession).isDelete, isFalse);
      expect(op(id: 'a', seq: 1, kind: OpKind.deleteList).isDelete, isTrue);
      expect(op(id: 'a', seq: 1, kind: OpKind.createList).isDelete, isFalse);
    });
  });
}
