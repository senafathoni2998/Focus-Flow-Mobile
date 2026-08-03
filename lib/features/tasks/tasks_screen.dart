import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/horizons.dart';
import '../../models/task.dart';
import '../../providers/filter_provider.dart';
import '../../providers/lists_provider.dart';
import '../../providers/tags_provider.dart';
import '../../providers/tasks_provider.dart';
import '../../widgets/common.dart';
import '../focus/focus_screen.dart';
import 'calendar_view.dart';
import 'matrix_view.dart';
import 'task_card.dart';
import 'task_editor_screen.dart';
import 'tasks_drawer.dart';

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});
  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

enum TaskView { list, calendar, matrix }

class _TasksScreenState extends ConsumerState<TasksScreen> {
  // View choice is local: it changes how the SAME filtered set is presented,
  // so it does not belong in the shared filter state.
  TaskView _view = TaskView.list;
  bool _searching = false;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _currentTitle() {
    final f = ref.watch(taskFilterProvider);
    if (f.tagId != null) {
      final tags = ref.watch(tagsControllerProvider).value ?? const [];
      for (final t in tags) {
        if (t.id == f.tagId) return '#${t.name}';
      }
      return 'Tag';
    }
    if (f.listId == 'inbox') return 'Inbox';
    if (f.listId != null) {
      final lists = ref.watch(listsControllerProvider).value ?? const [];
      for (final l in lists) {
        if (l.id == f.listId) return l.name;
      }
      return 'List';
    }
    for (final h in kHorizons) {
      if (h.key == f.horizon) return h.label;
    }
    return 'Tasks';
  }

  Future<void> _toggle(Task t) async {
    final ctrl = ref.read(tasksControllerProvider.notifier);
    try {
      if (t.isTerminal) {
        await ctrl.update(t.id, {'status': 'todo'});
      } else {
        final recurred = await ctrl.complete(t.id);
        if (recurred && mounted) showInfo(context, 'Recurring task moved to its next date');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(Task t) async {
    try {
      await ref.read(tasksControllerProvider.notifier).delete(t.id);
      if (mounted) showInfo(context, 'Task deleted');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _openEditor([Task? task]) {
    final f = ref.read(taskFilterProvider);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TaskEditorScreen(
        task: task,
        presetListId: task == null && f.listId != null && f.listId != 'inbox' ? f.listId : null,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tasksControllerProvider);
    final filter = ref.watch(taskFilterProvider);
    final subtasksByParent = ref.watch(subtasksByParentProvider);

    return Scaffold(
      drawer: const TasksDrawer(),
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: 'Search tasks…', border: InputBorder.none),
                onChanged: (v) =>
                    ref.read(taskFilterProvider.notifier).state = filter.copyWith(search: v),
              )
            : Text(_currentTitle()),
        actions: [
          if (_searching)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchCtrl.clear();
                ref.read(taskFilterProvider.notifier).state = filter.copyWith(search: '');
                setState(() => _searching = false);
              },
            )
          else ...[
            PopupMenuButton<TaskView>(
              tooltip: 'View',
              icon: Icon(switch (_view) {
                TaskView.list => Icons.view_list_outlined,
                TaskView.calendar => Icons.calendar_month_outlined,
                TaskView.matrix => Icons.grid_view_outlined,
              }),
              onSelected: (v) => setState(() => _view = v),
              itemBuilder: (_) => [
                for (final entry in const {
                  TaskView.list: ('List', Icons.view_list_outlined),
                  TaskView.calendar: ('Calendar', Icons.calendar_month_outlined),
                  TaskView.matrix: ('Matrix', Icons.grid_view_outlined),
                }.entries)
                  PopupMenuItem(
                    value: entry.key,
                    child: Row(
                      children: [
                        Icon(_view == entry.key ? Icons.check : entry.value.$2, size: 18),
                        const SizedBox(width: 8),
                        Text(entry.value.$1),
                      ],
                    ),
                  ),
              ],
            ),
            // Entry point for the pomodoro timer. It lives here rather than as a
            // sixth bottom-nav destination — five is already the Material maximum
            // and six labels crowd a 360dp screen — and this is where the intent
            // starts, since a pomodoro is usually run FOR a task.
            IconButton(
              tooltip: 'Focus timer',
              icon: const Icon(Icons.timer_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FocusScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => setState(() => _searching = true),
            ),
            IconButton(
              tooltip: filter.showCompleted ? 'Hide completed' : 'Show completed',
              icon: Icon(filter.showCompleted ? Icons.visibility : Icons.visibility_off),
              onPressed: () => ref.read(taskFilterProvider.notifier).state =
                  filter.copyWith(showCompleted: !filter.showCompleted),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              onSelected: (v) =>
                  ref.read(taskFilterProvider.notifier).state = filter.copyWith(sort: v),
              itemBuilder: (_) => [
                for (final e in kSortOptions.entries)
                  PopupMenuItem(
                    value: e.key,
                    child: Row(
                      children: [
                        Icon(filter.sort == e.key ? Icons.check : Icons.sort, size: 18),
                        const SizedBox(width: 8),
                        Text(e.value),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: async.when(
        loading: () => const LoadingCenter(),
        error: (e, _) => ErrorRetry(
          message: e.toString(),
          onRetry: () => ref.read(tasksControllerProvider.notifier).load(),
        ),
        data: (_) {
          final visible = ref.watch(visibleTasksProvider);
          if (_view != TaskView.list) {
            return RefreshIndicator(
              onRefresh: () => ref.read(tasksControllerProvider.notifier).refresh(),
              child: _view == TaskView.calendar
                  ? CalendarView(onTap: _openEditor, onToggle: _toggle)
                  : MatrixView(onTap: _openEditor, onToggle: _toggle),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(tasksControllerProvider.notifier).refresh(),
            child: visible.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      EmptyState(
                        icon: Icons.check_circle_outline,
                        title: 'Nothing here',
                        subtitle: 'Add a task with the + button, or pick another list.',
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final t = visible[i];
                      final subs = subtasksByParent[t.id] ?? const [];
                      final done = subs.where((s) => s.isCompleted).length;
                      return Dismissible(
                        key: ValueKey(t.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.error,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        confirmDismiss: (_) => confirmDialog(
                          context,
                          title: 'Delete task',
                          message: 'Delete "${t.title}"? Subtasks will be removed too.',
                        ),
                        onDismissed: (_) => _delete(t),
                        child: TaskCard(
                          task: t,
                          subtaskDone: done,
                          subtaskTotal: subs.length,
                          onToggle: () => _toggle(t),
                          onTap: () => _openEditor(t),
                        ),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}
