import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/offline/queue_op.dart';
import 'package:focusflow_mobile/core/offline/write_queue_store.dart';

/// This file holds the user's unsent work. Its two dangerous properties are
/// scoping (another account must never read it) and atomicity (a crash must
/// never leave "op removed" and "server id recorded" disagreeing).

QueuedOp op(String id, {int seq = 1, String? assigns, OpKind kind = OpKind.createTask}) =>
    QueuedOp(
      id: id,
      seq: seq,
      kind: kind,
      target: kind == OpKind.createTask ? '' : 'srv1',
      assigns: assigns,
      body: <String, dynamic>{'title': 'x'},
      summary: 'New task "x"',
      createdAtMs: 0,
    );

void main() {
  late Directory dir;
  late WriteQueueStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('focusflow_queue_test');
    store = WriteQueueStore(directory: dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File fileFor(String scope) => File('${dir.path}/${scope}__queue.json');

  test('reads back what it wrote, from a cold instance', () async {
    store.setScope('u1');
    await store.save(QueueDoc(
      seq: 3,
      ops: <QueuedOp>[op('op_1', seq: 3, assigns: 'local_a')],
      idMap: const <String, String>{'local_z': 'srv9'},
    ));

    // A fresh instance over the same directory — this is the cold start the
    // queue exists for, not a memory read.
    final WriteQueueStore cold = WriteQueueStore(directory: dir)..setScope('u1');
    final QueueDoc doc = await cold.load();

    expect(doc.seq, 3);
    expect(doc.ops.single.id, 'op_1');
    expect(doc.ops.single.assigns, 'local_a');
    expect(doc.idMap, <String, String>{'local_z': 'srv9'});
  });

  test('one account cannot read another\'s queue', () async {
    store.setScope('u1');
    await store.save(QueueDoc(ops: <QueuedOp>[op('op_1')]));

    store.setScope('u2');
    expect((await store.load()).ops, isEmpty);
  });

  test('unscoped, a save writes nothing at all', () async {
    // Signed out, every read and write is a no-op — never a shared namespace
    // the next account could inherit.
    store.setScope(null);
    await store.save(QueueDoc(ops: <QueuedOp>[op('op_1')]));
    expect(dir.listSync().whereType<File>(), isEmpty);
    expect((await store.load()).ops, isEmpty);
  });

  test('clearScope deletes only the current account\'s file', () async {
    store.setScope('u1');
    await store.save(QueueDoc(ops: <QueuedOp>[op('op_1')]));
    store.setScope('u2');
    await store.save(QueueDoc(ops: <QueuedOp>[op('op_2')]));

    await store.clearScope();
    expect(await fileFor('u2').exists(), isFalse);
    expect(await fileFor('u1').exists(), isTrue);

    store.setScope('u1');
    expect((await store.load()).ops.single.id, 'op_1');
  });

  test('a truncated file is SET ASIDE, not deleted', () async {
    // For the read cache a corrupt entry is a miss. Here it is the user's typed
    // work, so it must stay recoverable by hand.
    store.setScope('u1');
    await fileFor('u1').writeAsString('{"ops": [');

    final QueueDoc doc = await store.load();
    expect(doc.ops, isEmpty);
    expect(store.corruptDetected, isTrue);

    final Iterable<String> names =
        dir.listSync().whereType<File>().map((File f) => f.uri.pathSegments.last);
    expect(names.any((String n) => n.contains('.corrupt-')), isTrue);
  });

  test('a document from a newer build is set aside rather than guessed at', () async {
    store.setScope('u1');
    await fileFor('u1').writeAsString(jsonEncode(<String, dynamic>{
      'version': 99,
      'seq': 1,
      'ops': <dynamic>[],
    }));

    expect((await store.load()).ops, isEmpty);
    expect(store.corruptDetected, isTrue);
  });

  test('one unreadable row does not cost the rest of the queue', () async {
    store.setScope('u1');
    await fileFor('u1').writeAsString(jsonEncode(<String, dynamic>{
      'version': 1,
      'seq': 2,
      'ops': <dynamic>[
        <String, dynamic>{'kind': 'somethingElse', 'id': 'bad', 'seq': 1},
        op('op_good', seq: 2).toJson(),
      ],
      'idMap': <String, String>{},
      'dead': <dynamic>[],
    }));

    final QueueDoc doc = await store.load();
    expect(doc.ops.map((QueuedOp o) => o.id), <String>['op_good']);
  });

  test('ops, idMap and dead commit together', () async {
    // The whole reason they share one document: a reload must never show an op
    // removed without the mapping its dependents need already present.
    store.setScope('u1');
    await store.save(QueueDoc(
      seq: 5,
      ops: <QueuedOp>[op('op_2', seq: 5)],
      idMap: const <String, String>{'local_a': 'srv1'},
      dead: <QueuedOp>[
        op('op_dead', seq: 4).copyWith(reason: DeadReason.rejected, errorStatus: 400),
      ],
    ));

    final QueueDoc doc = await WriteQueueStore(directory: dir).let((WriteQueueStore s) {
      s.setScope('u1');
      return s;
    }).load();

    expect(doc.ops.single.id, 'op_2');
    expect(doc.idMap['local_a'], 'srv1');
    expect(doc.dead.single.reason, DeadReason.rejected);
    expect(doc.dead.single.errorStatus, 400);
  });

  test('a file from an older format version still loads', () async {
    // Reading forward must never lose data: v1 held only task ops and every one
    // of them still parses.
    store.setScope('u1');
    await fileFor('u1').writeAsString(jsonEncode(<String, dynamic>{
      'version': 1,
      'seq': 1,
      'ops': <dynamic>[op('op_1', seq: 1, assigns: 'local_a').toJson()],
      'idMap': <String, String>{},
      'dead': <dynamic>[],
    }));

    final QueueDoc doc = await store.load();
    expect(doc.ops.single.id, 'op_1');
    expect(store.corruptDetected, isFalse);
  });

  test('list ops survive the disk round trip', () async {
    store.setScope('u1');
    await store.save(QueueDoc(
      seq: 1,
      ops: <QueuedOp>[op('op_l', seq: 1, kind: OpKind.createList, assigns: 'local_L')],
    ));

    final QueueDoc doc = await WriteQueueStore(directory: dir).let((WriteQueueStore s) {
      s.setScope('u1');
      return s;
    }).load();
    expect(doc.ops.single.kind, OpKind.createList);
    expect(doc.ops.single.entity, OpEntity.list);
  });

  test('an absent file is an empty queue, not an error', () async {
    store.setScope('u1');
    expect((await store.load()).isEmpty, isTrue);
    expect(store.corruptDetected, isFalse);
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
