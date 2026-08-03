import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';

/// The offline write queue's entire policy surface lives in queue_op.dart, and
/// every case here is a specific way a user's write could be duplicated, lost,
/// or retried until the battery dies. The file is pure, so all of it is testable
/// without a device.

QueuedOp op({
  String id = 'op_1',
  int seq = 1,
  OpKind kind = OpKind.updateTask,
  String target = 'srv1',
  String? assigns,
  List<String> deps = const <String>[],
  Map<String, dynamic>? body,
  String? key,
  int attempts = 0,
  int createdAtMs = 0,
  int nextAtMs = 0,
}) {
  return QueuedOp(
    id: id,
    seq: seq,
    kind: kind,
    target: target,
    assigns: assigns,
    deps: deps,
    body: body,
    key: key,
    summary: 'summary',
    createdAtMs: createdAtMs,
    attempts: attempts,
    nextAtMs: nextAtMs,
  );
}

void main() {
  group('ids and keys', () {
    test('an idempotency key is 32 hex chars, inside the server 8..200 bound', () {
      final String k = newIdempotencyKey();
      expect(k.length, 32);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(k), isTrue);
      expect(k.length >= 8 && k.length <= 200, isTrue);
    });

    test('10000 keys are all distinct', () {
      final Set<String> seen = <String>{};
      for (int i = 0; i < 10000; i++) {
        seen.add(newIdempotencyKey());
      }
      expect(seen.length, 10000);
    });

    test('a seeded generator is deterministic', () {
      expect(newIdempotencyKey(rng: Random(1)), newIdempotencyKey(rng: Random(1)));
    });

    test('isLocalId recognises only the real prefix', () {
      expect(isLocalId(newLocalId()), isTrue);
      expect(isLocalId('cmf2x9k0a0000qz3h1v7bd4e1'), isFalse);
      expect(isLocalId('local'), isFalse);
    });
  });

  group('classify', () {
    test('no answer at all is a transport retry, whatever the kind', () {
      for (final OpKind k in OpKind.values) {
        expect(classify(kind: k, status: null, hadResponse: false),
            OpOutcome.retryTransport);
      }
    });

    test('2xx succeeds', () {
      expect(classify(kind: OpKind.createTask, status: 200, hadResponse: true),
          OpOutcome.succeeded);
      expect(classify(kind: OpKind.createTask, status: 201, hadResponse: true),
          OpOutcome.succeeded);
    });

    test('404 is success for DELETE only', () {
      expect(classify(kind: OpKind.deleteTask, status: 404, hadResponse: true),
          OpOutcome.succeeded);
      // A completion the server never recorded must NOT be swallowed as success:
      // the op would be dropped and the checkbox would silently un-tick.
      expect(classify(kind: OpKind.completeTask, status: 404, hadResponse: true),
          OpOutcome.terminal);
      expect(classify(kind: OpKind.updateTask, status: 404, hadResponse: true),
          OpOutcome.terminal);
    });

    test('client errors are terminal', () {
      for (final int s in <int>[400, 403, 410, 422]) {
        expect(classify(kind: OpKind.updateTask, status: s, hadResponse: true),
            OpOutcome.terminal);
      }
    });

    test('server errors and throttling are retryable', () {
      for (final int s in <int>[408, 429, 500, 502, 503]) {
        expect(classify(kind: OpKind.updateTask, status: s, hadResponse: true),
            OpOutcome.retryServer);
      }
    });

    test('409 is its own outcome, and 401 pauses', () {
      expect(classify(kind: OpKind.createTask, status: 409, hadResponse: true),
          OpOutcome.retryPending);
      expect(classify(kind: OpKind.createTask, status: 401, hadResponse: true),
          OpOutcome.authPaused);
    });
  });

  group('backoff, due, expiry', () {
    test('backoff is non-decreasing and capped', () {
      Duration prev = Duration.zero;
      for (int i = 0; i < 12; i++) {
        final Duration d = backoffFor(i);
        expect(d >= prev, isTrue, reason: 'attempt $i went backwards');
        prev = d;
      }
      expect(backoffFor(0) > Duration.zero, isTrue);
      expect(backoffFor(5), kMaxBackoff);
      expect(backoffFor(99), kMaxBackoff);
    });

    test('isDue respects the schedule', () {
      const int now = 1000000;
      expect(isDue(op(nextAtMs: now), now), isTrue);
      expect(isDue(op(nextAtMs: now + 3000), now), isFalse);
    });

    test('a wait longer than any backoff we schedule is clock skew, not a wait', () {
      // Set the device clock forward, then back: without this clamp every op is
      // scheduled arbitrarily far ahead and the queue wedges permanently.
      const int now = 1000000;
      final int tenDays = const Duration(days: 10).inMilliseconds;
      expect(isDue(op(nextAtMs: now + tenDays), now), isTrue);
    });

    test('expiry is measured from creation', () {
      final int now = const Duration(days: 20).inMilliseconds;
      final int thirteenDaysAgo = now - const Duration(days: 13).inMilliseconds;
      final int fifteenDaysAgo = now - const Duration(days: 15).inMilliseconds;
      expect(isExpired(op(createdAtMs: thirteenDaysAgo), now), isFalse);
      expect(isExpired(op(createdAtMs: fifteenDaysAgo), now), isTrue);
    });
  });

  group('resolve at dispatch', () {
    test('a local target becomes the mapped server id', () {
      final Resolution r = resolve(
        op(kind: OpKind.updateTask, target: 'local_a', deps: <String>['local_a']),
        <String, String>{'local_a': 'srv1'},
      );
      expect(r.isReady, isTrue);
      expect(r.op!.path, '/tasks/srv1');
      expect(r.op!.method, 'PATCH');
    });

    test('complete and delete resolve to their own paths', () {
      final Resolution c = resolve(
        op(kind: OpKind.completeTask, target: 'local_a', deps: <String>['local_a']),
        <String, String>{'local_a': 'srv1'},
      );
      expect(c.op!.path, '/tasks/srv1/complete');
      expect(c.op!.method, 'POST');

      final Resolution d = resolve(
        op(kind: OpKind.deleteTask, target: 'local_a', deps: <String>['local_a']),
        <String, String>{'local_a': 'srv1'},
      );
      expect(d.op!.path, '/tasks/srv1');
      expect(d.op!.method, 'DELETE');
    });

    test('a parentTaskId in the body is substituted, and the stored body is not', () {
      final Map<String, dynamic> body = <String, dynamic>{
        'title': 'Check the fridge',
        'parentTaskId': 'local_a',
      };
      final QueuedOp o = op(
        kind: OpKind.createTask,
        target: '',
        assigns: 'local_b',
        deps: <String>['local_a'],
        body: body,
      );
      final String before = jsonEncode(o.body);

      final Resolution r = resolve(o, <String, String>{'local_a': 'srv1'});
      expect(r.op!.body!['parentTaskId'], 'srv1');
      expect(r.op!.path, '/tasks');
      expect(r.op!.idPath, 'task.id');

      // THE load-bearing assertion: the persisted body is untouched. If it were
      // rewritten after the key was minted, the server's body hash would change
      // and the retry would 422 forever with no way to recover the write.
      expect(jsonEncode(o.body), before);
      expect(o.body!['parentTaskId'], 'local_a');
    });

    test('a title that merely looks like a local id survives verbatim', () {
      final QueuedOp o = op(
        kind: OpKind.createTask,
        target: '',
        assigns: 'local_b',
        body: <String, dynamic>{'title': 'local_max notes'},
      );
      final Resolution r = resolve(o, <String, String>{'local_max': 'srv9'});
      expect(r.op!.body!['title'], 'local_max notes');
    });

    test('an unmapped local id blocks rather than shipping local_ to the server', () {
      final Resolution r = resolve(
        op(kind: OpKind.updateTask, target: 'local_a', deps: <String>['local_a']),
        <String, String>{},
      );
      expect(r.isReady, isFalse);
      expect(r.op, isNull);
      expect(r.missing, <String>['local_a']);
    });

    test('a server-id target passes straight through', () {
      final Resolution r = resolve(op(target: 'srv1'), <String, String>{});
      expect(r.op!.path, '/tasks/srv1');
    });

    test('unresolvedDeps lists exactly what is missing', () {
      final QueuedOp o = op(deps: <String>['local_a', 'local_b']);
      expect(unresolvedDeps(o, <String, String>{'local_a': 'srv1'}),
          <String>['local_b']);
      expect(unresolvedDeps(o, <String, String>{'local_a': 'x', 'local_b': 'y'}),
          isEmpty);
    });
  });

  group('cascade and annihilation', () {
    List<QueuedOp> chain() => <QueuedOp>[
          op(id: 'c_a', seq: 1, kind: OpKind.createTask, target: '', assigns: 'local_a'),
          op(id: 'p_a', seq: 2, kind: OpKind.updateTask, target: 'local_a', deps: <String>['local_a']),
          op(id: 'c_b', seq: 3, kind: OpKind.createTask, target: '', assigns: 'local_b', deps: <String>['local_a'], body: <String, dynamic>{'parentTaskId': 'local_a'}),
          op(id: 'k_b', seq: 4, kind: OpKind.completeTask, target: 'local_b', deps: <String>['local_b']),
          op(id: 'other', seq: 5, kind: OpKind.updateTask, target: 'srv9'),
        ];

    test('a dead create poisons its dependents transitively', () {
      final Set<String> doomed = cascadeFrom(chain(), 'local_a');
      expect(doomed, containsAll(<String>['p_a', 'c_b', 'k_b']));
    });

    test('the dead create itself and unrelated ops are not in the set', () {
      final Set<String> doomed = cascadeFrom(chain(), 'local_a');
      expect(doomed.contains('c_a'), isFalse);
      expect(doomed.contains('other'), isFalse);
    });

    test('create-then-delete offline never touches the network', () {
      final List<QueuedOp> ops = <QueuedOp>[
        op(id: 'c', seq: 1, kind: OpKind.createTask, target: '', assigns: 'local_a'),
        op(id: 'd', seq: 2, kind: OpKind.deleteTask, target: 'local_a', deps: <String>['local_a']),
      ];
      expect(cancelCreateThenDelete(ops, 'local_a'), isEmpty);
    });

    test('once the create has been attempted both ops must run', () {
      // The outcome is unknown, so a server row may exist that only the delete
      // can clean up. Dropping both would leak a task the user deleted.
      final List<QueuedOp> ops = <QueuedOp>[
        op(id: 'c', seq: 1, kind: OpKind.createTask, target: '', assigns: 'local_a', attempts: 1),
        op(id: 'd', seq: 2, kind: OpKind.deleteTask, target: 'local_a', deps: <String>['local_a']),
      ];
      expect(cancelCreateThenDelete(ops, 'local_a'), isNull);
    });

    test('no delete queued means nothing is cancelled', () {
      final List<QueuedOp> ops = <QueuedOp>[
        op(id: 'c', seq: 1, kind: OpKind.createTask, target: '', assigns: 'local_a'),
      ];
      expect(cancelCreateThenDelete(ops, 'local_a'), isNull);
    });
  });

  group('serialization', () {
    test('every field round-trips', () {
      final QueuedOp o = QueuedOp(
        id: 'op_x',
        seq: 7,
        kind: OpKind.completeTask,
        target: 'srv1',
        assigns: 'local_z',
        deps: <String>['local_a', 'local_b'],
        body: <String, dynamic>{'a': 1},
        key: 'abcdefabcdefabcdefabcdefabcdefab',
        summary: 'Complete "x"',
        createdAtMs: 123,
        attempts: 2,
        serverAttempts: 1,
        pendingAttempts: 1,
        nextAtMs: 456,
        errorStatus: 400,
        errorMessage: 'nope',
        reason: DeadReason.rejected,
        diedAtMs: 789,
      );
      final QueuedOp? back = QueuedOp.fromJson(o.toJson());
      expect(back, isNotNull);
      expect(back!.id, o.id);
      expect(back.seq, o.seq);
      expect(back.kind, o.kind);
      expect(back.target, o.target);
      expect(back.assigns, o.assigns);
      expect(back.deps, o.deps);
      expect(back.key, o.key);
      expect(back.summary, o.summary);
      expect(back.attempts, o.attempts);
      expect(back.serverAttempts, o.serverAttempts);
      expect(back.pendingAttempts, o.pendingAttempts);
      expect(back.nextAtMs, o.nextAtMs);
      expect(back.errorStatus, o.errorStatus);
      expect(back.errorMessage, o.errorMessage);
      expect(back.reason, DeadReason.rejected);
      expect(back.diedAtMs, o.diedAtMs);
    });

    test('an unknown kind is dropped, not thrown', () {
      // One bad row must not cost the user the rest of the queue.
      expect(QueuedOp.fromJson(<String, dynamic>{'kind': 'createHabit', 'id': 'x', 'seq': 1}),
          isNull);
      expect(QueuedOp.fromJson(<String, dynamic>{'kind': 'createTask'}), isNull);
    });

    test('body key order survives a disk round trip', () {
      // The server hashes JSON.stringify(body). If the key order changed across
      // a restart, the retry would carry a different hash under an already-minted
      // key and 422 forever — a write the user made, permanently unsendable.
      final Map<String, dynamic> body = <String, dynamic>{
        'title': 'z',
        'priority': 'high',
        'dueDate': '2026-08-04',
        'listId': null,
        'goalId': null,
        'tags': <String>['b', 'a'],
        'reminders': <String>[],
        'recurrence': null,
        'description': 'd',
        'parentTaskId': null,
      };
      final QueuedOp o = op(kind: OpKind.createTask, target: '', assigns: 'local_a', body: body);

      final String onDisk = jsonEncode(o.toJson());
      final QueuedOp back =
          QueuedOp.fromJson(jsonDecode(onDisk) as Map<String, dynamic>)!;

      expect(jsonEncode(back.body), jsonEncode(o.body));
    });
  });

  test('copyWith leaves identity alone and updates counters', () {
    final QueuedOp o = op(id: 'op_1', attempts: 1);
    final QueuedOp n = o.copyWith(attempts: 2, nextAtMs: 99);
    expect(n.id, 'op_1');
    expect(n.seq, o.seq);
    expect(n.attempts, 2);
    expect(n.nextAtMs, 99);
    expect(n.serverAttempts, o.serverAttempts);
  });

  test('method matches the route each op actually calls', () {
    expect(op(kind: OpKind.createTask).method, 'POST');
    expect(op(kind: OpKind.completeTask).method, 'POST');
    expect(op(kind: OpKind.updateTask).method, 'PATCH');
    expect(op(kind: OpKind.deleteTask).method, 'DELETE');
  });

  test('summaries name the task so a dead letter is readable', () {
    expect(summaryFor(OpKind.createTask, <String, dynamic>{'title': 'Buy milk'}, ''),
        'New task "Buy milk"');
    expect(summaryFor(OpKind.completeTask, null, 'Water plants'),
        'Complete "Water plants"');
    expect(summaryFor(OpKind.deleteTask, null, ''), 'Delete a task');
  });
}
