import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/offline/queue_flusher.dart';
import '../../core/offline/task_overlay.dart' show PendingState;
import '../../models/habit.dart';
import '../../providers/filter_provider.dart';
import '../../providers/habits_provider.dart';
import '../../providers/write_queue_provider.dart';
import '../../widgets/common.dart';

class HabitsScreen extends ConsumerWidget {
  const HabitsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(habitsControllerProvider);
    // Content comes from the overlay so a habit made offline is real
    // immediately; the AsyncValue is still consulted for loading and error.
    final overlaid = ref.watch(allHabitsProvider);
    final pendingStates = ref.watch(habitPendingStateProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Habits')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const HabitEditorScreen()),
        ),
        child: const Icon(Icons.add),
      ),
      body: state.when(
        loading: () => const LoadingCenter(),
        error: (e, _) =>
            ErrorRetry(message: '$e', onRetry: () => ref.read(habitsControllerProvider.notifier).load()),
        data: (_) {
          // The overlay, not the raw response: a habit created offline must be
          // real on this screen immediately, and one whose edit is pending must
          // show the edit.
          final habits = overlaid;
          return RefreshIndicator(
            onRefresh: () => ref.read(habitsControllerProvider.notifier).refresh(),
            child: habits.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 120),
                    EmptyState(
                      icon: Icons.local_fire_department_outlined,
                      title: 'No habits yet',
                      subtitle: 'Build a routine — tap + to add your first habit.',
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    itemCount: habits.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) => _HabitCard(
                      habit: habits[i],
                      pending: pendingStates[habits[i].id],
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class _HabitCard extends ConsumerWidget {
  const _HabitCard({required this.habit, this.pending});
  final Habit habit;
  final PendingState? pending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final color = semanticColor(habit.color);
    final s = habit.stats;
    final ctrl = ref.read(habitsControllerProvider.notifier);

    // No longer disabled for an unsynced habit. A check-in is now a queued op
    // that DEPENDS on the create, so the queue holds it until the real id
    // exists and then substitutes it — checking in a habit you just made
    // offline is the ordinary case, not an error.
    Future<void> run(Future<SubmitOutcome> Function() f) async {
      try {
        // Silent when it lands, a word when it does not. A toast on every tap of
        // a +1 button would be worse than no feedback — the number moving IS the
        // feedback, and the cloud badge says the rest.
        final SubmitOutcome outcome = await f();
        if (outcome == SubmitOutcome.deferred && context.mounted) {
          showOfflineSaved(context);
        }
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return SoftCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => HabitEditorScreen(habit: habit)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withAlpha(38),
            child: Text(habit.icon, style: const TextStyle(fontSize: 20)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Before the name, so a habit that has not reached the
                    // server is never mistaken for one that has. Failed is amber
                    // and the row STAYS — a habit the user typed must not vanish
                    // because the server refused it.
                    if (pending != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Icon(
                          switch (pending!) {
                            PendingState.queued => Icons.cloud_queue,
                            PendingState.sending => Icons.cloud_sync,
                            PendingState.failed => Icons.error_outline,
                          },
                          size: 14,
                          color: pending == PendingState.failed
                              ? scheme.error
                              : scheme.outline,
                        ),
                      ),
                    Expanded(
                      child: Text(habit.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.local_fire_department, size: 15, color: color),
                    const SizedBox(width: 2),
                    Text('${s.currentStreak}${s.streakUnit == 'week' ? 'w' : 'd'}',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    const SizedBox(width: 12),
                    Icon(Icons.calendar_today, size: 13, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Text('${s.monthlyRate}% this month',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
                if (habit.isAmount) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_fmt(s.todayAmount)} / ${_fmt(habit.targetAmount ?? 1)} ${habit.unit ?? ''} today',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (habit.isAmount)
            Row(
              children: [
                IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => run(() => ctrl.checkIn(habit.id, delta: -1)),
                  icon: const Icon(Icons.remove),
                ),
                IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => run(() => ctrl.checkIn(habit.id, delta: 1)),
                  icon: const Icon(Icons.add),
                ),
              ],
            )
          else
            IconButton(
              iconSize: 34,
              onPressed: () => run(() => ctrl.checkIn(habit.id, delta: s.todayDone ? -1 : 1)),
              icon: Icon(
                s.todayDone ? Icons.check_circle : Icons.radio_button_unchecked,
                color: s.todayDone ? color : scheme.outline,
              ),
            ),
        ],
      ),
    );
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Create / edit a habit.
class HabitEditorScreen extends ConsumerStatefulWidget {
  const HabitEditorScreen({super.key, this.habit});
  final Habit? habit;

  @override
  ConsumerState<HabitEditorScreen> createState() => _HabitEditorScreenState();
}

class _HabitEditorScreenState extends ConsumerState<HabitEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _unit;
  late final TextEditingController _target;

  String _icon = '✅';
  String _color = 'primary';
  String _goalType = 'achieve';
  String _frequencyType = 'daily';
  final Set<int> _weekdays = {};
  int _weeklyTarget = 3;
  bool _saving = false;

  bool get _isEdit => widget.habit != null;

  @override
  void initState() {
    super.initState();
    final h = widget.habit;
    _name = TextEditingController(text: h?.name ?? '');
    _unit = TextEditingController(text: h?.unit ?? '');
    _target = TextEditingController(text: (h?.targetAmount ?? 1).toString());
    _icon = h?.icon ?? '✅';
    _color = h?.color ?? 'primary';
    _goalType = h?.goalType ?? 'achieve';
    // Reconstruct the UI mode: a stored `daily` habit with weekdays set is the
    // "specific days of the week" mode (the backend has no separate value for it).
    if (h == null) {
      _frequencyType = 'daily';
    } else if (h.frequencyType == 'weekly') {
      _frequencyType = 'weekly';
    } else if (h.weekdays.isNotEmpty) {
      _frequencyType = 'specific';
    } else {
      _frequencyType = 'daily';
    }
    _weekdays.addAll(h?.weekdays ?? const []);
    _weeklyTarget = h?.weeklyTarget ?? 3;
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showError(context, 'Name is required');
      return;
    }
    // Frequency resolution: "specific days" is a daily habit with a weekday list.
    final body = <String, dynamic>{
      'name': name,
      'icon': _icon,
      'color': _color,
      'goalType': _goalType,
      'frequencyType': _frequencyType == 'weekly' ? 'weekly' : 'daily',
      'weekdays': _frequencyType == 'specific' ? _weekdays.toList() : <int>[],
      'weeklyTarget': _frequencyType == 'weekly' ? _weeklyTarget : 1,
      if (_goalType == 'amount') 'targetAmount': double.tryParse(_target.text.trim()) ?? 1,
      if (_goalType == 'amount' && _unit.text.trim().isNotEmpty) 'unit': _unit.text.trim(),
    };
    if (_frequencyType == 'specific' && _weekdays.isEmpty) {
      showError(context, 'Pick at least one weekday');
      return;
    }
    setState(() => _saving = true);
    try {
      final ctrl = ref.read(habitsControllerProvider.notifier);
      final SubmitOutcome outcome = _isEdit
          ? await ctrl.update(widget.habit!.id, body)
          : await ctrl.create(body);
      if (mounted) {
        // Said out loud rather than implied: the editor closing normally would
        // otherwise read as "saved on the server", which it is not yet.
        if (outcome == SubmitOutcome.deferred) showOfflineSaved(context);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete habit?', message: 'All check-ins are removed.');
    if (!ok) return;
    try {
      final SubmitOutcome outcome =
          await ref.read(habitsControllerProvider.notifier).delete(widget.habit!.id);
      if (mounted) {
        if (outcome == SubmitOutcome.deferred) showOfflineSaved(context);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _archive() async {
    try {
      final SubmitOutcome outcome =
          await ref.read(habitsControllerProvider.notifier).archive(widget.habit!.id);
      if (mounted) {
        if (outcome == SubmitOutcome.deferred) showOfflineSaved(context);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit habit' : 'New habit'),
        actions: [
          if (_isEdit) ...[
            IconButton(tooltip: 'Archive', onPressed: _archive, icon: const Icon(Icons.archive_outlined)),
            IconButton(tooltip: 'Delete', onPressed: _delete, icon: const Icon(Icons.delete_outline)),
          ],
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Habit name'),
          ),
          const SizedBox(height: 20),
          _label('Icon'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: kIconChoices.map((e) {
              final sel = _icon == e;
              return GestureDetector(
                onTap: () => setState(() => _icon = e),
                child: CircleAvatar(
                  backgroundColor: sel
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Text(e, style: const TextStyle(fontSize: 18)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          _label('Color'),
          Wrap(
            spacing: 10,
            children: kSemanticColors.map((c) {
              final sel = _color == c;
              return GestureDetector(
                onTap: () => setState(() => _color = c),
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: semanticColor(c),
                  child: sel ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          _label('Goal type'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'achieve', label: Text('Do it'), icon: Icon(Icons.check)),
              ButtonSegment(value: 'amount', label: Text('Amount'), icon: Icon(Icons.tag)),
            ],
            selected: {_goalType},
            onSelectionChanged: (s) => setState(() => _goalType = s.first),
          ),
          if (_goalType == 'amount') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _target,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Daily target'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    decoration: const InputDecoration(labelText: 'Unit (e.g. glasses)'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          _label('Frequency'),
          DropdownButtonFormField<String>(
            value: _frequencyType,
            decoration: const InputDecoration(),
            items: const [
              DropdownMenuItem(value: 'daily', child: Text('Every day')),
              DropdownMenuItem(value: 'specific', child: Text('Specific days of the week')),
              DropdownMenuItem(value: 'weekly', child: Text('A number of times per week')),
            ],
            onChanged: (v) => setState(() => _frequencyType = v ?? 'daily'),
          ),
          if (_frequencyType == 'specific') ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              children: List.generate(7, (i) {
                final sel = _weekdays.contains(i);
                return FilterChip(
                  label: Text(kWeekdayLabels[i]),
                  selected: sel,
                  onSelected: (_) => setState(() => sel ? _weekdays.remove(i) : _weekdays.add(i)),
                );
              }),
            ),
          ],
          if (_frequencyType == 'weekly') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Times per week: '),
                Expanded(
                  child: Slider(
                    value: _weeklyTarget.toDouble(),
                    min: 1,
                    max: 7,
                    divisions: 6,
                    label: '$_weeklyTarget',
                    onChanged: (v) => setState(() => _weeklyTarget = v.round()),
                  ),
                ),
                Text('$_weeklyTarget'),
              ],
            ),
          ],
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.of(context).padding.bottom),
        child: FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_isEdit ? 'Save changes' : 'Create habit'),
        ),
      ),
    );
  }

  Widget _label(String t) =>
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)));
}
