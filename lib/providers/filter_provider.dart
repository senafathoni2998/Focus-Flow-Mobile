import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/horizons.dart';
import '../models/task.dart';
import 'tasks_provider.dart';

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

/// The filtered + sorted top-level tasks for the current selection.
final visibleTasksProvider = Provider<List<Task>>((ref) {
  final all = ref.watch(tasksControllerProvider).value ?? const [];
  final f = ref.watch(taskFilterProvider);
  final now = DateTime.now();

  var list = all.where((t) => t.parentTaskId == null).toList();

  if (f.listId == 'inbox') {
    list = list.where((t) => t.listId == null).toList();
  } else if (f.listId != null) {
    list = list.where((t) => t.listId == f.listId).toList();
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
  final all = ref.watch(tasksControllerProvider).value ?? const [];
  final map = <String, List<Task>>{};
  for (final t in all) {
    final p = t.parentTaskId;
    if (p != null) (map[p] ??= []).add(t);
  }
  return map;
});

/// Open-task counts per smart-list horizon, for the drawer badges.
final horizonCountsProvider = Provider<Map<String, int>>((ref) {
  final all = ref.watch(tasksControllerProvider).value ?? const [];
  final now = DateTime.now();
  final open = all.where((t) => t.parentTaskId == null && !t.isTerminal).toList();
  final counts = <String, int>{};
  for (final h in kHorizons) {
    counts[h.key] = open.where((t) => matchesHorizon(h.key, t.dueDate, t.status, now)).length;
  }
  return counts;
});
