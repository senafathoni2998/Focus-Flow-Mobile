import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/api_exception.dart';
import 'package:focusflow_mobile/core/offline/queue_flusher.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';
import 'package:focusflow_mobile/core/offline/write_queue_store.dart';

/// Every case here is a specific way a user's write could be duplicated, lost,
/// or retried until the battery dies. The transport is scripted and the clock is
/// injected, so none of it touches a network or waits on real time.

class FakeTransport implements QueueTransport {
  FakeTransport(this.script);

  /// One entry per send, in order. The last entry repeats once exhausted, which
  /// is what makes "always 500" and "always 409" easy to express.
  final List<TransportResult> script;
  final List<ResolvedOp> sent = <ResolvedOp>[];

  @override
  Future<TransportResult> send(ResolvedOp op) async {
    sent.add(op);
    final int i = sent.length - 1;
    return script[i < script.length ? i : script.length - 1];
  }
}

TransportResult ok({int status = 201, String id = 'srv1'}) => TransportResult(
      status: status,
      hadResponse: true,
      body: <String, dynamic>{
        'task': <String, dynamic>{'id': id, 'title': 'x', 'status': 'todo'}
      },
    );

TransportResult offline() =>
    const TransportResult(status: null, hadResponse: false, message: 'no network');

TransportResult http(int status, {String? message, int? retryAfter}) => TransportResult(
      status: status,
      hadResponse: true,
      message: message ?? 'status $status',
      retryAfterSeconds: retryAfter,
    );

QueuedOp mkOp(
  String id, {
  OpKind kind = OpKind.createTask,
  String target = '',
  String? assigns,
  List<String> deps = const <String>[],
  Map<String, dynamic>? body,
  String? key,
}) =>
    QueuedOp(
      id: id,
      seq: 0,
      kind: kind,
      target: target,
      assigns: assigns,
      deps: deps,
      body: body ?? (kind == OpKind.createTask ? <String, dynamic>{'title': id} : null),
      key: key ??
          (kind == OpKind.createTask || kind == OpKind.completeTask
              ? 'key_$id${'0' * 8}'
              : null),
      summary: '$kind $id',
      createdAtMs: 0,
    );

/// Let every already-scheduled microtask and zero-duration future run.
Future<void> pump() async {
  for (int i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Directory dir;
  late WriteQueueStore store;
  late FakeTransport transport;
  late QueueFlusher flusher;
  late List<Map<String, dynamic>> serverTasks;
  late int drained;
  int now = 1000000;
  String? uid = 'u1';

  QueueFlusher build(List<TransportResult> script) {
    transport = FakeTransport(script);
    serverTasks = <Map<String, dynamic>>[];
    drained = 0;
    return QueueFlusher(
      store: store,
      transport: transport,
      currentUserId: () async => uid,
      onChanged: (QueueDoc _, String? __, FlushState ___) {},
      onServerTask: serverTasks.add,
      onDrained: () => drained++,
      nowMs: () => now,
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('focusflow_flusher_test');
    store = WriteQueueStore(directory: dir)..setScope('u1');
    now = 1000000;
    uid = 'u1';
  });

  tearDown(() async {
    flusher.dispose();
    await pump();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('ops go out in seq order and the queue ends empty', () async {
    flusher = build(<TransportResult>[ok(id: 'a'), ok(id: 'b'), ok(id: 'c')]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await flusher.submit(mkOp('b', assigns: 'local_b'));
    await flusher.submit(mkOp('c', assigns: 'local_c'));
    await pump();
    await flusher.flush(force: true);
    await pump();

    expect(transport.sent.map((ResolvedOp o) => o.key),
        <String>['key_a00000000', 'key_b00000000', 'key_c00000000']);
    expect(flusher.pendingCount, 0);
    expect(flusher.deadCount, 0);
    expect(drained, greaterThan(0));
  });

  test('a lost response replays the SAME key and creates one task', () async {
    // The request left the socket, the answer never came back. Retrying without
    // a stable key is how you get two identical tasks.
    flusher = build(<TransportResult>[offline(), ok()]);
    final SubmitOutcome first =
        (await flusher.submit(mkOp('a', assigns: 'local_a'))).outcome;
    expect(first, SubmitOutcome.deferred);
    expect(flusher.pendingCount, 1);

    await pump();
    await flusher.flush(force: true);
    await pump();

    expect(transport.sent.length, 2);
    expect(transport.sent[0].key, transport.sent[1].key);
    expect(flusher.pendingCount, 0);
    expect(flusher.deadCount, 0);
  });

  test('a transport failure consumes no budget and stops the pass', () async {
    flusher = build(<TransportResult>[offline()]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await flusher.submit(mkOp('b', assigns: 'local_b'));
    await pump();

    // Only the head was tried: there is no network, so burning through the rest
    // would collect identical failures and inflate every counter for one cause.
    expect(transport.sent.length, 1);
    expect(flusher.state, FlushState.pausedOffline);
    expect(flusher.deadCount, 0);
  });

  test('being offline for a long time never dead-letters a valid write', () async {
    // The whole point of the no-budget rule. Far more attempts than either
    // budget would allow, and the write is still there waiting.
    flusher = build(<TransportResult>[offline()]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    for (int i = 0; i < kServerBudget + kPendingBudget + 5; i++) {
      await pump();
    await flusher.flush(force: true);
      await pump();
    }

    expect(flusher.deadCount, 0);
    expect(flusher.pendingCount, 1);
    final QueuedOp head = flusher.doc.ops.first;
    expect(head.serverAttempts, 0);
    expect(head.pendingAttempts, 0);
    // ...but it does record that it reached the wire, which is what stops a
    // create+delete pair from being annihilated after a lost response.
    expect(head.attempts, greaterThan(0));
  });

  test('a defer pushes nextAt out, so a trigger storm cannot hammer a dead socket',
      () async {
    flusher = build(<TransportResult>[offline()]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    expect(transport.sent.length, 1);
    expect(flusher.doc.ops.first.nextAtMs, greaterThan(now));

    // Three more triggers, none of them due yet.
    flusher.kick();
    flusher.kick();
    await flusher.flush();
    await pump();
    expect(transport.sent.length, 1);
  });

  test('repeated 5xx exhausts the budget and dead-letters as unconfirmed', () async {
    flusher = build(<TransportResult>[http(500)]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    for (int i = 0; i < kServerBudget + 2; i++) {
      await pump();
    await flusher.flush(force: true);
      await pump();
    }

    expect(transport.sent.length, kServerBudget);
    expect(flusher.pendingCount, 0);
    expect(flusher.deadCount, 1);
    expect(flusher.doc.dead.single.reason, DeadReason.unconfirmed);
  });

  test('409 has its own budget and reuses the key every time', () async {
    // idempotency.ts never releases a key stranded in `pending`, so without a
    // bound this would 409 until the phone died.
    flusher = build(<TransportResult>[http(409, retryAfter: 1)]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    for (int i = 0; i < kPendingBudget + 2; i++) {
      await pump();
    await flusher.flush(force: true);
      await pump();
    }

    expect(transport.sent.length, kPendingBudget);
    expect(transport.sent.map((ResolvedOp o) => o.key).toSet().length, 1);
    expect(flusher.doc.dead.single.reason, DeadReason.unconfirmed);
    expect(flusher.doc.dead.single.errorMessage, contains("couldn't confirm"));
  });

  test('a terminal failure does not block the ops behind it', () async {
    // The leading offline() is what gets all three ops queued: submit() attempts
    // inline whenever the queue is empty, and a terminal result there THROWS to
    // the editor instead of dead-lettering (see the submit group below).
    flusher = build(<TransportResult>[
      offline(),
      ok(id: 'srvA'),
      http(400, message: 'Invalid status'),
      ok(id: 'srvC'),
    ]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await flusher.submit(mkOp('b', kind: OpKind.updateTask, target: 'srv9', body: <String, dynamic>{'status': 'nope'}));
    await flusher.submit(mkOp('c', assigns: 'local_c'));
    await pump();
    await flusher.flush(force: true);
    await pump();

    expect(transport.sent.length, 4);
    expect(flusher.deadCount, 1);
    expect(flusher.doc.dead.single.reason, DeadReason.rejected);
    expect(flusher.doc.dead.single.errorStatus, 400);
    expect(flusher.pendingCount, 0);
  });

  test('a dead create takes its dependents with it, unsent', () async {
    flusher = build(<TransportResult>[
      offline(),
      http(400, message: 'Title is required'),
      ok(id: 'srvZ'),
    ]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await flusher.submit(mkOp('b',
        kind: OpKind.updateTask,
        target: 'local_a',
        deps: <String>['local_a'],
        body: <String, dynamic>{'title': 'edited'}));
    await flusher.submit(mkOp('c',
        assigns: 'local_c',
        deps: <String>['local_a'],
        body: <String, dynamic>{'title': 'sub', 'parentTaskId': 'local_a'}));
    await flusher.submit(mkOp('z', assigns: 'local_z'));

    await pump();
    await flusher.flush(force: true);
    await pump();

    // The create (twice — the offline attempt, then the 400) and the unrelated
    // op. The two dependents never went at all: three 404s and three baffling
    // dead letters for one cause helps nobody.
    expect(transport.sent.length, 3);
    expect(flusher.deadCount, 3);
    expect(
      flusher.doc.dead.map((QueuedOp o) => o.reason).toList(),
      <DeadReason>[DeadReason.rejected, DeadReason.orphaned, DeadReason.orphaned],
    );
    expect(flusher.pendingCount, 0);
  });

  test('a create\'s server id resolves everything queued behind it', () async {
    flusher = build(<TransportResult>[
      offline(),
      ok(id: 'srv1'),
      ok(status: 200, id: 'srv1'),
      ok(id: 'srv2'),
    ]);
    final Map<String, dynamic> patchBody = <String, dynamic>{'title': 'edited'};
    final Map<String, dynamic> subBody = <String, dynamic>{'title': 'sub', 'parentTaskId': 'local_a'};

    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await flusher.submit(mkOp('b',
        kind: OpKind.updateTask, target: 'local_a', deps: <String>['local_a'], body: patchBody));
    await flusher.submit(mkOp('c',
        assigns: 'local_c', deps: <String>['local_a'], body: subBody));

    await pump();
    await flusher.flush(force: true);
    await pump();

    expect(transport.sent[2].path, '/tasks/srv1');
    expect(transport.sent[3].body!['parentTaskId'], 'srv1');
    // And the PERSISTED bodies were never touched — that is what keeps the
    // idempotency body hash stable across retries.
    expect(subBody['parentTaskId'], 'local_a');
    expect(flusher.doc.idMap['local_a'], 'srv1');
  });

  test('404 is success on a delete and terminal on anything else', () async {
    flusher = build(<TransportResult>[http(404)]);
    await flusher.submit(mkOp('d', kind: OpKind.deleteTask, target: 'srv1'));
    await pump();
    await flusher.flush(force: true);
    await pump();
    expect(flusher.pendingCount, 0);
    expect(flusher.deadCount, 0);

    flusher.dispose();
    flusher = build(<TransportResult>[offline(), http(404)]);
    await flusher.submit(mkOp('p',
        kind: OpKind.updateTask, target: 'srv1', body: <String, dynamic>{'title': 'x'}));
    await pump();
    await flusher.flush(force: true);
    await pump();
    expect(flusher.deadCount, 1);
    expect(flusher.doc.dead.single.reason, DeadReason.rejected);
  });

  test('a 401 pauses without charging the op, and resumes on the same key', () async {
    flusher = build(<TransportResult>[http(401), ok()]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await pump();

    expect(flusher.state, FlushState.pausedAuth);
    expect(flusher.pendingCount, 1);
    expect(flusher.doc.ops.single.attempts, 0);

    await flusher.submit(mkOp('b', assigns: 'local_b'));
    await pump();
    // Still paused: nothing more goes out until the session is back.
    expect(transport.sent.length, 1);

    flusher.resumeAfterSignIn();
    await pump();
    expect(transport.sent.length, greaterThanOrEqualTo(2));
    expect(transport.sent[0].key, transport.sent[1].key);
  });

  test('the user id is re-checked before every send, not once per pass', () async {
    // Namespacing a file is not a security boundary — the ops are already in
    // memory. Without this check, user A's writes go out on user B's token.
    int calls = 0;
    transport = FakeTransport(<TransportResult>[ok(id: 'srv1')]);
    flusher = QueueFlusher(
      store: store,
      transport: transport,
      currentUserId: () async {
        calls++;
        return calls <= 1 ? 'u1' : 'u2';
      },
      onChanged: (QueueDoc _, String? __, FlushState ___) {},
      onServerTask: (Map<String, dynamic> _) {},
      onDrained: () {},
      nowMs: () => now,
    );

    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await flusher.submit(mkOp('b', assigns: 'local_b'));
    await pump();
    await flusher.flush(force: true);
    await pump();

    expect(transport.sent.length, lessThanOrEqualTo(1));
  });

  test('an op that outlived the expiry window is dead-lettered', () async {
    flusher = build(<TransportResult>[ok()]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    await pump();
    expect(flusher.pendingCount, 0);

    // A second op, then jump the clock past the window before it can go.
    flusher.dispose();
    flusher = build(<TransportResult>[offline()]);
    await flusher.submit(mkOp('b', assigns: 'local_b'));
    await pump();
    expect(flusher.pendingCount, 1);

    now += const Duration(days: kExpiryDays + 1).inMilliseconds;
    await pump();
    await flusher.flush(force: true);
    await pump();

    expect(flusher.deadCount, 1);
    expect(flusher.doc.dead.single.reason, DeadReason.expired);
  });

  group('submit', () {
    test('returns sent on an immediate success', () async {
      flusher = build(<TransportResult>[ok()]);
      expect((await flusher.submit(mkOp('a', assigns: 'local_a'))).outcome,
          SubmitOutcome.sent);
      expect(serverTasks.single['id'], 'srv1');
    });

    test('THROWS on an immediate rejection and never dead-letters it', () async {
      // Online, a 400 must still surface inline in the editor exactly as it did
      // before the queue existed. Only genuinely deferred writes can become
      // "Unsent changes".
      flusher = build(<TransportResult>[http(400, message: 'Title is required')]);
      await expectLater(
        flusher.submit(mkOp('a', assigns: 'local_a')),
        throwsA(isA<ApiException>()
            .having((ApiException e) => e.message, 'message', 'Title is required')),
      );
      expect(flusher.deadCount, 0);
      expect(flusher.pendingCount, 0);
    });

    test('returns deferred and keeps the op when there is no network', () async {
      flusher = build(<TransportResult>[offline()]);
      expect((await flusher.submit(mkOp('a', assigns: 'local_a'))).outcome,
          SubmitOutcome.deferred);
      expect(flusher.pendingCount, 1);
    });

    test('defers without sending when something is already queued', () async {
      flusher = build(<TransportResult>[offline()]);
      await flusher.submit(mkOp('a', assigns: 'local_a'));
      expect(transport.sent.length, 1);

      expect((await flusher.submit(mkOp('b', assigns: 'local_b'))).outcome,
          SubmitOutcome.deferred);
      await pump();
      // Strict FIFO: b cannot jump ahead of a, and a is in backoff.
      expect(transport.sent.length, 1);
      expect(flusher.pendingCount, 2);
    });

    test('a task typed then deleted before anything was sent is annihilated', () async {
      // 'first' occupies the head and fails offline, so 'a' is queued behind it
      // and never reaches the wire. Deleting it then costs nothing at all.
      flusher = build(<TransportResult>[offline()]);
      await flusher.submit(mkOp('first', assigns: 'local_first'));
      await flusher.submit(mkOp('a', assigns: 'local_a'));
      await pump();
      expect(flusher.pendingCount, 2);
      expect(transport.sent.length, 1);

      await flusher.submit(mkOp('d',
          kind: OpKind.deleteTask, target: 'local_a', deps: <String>['local_a']));
      await pump();

      expect(flusher.pendingCount, 1);
      expect(flusher.doc.ops.single.assigns, 'local_first');
      expect(transport.sent.length, 1);
    });

    test('after an unanswered send, the delete must still run', () async {
      // The create reached the wire and the answer was lost, so a row may exist
      // that only the delete can clean up. Annihilating both would leak it.
      flusher = build(<TransportResult>[offline()]);
      await flusher.submit(mkOp('a', assigns: 'local_a'));
      await pump();
      expect(flusher.doc.ops.single.attempts, greaterThan(0));

      await flusher.submit(mkOp('d',
          kind: OpKind.deleteTask, target: 'local_a', deps: <String>['local_a']));
      await pump();
      expect(flusher.pendingCount, 2);
    });

    test('the queue refuses new work at its cap rather than growing forever', () async {
      flusher = build(<TransportResult>[offline()]);
      for (int i = 0; i < kMaxPending; i++) {
        await flusher.submit(mkOp('op$i', assigns: 'local_$i'));
      }
      expect(flusher.pendingCount, kMaxPending);
      await expectLater(flusher.submit(mkOp('over', assigns: 'local_over')),
          throwsA(isA<QueueFullException>()));
      expect(flusher.pendingCount, kMaxPending);
    });
  });

  group('dead letter', () {
    test('retry reuses the key when the server released it', () async {
      // A handler returning non-2xx makes withIdempotency delete the key row, so
      // it is free again — and reusing it keeps the lost-response protection for
      // the retry, which a fresh key would throw away for nothing.
      flusher = build(<TransportResult>[offline(), http(400), offline()]);
      await flusher.submit(mkOp('a', assigns: 'local_a'));
      await pump();
    await flusher.flush(force: true);
      await pump();

      expect(flusher.deadCount, 1);
      final QueuedOp dead = flusher.doc.dead.single;
      expect(dead.errorStatus, 400);

      await flusher.retryDead(dead.id);
      expect(flusher.doc.ops.single.key, dead.key);
      expect(flusher.deadCount, 0);
    });

    test('retry after a 422 mints a FRESH key', () async {
      // A 422 is thrown before the handler runs, so the key was never released
      // and is still bound to the other body hash. The same key would 422 forever.
      flusher = build(<TransportResult>[offline(), http(422)]);
      await flusher.submit(mkOp('a', assigns: 'local_a'));
      await pump();
    await flusher.flush(force: true);
      await pump();

      expect(flusher.deadCount, 1);
      final QueuedOp dead = flusher.doc.dead.single;
      expect(dead.errorStatus, 422);
      final String? oldKey = dead.key;

      // Asserted before the retry's own kick() can run: the scripted transport
      // would 422 it again and empty the queue.
      await flusher.retryDead(dead.id);
      expect(flusher.doc.ops.single.key, isNot(oldKey));
      expect(flusher.doc.ops.single.key!.length, 32);
    });

    test('discard removes only the row asked for', () async {
      flusher = build(<TransportResult>[offline(), http(400), http(400), offline()]);
      await flusher.submit(mkOp('a', assigns: 'local_a'));
      await flusher.submit(mkOp('b', assigns: 'local_b'));
      await pump();
    await flusher.flush(force: true);
      await pump();
      expect(flusher.deadCount, 2);

      await flusher.discardDead(flusher.doc.dead.first.id);
      expect(flusher.deadCount, 1);
    });
  });

  test('a signed-out flusher holds nothing in memory', () async {
    flusher = build(<TransportResult>[offline()]);
    await flusher.submit(mkOp('a', assigns: 'local_a'));
    expect(flusher.pendingCount, 1);

    await flusher.setScope(null);
    expect(flusher.pendingCount, 0);

    // ...but the file is RETAINED. It is the user's own unsent work, not the
    // server's cached data, and the two must not share a retention policy.
    await flusher.setScope('u1');
    await pump();
    expect(flusher.doc.ops.length + flusher.doc.dead.length, 1);
  });
}
