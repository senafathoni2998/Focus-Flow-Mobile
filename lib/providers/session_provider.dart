import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/focus_session.dart';
import 'dashboard_provider.dart';
import '../core/offline/queue_flusher.dart';
import '../core/offline/queue_op.dart';
import 'providers.dart';
import 'write_queue_provider.dart';
import 'tasks_provider.dart';

/// Planned lengths, in seconds — the same values the web PomodoroTimer uses.
const kFocusDurations = <String, int>{
  'pomodoro': 25 * 60,
  'short-break': 5 * 60,
  'long-break': 15 * 60,
};

const kFocusLabels = <String, String>{
  'pomodoro': 'Focus',
  'short-break': 'Short break',
  'long-break': 'Long break',
};

enum FocusPhase { idle, running, paused }

class FocusState {
  const FocusState({
    this.phase = FocusPhase.idle,
    this.type = 'pomodoro',
    this.session,
    this.taskId,
    this.remaining = const Duration(minutes: 25),
    this.busy = false,
    this.error,
  });

  final FocusPhase phase;
  final String type;
  final FocusSession? session;
  final String? taskId;
  final Duration remaining;
  final bool busy;
  final String? error;

  int get plannedSeconds => kFocusDurations[type] ?? 25 * 60;

  double get progress {
    final total = plannedSeconds;
    if (total <= 0) return 0;
    final done = total - remaining.inSeconds;
    return (done / total).clamp(0.0, 1.0);
  }

  FocusState copyWith({
    FocusPhase? phase,
    String? type,
    FocusSession? session,
    bool clearSession = false,
    String? taskId,
    bool clearTaskId = false,
    Duration? remaining,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      FocusState(
        phase: phase ?? this.phase,
        type: type ?? this.type,
        session: clearSession ? null : (session ?? this.session),
        taskId: clearTaskId ? null : (taskId ?? this.taskId),
        remaining: remaining ?? this.remaining,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Drives the focus timer.
///
/// The countdown is ANCHORED TO A DEADLINE, not decremented once per tick. The
/// web timer decremented, which meant it stopped advancing whenever the tab was
/// throttled or the machine slept and then "completed" hours late, writing a
/// single multi-hour pomodoro into every focus metric. A phone backgrounds and
/// dozes far more aggressively than a browser tab, so the same design would fail
/// harder here. The ticker only re-reads the clock; suspending it changes nothing
/// except how often the label repaints, and on resume the remaining time is
/// simply correct.
///
/// The server independently clamps endTime to startTime + duration, so even a
/// client that lies cannot inflate the numbers.
class FocusController extends StateNotifier<FocusState> {
  FocusController(this._ref) : super(const FocusState());

  final Ref _ref;
  QueueFlusher get _queue => _ref.read(queueFlusherProvider);

  Timer? _ticker;
  DateTime? _deadline;

  void setType(String type) {
    if (state.phase != FocusPhase.idle) return; // stop first; no silent orphans
    state = state.copyWith(
      type: type,
      remaining: Duration(seconds: kFocusDurations[type] ?? 25 * 60),
      clearError: true,
    );
  }

  void setTask(String? taskId) {
    state = taskId == null
        ? state.copyWith(clearTaskId: true)
        : state.copyWith(taskId: taskId);
  }

  Future<void> start() async {
    if (state.phase != FocusPhase.idle || state.busy) return;

    // THE TIMER STARTS FIRST, before anything touches the network.
    //
    // It used to await the server, so with no signal the pomodoro simply did not
    // begin. The timer is local and deadline-anchored anyway; making it wait on
    // a round trip only meant a user on a plane could not focus at all.
    final DateTime startedAt = DateTime.now();
    final String localId = newLocalId();
    final String? taskId = state.type == 'pomodoro' ? state.taskId : null;

    _deadline = startedAt.add(Duration(seconds: state.plannedSeconds));
    state = state.copyWith(
      phase: FocusPhase.running,
      session: FocusSession(
        id: localId,
        type: state.type,
        duration: state.plannedSeconds,
        status: 'running',
        startTime: startedAt,
        taskId: taskId,
      ),
      busy: false,
      clearError: true,
      remaining: Duration(seconds: state.plannedSeconds),
    );
    _startTicker();

    final Map<String, dynamic> body = <String, dynamic>{
      if (taskId != null) 'taskId': taskId,
      'type': state.type,
      'duration': state.plannedSeconds,
      // FROZEN AT ENQUEUE, and the reason this can be queued at all. The server
      // used to stamp its own clock, so a flight's pomodoros all landed at the
      // instant the wifi reconnected — hours of focus time on the wrong DAY in
      // every chart. It clamps this to `<= now` and to 30 days back.
      'startTime': startedAt.toUtc().toIso8601String(),
    };

    try {
      await _queue.submit(QueuedOp(
        id: newOpId(),
        seq: 0,
        kind: OpKind.createSession,
        target: '',
        assigns: localId,
        // A session can be attributed to a task created in the same offline
        // stretch, so its taskId may itself be a local id.
        deps: <String>[
          if (taskId != null && isLocalId(taskId)) taskId,
        ],
        body: body,
        // Mandatory: POST /sessions is idempotency-wrapped, and creating a row
        // is the one inherently non-idempotent act.
        key: newIdempotencyKey(),
        summary: summaryFor(OpKind.createSession, null, ''),
        createdAtMs: startedAt.millisecondsSinceEpoch,
      ));
    } catch (e) {
      // The timer keeps running. The user's time is real whether or not we
      // managed to record it, and stopping the clock would be the worse lie.
      if (mounted) state = state.copyWith(error: e.toString());
    }
  }

  void pause() {
    if (state.phase != FocusPhase.running) return;
    _ticker?.cancel();
    _ticker = null;
    // Freeze the remaining time; the deadline is rebuilt from it on resume.
    state = state.copyWith(phase: FocusPhase.paused, remaining: _remainingNow());
    _deadline = null;
  }

  void resume() {
    if (state.phase != FocusPhase.paused) return;
    _deadline = DateTime.now().add(state.remaining);
    state = state.copyWith(phase: FocusPhase.running);
    _startTicker();
  }

  /// Stop early. The session is cancelled server-side so it never lingers as a
  /// zombie `running` row (the web timer used to leak exactly those).
  Future<void> cancel() async {
    final id = state.session?.id;
    _stopTicker();
    state = state.copyWith(
      phase: FocusPhase.idle,
      clearSession: true,
      remaining: Duration(seconds: state.plannedSeconds),
    );
    if (id == null) return;
    try {
      await _queue.submit(QueuedOp(
        id: newOpId(),
        seq: 0,
        kind: OpKind.cancelSession,
        target: id,
        deps: <String>[if (isLocalId(id)) id],
        // No key: /sessions/:id/cancel does not opt into idempotency. Replaying
        // it hits the "Session is not running" 409, which carries no Retry-After
        // and is therefore terminal — not six wasted attempts.
        summary: summaryFor(OpKind.cancelSession, null, ''),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (_) {
      // The local timer is already stopped; a stale row is not worth blocking on.
    }
  }

  Future<void> _complete() async {
    final id = state.session?.id;
    _stopTicker();
    state = state.copyWith(
      phase: FocusPhase.idle,
      clearSession: true,
      remaining: Duration(seconds: state.plannedSeconds),
    );
    if (id == null) return;
    try {
      final outcome = await _queue.submit(QueuedOp(
        id: newOpId(),
        seq: 0,
        kind: OpKind.completeSession,
        target: id,
        deps: <String>[if (isLocalId(id)) id],
        summary: summaryFor(OpKind.completeSession, null, ''),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      // A finished pomodoro changes a task's actualMin and the dashboard's focus
      // total, and neither derives from local state. Only worth re-reading if it
      // actually reached the server; a queued one is reconciled on drain.
      if (outcome.outcome == SubmitOutcome.sent) {
        if (state.type == 'pomodoro') {
          await _ref.read(tasksControllerProvider.notifier).refresh();
        }
        await _ref.read(dashboardControllerProvider.notifier).refresh();
      }
    } catch (e) {
      if (mounted) state = state.copyWith(error: e.toString());
    }
  }

  Duration _remainingNow() {
    final d = _deadline;
    if (d == null) return state.remaining;
    final left = d.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final left = _remainingNow();
      if (left <= Duration.zero) {
        unawaited(_complete());
        return;
      }
      state = state.copyWith(remaining: left);
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _deadline = null;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

final focusControllerProvider =
    StateNotifierProvider<FocusController, FocusState>((ref) => FocusController(ref));

/// Recent sessions, for the "today" summary on the focus screen.
final recentSessionsProvider = FutureProvider.autoDispose<List<FocusSession>>((ref) {
  return ref.watch(sessionRepositoryProvider).list(days: 7);
});
