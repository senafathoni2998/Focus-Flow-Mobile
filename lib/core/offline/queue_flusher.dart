import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api_client.dart';
import '../api_exception.dart';
import 'queue_op.dart';
import 'write_queue_store.dart';

/// Drains the write queue: strictly one op at a time, in `seq` order.
///
/// STRICT FIFO AND SINGLE FLIGHT are not conservatism, they are correctness. Out
/// of order, a PATCH can commit before the POST that creates its row, and two
/// edits to one task can land backwards. Concurrently, several triggers (a
/// resume, a successful GET, a fresh enqueue) would send the same head op at the
/// same time under one idempotency key and collect 409s from the server's own
/// claim check.

/// Thrown when the queue is at [kMaxPending]. Refusing at the door is the only
/// failure mode here that does not lose data.
class QueueFullException implements Exception {
  const QueueFullException();
  @override
  String toString() =>
      'Too many unsent changes are already waiting. Reconnect to send them.';
}

class TransportResult {
  const TransportResult({
    required this.status,
    required this.hadResponse,
    this.body,
    this.message,
    this.retryAfterSeconds,
  });

  final int? status;
  final bool hadResponse;
  final Map<String, dynamic>? body;
  final String? message;
  final int? retryAfterSeconds;
}

abstract class QueueTransport {
  Future<TransportResult> send(ResolvedOp op);
}

/// The only network-aware code in the queue. Everything else is pure or disk.
class ApiClientTransport implements QueueTransport {
  ApiClientTransport(this._api);
  final ApiClient _api;

  @override
  Future<TransportResult> send(ResolvedOp op) async {
    try {
      final ({int? status, dynamic data}) r = await _api.sendQueued(
        method: op.method,
        path: op.path,
        body: op.body,
        idempotencyKey: op.key,
      );
      return TransportResult(
        status: r.status,
        hadResponse: true,
        body: r.data is Map ? Map<String, dynamic>.from(r.data as Map) : null,
      );
    } on ApiException catch (e) {
      return TransportResult(
        status: e.statusCode,
        hadResponse: e.hadResponse,
        message: e.message,
        retryAfterSeconds: e.retryAfterSeconds,
      );
    }
  }
}

enum FlushState { idle, running, pausedOffline, pausedAuth }

/// What [QueueFlusher.submit] tells its caller.
enum SubmitOutcome {
  /// Reached the server and committed. The caller can treat it as done.
  sent,

  /// Safely persisted but not sent. The caller shows "saved offline".
  deferred,
}

int _realNow() => DateTime.now().millisecondsSinceEpoch;

class QueueFlusher {
  QueueFlusher({
    required WriteQueueStore store,
    required QueueTransport transport,
    required Future<String?> Function() currentUserId,
    required void Function(QueueDoc doc, String? inFlightOpId, FlushState state,
            bool recoveredFromCorruption)
        onChanged,
    required void Function(OpEntity entity, Map<String, dynamic> row) onServerRow,
    required void Function(Set<OpEntity> touched) onDrained,
    int Function() nowMs = _realNow,
  })  : _store = store,
        _transport = transport,
        _currentUserId = currentUserId,
        _onChanged = onChanged,
        _onServerRow = onServerRow,
        _onDrained = onDrained,
        _nowMs = nowMs;

  final WriteQueueStore _store;
  final QueueTransport _transport;
  final Future<String?> Function() _currentUserId;
  final void Function(QueueDoc doc, String? inFlightOpId, FlushState state,
          bool recoveredFromCorruption)
      _onChanged;
  final void Function(OpEntity entity, Map<String, dynamic> row) _onServerRow;
  final void Function(Set<OpEntity> touched) _onDrained;
  final int Function() _nowMs;

  QueueDoc _doc = const QueueDoc();
  FlushState _state = FlushState.idle;
  String? _inFlightOpId;
  bool _flushing = false;
  bool _rerun = false;
  bool _rerunForce = false;
  bool _pausedAuth = false;
  Timer? _timer;
  bool _disposed = false;

  /// Consecutive sends that got no answer at all.
  ///
  /// Deliberately NOT stored on the op: transport failures must never consume a
  /// retry budget, or a fortnight offline would dead-letter perfectly valid
  /// writes. It only spaces the attempts out, so a dead network is polled at a
  /// widening interval instead of on every trigger. Reset by any success.
  int _offlineStreak = 0;

  /// Entities whose rows changed since the last drain. `onDrained` refreshes
  /// exactly these — a full refresh of everything on every drain would be four
  /// requests where one is needed, and refreshing only tasks (as it did) left a
  /// list created offline showing its local id until the user changed tabs.
  final Set<OpEntity> _touched = <OpEntity>{};

  FlushState get state => _state;
  QueueDoc get doc => _doc;
  int get pendingCount => _doc.ops.length;
  int get deadCount => _doc.dead.length;
  String? get inFlightOpId => _inFlightOpId;

  /// Point at an account and load its queue. Passing null (signed out) leaves
  /// the file untouched — the queue is the user's own unsent work, not the
  /// server's cached data, and the two must not share a retention policy.
  Future<void> setScope(String? userId) async {
    _timer?.cancel();
    _timer = null;
    _store.setScope(userId);
    _pausedAuth = false;
    if (userId == null) {
      _doc = const QueueDoc();
      _inFlightOpId = null;
      _state = FlushState.idle;
      _emit();
      return;
    }
    _doc = await _store.load();
    _emit();
    kick();
  }

  void pauseForAuth() {
    _pausedAuth = true;
    _state = FlushState.pausedAuth;
    _timer?.cancel();
    _timer = null;
    _emit();
  }

  void resumeAfterSignIn() {
    _pausedAuth = false;
    kick();
  }

  /// Debounced trigger. Safe to call from anywhere, as often as you like.
  void kick() {
    if (_disposed) return;
    unawaited(flush());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  // --- enqueue ---------------------------------------------------------------

  /// Persist an op, then attempt it if nothing is ahead of it.
  ///
  /// ONE CODE PATH, online and offline. The alternative — attempt inline and only
  /// queue on failure — makes the offline branch run on maybe 1% of writes, where
  /// it rots undetected, and leaves a window in which a request has been sent but
  /// never persisted. Here the op is durable before anything touches the wire.
  ///
  /// The terminal branch below is what preserves today's UX exactly: online, a
  /// 400 still throws out of `TasksController` and surfaces inline in the editor,
  /// and never becomes a dead letter. Only writes that were genuinely deferred
  /// can end up in "Unsent changes".
  Future<({SubmitOutcome outcome, Map<String, dynamic>? response})> submit(
      QueuedOp op) async {
    if (_store.scope == null) {
      // Not scoped (signed out, or a store that never loaded). Queueing here
      // would write nothing and silently swallow the user's work, so this
      // behaves exactly as the app did before the queue existed.
      final Resolution r = resolve(op, const <String, String>{});
      if (!r.isReady) throw ApiException('This change is missing its task.');
      final TransportResult res = await _send(r.op!);
      if (classify(
            kind: op.kind,
            status: res.status,
            hadResponse: res.hadResponse,
            hasRetryAfter: res.retryAfterSeconds != null,
          ) ==
          OpOutcome.succeeded) {
        _emitServerRow(op, res);
        return (outcome: SubmitOutcome.sent, response: res.body);
      }
      throw ApiException(
        res.message ?? 'Could not save this change.',
        statusCode: res.status,
        hadResponse: res.hadResponse,
      );
    }

    if (_doc.ops.length >= kMaxPending) throw const QueueFullException();

    final bool hadWork = _doc.ops.isNotEmpty || _timer != null;
    final int seq = _doc.seq + 1;
    final QueuedOp staged = op.copyWith(seq: seq);

    List<QueuedOp> ops = <QueuedOp>[..._doc.ops, staged];

    // A task typed and then deleted while still offline should never touch the
    // network at all.
    //
    // NOT while its create is on the wire. `submit()` deliberately runs without
    // the single-flight guard (it must stay responsive while the queue drains),
    // so without this check the collapse could delete the very op a send was
    // awaiting — and the outcome handler would then act on whatever had moved
    // into its place. `attempts` does not cover this: it is incremented when a
    // send FAILS, so an op still in flight is sitting at attempts == 0.
    final bool createIsInFlight = _inFlightOpId != null &&
        ops.any((QueuedOp o) =>
            o.id == _inFlightOpId &&
            o.kind == OpKind.createTask &&
            o.assigns == staged.target);
    if (staged.kind == OpKind.deleteTask &&
        isLocalId(staged.target) &&
        !createIsInFlight) {
      final List<QueuedOp>? collapsed =
          cancelCreateThenDelete(ops, staged.target);
      if (collapsed != null) {
        await _commit(_doc.copyWith(seq: seq, ops: collapsed));
        return (outcome: SubmitOutcome.sent, response: null);
      }
    }

    await _commit(_doc.copyWith(seq: seq, ops: ops));

    if (hadWork || _pausedAuth) {
      kick();
      return (outcome: SubmitOutcome.deferred, response: null);
    }
    return _submitInline(staged.id);
  }

  Future<({SubmitOutcome outcome, Map<String, dynamic>? response})> _submitInline(
      String opId) async {
    if (_flushing) {
      _rerun = true;
      return (outcome: SubmitOutcome.deferred, response: null);
    }
    _flushing = true;
    try {
      if (_doc.ops.isEmpty || _doc.ops.first.id != opId) {
        _rerun = true;
        return (outcome: SubmitOutcome.deferred, response: null);
      }
      final String? uid = await _currentUserId();
      if (uid == null || uid != _store.scope) {
        return (outcome: SubmitOutcome.deferred, response: null);
      }

      final QueuedOp head = _doc.ops.first;
      final Resolution r = resolve(head, _doc.idMap);
      if (!r.isReady) {
        await _dieHead(head,
            reason: DeadReason.orphaned,
            message: 'the task it belongs to was never created');
        return (outcome: SubmitOutcome.deferred, response: null);
      }

      _inFlightOpId = head.id;
      _state = FlushState.running;
      _emit();
      final String? sentUnderScope = _store.scope;
      final TransportResult res = await _send(r.op!);
      _inFlightOpId = null;

      // RE-CHECKED AFTER THE AWAIT, not only before it. The send can straddle a
      // sign-out and a sign-in as somebody else: `setScope` replaces `_doc`
      // wholesale with the new account's queue, and applying this outcome to it
      // would delete one of THEIR ops. Abandoning the outcome is safe — the op
      // is still in its own account's file with its idempotency key intact, so
      // replaying it resolves whatever actually happened.
      if (sentUnderScope != _store.scope) {
        _state = FlushState.idle;
        _emit();
        return (outcome: SubmitOutcome.deferred, response: null);
      }

      final OpOutcome outcome = classify(
        kind: head.kind,
        status: res.status,
        hadResponse: res.hadResponse,
        hasRetryAfter: res.retryAfterSeconds != null,
      );

      switch (outcome) {
        case OpOutcome.succeeded:
          await _succeedHead(head, res, r.op!);
          _state = FlushState.idle;
          if (_doc.ops.isEmpty && _touched.isNotEmpty) {
            final Set<OpEntity> touched = Set<OpEntity>.from(_touched);
            _touched.clear();
            _onDrained(touched);
          }
          return (outcome: SubmitOutcome.sent, response: res.body);

        case OpOutcome.terminal:
          // Remove it WITHOUT dead-lettering. The user is looking at the editor
          // and gets the server's own message inline, exactly as before.
          await _commit(_doc.copyWith(ops: _doc.ops.sublist(1)));
          _state = FlushState.idle;
          throw ApiException(
            res.message ?? 'Could not save this change.',
            statusCode: res.status,
            hadResponse: true,
          );

        case OpOutcome.authPaused:
          pauseForAuth();
          return (outcome: SubmitOutcome.deferred, response: null);

        case OpOutcome.retryTransport:
          await _deferHeadForNetwork();
          return (outcome: SubmitOutcome.deferred, response: null);

        case OpOutcome.retryServer:
        case OpOutcome.retryPending:
          await _penaliseHead(head, outcome, res);
          _armForHead();
          return (outcome: SubmitOutcome.deferred, response: null);
      }
    } finally {
      _inFlightOpId = null;
      _flushing = false;
      if (_rerun) {
        _rerun = false;
        kick();
      }
    }
  }

  // --- draining --------------------------------------------------------------

  Future<void> flush({bool force = false}) async {
    if (_disposed) return;
    if (_flushing) {
      // Fold this trigger into the running pass rather than racing it. `force`
      // is carried across so an explicit "Retry now" is not silently downgraded
      // to a scheduled attempt just because a background flush was in progress.
      _rerun = true;
      _rerunForce = _rerunForce || force;
      return;
    }
    _flushing = true;
    try {
      bool nextForce = force;
      do {
        _rerun = false;
        _rerunForce = false;
        await _pass(force: nextForce);
        nextForce = _rerunForce;
      } while (_rerun && !_disposed);
    } finally {
      _flushing = false;
      _inFlightOpId = null;
    }
  }

  Future<void> _pass({required bool force}) async {
    if (_pausedAuth) {
      _state = FlushState.pausedAuth;
      _emit();
      return;
    }

    while (!_disposed) {
      // BEFORE EVERY REQUEST, not once per pass. A long flush can straddle a
      // sign-out and sign-in as somebody else, and the ops are already in
      // memory — so the filename is not the boundary, this check is. Without
      // it, user A's queued writes would go out under user B's bearer token.
      final String? uid = await _currentUserId();
      if (uid == null || uid != _store.scope) {
        _state = FlushState.idle;
        _emit();
        return;
      }

      if (_doc.ops.isEmpty) {
        _state = FlushState.idle;
        _emit();
        if (_touched.isNotEmpty) {
          final Set<OpEntity> touched = Set<OpEntity>.from(_touched);
          _touched.clear();
          _onDrained(touched);
        }
        return;
      }

      final QueuedOp head = _doc.ops.first;

      if (isExpired(head, _nowMs())) {
        await _dieHead(head,
            reason: DeadReason.expired,
            message: 'This waited more than $kExpiryDays days without a connection.');
        continue;
      }

      if (!force && !isDue(head, _nowMs())) {
        // The state is deliberately NOT reset here. Work is still pending and we
        // are only waiting out a backoff, so reporting `idle` would clear the
        // "waiting for a connection" banner while the queue is doing exactly
        // that — the user would see no explanation for why nothing is saving.
        _emit();
        _arm(Duration(milliseconds: head.nextAtMs - _nowMs()));
        return;
      }

      final Resolution r = resolve(head, _doc.idMap);
      if (!r.isReady) {
        // FAIL CLOSED. Shipping a `local_` id to the server would 404 on the
        // parent lookup or, worse, create an orphan the user can never find.
        await _dieHead(head,
            reason: DeadReason.orphaned,
            message: 'the task it belongs to was never created');
        continue;
      }

      _inFlightOpId = head.id;
      _state = FlushState.running;
      _emit();
      final String? sentUnderScope = _store.scope;
      final TransportResult res = await _send(r.op!);
      _inFlightOpId = null;

      // See the note in _submitInline: the scope can change across this await.
      if (sentUnderScope != _store.scope) {
        _state = FlushState.idle;
        _emit();
        return;
      }

      final OpOutcome outcome = classify(
        kind: head.kind,
        status: res.status,
        hadResponse: res.hadResponse,
        hasRetryAfter: res.retryAfterSeconds != null,
      );

      switch (outcome) {
        case OpOutcome.succeeded:
          await _succeedHead(head, res, r.op!);

        case OpOutcome.terminal:
          // The pass CONTINUES: one rejected title must not block every other
          // write behind it forever.
          await _dieHead(head,
              reason: DeadReason.rejected,
              status: res.status,
              message: res.message);

        case OpOutcome.authPaused:
          pauseForAuth();
          return;

        case OpOutcome.retryTransport:
          // The pass STOPS. There is no network, so burning through twenty ops
          // would collect twenty identical failures and inflate twenty counters
          // for one cause. No budget is consumed: being offline is not a fault
          // of the write.
          await _deferHeadForNetwork();
          return;

        case OpOutcome.retryServer:
        case OpOutcome.retryPending:
          final bool stillPending = await _penaliseHead(head, outcome, res);
          if (stillPending) {
            _state = FlushState.idle;
            _emit();
            _armForHead();
            return;
          }
          // Budget exhausted → the head was dead-lettered; carry on.
      }
    }
  }

  /// Push the head out to the next attempt without charging it anything.
  ///
  /// The delay MUST be written to the op, not just held in a Timer. Without it
  /// `isDue` stays true, so the very next trigger — a resume, another enqueue,
  /// any successful GET — re-sends immediately, and a phone with no signal
  /// hammers a dead socket on every one of them.
  Future<void> _deferHeadForNetwork() async {
    _state = FlushState.pausedOffline;
    final Duration wait = backoffFor(_offlineStreak);
    _offlineStreak++;
    if (_doc.ops.isNotEmpty) {
      final QueuedOp head = _doc.ops.first;
      await _commit(_doc.copyWith(ops: <QueuedOp>[
        head.copyWith(
          // `attempts` still increments. It counts times this op was put ON THE
          // WIRE, which is not the same as times it was charged a budget — and
          // the difference matters: cancelCreateThenDelete only annihilates a
          // create at attempts == 0, because after even an unanswered send the
          // server may hold a row that only the delete can clean up. The two
          // budget counters below are untouched, which is what "transport
          // failures are free" actually means.
          attempts: head.attempts + 1,
          nextAtMs: _nowMs() + wait.inMilliseconds,
        ),
        ..._doc.ops.sublist(1),
      ]));
    }
    _state = FlushState.pausedOffline;
    _emit();
    _arm(wait);
  }

  void _armForHead() {
    if (_doc.ops.isEmpty) return;
    _arm(Duration(
        milliseconds: (_doc.ops.first.nextAtMs - _nowMs()).clamp(0, 1 << 30)));
  }

  Future<TransportResult> _send(ResolvedOp op) async {
    try {
      return await _transport.send(op);
    } catch (e) {
      // A transport that throws rather than returning is still "no answer".
      return TransportResult(status: null, hadResponse: false, message: '$e');
    }
  }

  // --- outcomes --------------------------------------------------------------

  /// Where the op that was just sent sits now, or -1 if it is gone.
  ///
  /// EVERY outcome handler looks the op up by ID rather than taking
  /// `_doc.ops.first`. Between the send and its answer the queue can genuinely
  /// change underneath: `submit()` runs without the flusher's single-flight
  /// guard and can collapse a create+delete pair, and `setScope()` can replace
  /// `_doc` wholesale. Acting on "whatever is at the head now" meant a
  /// completed send deleting an UNRELATED op — including one belonging to a
  /// different account.
  int _indexOfSent(QueuedOp sent) =>
      _doc.ops.indexWhere((QueuedOp o) => o.id == sent.id);

  List<QueuedOp> _without(int i) => <QueuedOp>[
        ..._doc.ops.sublist(0, i),
        ..._doc.ops.sublist(i + 1),
      ];

  Future<void> _succeedHead(
      QueuedOp head, TransportResult res, ResolvedOp resolved) async {
    final int i = _indexOfSent(head);
    if (i < 0) {
      // The op left the queue while it was on the wire. Its work DID land, so
      // the id mapping is still worth recording; removing some other row is not.
      _offlineStreak = 0;
      return;
    }
    final List<QueuedOp> remaining = _without(i);
    Map<String, String> idMap = _doc.idMap;

    final String? assigns = head.assigns;
    final String? idPath = resolved.idPath;
    if (assigns != null && idPath != null) {
      final String? serverId = _extractId(res.body, idPath);
      if (serverId != null) {
        idMap = _prune(<String, String>{...idMap, assigns: serverId});
      }
    }

    // ONE write commits both "the op is gone" and "its server id is known".
    // Split across two, a crash between them would strand every dependent op
    // pointing at a local id that resolves to nothing.
    await _commit(_doc.copyWith(ops: remaining, idMap: idMap));
    _offlineStreak = 0;
    _touched.add(head.entity);
    _emitServerRow(head, res);
  }

  /// Route an acked response to whichever controller owns that entity.
  ///
  /// The envelope key differs per entity (`{task: …}`, `{list: …}`), so this
  /// reads the one belonging to the op that was sent. Reading only `task` — as
  /// it did while tasks were the only entity — silently dropped a list create's
  /// response, and the drawer never learned the row's real id from the queue.
  void _emitServerRow(QueuedOp op, TransportResult res) {
    final String envelope = switch (op.entity) {
      OpEntity.task => 'task',
      OpEntity.list => 'list',
    };
    final Object? row = res.body?[envelope];
    if (row is Map) _onServerRow(op.entity, Map<String, dynamic>.from(row));
  }

  /// Charge an attempt. Returns true if the op is still pending, false if the
  /// budget ran out and it was dead-lettered.
  Future<bool> _penaliseHead(
      QueuedOp head, OpOutcome outcome, TransportResult res) async {
    final int i = _indexOfSent(head);
    if (i < 0) return false; // gone from under us; nothing to charge
    final bool pendingKind = outcome == OpOutcome.retryPending;

    final int serverAttempts =
        head.serverAttempts + (pendingKind ? 0 : 1);
    final int pendingAttempts =
        head.pendingAttempts + (pendingKind ? 1 : 0);

    final bool exhausted = pendingKind
        ? pendingAttempts >= kPendingBudget
        : serverAttempts >= kServerBudget;

    if (exhausted) {
      await _dieHead(
        head,
        reason: DeadReason.unconfirmed,
        status: res.status,
        message: pendingKind
            ? "We couldn't confirm this was saved."
            : (res.message ?? 'The server kept failing on this.'),
      );
      return false;
    }

    // A 409 carries Retry-After: the server is telling us its own claim is still
    // in flight, so honour it rather than guessing.
    final Duration wait = pendingKind
        ? Duration(seconds: res.retryAfterSeconds ?? 1)
        // Scaled by the SERVER-failure count, not the total: attempts also
        // counts unanswered sends, and a week offline must not push a real 5xx
        // retry straight to the cap.
        : backoffFor(serverAttempts - 1);

    final QueuedOp updated = head.copyWith(
      attempts: head.attempts + 1,
      serverAttempts: serverAttempts,
      pendingAttempts: pendingAttempts,
      nextAtMs: _nowMs() + wait.inMilliseconds,
    );
    final List<QueuedOp> ops = <QueuedOp>[..._doc.ops];
    ops[i] = updated;
    await _commit(_doc.copyWith(ops: ops));
    return true;
  }

  Future<void> _dieHead(QueuedOp head,
      {DeadReason reason = DeadReason.rejected, int? status, String? message}) async {
    final int i = _indexOfSent(head);
    if (i < 0) return;
    final int now = _nowMs();

    final List<QueuedOp> dying = <QueuedOp>[
      head.copyWith(
        reason: reason,
        errorStatus: status,
        errorMessage: message,
        diedAtMs: now,
      ),
    ];

    List<QueuedOp> remaining = _without(i);

    // A create that will never happen takes its dependents with it, in the SAME
    // write. Sending them would produce one 404 and one baffling dead letter per
    // dependent, all from a single cause.
    final String? assigns = head.assigns;
    if (assigns != null) {
      final Set<String> doomed = cascadeFrom(remaining, assigns);
      if (doomed.isNotEmpty) {
        for (final QueuedOp op in remaining) {
          if (!doomed.contains(op.id)) continue;
          dying.add(op.copyWith(
            reason: DeadReason.orphaned,
            errorMessage: 'the task it belongs to was never created',
            diedAtMs: now,
          ));
        }
        remaining =
            remaining.where((QueuedOp o) => !doomed.contains(o.id)).toList();
      }
    }

    List<QueuedOp> dead = <QueuedOp>[..._doc.dead, ...dying];
    int dropped = _doc.droppedDead;
    if (dead.length > kMaxDead) {
      // Counted, not forgotten — see QueueDoc.droppedDead.
      dropped += dead.length - kMaxDead;
      dead = dead.sublist(dead.length - kMaxDead);
    }

    await _commit(
        _doc.copyWith(ops: remaining, dead: dead, droppedDead: dropped));
  }

  // --- dead-letter actions ---------------------------------------------------

  /// Put a failed write back in the queue.
  ///
  /// THE KEY RULE. For 400/403/404 the server already released the key when the
  /// handler returned non-2xx, so reusing it is both legal and desirable — it
  /// keeps the lost-response protection. A 422 is different: it is thrown BEFORE
  /// the handler runs, so nothing was released and the key is still bound to the
  /// other body hash. Retrying with it would 422 forever.
  Future<void> retryDead(String opId) async {
    final int i = _doc.dead.indexWhere((QueuedOp o) => o.id == opId);
    if (i < 0) return;
    final QueuedOp dead = _doc.dead[i];

    final QueuedOp revived = QueuedOp(
      id: dead.id,
      seq: _doc.seq + 1,
      kind: dead.kind,
      target: dead.target,
      assigns: dead.assigns,
      deps: dead.deps,
      body: dead.body,
      key: dead.errorStatus == 422 && dead.key != null
          ? newIdempotencyKey()
          : dead.key,
      summary: dead.summary,
      createdAtMs: _nowMs(),
      // CARRIED OVER, not reset. `attempts` means "times this reached the
      // wire", and cancelCreateThenDelete relies on it: a create that was sent
      // and merely lost its answer may already exist on the server, so only the
      // delete can clean it up. Resetting it to 0 re-armed the annihilation and
      // would have leaked that row. The two BUDGET counters do start fresh —
      // that is the point of retrying.
      attempts: dead.attempts,
      );

    final List<QueuedOp> deadList = <QueuedOp>[..._doc.dead]..removeAt(i);
    await _commit(_doc.copyWith(
      seq: _doc.seq + 1,
      ops: <QueuedOp>[..._doc.ops, revived],
      dead: deadList,
    ));
    kick();
  }

  Future<void> discardDead(String opId) async {
    final List<QueuedOp> deadList =
        _doc.dead.where((QueuedOp o) => o.id != opId).toList();
    if (deadList.length == _doc.dead.length) return;
    await _commit(_doc.copyWith(dead: deadList));
  }

  /// Only ever called for an explicit "discard and sign out". Never as cleanup.
  Future<void> discardAllForSignOut() async {
    await _store.clearScope();
    _doc = const QueueDoc();
    _inFlightOpId = null;
    _emit();
  }

  // --- plumbing --------------------------------------------------------------

  Future<void> _commit(QueueDoc doc) async {
    _doc = doc;
    try {
      await _store.save(doc);
    } catch (e) {
      // The in-memory state is already correct; a failed write means it will not
      // survive a restart. Loud, because that IS data loss on a kill.
      debugPrint('[queue] FAILED to persist the queue: $e');
    }
    _emit();
  }

    /// True once a load found a queue file it could not parse and moved it aside.
  ///
  /// It has to reach the UI. Without a reader, an account whose unsent work was
  /// just set aside opened Settings -> Unsent changes and read "Everything is
  /// saved" — the one message that is certainly false in that moment.
  bool get recoveredFromCorruption => _store.corruptDetected;

  void _emit() =>
      _onChanged(_doc, _inFlightOpId, _state, _store.corruptDetected);

  void _arm(Duration d) {
    if (_disposed) return;
    _timer?.cancel();
    final Duration wait = d < Duration.zero ? Duration.zero : d;
    _timer = Timer(wait, () {
      _timer = null;
      kick();
    });
  }

  static String? _extractId(Map<String, dynamic>? body, String path) {
    if (body == null) return null;
    Object? cur = body;
    for (final String segment in path.split('.')) {
      if (cur is Map && cur.containsKey(segment)) {
        cur = cur[segment];
      } else {
        return null;
      }
    }
    return cur is String && cur.isNotEmpty ? cur : null;
  }

  /// The map outlives the ops that made it: a local id can still be held by a
  /// Task row on screen, or by a cached response, long after the queue drained.
  static Map<String, String> _prune(Map<String, String> m) {
    const int keep = 300;
    if (m.length <= keep) return m;
    final List<String> keys = m.keys.toList();
    final Map<String, String> out = <String, String>{};
    for (final String k in keys.sublist(keys.length - keep)) {
      out[k] = m[k]!;
    }
    return out;
  }
}
