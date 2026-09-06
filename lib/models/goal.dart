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

  Map<String, dynamic> toJson() => <String, dynamic>{
        'percent': percent,
        'isAchieved': isAchieved,
        'daysRemaining': daysRemaining,
        'isOverdue': isOverdue,
      };
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
        // Goal deadlines are stored at UTC-midnight; key by UTC calendar day so
        // the date doesn't shift across timezones.
        targetDate: Dates.parseUtcDay(j['targetDate']),
        status: asString(j['status'], 'active'),
        order: j['order'] == null ? null : asInt(j['order']),
        taskTotal: j['taskTotal'] == null ? null : asInt(j['taskTotal']),
        taskCompleted: j['taskCompleted'] == null ? null : asInt(j['taskCompleted']),
        progress: j['progress'] is Map ? GoalProgress.fromJson(asMap(j['progress'])) : GoalProgress.empty(),
      );

  /// The inverse of [Goal.fromJson], for the offline overlay — which folds
  /// pending writes in JSON space so a PATCH body can be applied with the
  /// server's own key-presence semantics.
  ///
  /// `progress`, `taskTotal` and `taskCompleted` are emitted even though they
  /// are server-derived: [Goal.fromJson] substitutes GoalProgress.empty() when
  /// `progress` is missing, so dropping them here would show every overlaid goal
  /// at 0% the moment any edit was pending.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'description': description,
        'icon': icon,
        'color': color,
        'progressType': progressType,
        'targetValue': targetValue,
        'currentValue': currentValue,
        'unit': unit,
        'manualProgress': manualProgress,
        // Emitted as a UTC-MIDNIGHT INSTANT, which is what the server sends and
        // therefore what fromJson's parseUtcDay is built to read back.
        //
        // NOT `Dates.ymd(...)`. parseUtcDay is not the inverse of ymd: a bare
        // yyyy-MM-dd parses as LOCAL midnight and is then converted to UTC, so
        // east of UTC it lands on the previous calendar day. The editor still
        // SENDS ymd, because that is what the write path expects — the two
        // directions genuinely use different shapes.
        'targetDate': targetDate == null
            ? null
            : DateTime.utc(targetDate!.year, targetDate!.month, targetDate!.day)
                .toIso8601String(),
        'status': status,
        'order': order,
        'taskTotal': taskTotal,
        'taskCompleted': taskCompleted,
        'progress': progress.toJson(),
      };
}
