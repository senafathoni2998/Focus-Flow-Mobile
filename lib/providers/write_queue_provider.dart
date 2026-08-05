import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/queue_flusher.dart';
import '../core/offline/queue_op.dart';
import '../core/offline/task_overlay.dart';
import '../core/offline/write_queue_store.dart';
import 'providers.dart';
import 'lists_provider.dart';
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
    },
    onServerRow: (OpEntity entity, Map<String, dynamic> row) {
      // Written into server truth in the same turn the op leaves the queue, so
      // the row never blinks out between "acked" and "authoritative".
      switch (entity) {
        case OpEntity.task:
          ref.read(tasksControllerProvider.notifier).upsertFromServer(row);
        case OpEntity.list:
          ref.read(listsControllerProvider.notifier).upsertFromServer(row);
      }
    },
    onDrained: (Set<OpEntity> touched) {
      // Everything the queue guessed at locally — order, tag ids, a recurring
      // task's next date, a list's server id — is only knowable from the server,
      // so reconcile once the queue is empty rather than after each op. Only the
      // entities that actually changed: refreshing all of them every time would
      // be several requests where one is needed.
      if (touched.contains(OpEntity.task)) {
        ref.read(tasksControllerProvider.notifier).refresh();
      }
      if (touched.contains(OpEntity.list)) {
        // A list DELETE re-parents its tasks to the Inbox through a database
        // cascade the service never mentions, so tasks are stale too.
        ref.read(listsControllerProvider.notifier).refresh();
        ref.read(tasksControllerProvider.notifier).refresh();
      }
    },
  );
  ref.onDispose(flusher.dispose);
  return flusher;
});

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
