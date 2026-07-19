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
