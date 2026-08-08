import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/horizons.dart';
import '../models/task.dart';
import '../core/offline/goal_overlay.dart';
import '../core/offline/list_overlay.dart';
import '../core/offline/task_overlay.dart';
import '../models/goal.dart';
import '../models/task_list.dart';
import 'goals_provider.dart';
import 'lists_provider.dart';
import 'tasks_provider.dart';
import 'write_queue_provider.dart';

/// The current task-workspace selection: which smart list / list / tag, plus
/// search, sort, and whether completed tasks are shown.
class TaskFilter {
  const TaskFilter({
    this.horizon = 'all',
    this.listId, // null = all lists; 'inbox' = Inbox; else a list id
    this.tagId,
    this.search = '',
    this.sort = 'default',
    this.showCompleted = false,
  });

  final String horizon;
  final String? listId;
  final String? tagId;
  final String search;
  final String sort;
  final bool showCompleted;

  TaskFilter copyWith({
    String? horizon,
    Object? listId = _sentinel,
    Object? tagId = _sentinel,
    String? search,
    String? sort,
    bool? showCompleted,
  }) {
    return TaskFilter(
      horizon: horizon ?? this.horizon,
      listId: listId == _sentinel ? this.listId : listId as String?,
      tagId: tagId == _sentinel ? this.tagId : tagId as String?,
      search: search ?? this.search,
      sort: sort ?? this.sort,
      showCompleted: showCompleted ?? this.showCompleted,
    );
  }

  static const Object _sentinel = Object();
}

final taskFilterProvider = StateProvider<TaskFilter>((ref) => const TaskFilter());

int _cmpNullableDate(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1; // nulls last
  if (b == null) return -1;
  return a.compareTo(b);
}

/// Server truth with every pending write folded on top. EVERY task reader
/// watches this, never `tasksControllerProvider` directly.
///
/// Dead ops are folded in too. Without that, a task the user typed offline whose
/// create the server then rejected would vanish from the list the instant it was
/// dead-lettered — they would watch their own typing disappear with no
/// explanation. It stays, badged, until they decide what to do with it.
final allTasksProvider = Provider<List<Task>>((ref) {
  final server = ref.watch(tasksControllerProvider).value ?? const <Task>[];
  final pending = ref.watch(pendingOpsProvider);
  final dead = ref.watch(deadOpsProvider);
  final idMap = ref.watch(queueIdMapProvider);
  if (pending.isEmpty && dead.isEmpty) return server;
  return applyQueue(server, [...pending, ...dead], idMap);
});

/// Server truth for lists with pending creates and deletes folded on top.
/// Every list reader watches this, never `listsControllerProvider` directly.
final allListsProvider = Provider<List<TaskList>>((ref) {
  final server = ref.watch(listsControllerProvider).value ?? const <TaskList>[];
  final pending = ref.watch(pendingOpsProvider);
  final dead = ref.watch(deadOpsProvider);
  final idMap = ref.watch(queueIdMapProvider);
  if (pending.isEmpty && dead.isEmpty) return server;
  return applyListQueue(server, [...pending, ...dead], idMap);
});

/// The selected list id, resolved through the queue's id map.
///
/// Selecting a list created offline stores its `local_` id in the filter. When
/// the create lands, every task's `listId` becomes the SERVER id — so without
/// this the comparison stopped matching and the view the user was looking at
/// silently emptied, with a list still highlighted in the drawer.
final selectedListIdProvider = Provider<String?>((ref) {
  final id = ref.watch(taskFilterProvider).listId;
  if (id == null || id == 'inbox') return id;
  return ref.watch(queueIdMapProvider)[id] ?? id;
});

/// Server truth for goals with pending writes folded on top. Every goal reader
/// watches this, never `goalsControllerProvider` directly.
final allGoalsProvider = Provider<List<Goal>>((ref) {
  final server = ref.watch(goalsControllerProvider).value ?? const <Goal>[];
  final pending = ref.watch(pendingOpsProvider);
  final dead = ref.watch(deadOpsProvider);
  final idMap = ref.watch(queueIdMapProvider);
  if (pending.isEmpty && dead.isEmpty) return server;
  return applyGoalQueue(server, [...pending, ...dead], idMap);
});

/// The filtered + sorted top-level tasks for the current selection.
final visibleTasksProvider = Provider<List<Task>>((ref) {
  final all = ref.watch(allTasksProvider);
  final f = ref.watch(taskFilterProvider);
  final now = DateTime.now();

  var list = all.where((t) => t.parentTaskId == null).toList();

  final selectedList = ref.watch(selectedListIdProvider);
  if (selectedList == 'inbox') {
    list = list.where((t) => t.listId == null).toList();
  } else if (selectedList != null) {
    list = list.where((t) => t.listId == selectedList).toList();
  }

  if (f.tagId != null) {
    list = list.where((t) => t.tags.any((tg) => tg.id == f.tagId)).toList();
  }

  list = list.where((t) => matchesHorizon(f.horizon, t.dueDate, t.status, now)).toList();

  final q = f.search.trim().toLowerCase();
  if (q.isNotEmpty) {
    list = list
        .where((t) =>
            t.title.toLowerCase().contains(q) ||
            (t.description ?? '').toLowerCase().contains(q))
        .toList();
  }

  if (!f.showCompleted) {
    list = list.where((t) => !t.isTerminal).toList();
  }

  switch (f.sort) {
    case 'dueDate':
      list.sort((a, b) => _cmpNullableDate(a.dueDate, b.dueDate));
      break;
    case 'priority':
      list.sort((a, b) => priorityRankOf(b.priority).compareTo(priorityRankOf(a.priority)));
      break;
    case 'title':
      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      break;
    case 'created':
      // No createdAt on the client model; fall back to the server order.
      list.sort((a, b) => (a.order ?? 0).compareTo(b.order ?? 0));
      break;
    default:
      list.sort((a, b) => (a.order ?? 0).compareTo(b.order ?? 0));
  }

  return list;
});

/// Subtasks grouped by their parent id (for progress badges + the editor).
final subtasksByParentProvider = Provider<Map<String, List<Task>>>((ref) {
  final all = ref.watch(allTasksProvider);
  final map = <String, List<Task>>{};
  for (final t in all) {
    final p = t.parentTaskId;
    if (p != null) (map[p] ??= []).add(t);
  }
  return map;
});

/// Open-task counts per smart-list horizon, for the drawer badges.
final horizonCountsProvider = Provider<Map<String, int>>((ref) {
  final all = ref.watch(allTasksProvider);
  final now = DateTime.now();
  final open = all.where((t) => t.parentTaskId == null && !t.isTerminal).toList();
  final counts = <String, int>{};
  for (final h in kHorizons) {
    counts[h.key] = open.where((t) => matchesHorizon(h.key, t.dueDate, t.status, now)).length;
  }
  return counts;
});
