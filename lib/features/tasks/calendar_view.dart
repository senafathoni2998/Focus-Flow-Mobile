import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/task.dart';
import '../../providers/filter_provider.dart';
import 'task_card.dart';

/// Month grid keyed by due date, ported from the web `TaskCalendarView`.
///
/// Undated tasks are simply absent — a calendar cannot place them, and inventing
/// a slot ("today", "unscheduled" row) would misrepresent them. The drawer's
/// "No Date" smart list is where those live.
String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, List<Task>> groupByDueDay(List<Task> tasks) {
  final out = <String, List<Task>>{};
  for (final t in tasks) {
    final due = t.dueDate;
    if (due == null) continue;
    (out[_ymd(due)] ??= []).add(t);
  }
  return out;
}

class CalendarView extends ConsumerStatefulWidget {
  const CalendarView({super.key, required this.onTap, required this.onToggle});
  final void Function(Task) onTap;
  final void Function(Task) onToggle;

  @override
  ConsumerState<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends ConsumerState<CalendarView> {
  late DateTime _month;
  DateTime? _selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _selected = DateTime(now.year, now.month, now.day);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      // Keep a selection inside the visible month so the list below always
      // corresponds to something on the grid.
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final byDay = groupByDueDay(ref.watch(visibleTasksProvider));

    final firstOfMonth = DateTime(_month.year, _month.month);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    // Dart's weekday is 1=Mon..7=Sun; the grid starts on Sunday like the web.
    final leading = firstOfMonth.weekday % 7;
    final today = DateTime.now();
    final todayKey = _ymd(today);

    final cells = <DateTime?>[
      ...List.filled(leading, null),
      for (var d = 1; d <= daysInMonth; d++) DateTime(_month.year, _month.month, d),
    ];

    final selectedTasks =
        _selected == null ? const <Task>[] : (byDay[_ymd(_selected!)] ?? const <Task>[]);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => _shiftMonth(-1),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous month',
            ),
            Expanded(
              child: Text(
                '${_monthName(_month.month)} ${_month.year}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
            IconButton(
              onPressed: () => _shiftMonth(1),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next month',
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final d in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
              Expanded(
                child: Center(
                  child: Text(d,
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: [
            for (final day in cells)
              if (day == null)
                const SizedBox.shrink()
              else
                _DayCell(
                  day: day,
                  count: (byDay[_ymd(day)] ?? const []).length,
                  isToday: _ymd(day) == todayKey,
                  isSelected: _selected != null && _ymd(day) == _ymd(_selected!),
                  onTap: () => setState(() => _selected = day),
                ),
          ],
        ),
        const SizedBox(height: 16),
        if (_selected == null)
          Text('Pick a day to see its tasks.',
              style: TextStyle(color: scheme.outline))
        else ...[
          Text(
            '${_selected!.day} ${_monthName(_selected!.month)}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (selectedTasks.isEmpty)
            Text('Nothing due this day.', style: TextStyle(color: scheme.outline))
          else
            for (final t in selectedTasks) ...[
              TaskCard(
                task: t,
                onTap: () => widget.onTap(t),
                onToggle: () => widget.onToggle(t),
              ),
              const SizedBox(height: 8),
            ],
        ],
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.count,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  final DateTime day;
  final int count;
  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          border: isToday ? Border.all(color: scheme.primary, width: 1.5) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 2),
            // A dot with a count rather than the titles: at seven columns wide
            // there is no room for text that would actually be readable.
            if (count > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('$count',
                    style: TextStyle(fontSize: 10, color: scheme.onPrimary)),
              )
            else
              const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }
}

String _monthName(int m) => const [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ][m - 1];
