import '../core/json.dart';

/// Dashboard summary (from GET /analytics).
class DashboardSummary {
  DashboardSummary({
    required this.total,
    required this.byStatus,
    required this.overdue,
    required this.dueToday,
    required this.completedToday,
    required this.completedThisWeek,
    required this.focusMinutesThisWeek,
    required this.activeGoals,
    required this.habitCount,
  });

  final int total;
  final Map<String, int> byStatus;
  final int overdue;
  final int dueToday;
  final int completedToday;
  final int completedThisWeek;
  final int focusMinutesThisWeek;
  final int activeGoals;
  final int habitCount;

  int statusCount(String s) => byStatus[s] ?? 0;

  /// Work still open — everything not closed as completed or wont-do.
  ///
  /// `total` is the ALL-TIME task count, so pairing it with a 7-day numerator
  /// produces a ratio that shrinks forever as the archive grows. This is the
  /// comparable denominator for "how much of what's on my plate did I finish".
  int get openTasks => statusCount('todo') + statusCount('in-progress');

  factory DashboardSummary.fromJson(Map<String, dynamic> j) {
    final tasks = asMap(j['tasks']);
    final bs = asMap(tasks['byStatus']);
    return DashboardSummary(
      total: asInt(tasks['total']),
      byStatus: bs.map((k, v) => MapEntry(k, asInt(v))),
      overdue: asInt(tasks['overdue']),
      dueToday: asInt(tasks['dueToday']),
      completedToday: asInt(tasks['completedToday']),
      completedThisWeek: asInt(tasks['completedThisWeek']),
      focusMinutesThisWeek: asInt(j['focusMinutesThisWeek']),
      activeGoals: asInt(j['activeGoals']),
      habitCount: asInt(j['habitCount']),
    );
  }
}
