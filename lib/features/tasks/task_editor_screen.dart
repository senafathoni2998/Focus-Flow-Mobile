import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/date_format.dart';
import '../../models/task.dart';
import '../../providers/filter_provider.dart';
import '../../providers/tags_provider.dart';
import '../../core/offline/queue_flusher.dart';
import '../../providers/tasks_provider.dart';
import '../../widgets/common.dart';

/// Create or edit a task. Passing [task] switches to edit mode (adds the subtasks
/// section + a delete action).
class TaskEditorScreen extends ConsumerStatefulWidget {
  const TaskEditorScreen({
    super.key,
    this.task,
    this.presetListId,
    this.presetTitle,
    this.presetDescription,
  });
  final Task? task;
  final String? presetListId;
  /// Prefilled when a new task starts from somewhere else — currently the
  /// Android share sheet. Ignored when editing an existing task.
  final String? presetTitle;
  final String? presetDescription;

  @override
  ConsumerState<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends ConsumerState<TaskEditorScreen> {
  late final TextEditingController _title;
  late final TextEditingController _desc;
  final _tagInput = TextEditingController();

  String _priority = 'medium';
  DateTime? _dueDate;
  String? _listId; // null = Inbox
  String? _goalId;
  String? _recurrence; // null = none
  final List<String> _tags = [];
  final List<DateTime> _reminders = [];
  bool _saving = false;

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? widget.presetTitle ?? '');
    _desc = TextEditingController(text: t?.description ?? widget.presetDescription ?? '');
    _priority = t?.priority ?? 'medium';
    _dueDate = t?.dueDate;
    _listId = t?.listId ?? widget.presetListId;
    _goalId = t?.goalId;
    _recurrence = t?.recurrence?.freq;
    _tags.addAll((t?.tags ?? []).map((e) => e.name));
    _reminders.addAll((t?.reminders ?? []).map((e) => e.triggerAt));
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _tagInput.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _dueDate = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _addReminder() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() => _reminders.add(dt));
  }

  void _addTag(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return;
    if (!_tags.contains(name)) setState(() => _tags.add(name));
    _tagInput.clear();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showError(context, 'Title is required');
      return;
    }
    setState(() => _saving = true);
    final ctrl = ref.read(tasksControllerProvider.notifier);
    try {
      final SubmitOutcome outcome;
      if (_isEdit) {
        outcome = await ctrl.update(widget.task!.id, {
          'title': title,
          'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          'priority': _priority,
          'dueDate': _dueDate != null ? Dates.ymd(_dueDate!) : '',
          'listId': _listId,
          'goalId': _goalId,
          'tags': _tags,
          'reminders': _reminders.map(Dates.utcIso).toList(),
          'recurrence': _recurrence,
        });
      } else {
        outcome = await ctrl.create({
          'title': title,
          if (_desc.text.trim().isNotEmpty) 'description': _desc.text.trim(),
          'priority': _priority,
          if (_dueDate != null) 'dueDate': Dates.ymd(_dueDate!),
          if (_listId != null) 'listId': _listId,
          if (_goalId != null) 'goalId': _goalId,
          if (_tags.isNotEmpty) 'tags': _tags,
          if (_reminders.isNotEmpty) 'reminders': _reminders.map(Dates.utcIso).toList(),
          if (_recurrence != null) 'recurrence': _recurrence,
        });
      }
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

  Future<void> _deleteTask() async {
    final ok = await confirmDialog(
      context,
      title: 'Delete task?',
      message: 'This also deletes its subtasks. This cannot be undone.',
    );
    if (!ok) return;
    try {
      await ref.read(tasksControllerProvider.notifier).delete(widget.task!.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(allListsProvider);
    final goals = ref.watch(allGoalsProvider);
    final knownTags = ref.watch(tagsControllerProvider).value ?? const [];
    final suggestions = knownTags.where((t) => !_tags.contains(t.name)).take(8).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit task' : 'New task'),
        actions: [
          if (_isEdit)
            IconButton(
              tooltip: 'Delete',
              onPressed: _deleteTask,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 20),
          _label('Priority'),
          Wrap(
            spacing: 8,
            children: kTaskPriorities.map((p) {
              final selected = _priority == p;
              return ChoiceChip(
                label: Text(kPriorityLabels[p]!),
                selected: selected,
                avatar: Icon(Icons.flag, size: 16, color: priorityColor(p)),
                onSelected: (_) => setState(() => _priority = p),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          _label('Due date'),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDueDate,
                  icon: const Icon(Icons.event),
                  label: Text(_dueDate != null ? Dates.dayLabel(_dueDate!) : 'No date'),
                ),
              ),
              if (_dueDate != null)
                IconButton(
                  onPressed: () => setState(() => _dueDate = null),
                  icon: const Icon(Icons.clear),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _label('Repeat'),
          DropdownButtonFormField<String?>(
            value: _recurrence,
            decoration: const InputDecoration(),
            items: [
              const DropdownMenuItem(value: null, child: Text('Does not repeat')),
              ...kRecurrenceFreqs.map((f) => DropdownMenuItem(value: f, child: Text(kRecurrenceLabels[f]!))),
            ],
            onChanged: (v) => setState(() => _recurrence = v),
          ),
          const SizedBox(height: 20),
          _label('List'),
          DropdownButtonFormField<String?>(
            // Guard against a stale/deleted list id (e.g. the list was removed, or
            // `lists` hasn't loaded yet): DropdownButton asserts the value matches
            // exactly one item, so fall back to Inbox (null) when it's absent.
            value: lists.any((l) => l.id == _listId) ? _listId : null,
            decoration: const InputDecoration(),
            items: [
              const DropdownMenuItem(value: null, child: Text('Inbox')),
              ...lists.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))),
            ],
            onChanged: (v) => setState(() => _listId = v),
          ),
          const SizedBox(height: 20),
          _label('Goal'),
          DropdownButtonFormField<String?>(
            // Guard against a goal id that's absent from the active-goals list
            // (e.g. the linked goal was archived), which would trip the dropdown's
            // single-matching-item assertion. Fall back to "None".
            value: goals.any((g) => g.id == _goalId) ? _goalId : null,
            decoration: const InputDecoration(),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              ...goals.map((g) => DropdownMenuItem(value: g.id, child: Text('${g.icon} ${g.title}'))),
            ],
            onChanged: (v) => setState(() => _goalId = v),
          ),
          const SizedBox(height: 20),
          _label('Tags'),
          if (_tags.isNotEmpty)
            Wrap(
              spacing: 8,
              children: _tags
                  .map((t) => Chip(
                        label: Text(t),
                        onDeleted: () => setState(() => _tags.remove(t)),
                      ))
                  .toList(),
            ),
          TextField(
            controller: _tagInput,
            decoration: InputDecoration(
              hintText: 'Add a tag',
              suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () => _addTag(_tagInput.text)),
            ),
            onSubmitted: _addTag,
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: suggestions
                  .map((t) => ActionChip(label: Text(t.name), onPressed: () => _addTag(t.name)))
                  .toList(),
            ),
          ],
          const SizedBox(height: 20),
          _label('Reminders'),
          ..._reminders.asMap().entries.map((e) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.notifications_none),
                title: Text(Dates.dateTimeLabel(e.value)),
                trailing: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _reminders.removeAt(e.key)),
                ),
              )),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addReminder,
              icon: const Icon(Icons.add_alarm),
              label: const Text('Add reminder'),
            ),
          ),
          if (_isEdit) ...[
            const SizedBox(height: 24),
            _SubtasksSection(parent: widget.task!),
          ],
        ],
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 8 + MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom),
        child: FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_isEdit ? 'Save changes' : 'Create task'),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}

/// Subtask checklist shown inside the editor (edit mode only).
class _SubtasksSection extends ConsumerStatefulWidget {
  const _SubtasksSection({required this.parent});
  final Task parent;

  @override
  ConsumerState<_SubtasksSection> createState() => _SubtasksSectionState();
}

class _SubtasksSectionState extends ConsumerState<_SubtasksSection> {
  final _input = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final title = _input.text.trim();
    if (title.isEmpty) return;
    setState(() => _busy = true);
    try {
      final outcome = await ref.read(tasksControllerProvider.notifier).create({
        'title': title,
        'parentTaskId': widget.parent.id,
        if (widget.parent.listId != null) 'listId': widget.parent.listId,
      });
      if (outcome == SubmitOutcome.deferred && mounted) showOfflineSaved(context);
      _input.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(Task sub) async {
    final ctrl = ref.read(tasksControllerProvider.notifier);
    try {
      if (sub.isCompleted) {
        await ctrl.update(sub.id, {'status': 'todo'});
      } else {
        await ctrl.complete(sub.id);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subs = ref.watch(subtasksByParentProvider)[widget.parent.id] ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Subtasks', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        ...subs.map((s) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: IconButton(
                icon: Icon(s.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked),
                color: s.isCompleted ? Theme.of(context).colorScheme.primary : null,
                onPressed: () => _toggle(s),
              ),
              title: Text(
                s.title,
                style: TextStyle(
                  decoration: s.isCompleted ? TextDecoration.lineThrough : null,
                ),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => ref.read(tasksControllerProvider.notifier).delete(s.id),
              ),
            )),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                decoration: const InputDecoration(hintText: 'Add a subtask', isDense: true),
                onSubmitted: (_) => _add(),
              ),
            ),
            IconButton(onPressed: _busy ? null : _add, icon: const Icon(Icons.add)),
          ],
        ),
      ],
    );
  }
}
