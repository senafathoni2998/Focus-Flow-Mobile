import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/task.dart';
import '../../providers/filter_provider.dart';
import 'task_card.dart';

/// Eisenhower matrix, ported from the web `TaskMatrixView`.
///
/// Urgency and importance are derived exactly as the web does — importance is
/// `priority == 'high'`, urgency is "due within two days, or overdue" — so the
/// same task lands in the same quadrant on both surfaces. Getting that subtly
/// wrong would be worse than not shipping the view: two devices disagreeing about
/// what is urgent is harder to trust than one device not showing it at all.
const int kUrgentWithinDays = 2;

enum Quadrant { doFirst, schedule, delegate, later }

class _QuadrantSpec {
  const _QuadrantSpec(this.quadrant, this.title, this.subtitle, this.color);
  final Quadrant quadrant;
  final String title;
  final String subtitle;
  final Color color;
}

const _specs = <_QuadrantSpec>[
  _QuadrantSpec(Quadrant.doFirst, 'Do first', 'Urgent & important', Color(0xFFE5484D)),
  _QuadrantSpec(Quadrant.schedule, 'Schedule', 'Important, not urgent', Color(0xFF3B82F6)),
  _QuadrantSpec(Quadrant.delegate, 'Delegate', 'Urgent, not important', Color(0xFFF59E0B)),
  _QuadrantSpec(Quadrant.later, 'Later', 'Neither', Color(0xFF9CA3AF)),
];

int _daysUntil(DateTime due, DateTime now) {
  final d = DateTime(due.year, due.month, due.day);
  final n = DateTime(now.year, now.month, now.day);
  return d.difference(n).inDays;
}

Quadrant quadrantOf(Task t, DateTime now) {
  final important = t.priority == 'high';
  final urgent = t.dueDate != null && _daysUntil(t.dueDate!, now) <= kUrgentWithinDays;
  if (urgent && important) return Quadrant.doFirst;
  if (important) return Quadrant.schedule;
  if (urgent) return Quadrant.delegate;
  return Quadrant.later;
}

/// Group the ACTIONABLE tasks (terminal ones are done; a matrix of finished work
/// is noise) into the four quadrants.
Map<Quadrant, List<Task>> groupByQuadrant(List<Task> tasks, DateTime now) {
  final out = {for (final q in Quadrant.values) q: <Task>[]};
  for (final t in tasks) {
    if (t.isTerminal) continue;
    out[quadrantOf(t, now)]!.add(t);
  }
  return out;
}

class MatrixView extends ConsumerWidget {
  const MatrixView({super.key, required this.onTap, required this.onToggle});
  final void Function(Task) onTap;
  final void Function(Task) onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(visibleTasksProvider);
    final groups = groupByQuadrant(tasks, DateTime.now());

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        for (final spec in _specs) ...[
          _QuadrantSection(
            spec: spec,
            tasks: groups[spec.quadrant]!,
            onTap: onTap,
            onToggle: onToggle,
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _QuadrantSection extends StatelessWidget {
  const _QuadrantSection({
    required this.spec,
    required this.tasks,
    required this.onTap,
    required this.onToggle,
  });
  final _QuadrantSpec spec;
  final List<Task> tasks;
  final void Function(Task) onTap;
  final void Function(Task) onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 4, height: 28, color: spec.color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(spec.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(spec.subtitle,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: spec.color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${tasks.length}',
                  style: TextStyle(fontSize: 12, color: spec.color, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Nothing here', style: TextStyle(color: scheme.outline, fontSize: 13)),
          )
        else
          for (final t in tasks) ...[
            TaskCard(task: t, onTap: () => onTap(t), onToggle: () => onToggle(t)),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}
