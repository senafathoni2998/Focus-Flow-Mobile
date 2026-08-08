import '../core/date_format.dart';
import '../core/json.dart';

class Tag {
  Tag({required this.id, required this.name, this.color});
  final String id;
  final String name;
  final String? color;

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
        id: asString(j['id']),
        name: asString(j['name']),
        color: asStringOrNull(j['color']),
      );

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'id': id, 'name': name, 'color': color};
}

class RecurrenceSummary {
  RecurrenceSummary({required this.freq, this.interval});
  final String freq;
  final int? interval;

  factory RecurrenceSummary.fromJson(Map<String, dynamic> j) => RecurrenceSummary(
        freq: asString(j['freq']),
        interval: j['interval'] == null ? null : asInt(j['interval']),
      );

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'freq': freq, 'interval': interval};
}

class ReminderSummary {
  ReminderSummary({required this.id, required this.triggerAt});
  final String id;
  final DateTime triggerAt;

  factory ReminderSummary.fromJson(Map<String, dynamic> j) => ReminderSummary(
        id: asString(j['id']),
        triggerAt: Dates.parse(j['triggerAt']) ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'triggerAt': Dates.utcIso(triggerAt),
      };
}

class Task {
  Task({
    required this.id,
    required this.title,
    this.description,
    required this.status,
    required this.priority,
    this.dueDate,
    this.startDate,
    this.isAllDay = true,
    this.completedAt,
    this.order,
    this.priorityRank,
    this.timeEstimateMin,
    this.estimatedPomos,
    this.actualMin = 0,
    this.parentTaskId,
    this.listId,
    this.goalId,
    this.tags = const [],
    this.recurrence,
    this.reminders = const [],
    this.updatedAt,
  });

  final String id;
  final String title;
  final String? description;
  final String status;
  final String priority;
  final DateTime? dueDate;
  final DateTime? startDate;
  final bool isAllDay;
  final DateTime? completedAt;
  final int? order;
  final int? priorityRank;
  final int? timeEstimateMin;
  final int? estimatedPomos;
  final int actualMin;
  final String? parentTaskId;
  final String? listId;
  final String? goalId;
  final List<Tag> tags;
  final RecurrenceSummary? recurrence;
  final List<ReminderSummary> reminders;

  /// When the server last wrote this row.
  ///
  /// Sent back with a QUEUED edit as `expectedUpdatedAt`, so the server can
  /// refuse one that was based on a version somebody else has since replaced.
  /// Online that race is about a second wide; a queued PATCH can sit for 14 days.
  final DateTime? updatedAt;

  bool get isCompleted => status == 'completed';
  bool get isTerminal => status == 'completed' || status == 'wont-do';
  bool get isSubtask => parentTaskId != null;
  bool get isRecurring => recurrence != null;

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: asString(j['id']),
        title: asString(j['title']),
        description: asStringOrNull(j['description']),
        status: asString(j['status'], 'todo'),
        priority: asString(j['priority'], 'medium'),
        dueDate: Dates.parse(j['dueDate']),
        startDate: Dates.parse(j['startDate']),
        isAllDay: asBool(j['isAllDay'], true),
        completedAt: Dates.parse(j['completedAt']),
        order: j['order'] == null ? null : asInt(j['order']),
        priorityRank: j['priorityRank'] == null ? null : asInt(j['priorityRank']),
        timeEstimateMin: j['timeEstimateMin'] == null ? null : asInt(j['timeEstimateMin']),
        estimatedPomos: j['estimatedPomos'] == null ? null : asInt(j['estimatedPomos']),
        actualMin: asInt(j['actualMin']),
        parentTaskId: asStringOrNull(j['parentTaskId']),
        listId: asStringOrNull(j['listId']),
        goalId: asStringOrNull(j['goalId']),
        tags: asMapList(j['tags']).map(Tag.fromJson).toList(),
        recurrence: j['recurrence'] is Map
            ? RecurrenceSummary.fromJson(asMap(j['recurrence']))
            : null,
        reminders: asMapList(j['reminders']).map(ReminderSummary.fromJson).toList(),
        updatedAt: Dates.parse(j['updatedAt']),
      );

  /// The inverse of [Task.fromJson], field for field.
  ///
  /// Exists for the offline write queue's overlay, which applies a PATCH body to
  /// a task by round-tripping it through JSON. That is done rather than with a
  /// 20-field `copyWith` because the wire shapes genuinely differ from the model
  /// — `body['tags']` is a list of NAMES where `Task.tags` is a list of [Tag],
  /// and `body['recurrence']` is a bare freq string where `Task.recurrence` is an
  /// object — so one explicit mapping is easier to verify than a `copyWith` with
  /// a null-clearing sentinel per field.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'description': description,
        'status': status,
        'priority': priority,
        'dueDate': dueDate?.toIso8601String(),
        'startDate': startDate?.toIso8601String(),
        'isAllDay': isAllDay,
        'completedAt': completedAt?.toIso8601String(),
        'order': order,
        'priorityRank': priorityRank,
        'timeEstimateMin': timeEstimateMin,
        'estimatedPomos': estimatedPomos,
        'actualMin': actualMin,
        'parentTaskId': parentTaskId,
        'listId': listId,
        'goalId': goalId,
        'tags': tags.map((Tag t) => t.toJson()).toList(),
        'recurrence': recurrence?.toJson(),
        'reminders': reminders.map((ReminderSummary r) => r.toJson()).toList(),
        'updatedAt': updatedAt?.toIso8601String(),
      };
}
