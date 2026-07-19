import '../core/date_format.dart';
import '../core/json.dart';

/// A fired-but-undispatched reminder (from GET /reminders/due).
class DueReminder {
  DueReminder({
    required this.id,
    required this.triggerAt,
    required this.taskId,
    required this.taskTitle,
  });

  final String id;
  final DateTime triggerAt;
  final String taskId;
  final String taskTitle;

  factory DueReminder.fromJson(Map<String, dynamic> j) {
    final task = asMap(j['task']);
    return DueReminder(
      id: asString(j['id']),
      triggerAt: Dates.parse(j['triggerAt']) ?? DateTime.now(),
      taskId: asString(task['id']),
      taskTitle: asString(task['title']),
    );
  }
}
