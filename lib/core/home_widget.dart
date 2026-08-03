import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/task.dart';

/// What the home-screen widget shows.
///
/// Deliberately tiny. The widget is redrawn by the launcher through RemoteViews
/// and must paint instantly from a stored snapshot, so this carries a count and
/// three titles — not a task list the widget would have to page through.
@immutable
class WidgetSnapshot {
  const WidgetSnapshot({required this.count, required this.titles, required this.updatedLabel});

  /// How many open tasks are due today or already overdue.
  final int count;

  /// The first few of them, for the body.
  final List<String> titles;

  /// When this snapshot was taken. Shown verbatim, because the widget is only
  /// ever as fresh as the last time the app had the data — implying it is live
  /// would be a lie the user cannot check.
  final String updatedLabel;

  String toJson() => jsonEncode({
        'count': count,
        'titles': titles,
        'updatedLabel': updatedLabel,
      });

  @override
  bool operator ==(Object other) =>
      other is WidgetSnapshot &&
      other.count == count &&
      other.updatedLabel == updatedLabel &&
      listEquals(other.titles, titles);

  @override
  int get hashCode => Object.hash(count, updatedLabel, Object.hashAll(titles));
}

/// Maximum titles the layout has room for.
const int kWidgetTitleSlots = 3;

/// Pick what the widget should say, from the full task list.
///
/// Pure and separately tested: this is the entire content of the widget, and it
/// has to agree with what the Today smart list shows — a widget that disagrees
/// with the app it belongs to is worse than no widget.
WidgetSnapshot buildWidgetSnapshot(List<Task> tasks, DateTime now) {
  final endOfToday = DateTime(now.year, now.month, now.day + 1);

  final due = tasks
      .where((t) =>
          // Subtasks surface inside their parent, never as their own row.
          t.parentTaskId == null &&
          !t.isTerminal &&
          t.dueDate != null &&
          t.dueDate!.isBefore(endOfToday))
      .toList()
    // Overdue first, then by due date — the same ordering the Today list uses.
    ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));

  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');

  return WidgetSnapshot(
    count: due.length,
    titles: due.take(kWidgetTitleSlots).map((t) => t.title).toList(),
    updatedLabel: 'Updated $hh:$mm',
  );
}

/// Pushes snapshots to the Android widget.
class HomeWidgetService {
  HomeWidgetService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('focusflow/widget');

  final MethodChannel _channel;
  WidgetSnapshot? _last;

  /// Send [snapshot] unless it is identical to the last one.
  ///
  /// Every task refresh would otherwise wake the launcher to redraw the same
  /// pixels; the timestamp is excluded from the comparison so a redraw only
  /// happens when the CONTENT changed.
  Future<void> push(WidgetSnapshot snapshot) async {
    final unchanged = _last != null &&
        _last!.count == snapshot.count &&
        listEquals(_last!.titles, snapshot.titles);
    if (unchanged) return;
    _last = snapshot;

    try {
      await _channel.invokeMethod<void>('updateWidget', snapshot.toJson());
    } on MissingPluginException {
      // No host side (tests, another platform) — the widget is an extra, not a
      // dependency of the app working.
    } catch (e) {
      debugPrint('[widget] update failed: $e');
    }
  }
}
