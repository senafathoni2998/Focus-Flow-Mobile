import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/date_format.dart';
import '../../models/goal.dart';
import '../../providers/goals_provider.dart';
import '../../widgets/common.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(goalsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Goals')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const GoalEditorScreen()),
        ),
        child: const Icon(Icons.add),
      ),
      body: state.when(
        loading: () => const LoadingCenter(),
        error: (e, _) =>
            ErrorRetry(message: '$e', onRetry: () => ref.read(goalsControllerProvider.notifier).load()),
        data: (goals) {
          final active = goals.where((g) => g.status != 'achieved').toList();
          final achieved = goals.where((g) => g.status == 'achieved').toList();
          return RefreshIndicator(
            onRefresh: () => ref.read(goalsControllerProvider.notifier).refresh(),
            child: goals.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 120),
                    EmptyState(
                      icon: Icons.flag_outlined,
                      title: 'No goals yet',
                      subtitle: 'Set something to aim for — tap + to add a goal.',
                    ),
                  ])
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                    children: [
                      for (final g in active) ...[
                        _GoalCard(goal: g),
                        const SizedBox(height: 8),
                      ],
                      if (achieved.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(4, 12, 4, 8),
                          child: Text('Achieved', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        for (final g in achieved) ...[
                          _GoalCard(goal: g),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class _GoalCard extends ConsumerWidget {
  const _GoalCard({required this.goal});
  final Goal goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final color = semanticColor(goal.color);
    final p = goal.progress;
    final ctrl = ref.read(goalsControllerProvider.notifier);

    Future<void> run(Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    String subtitle() {
      if (goal.isTasks) return '${goal.taskCompleted ?? 0}/${goal.taskTotal ?? 0} tasks';
      if (goal.isNumeric) {
        return '${_fmt(goal.currentValue)} / ${_fmt(goal.targetValue ?? 0)} ${goal.unit ?? ''}';
      }
      return '${goal.manualProgress}%';
    }

    return SoftCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => GoalEditorScreen(goal: goal)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(goal.icon, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(goal.title,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
              IconButton(
                tooltip: p.isAchieved ? 'Reopen' : 'Mark achieved',
                icon: Icon(p.isAchieved ? Icons.emoji_events : Icons.emoji_events_outlined,
                    color: p.isAchieved ? color : scheme.outline),
                onPressed: () =>
                    run(() => ctrl.setStatus(goal.id, p.isAchieved ? 'active' : 'achieved')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (p.percent / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: scheme.surfaceContainer,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('${p.percent}%', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(subtitle(),
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
              if (goal.targetDate != null)
                Text(
                  _deadline(p.daysRemaining),
                  style: TextStyle(
                    fontSize: 12,
                    color: p.isOverdue ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (!goal.isTasks) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => run(() => ctrl.adjustProgress(goal.id, goal.isNumeric ? -1 : -10)),
                  icon: const Icon(Icons.remove),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => run(() => ctrl.adjustProgress(goal.id, goal.isNumeric ? 1 : 10)),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _deadline(int? days) {
    if (days == null) return '';
    if (days < 0) return '${-days}d overdue';
    if (days == 0) return 'Due today';
    return '${days}d left';
  }

  String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Create / edit a goal.
class GoalEditorScreen extends ConsumerStatefulWidget {
  const GoalEditorScreen({super.key, this.goal});
  final Goal? goal;

  @override
  ConsumerState<GoalEditorScreen> createState() => _GoalEditorScreenState();
}

class _GoalEditorScreenState extends ConsumerState<GoalEditorScreen> {
  late final TextEditingController _title;
  late final TextEditingController _desc;
  late final TextEditingController _target;
  late final TextEditingController _unit;

  String _icon = '🎯';
  String _color = 'primary';
  String _progressType = 'manual';
  int _manualProgress = 0;
  DateTime? _targetDate;
  bool _saving = false;

  bool get _isEdit => widget.goal != null;

  @override
  void initState() {
    super.initState();
    final g = widget.goal;
    _title = TextEditingController(text: g?.title ?? '');
    _desc = TextEditingController(text: g?.description ?? '');
    _target = TextEditingController(text: g?.targetValue != null ? _fmt(g!.targetValue!) : '');
    _unit = TextEditingController(text: g?.unit ?? '');
    _icon = g?.icon ?? '🎯';
    _color = g?.color ?? 'primary';
    _progressType = g?.progressType ?? 'manual';
    _manualProgress = g?.manualProgress ?? 0;
    _targetDate = g?.targetDate;
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _target.dispose();
    _unit.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _targetDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) setState(() => _targetDate = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showError(context, 'Title is required');
      return;
    }
    if (_progressType == 'numeric') {
      final t = double.tryParse(_target.text.trim());
      if (t == null || t <= 0) {
        showError(context, 'Enter a positive target value');
        return;
      }
    }
    final body = <String, dynamic>{
      'title': title,
      'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
      'icon': _icon,
      'color': _color,
      'progressType': _progressType,
      'targetDate': _targetDate != null ? Dates.ymd(_targetDate!) : null,
      if (_progressType == 'numeric') 'targetValue': double.tryParse(_target.text.trim()) ?? 1,
      if (_progressType == 'numeric' && _unit.text.trim().isNotEmpty) 'unit': _unit.text.trim(),
      if (_progressType == 'manual') 'manualProgress': _manualProgress,
    };
    setState(() => _saving = true);
    try {
      final ctrl = ref.read(goalsControllerProvider.notifier);
      if (_isEdit) {
        await ctrl.update(widget.goal!.id, body);
      } else {
        await ctrl.create(body);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Delete goal?', message: 'Linked tasks are kept.');
    if (!ok) return;
    try {
      await ref.read(goalsControllerProvider.notifier).delete(widget.goal!.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _archive() async {
    try {
      await ref.read(goalsControllerProvider.notifier).setStatus(widget.goal!.id, 'archived');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit goal' : 'New goal'),
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
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Goal title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Notes'),
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
          _label('Track progress by'),
          DropdownButtonFormField<String>(
            value: _progressType,
            decoration: const InputDecoration(),
            items: const [
              DropdownMenuItem(value: 'manual', child: Text('Manual percentage')),
              DropdownMenuItem(value: 'numeric', child: Text('A number (e.g. 10 books)')),
              DropdownMenuItem(value: 'tasks', child: Text('Linked tasks')),
            ],
            onChanged: (v) => setState(() => _progressType = v ?? 'manual'),
          ),
          if (_progressType == 'numeric') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _target,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Target'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    decoration: const InputDecoration(labelText: 'Unit'),
                  ),
                ),
              ],
            ),
          ],
          if (_progressType == 'manual') ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Progress: '),
                Expanded(
                  child: Slider(
                    value: _manualProgress.toDouble(),
                    max: 100,
                    divisions: 20,
                    label: '$_manualProgress%',
                    onChanged: (v) => setState(() => _manualProgress = v.round()),
                  ),
                ),
                Text('$_manualProgress%'),
              ],
            ),
          ],
          if (_progressType == 'tasks')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Progress is derived from tasks you assign to this goal.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 20),
          _label('Deadline'),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text(_targetDate != null ? Dates.dayLabel(_targetDate!) : 'No deadline'),
                ),
              ),
              if (_targetDate != null)
                IconButton(onPressed: () => setState(() => _targetDate = null), icon: const Icon(Icons.clear)),
            ],
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.of(context).padding.bottom),
        child: FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_isEdit ? 'Save changes' : 'Create goal'),
        ),
      ),
    );
  }

  Widget _label(String t) =>
      Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)));

  String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}
