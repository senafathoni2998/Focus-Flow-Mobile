import 'package:flutter/material.dart';

import 'constants.dart';

/// Date-horizon smart lists, ported from the web app's `dateHorizon.ts`.
///
/// Each horizon resolves to a half-open `[start, end)` range over a task's due
/// date, with two TickTick-style special cases:
///  - `overdue` = due before today AND still open (non-terminal),
///  - `today`   = due today, PLUS open overdue tasks folded in.
class Horizon {
  const Horizon(this.key, this.label, this.icon);
  final String key;
  final String label;
  final IconData icon;
}

const List<Horizon> kHorizons = [
  Horizon('all', 'All Tasks', Icons.all_inbox_outlined),
  Horizon('today', 'Today', Icons.today_outlined),
  Horizon('overdue', 'Overdue', Icons.warning_amber_outlined),
  Horizon('tomorrow', 'Tomorrow', Icons.wb_sunny_outlined),
  Horizon('next7', 'Next 7 Days', Icons.date_range_outlined),
  Horizon('thisMonth', 'This Month', Icons.calendar_month_outlined),
  Horizon('nextMonth', 'Next Month', Icons.calendar_month),
  Horizon('thisYear', 'This Year', Icons.event_note_outlined),
  Horizon('nextYear', 'Next Year', Icons.event_note),
  Horizon('noDate', 'No Date', Icons.event_busy_outlined),
];

DateTime _addMonths(DateTime d, int n) {
  final total = d.month - 1 + n;
  final y = d.year + (total ~/ 12);
  final m = total % 12;
  return DateTime(y, m + 1, d.day);
}

/// Whether a task with [due] (local) and [status] falls in [horizon] at [now].
bool matchesHorizon(String horizon, DateTime? due, String status, DateTime now) {
  final sod = DateTime(now.year, now.month, now.day);
  final open = !isTerminalStatus(status);

  bool inRange(DateTime start, DateTime end) =>
      due != null && !due.isBefore(start) && due.isBefore(end);

  switch (horizon) {
    case 'all':
      return true;
    case 'noDate':
      return due == null;
    case 'overdue':
      return due != null && due.isBefore(sod) && open;
    case 'today':
      final inToday = inRange(sod, sod.add(const Duration(days: 1)));
      final foldedOverdue = due != null && due.isBefore(sod) && open;
      return inToday || foldedOverdue;
    case 'tomorrow':
      return inRange(sod.add(const Duration(days: 1)), sod.add(const Duration(days: 2)));
    case 'next7':
      return inRange(sod, sod.add(const Duration(days: 7)));
    case 'thisMonth':
      final start = DateTime(now.year, now.month, 1);
      return inRange(start, _addMonths(start, 1));
    case 'nextMonth':
      final start = _addMonths(DateTime(now.year, now.month, 1), 1);
      return inRange(start, _addMonths(start, 1));
    case 'thisYear':
      return inRange(DateTime(now.year, 1, 1), DateTime(now.year + 1, 1, 1));
    case 'nextYear':
      return inRange(DateTime(now.year + 1, 1, 1), DateTime(now.year + 2, 1, 1));
    default:
      return true;
  }
}

const Map<String, String> kSortOptions = {
  'default': 'Default',
  'dueDate': 'Due date',
  'priority': 'Priority',
  'title': 'Title',
  'created': 'Created',
};
