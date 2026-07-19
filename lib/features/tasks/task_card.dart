import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/date_format.dart';
import '../../models/task.dart';

/// A single task row: completion toggle, title, and metadata (due date, priority,
/// tags, subtask progress, recurrence + reminder badges).
class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onTap,
    this.subtaskDone = 0,
    this.subtaskTotal = 0,
  });

  final Task task;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final int subtaskDone;
  final int subtaskTotal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final done = task.isTerminal;
    final overdue = task.dueDate != null &&
        task.dueDate!.isBefore(DateTime(now.year, now.month, now.day)) &&
        !done;

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                onPressed: onToggle,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: done ? scheme.primary : scheme.outline,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (task.priority != 'none' && task.priority != 'medium')
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 2),
                            child: Icon(Icons.flag, size: 14, color: priorityColor(task.priority)),
                          ),
                        Expanded(
                          child: Text(
                            task.title,
                            style: TextStyle(
                              fontSize: 15,
                              decoration: done ? TextDecoration.lineThrough : null,
                              color: done ? scheme.onSurfaceVariant : scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_hasMeta) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (task.dueDate != null)
                            _MetaChip(
                              icon: Icons.event,
                              label: Dates.relativeDay(task.dueDate!, now),
                              color: overdue ? scheme.error : scheme.onSurfaceVariant,
                            ),
                          if (task.isRecurring)
                            _MetaChip(
                                icon: Icons.repeat,
                                label: kRecurrenceLabels[task.recurrence!.freq] ?? 'Repeats',
                                color: scheme.onSurfaceVariant),
                          if (task.reminders.isNotEmpty)
                            _MetaChip(
                                icon: Icons.notifications_none,
                                label: '${task.reminders.length}',
                                color: scheme.onSurfaceVariant),
                          if (subtaskTotal > 0)
                            _MetaChip(
                                icon: Icons.checklist,
                                label: '$subtaskDone/$subtaskTotal',
                                color: subtaskDone == subtaskTotal
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant),
                          for (final tag in task.tags.take(3))
                            _MetaChip(icon: Icons.label_outline, label: tag.name, color: scheme.tertiary),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _hasMeta =>
      task.dueDate != null ||
      task.isRecurring ||
      task.reminders.isNotEmpty ||
      subtaskTotal > 0 ||
      task.tags.isNotEmpty;
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}
