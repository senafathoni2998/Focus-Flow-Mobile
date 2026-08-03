import 'dart:math';

/// One pending write intent, and every policy decision the queue makes about it.
///
/// This file is deliberately pure — `dart:math` and nothing else. No Flutter, no
/// IO, no Dio. Everything that decides whether a write is duplicated, lost or
/// retried forever lives here, so the whole policy surface can be read in one
/// sitting and covered by plain unit tests on a machine with no device attached.
///
/// THE ONE RULE THAT HOLDS THE DESIGN UP: a persisted op body is NEVER rewritten.
/// Local ids are substituted into a throwaway [ResolvedOp] at dispatch time (see
/// [resolve]). The server hashes `JSON.stringify(body)` and refuses a second
/// request that reuses an idempotency key with a different body hash (422, thrown
/// *before* the handler runs, so the key is never released and the write is
/// wedged permanently). Because we never mutate what we stored, the bytes sent
/// under a given key are identical on every attempt and that 422 is structurally
/// unreachable rather than merely unlikely.

/// The four task writes queued in phase 1. Everything else is online-only; see
/// DECISIONS.md F7 for the per-operation refusals and why each one was refused.
enum OpKind { createTask, updateTask, completeTask, deleteTask }

/// What the flusher decided about one send.
enum OpOutcome {
  /// 2xx, or 404 on a delete (the row is gone, which is what was asked for).
  succeeded,

  /// No answer at all. Does NOT consume a budget — being offline is not the
  /// op's fault, and a fortnight at sea must not dead-letter a valid write.
  retryTransport,

  /// 5xx / 408 / 429 — the server answered, badly. Bounded by [kServerBudget].
  retryServer,

  /// 409: the idempotency key is claimed and still pending. Bounded separately
  /// by [kPendingBudget]; see the note on that constant for why.
  retryPending,

  /// 400 / 403 / 404-on-anything-but-delete / 410 / 422. Will never succeed.
  terminal,

  /// A 401 that survived ApiClient's one automatic refresh.
  authPaused,
}

/// Why an op is in the dead letter. Shown to the user, so the wording of each
/// case matters as much as the classification.
enum DeadReason {
  /// The server rejected it outright and said why.
  rejected,

  /// The create it depended on never happened, so this could never land.
  orphaned,

  /// We ran out of attempts without ever learning whether it committed.
  unconfirmed,

  /// It sat unsent for [kExpiryDays].
  expired,
}

// --- budgets -----------------------------------------------------------------

/// 5xx/408/429 attempts before giving up. The server is answering, so a fault
/// that survives eight tries is not going to clear on the ninth.
const int kServerBudget = 8;

/// 409 attempts before giving up.
///
/// This is separate from [kServerBudget] because it guards a different failure:
/// `idempotency.ts` has no TTL and never releases a key left in `pending`, so a
/// server process killed between claiming the key and finalising it strands that
/// key forever. Without a bounded budget the queue would 409 until the battery
/// died. After this many we dead-letter with the honest wording — we genuinely
/// do not know whether it was saved.
const int kPendingBudget = 6;

/// Refuse new ops past this depth rather than growing without bound. Refusing at
/// the door is the only failure mode here that does not lose data.
const int kMaxPending = 500;

/// Dead letters kept before the oldest are dropped.
const int kMaxDead = 200;

/// An op older than this is dead-lettered as [DeadReason.expired].
const int kExpiryDays = 14;

/// The largest single backoff. Doubles as the clock-skew threshold in [isDue].
const Duration kMaxBackoff = Duration(seconds: 300);

const List<int> _backoffSeconds = <int>[1, 2, 5, 15, 60, 300];

// --- ids and keys ------------------------------------------------------------

final Random _secureRng = Random.secure();

String _hex(int byteCount, Random? rng) {
  final Random r = rng ?? _secureRng;
  final StringBuffer sb = StringBuffer();
  for (int i = 0; i < byteCount; i++) {
    sb.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// A placeholder id for a task that exists only in the queue. Prefixed so
/// [isLocalId] can recognise it without a lookup, and long enough that it can
/// never collide with itself.
String newLocalId({Random? rng}) => 'local_${_hex(10, rng)}';

String newOpId({Random? rng}) => 'op_${_hex(12, rng)}';

/// 32 hex characters — 128 bits from `Random.secure()`, comfortably inside the
/// server's 8..200 bound.
///
/// NEVER derive this from a task id, title, timestamp or sequence number. The
/// server's uniqueness index is `(userId, key)` and does NOT include the
/// endpoint, and `POST /tasks/:id/complete` hashes a constant body (the route
/// passes `null`), so two completes sharing a derived key would replay the first
/// task's 200 for the second — silently leaving it uncompleted with no error
/// anywhere. 128 random bits is the only thing standing between those two cases.
String newIdempotencyKey({Random? rng}) => _hex(16, rng);

bool isLocalId(String v) => v.startsWith('local_');

// --- the op ------------------------------------------------------------------

class QueuedOp {
  const QueuedOp({
    required this.id,
    required this.seq,
    required this.kind,
    required this.target,
    this.assigns,
    this.deps = const <String>[],
    this.body,
    this.key,
    required this.summary,
    required this.createdAtMs,
    this.attempts = 0,
    this.serverAttempts = 0,
    this.pendingAttempts = 0,
    this.nextAtMs = 0,
    this.errorStatus,
    this.errorMessage,
    this.reason,
    this.diedAtMs,
  });

  final String id;

  /// Monotonic, never reused. Defines FIFO order.
  final int seq;

  final OpKind kind;

  /// The task this acts on. `''` for [OpKind.createTask]. May be a `local_` id
  /// whose create has not landed yet.
  final String target;

  /// The local id this op will resolve once the server answers. Only creates.
  final String? assigns;

  /// Local ids this op references. An op is never dispatched while any of these
  /// is unresolved.
  final List<String> deps;

  /// Stored verbatim as the UI built it and re-encoded with `jsonEncode`. Never
  /// rebuilt from typed fields, never mutated. See the file header.
  final Map<String, dynamic>? body;

  /// The idempotency key, or null for routes that do not opt in.
  final String? key;

  /// Minted at enqueue for the dead-letter UI, because by the time an op fails
  /// the task it names may not exist anywhere the UI can look it up.
  final String summary;

  final int createdAtMs;

  /// Total attempts, and what the UI shows.
  final int attempts;

  /// Attempts that got a 5xx/408/429. Bounded by [kServerBudget].
  final int serverAttempts;

  /// Attempts that got a 409. Bounded by [kPendingBudget].
  final int pendingAttempts;

  /// Earliest ms at which this may be sent again.
  final int nextAtMs;

  // Dead-letter fields; all null while the op is pending.
  final int? errorStatus;
  final String? errorMessage;
  final DeadReason? reason;
  final int? diedAtMs;

  String get method {
    switch (kind) {
      case OpKind.createTask:
      case OpKind.completeTask:
        return 'POST';
      case OpKind.updateTask:
        return 'PATCH';
      case OpKind.deleteTask:
        return 'DELETE';
    }
  }

  bool get carriesKey => key != null;

  QueuedOp copyWith({
    /// Only the flusher sets this, when it assigns the op its FIFO position at
    /// enqueue. Nothing else may ever renumber an op.
    int? seq,
    int? attempts,
    int? serverAttempts,
    int? pendingAttempts,
    int? nextAtMs,
    String? key,
    int? errorStatus,
    String? errorMessage,
    DeadReason? reason,
    int? diedAtMs,
  }) {
    return QueuedOp(
      id: id,
      seq: seq ?? this.seq,
      kind: kind,
      target: target,
      assigns: assigns,
      deps: deps,
      body: body,
      key: key ?? this.key,
      summary: summary,
      createdAtMs: createdAtMs,
      attempts: attempts ?? this.attempts,
      serverAttempts: serverAttempts ?? this.serverAttempts,
      pendingAttempts: pendingAttempts ?? this.pendingAttempts,
      nextAtMs: nextAtMs ?? this.nextAtMs,
      errorStatus: errorStatus ?? this.errorStatus,
      errorMessage: errorMessage ?? this.errorMessage,
      reason: reason ?? this.reason,
      diedAtMs: diedAtMs ?? this.diedAtMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'seq': seq,
        'kind': kind.name,
        'target': target,
        'assigns': assigns,
        'deps': deps,
        'body': body,
        'key': key,
        'summary': summary,
        'createdAtMs': createdAtMs,
        'attempts': attempts,
        'serverAttempts': serverAttempts,
        'pendingAttempts': pendingAttempts,
        'nextAtMs': nextAtMs,
        if (errorStatus != null) 'errorStatus': errorStatus,
        if (errorMessage != null) 'errorMessage': errorMessage,
        if (reason != null) 'reason': reason!.name,
        if (diedAtMs != null) 'diedAtMs': diedAtMs,
      };

  /// Returns null for anything it cannot make sense of, so one bad row cannot
  /// cost the user the rest of the queue.
  static QueuedOp? fromJson(Map<String, dynamic> j) {
    final Object? rawKind = j['kind'];
    if (rawKind is! String) return null;
    OpKind? kind;
    for (final OpKind k in OpKind.values) {
      if (k.name == rawKind) kind = k;
    }
    if (kind == null) return null;

    final Object? id = j['id'];
    final Object? seq = j['seq'];
    if (id is! String || id.isEmpty || seq is! int) return null;

    final Object? rawBody = j['body'];
    final Object? rawDeps = j['deps'];
    final Object? rawReason = j['reason'];
    DeadReason? reason;
    if (rawReason is String) {
      for (final DeadReason r in DeadReason.values) {
        if (r.name == rawReason) reason = r;
      }
    }

    return QueuedOp(
      id: id,
      seq: seq,
      kind: kind,
      target: j['target'] is String ? j['target'] as String : '',
      assigns: j['assigns'] is String ? j['assigns'] as String : null,
      deps: rawDeps is List
          ? rawDeps.whereType<String>().toList()
          : const <String>[],
      // `Map<String, dynamic>.from` preserves insertion order, which is what
      // keeps `jsonEncode(body)` byte-identical across a restart — and therefore
      // keeps the server's body hash stable under an already-minted key.
      body: rawBody is Map ? Map<String, dynamic>.from(rawBody) : null,
      key: j['key'] is String ? j['key'] as String : null,
      summary: j['summary'] is String ? j['summary'] as String : '',
      createdAtMs: j['createdAtMs'] is int ? j['createdAtMs'] as int : 0,
      attempts: j['attempts'] is int ? j['attempts'] as int : 0,
      serverAttempts: j['serverAttempts'] is int ? j['serverAttempts'] as int : 0,
      pendingAttempts:
          j['pendingAttempts'] is int ? j['pendingAttempts'] as int : 0,
      nextAtMs: j['nextAtMs'] is int ? j['nextAtMs'] as int : 0,
      errorStatus: j['errorStatus'] is int ? j['errorStatus'] as int : null,
      errorMessage: j['errorMessage'] is String ? j['errorMessage'] as String : null,
      reason: reason,
      diedAtMs: j['diedAtMs'] is int ? j['diedAtMs'] as int : null,
    );
  }
}

// --- resolve-at-dispatch -----------------------------------------------------

/// A request as it will actually go on the wire. Built fresh for every attempt
/// and never persisted.
class ResolvedOp {
  const ResolvedOp({
    required this.method,
    required this.path,
    required this.body,
    required this.key,
    required this.idPath,
  });

  final String method;
  final String path;
  final Map<String, dynamic>? body;
  final String? key;

  /// Where to find the new server id in the response, for ops that assign one.
  /// `'task.id'` for a create, null otherwise.
  final String? idPath;
}

class Resolution {
  const Resolution.ready(ResolvedOp this.op) : missing = const <String>[];
  const Resolution.blocked(this.missing) : op = null;

  final ResolvedOp? op;
  final List<String> missing;

  bool get isReady => op != null;
}

/// The local ids this op still cannot resolve.
List<String> unresolvedDeps(QueuedOp op, Map<String, String> idMap) {
  final List<String> missing = <String>[];
  for (final String dep in op.deps) {
    if (isLocalId(dep) && !idMap.containsKey(dep)) missing.add(dep);
  }
  return missing;
}

/// Body keys whose VALUE may be a local id and must be substituted.
///
/// Phase 1 is `parentTaskId` alone: `listId` and `goalId` always hold server ids
/// because lists and goals are not queued yet. Phase 2 adds them here and
/// nothing else in the algorithm changes.
const List<String> kIdBearingBodyKeys = <String>['parentTaskId'];

/// Substitute local ids into a throwaway request. Returns [Resolution.blocked]
/// if any is still unknown — the caller must then FAIL CLOSED rather than send.
///
/// Sending `POST /tasks {"parentTaskId": "local_7b1e…"}` would 404 on the parent
/// lookup or, worse, create an orphan the user can never find.
Resolution resolve(QueuedOp op, Map<String, String> idMap) {
  final List<String> missing = <String>[];

  String target = op.target;
  if (target.isNotEmpty && isLocalId(target)) {
    final String? mapped = idMap[target];
    if (mapped == null) {
      missing.add(target);
    } else {
      target = mapped;
    }
  }

  Map<String, dynamic>? body;
  final Map<String, dynamic>? source = op.body;
  if (source != null) {
    // A copy: the persisted body must come out of this function untouched.
    body = Map<String, dynamic>.from(source);
    for (final String field in kIdBearingBodyKeys) {
      if (!body.containsKey(field)) continue;
      final Object? v = body[field];
      // Whole-value match, never a substring — a task titled "local_max notes"
      // is not an id and must survive verbatim.
      if (v is String && isLocalId(v)) {
        final String? mapped = idMap[v];
        if (mapped == null) {
          missing.add(v);
        } else {
          body[field] = mapped;
        }
      }
    }
  }

  if (missing.isNotEmpty) return Resolution.blocked(missing);

  final String path = switch (op.kind) {
    OpKind.createTask => '/tasks',
    OpKind.updateTask || OpKind.deleteTask => '/tasks/$target',
    OpKind.completeTask => '/tasks/$target/complete',
  };

  return Resolution.ready(ResolvedOp(
    method: op.method,
    path: path,
    body: body,
    key: op.key,
    idPath: op.kind == OpKind.createTask ? 'task.id' : null,
  ));
}

// --- policy ------------------------------------------------------------------

/// Turn one HTTP outcome into a decision.
///
/// [hadResponse] distinguishes "the server said something" from "we never got an
/// answer", which is the difference between consuming a retry budget and not.
OpOutcome classify({
  required OpKind kind,
  required int? status,
  required bool hadResponse,
}) {
  if (!hadResponse || status == null) return OpOutcome.retryTransport;
  if (status >= 200 && status < 300) return OpOutcome.succeeded;

  // A delete whose row is already gone achieved exactly what was asked. Task ids
  // are server cuids and are never reused, so a 404 here can only mean "already
  // deleted" — not "you are deleting someone else's row".
  //
  // This is SUCCESS FOR DELETE ONLY. A 404 on a complete means the completion
  // was never recorded; calling that success would drop the op, drop its
  // optimistic row, and un-tick the checkbox on the next refresh with no trace.
  if (status == 404 && kind == OpKind.deleteTask) return OpOutcome.succeeded;

  if (status == 401) return OpOutcome.authPaused;
  if (status == 409) return OpOutcome.retryPending;
  if (status == 408 || status == 429 || status >= 500) return OpOutcome.retryServer;
  return OpOutcome.terminal;
}

Duration backoffFor(int attempts) {
  final int i = attempts <= 0
      ? 0
      : (attempts >= _backoffSeconds.length ? _backoffSeconds.length - 1 : attempts);
  return Duration(seconds: _backoffSeconds[i]);
}

/// Whether this op may be sent now.
///
/// The second branch is a clock-skew clamp. `nextAtMs` is an absolute wall-clock
/// instant, so a user who sets the device clock forward and then back leaves ops
/// scheduled arbitrarily far in the future and the queue wedges permanently. A
/// wait longer than the largest backoff we ever schedule cannot be one we
/// scheduled, so it is treated as due.
bool isDue(QueuedOp op, int nowMs) {
  if (op.nextAtMs <= nowMs) return true;
  return op.nextAtMs - nowMs > kMaxBackoff.inMilliseconds;
}

bool isExpired(QueuedOp op, int nowMs) =>
    nowMs - op.createdAtMs > const Duration(days: kExpiryDays).inMilliseconds;

// --- cascade and coalescing --------------------------------------------------

/// Every op that transitively depends on a local id that will never exist.
///
/// Returns op ids, not ops, so the caller can move them all in ONE store write.
/// Sending them instead would produce one 404 per dependent and one confusing
/// dead-letter row per 404, for a single underlying cause.
Set<String> cascadeFrom(List<QueuedOp> ops, String deadLocalId) {
  final Set<String> poisoned = <String>{deadLocalId};
  final Set<String> doomed = <String>{};

  // Fixed point rather than one pass: a subtask create under a subtask create
  // only becomes doomed once its own parent has been marked.
  bool changed = true;
  while (changed) {
    changed = false;
    for (final QueuedOp op in ops) {
      if (doomed.contains(op.id)) continue;
      bool hit = false;
      for (final String dep in op.deps) {
        if (poisoned.contains(dep)) {
          hit = true;
          break;
        }
      }
      if (!hit) continue;
      doomed.add(op.id);
      changed = true;
      final String? assigns = op.assigns;
      if (assigns != null) poisoned.add(assigns);
    }
  }
  return doomed;
}

/// A task typed and then deleted while offline should never touch the network.
///
/// Returns the ops that remain, or null to keep everything as-is.
///
/// The `attempts == 0` guard is load-bearing: once the create has been attempted
/// its outcome is unknown, so a server row may exist that only the delete can
/// clean up. Dropping both then would leak a task the user thinks they deleted.
List<QueuedOp>? cancelCreateThenDelete(List<QueuedOp> ops, String localId) {
  QueuedOp? create;
  QueuedOp? del;
  for (final QueuedOp op in ops) {
    if (op.kind == OpKind.createTask && op.assigns == localId) create = op;
    if (op.kind == OpKind.deleteTask && op.target == localId) del = op;
  }
  if (create == null || del == null) return null;
  if (create.attempts != 0) return null;

  final Set<String> doomed = cascadeFrom(ops, localId)
    ..add(create.id)
    ..add(del.id);
  return ops.where((QueuedOp o) => !doomed.contains(o.id)).toList();
}

// --- summaries ---------------------------------------------------------------

String summaryFor(OpKind kind, Map<String, dynamic>? body, String fallbackTitle) {
  final Object? raw = body == null ? null : body['title'];
  final String title =
      raw is String && raw.trim().isNotEmpty ? raw.trim() : fallbackTitle;
  final String subject = title.isEmpty ? 'a task' : '"$title"';
  switch (kind) {
    case OpKind.createTask:
      return 'New task $subject';
    case OpKind.updateTask:
      return 'Edit $subject';
    case OpKind.completeTask:
      return 'Complete $subject';
    case OpKind.deleteTask:
      return 'Delete $subject';
  }
}
