import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/session_provider.dart';
import '../../providers/filter_provider.dart';

/// Pomodoro timer.
///
/// The whole /sessions API was already built and tested but had no mobile UI, so
/// a phone-only user saw a permanent "Focus (7d) = 0m" and every task's tracked
/// time stayed at zero — both are derived solely from FocusSession rows.
class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  static String _mmss(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final s = ref.watch(focusControllerProvider);
    final ctrl = ref.read(focusControllerProvider.notifier);
    // The overlay, not the raw controller: a task created while offline must be
    // selectable as the thing you are focusing on.
    final tasks = ref.watch(allTasksProvider);
    final openTasks = tasks
        .where((t) => t.status != 'completed' && t.status != 'wont-do' && t.parentTaskId == null)
        .toList();

    final idle = s.phase == FocusPhase.idle;

    return Scaffold(
      appBar: AppBar(title: const Text('Focus')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          SegmentedButton<String>(
            segments: [
              for (final e in kFocusDurations.entries)
                ButtonSegment(value: e.key, label: Text(kFocusLabels[e.key] ?? e.key)),
            ],
            selected: {s.type},
            // Changing type mid-session would orphan the running row, so it is
            // only offered while idle rather than silently abandoning it.
            onSelectionChanged: idle ? (sel) => ctrl.setType(sel.first) : null,
          ),
          const SizedBox(height: 28),

          Center(
            child: SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: s.progress,
                      strokeWidth: 10,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _mmss(s.remaining),
                        style: const TextStyle(
                          fontSize: 46,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(kFocusLabels[s.type] ?? s.type,
                          style: TextStyle(color: scheme.outline)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),

          if (s.type == 'pomodoro')
            DropdownButtonFormField<String?>(
              initialValue: openTasks.any((t) => t.id == s.taskId) ? s.taskId : null,
              decoration: const InputDecoration(labelText: 'Working on (optional)'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Nothing in particular')),
                ...openTasks.map(
                  (t) => DropdownMenuItem(
                    value: t.id,
                    child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: idle ? ctrl.setTask : null,
            ),
          const SizedBox(height: 20),

          Row(
            children: [
              if (idle)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: s.busy ? null : ctrl.start,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(s.busy ? 'Starting…' : 'Start'),
                  ),
                )
              else ...[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: s.phase == FocusPhase.running ? ctrl.pause : ctrl.resume,
                    icon: Icon(s.phase == FocusPhase.running ? Icons.pause : Icons.play_arrow),
                    label: Text(s.phase == FocusPhase.running ? 'Pause' : 'Resume'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: ctrl.cancel,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ],
          ),

          if (s.error != null) ...[
            const SizedBox(height: 16),
            Text(s.error!, style: TextStyle(color: scheme.error)),
          ],

          const SizedBox(height: 28),
          Text('Last 7 days', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ref.watch(recentSessionsProvider).when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Text('Could not load recent sessions.',
                    style: TextStyle(color: scheme.outline)),
                data: (sessions) {
                  final done = sessions
                      .where((x) => x.status == 'completed' && x.type == 'pomodoro')
                      .toList();
                  if (done.isEmpty) {
                    return Text('No completed pomodoros yet.',
                        style: TextStyle(color: scheme.outline));
                  }
                  final minutes = done.fold<int>(
                    0,
                    (a, x) => a + (x.elapsed?.inMinutes ?? 0),
                  );
                  return Text(
                    '${done.length} pomodoro${done.length == 1 ? '' : 's'} · $minutes min',
                    style: TextStyle(color: scheme.outline),
                  );
                },
              ),
        ],
      ),
    );
  }
}
