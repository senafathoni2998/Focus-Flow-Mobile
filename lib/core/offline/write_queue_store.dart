import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'queue_op.dart';

/// The queue's durable state: pending ops, the local→server id map, and the
/// dead letter — all in ONE document.
///
/// WHY ONE DOCUMENT. The dangerous moment is between "the create succeeded" and
/// "its server id was recorded". If those were two files, a crash in between
/// would leave every dependent op pointing at a local id that will never
/// resolve — three 404s and three confusing dead letters from one cause. Held
/// together and committed by a single `rename()`, that intermediate state is not
/// expressible.
///
/// WHY THE CORRUPT FILE IS RENAMED, NOT DELETED. For the read cache a corrupt
/// entry is a miss and deleting it costs nothing. Here it is the user's typed
/// work, so it is moved aside where it can still be recovered by hand.
///
/// The format version below is bumped whenever an [OpKind] value is added.
///
/// Reading forward is safe — a version-1 file loads unchanged. The danger is
/// backwards: an older build meets `createList`, `QueuedOp.fromJson` returns
/// null, and the tolerant path meant for ONE corrupt row silently discards the
/// user's work. A version it does not recognise makes it set the whole file
/// aside instead, where it is still recoverable.
///   v1 — task create/update/complete/delete
///   v2 — list create/delete
///   v3 — focus session create/complete/cancel
///   v4 — goal create/update/delete/status
///   v5 — habit create/update/delete/archive
///   v6 — the two deltas: goal progress, habit check-in
const int kQueueFormatVersion = 6;

class QueueDoc {
  const QueueDoc({
    this.seq = 0,
    this.ops = const <QueuedOp>[],
    this.dead = const <QueuedOp>[],
    this.idMap = const <String, String>{},
    this.droppedDead = 0,
    this.syncCursor,
  });

  /// Monotonic allocator. Never reused, so FIFO order is stable across restarts.
  final int seq;
  final List<QueuedOp> ops;
  final List<QueuedOp> dead;
  final Map<String, String> idMap;

  /// How many dead letters were dropped to stay under [kMaxDead].
  ///
  /// Counted rather than forgotten. "Nothing is ever auto-discarded" is one of
  /// this feature's promises, and the cap quietly broke it — a heavy offline
  /// week could push older failures out with nothing said anywhere. The cap
  /// stays (unbounded growth is its own failure), but the user is told.
  final int droppedDead;

  /// The server timestamp the last delta sync returned, or null for "never".
  ///
  /// It lives HERE rather than in its own file because this document is already
  /// scoped per account, written atomically, and wiped by the same rules. A
  /// second store would be a second scoping mechanism to get wrong, and getting
  /// scoping wrong is the cross-account class of bug. If this file is ever set
  /// aside as unreadable the cursor goes with it, and the next sync is a full
  /// one — a safe way to lose it.
  final String? syncCursor;

  bool get isEmpty => ops.isEmpty && dead.isEmpty;

  QueueDoc copyWith({
    int? seq,
    List<QueuedOp>? ops,
    List<QueuedOp>? dead,
    Map<String, String>? idMap,
    int? droppedDead,
    String? syncCursor,
  }) {
    return QueueDoc(
      seq: seq ?? this.seq,
      ops: ops ?? this.ops,
      dead: dead ?? this.dead,
      idMap: idMap ?? this.idMap,
      droppedDead: droppedDead ?? this.droppedDead,
      syncCursor: syncCursor ?? this.syncCursor,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': kQueueFormatVersion,
        'seq': seq,
        'ops': ops.map((QueuedOp o) => o.toJson()).toList(),
        'idMap': idMap,
        'dead': dead.map((QueuedOp o) => o.toJson()).toList(),
        // Absent in a v1/v2 file, which reads back as 0 — no version bump.
        if (droppedDead > 0) 'droppedDead': droppedDead,
        if (syncCursor != null) 'syncCursor': syncCursor,
      };

  /// Tolerant by design: a row it cannot read is dropped, never thrown. One bad
  /// op must not cost the user everything else they wrote offline.
  static QueueDoc fromJson(Object? raw) {
    if (raw is! Map) return const QueueDoc();
    final Map<String, dynamic> j = Map<String, dynamic>.from(raw);

    List<QueuedOp> readOps(Object? v) {
      if (v is! List) return const <QueuedOp>[];
      final List<QueuedOp> out = <QueuedOp>[];
      for (final Object? e in v) {
        if (e is! Map) continue;
        final QueuedOp? op = QueuedOp.fromJson(Map<String, dynamic>.from(e));
        if (op != null) out.add(op);
      }
      return out;
    }

    final Map<String, String> idMap = <String, String>{};
    final Object? rawMap = j['idMap'];
    if (rawMap is Map) {
      rawMap.forEach((Object? k, Object? v) {
        if (k is String && v is String) idMap[k] = v;
      });
    }

    return QueueDoc(
      seq: j['seq'] is int ? j['seq'] as int : 0,
      ops: readOps(j['ops']),
      dead: readOps(j['dead']),
      idMap: idMap,
      droppedDead: j['droppedDead'] is int ? j['droppedDead'] as int : 0,
      syncCursor: j['syncCursor'] is String ? j['syncCursor'] as String : null,
    );
  }
}

class WriteQueueStore {
  WriteQueueStore({Directory? directory}) : _override = directory;

  final Directory? _override;
  Directory? _dir;
  String? _scope;
  bool _corruptDetected = false;

  /// The account this queue belongs to. Null (signed out) makes every read and
  /// write a no-op rather than falling back to a shared namespace.
  String? get scope => _scope;

  /// True once a load found a file it could not parse and moved it aside.
  bool get corruptDetected => _corruptDetected;

  void setScope(String? userScope) {
    if (_scope == userScope) return;
    _scope = userScope;
    _corruptDetected = false;
  }

  Future<Directory> _resolveDir() async {
    if (_override != null) return _override;
    _dir ??= Directory(
        '${(await getApplicationDocumentsDirectory()).path}/write_queue');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    return _dir!;
  }

  String _fileName(String scope) {
    final String safe = scope.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return '${safe}__queue.json';
  }

  Future<File?> _file() async {
    final String? scope = _scope;
    if (scope == null) return null;
    final Directory dir = await _resolveDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/${_fileName(scope)}');
  }

  Future<QueueDoc> load() async {
    final File? file = await _file();
    if (file == null) return const QueueDoc();
    try {
      if (!await file.exists()) return const QueueDoc();
      final String text = await file.readAsString();
      if (text.trim().isEmpty) return const QueueDoc();
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) {
        await _setAside(file, 'not an object');
        return const QueueDoc();
      }
      final Object? version = decoded['version'];
      if (version is! int || version > kQueueFormatVersion) {
        // Written by a NEWER build. Guessing at a format we do not know could
        // send a malformed request; setting it aside keeps the data recoverable.
        await _setAside(file, 'unknown version $version');
        return const QueueDoc();
      }
      return QueueDoc.fromJson(decoded);
    } catch (e) {
      await _setAside(file, '$e');
      return const QueueDoc();
    }
  }

  Future<void> _setAside(File file, String why) async {
    _corruptDetected = true;
    debugPrint('[queue] unreadable queue file set aside ($why)');
    try {
      if (!await file.exists()) return;
      final int stamp = DateTime.now().millisecondsSinceEpoch;
      await file.rename('${file.path}.corrupt-$stamp.json');
    } catch (e) {
      debugPrint('[queue] could not set the file aside: $e');
    }
  }

  /// One atomic write. Throws on failure — unlike the read cache, a write that
  /// silently did not happen here means losing the user's work.
  ///
  /// SERIALISED, and that is not caution. Every writer used to derive the same
  /// `<file>.tmp`, and `writeAsString` truncates at 0, so two overlapping saves
  /// wrote over each other in one file: the shorter one overwrote the longer
  /// one's prefix and left its tail past the closing brace, then whichever
  /// renamed first won and the loser threw PathNotFoundException. The published
  /// file was unparseable, so the next launch set it aside and the user's entire
  /// queue — pending ops AND dead letters — was gone.
  ///
  /// That was trivially reachable: `submit()` commits without holding the
  /// flusher's single-flight guard, so any write the user makes while the queue
  /// is draining races the drain's own commit. Verified: 30/30 trials corrupted.
  Future<void> save(QueueDoc doc) {
    final Future<void> queued = _writeChain.then<void>((_) => _writeOnce(doc));
    // The chain has to survive a failed write, or one IO error would reject
    // every save after it for the life of the process.
    _writeChain = queued.then<void>((_) {}, onError: (Object _) {});
    return queued;
  }

  Future<void> _writeChain = Future<void>.value();
  int _tmpCounter = 0;

  Future<void> _writeOnce(QueueDoc doc) async {
    final File? file = await _file();
    if (file == null) return;
    // A distinct name per call, so even if serialisation were ever bypassed two
    // writers could not share a buffer. Belt as well as braces.
    final File tmp = File('${file.path}.${_tmpCounter++}.tmp');
    try {
      // Write-then-rename: a process killed mid-write would otherwise leave a
      // truncated file, which reads as corruption rather than as the previous
      // good state.
      await tmp.writeAsString(jsonEncode(doc.toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      // Never leave a stray temp file behind to be mistaken for the real one.
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Delete this account's queue. Only ever called for an explicit
  /// "discard and sign out" — never as cleanup.
  Future<void> clearScope() async {
    final File? file = await _file();
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[queue] clear failed: $e');
    }
  }
}
