import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/queue_flusher.dart';
import '../core/offline/queue_op.dart';
import '../core/offline/task_overlay.dart';
import '../core/offline/write_queue_store.dart';
import '../data/sync_repository.dart';
import 'providers.dart';
import 'dashboard_provider.dart';
import 'goals_provider.dart';
import 'habits_provider.dart';
import 'lists_provider.dart';
import 'session_provider.dart';
import 'tags_provider.dart';
import 'tasks_provider.dart';

/// Riverpod wiring for the offline write queue.
///
/// The flusher owns the truth; these StateProviders are a projection of it that
/// widgets can watch. They are only ever written from the flusher's `onChanged`,
/// never by the UI.

final writeQueueStoreProvider =
    Provider<WriteQueueStore>((ref) => WriteQueueStore());

final pendingOpsProvider =
    StateProvider<List<QueuedOp>>((ref) => const <QueuedOp>[]);
final deadOpsProvider = StateProvider<List<QueuedOp>>((ref) => const <QueuedOp>[]);
final queueIdMapProvider =
    StateProvider<Map<String, String>>((ref) => const <String, String>{});
final inFlightOpIdProvider = StateProvider<String?>((ref) => null);
final queueStateProvider = StateProvider<FlushState>((ref) => FlushState.idle);

/// Set when a queue file could not be parsed and was moved aside. The work in it
/// is gone from the app; saying so is the least we owe the user.
final queueCorruptedProvider = StateProvider<bool>((ref) => false);

/// Failures dropped to stay under the dead-letter cap. See QueueDoc.droppedDead.
final droppedDeadProvider = StateProvider<int>((ref) => 0);

final queueFlusherProvider = Provider<QueueFlusher>((ref) {
  final QueueFlusher flusher = QueueFlusher(
    store: ref.watch(writeQueueStoreProvider),
    transport: ApiClientTransport(ref.watch(apiClientProvider)),
    // Read at call time, not captured: the whole point is to notice that the
    // signed-in user CHANGED while a flush was in flight.
    currentUserId: () => ref.read(tokenStorageProvider).getUserId(),
    onChanged: (QueueDoc doc, String? inFlightOpId, FlushState state,
        bool recoveredFromCorruption) {
      ref.read(pendingOpsProvider.notifier).state = doc.ops;
      ref.read(deadOpsProvider.notifier).state = doc.dead;
      ref.read(queueIdMapProvider.notifier).state = doc.idMap;
      ref.read(inFlightOpIdProvider.notifier).state = inFlightOpId;
      ref.read(queueStateProvider.notifier).state = state;
      ref.read(queueCorruptedProvider.notifier).state = recoveredFromCorruption;
      ref.read(droppedDeadProvider.notifier).state = doc.droppedDead;
    },
    onServerRow: (OpKind kind, OpEntity entity, Map<String, dynamic> row) {
      // Written into server truth in the same turn the op leaves the queue, so
      // the row never blinks out between "acked" and "authoritative".
      switch (entity) {
        case OpEntity.task:
          ref.read(tasksControllerProvider.notifier).upsertFromServer(row);
        case OpEntity.list:
          ref.read(listsControllerProvider.notifier).upsertFromServer(row);
        case OpEntity.goal:
          // Deliberately NOT folded. POST /goals and PATCH /goals/:id return the
          // RAW row — goalService applies withProgress/withTaskCounts only in
          // the LIST endpoints — so upserting an ack would blank the goal to 0%
          // until the next full fetch. The post-drain delta carries the properly
          // serialised row instead.
          break;
        case OpEntity.habit:
          // A CHECK-IN's ack is folded; every other habit ack is not, and the
          // difference is what the response actually contains.
          //
          // POST /habits and PATCH /habits/:id return the RAW row — withHabitStats
          // runs only on the list and sync paths — and Habit.fromJson substitutes
          // HabitStats.empty() when `stats` is missing, so upserting one would
          // blank the streak to zero. checkInHabit returns the habit WITH
          // recomputed stats, which is the whole point of that endpoint.
          //
          // And here folding is not merely safe, it is required: a check-in
          // writes HabitCheckIn, never Habit, so the habit's own `updatedAt`
          // does not move and the post-drain delta will not carry it back. Skip
          // this and the tick the user just watched go on would come straight
          // off again the moment the op left the queue.
          if (kind == OpKind.checkInHabit) {
            ref.read(habitsControllerProvider.notifier).upsertFromServer(row);
          }
          break;
        case OpEntity.session:
          // Nothing to fold. The focus timer runs off local state and its
          // complete/cancel ops reference the session by its LOCAL id, which the
          // queue resolves from the id map — so the server id is never needed on
          // screen. The 7-day summary is refreshed on drain instead.
          break;
      }
    },
    onDrained: (Set<OpEntity> touched) {
      // Everything the queue guessed at locally — order, tag ids, a recurring
      // task's next date, a list's server id — is only knowable from the server,
      // so reconcile once the queue is empty rather than after each op.
      //
      // ONE delta request, not a full GET per entity. A drain can change more
      // than it wrote: deleting a list re-parents every task in it to the Inbox
      // through a database cascade the service never mentions, and creating a
      // task can mint tags the drawer has never seen. Asking "what changed since
      // the cursor" covers all of that in a single round trip and returns the
      // deletions too, which no list endpoint can express.
      unawaited(_reconcileAfterDrain(ref, touched));
    },
  );
  ref.onDispose(flusher.dispose);
  return flusher;
});

/// Pull everything that changed while the queue was draining.
///
/// Falls back to the old per-entity refreshes if the delta fails, because a
/// failed reconcile must not leave the screen showing values the queue only
/// guessed at — a stale full refresh is better than a confident wrong one.
Future<void> _reconcileAfterDrain(Ref ref, Set<OpEntity> touched) async {
  final QueueFlusher flusher = ref.read(queueFlusherProvider);
  try {
    final SyncDelta delta =
        await ref.read(syncRepositoryProvider).since(flusher.syncCursor);

    Set<String> deletedOf(String type) => delta.deleted
        .where((({String id, String type}) d) => d.type == type)
        .map((({String id, String type}) d) => d.id)
        .toSet();

    ref.read(tasksControllerProvider.notifier).applyServerDelta(
        delta.tasks, deletedOf('task'),
        full: delta.full);
    ref.read(listsControllerProvider.notifier).applyServerDelta(
        delta.lists, deletedOf('list'),
        full: delta.full);
    ref.read(tagsControllerProvider.notifier).applyServerDelta(
        delta.tags, deletedOf('tag'),
        full: delta.full);
    ref.read(goalsControllerProvider.notifier).applyServerDelta(
        delta.goals, deletedOf('goal'),
        full: delta.full);
    ref.read(habitsControllerProvider.notifier).applyServerDelta(
        delta.habits, deletedOf('habit'),
        full: delta.full);

    if (touched.contains(OpEntity.session)) {
      // A completed pomodoro changes a task's actualMin and the dashboard's
      // focus total, and neither is derived from anything the delta carries —
      // both are computed server-side from the session rows.
      ref.invalidate(recentSessionsProvider);
      unawaited(ref.read(dashboardControllerProvider.notifier).refresh());
    }

    // Only now. Advancing first and then failing to apply would skip these
    // changes for good, since the next request asks for everything since a
    // point we never processed.
    await flusher.advanceSyncCursor(delta.serverTime);
  } catch (_) {
    if (touched.contains(OpEntity.task) || touched.contains(OpEntity.list)) {
      unawaited(ref.read(tasksControllerProvider.notifier).refresh());
    }
    if (touched.contains(OpEntity.list)) {
      unawaited(ref.read(listsControllerProvider.notifier).refresh());
    }
  }
}

/// Pending + failed. What the Settings row and the app-bar badge count.
final unsentCountProvider = Provider<int>((ref) =>
    ref.watch(pendingOpsProvider).length + ref.watch(deadOpsProvider).length);

final failedCountProvider =
    Provider<int>((ref) => ref.watch(deadOpsProvider).length);

/// Row badges, keyed by id within ONE entity's namespace.
///
/// Separate maps per entity on purpose: tasks and lists have independent id
/// spaces, so a single flat map would put a list id somewhere a task lookup
/// could find it.
Map<String, PendingState> _badges(Ref ref, OpEntity entity) =>
    pendingStateByEntityId(
      entity,
      ref.watch(pendingOpsProvider),
      ref.watch(deadOpsProvider),
      ref.watch(inFlightOpIdProvider),
      ref.watch(queueIdMapProvider),
    );

final taskPendingStateProvider =
    Provider<Map<String, PendingState>>((ref) => _badges(ref, OpEntity.task));

final listPendingStateProvider =
    Provider<Map<String, PendingState>>((ref) => _badges(ref, OpEntity.list));

final habitPendingStateProvider =
    Provider<Map<String, PendingState>>((ref) => _badges(ref, OpEntity.habit));

/// Mounted once above the screen swap, beside the reminder poller.
///
/// App resume is the cheapest reliable "the network may be back" signal there
/// is: no package, no permission, no polling. The other trigger is any 2xx from
/// any request (see ApiClient.onNetworkOk), which covers the case where the app
/// was never backgrounded at all.
class QueueLifecycle extends ConsumerStatefulWidget {
  const QueueLifecycle({required this.child, super.key});
  final Widget child;

  @override
  ConsumerState<QueueLifecycle> createState() => _QueueLifecycleState();
}

class _QueueLifecycleState extends ConsumerState<QueueLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(queueFlusherProvider).kick();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
