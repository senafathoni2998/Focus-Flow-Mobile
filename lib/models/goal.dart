import '../core/date_format.dart';
import '../core/json.dart';

/// Server-computed goal progress (from `goalStats.ts`).
class GoalProgress {
  GoalProgress({
    required this.percent,
    required this.isAchieved,
    this.daysRemaining,
    required this.isOverdue,
  });

  final int percent; // 0-100
  final bool isAchieved;
  final int? daysRemaining;
  final bool isOverdue;

  factory GoalProgress.fromJson(Map<String, dynamic> j) => GoalProgress(
        percent: asInt(j['percent']),
        isAchieved: asBool(j['isAchieved']),
        daysRemaining: j['daysRemaining'] == null ? null : asInt(j['daysRemaining']),
        isOverdue: asBool(j['isOverdue']),
      );

  static GoalProgress empty() =>
      GoalProgress(percent: 0, isAchieved: false, daysRemaining: null, isOverdue: false);
}

class Goal {
  Goal({
    required this.id,
    required this.title,
    this.description,
    required this.icon,
    required this.color,
    required this.progressType,
    this.targetValue,
    required this.currentValue,
    this.unit,
    required this.manualProgress,
    this.targetDate,
    required this.status,
    this.order,
    this.taskTotal,
    this.taskCompleted,
    required this.progress,
  });

  final String id;
  final String title;
  final String? description;
  final String icon;
  final String color;
  final String progressType; // manual | numeric | tasks
  final double? targetValue;
  final double currentValue;
  final String? unit;
  final int manualProgress;
  final DateTime? targetDate;
  final String status; // active | achieved | archived
  final int? order;
  final int? taskTotal;
  final int? taskCompleted;
  final GoalProgress progress;

  bool get isNumeric => progressType == 'numeric';
  bool get isManual => progressType == 'manual';
  bool get isTasks => progressType == 'tasks';

  factory Goal.fromJson(Map<String, dynamic> j) => Goal(
        id: asString(j['id']),
        title: asString(j['title']),
        description: asStringOrNull(j['description']),
        icon: asString(j['icon'], '🎯'),
        color: asString(j['color'], 'primary'),
        progressType: asString(j['progressType'], 'manual'),
        targetValue: asDoubleOrNull(j['targetValue']),
        currentValue: asDouble(j['currentValue']),
        unit: asStringOrNull(j['unit']),
        manualProgress: asInt(j['manualProgress']),
        targetDate: Dates.parse(j['targetDate']),
        status: asString(j['status'], 'active'),
        order: j['order'] == null ? null : asInt(j['order']),
        taskTotal: j['taskTotal'] == null ? null : asInt(j['taskTotal']),
        taskCompleted: j['taskCompleted'] == null ? null : asInt(j['taskCompleted']),
        progress: j['progress'] is Map ? GoalProgress.fromJson(asMap(j['progress'])) : GoalProgress.empty(),
      );
}
