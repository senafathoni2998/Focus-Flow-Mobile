import '../core/json.dart';

/// A focus (pomodoro) session row.
///
/// `duration` is the PLANNED length in seconds; the measured length is
/// `endTime - startTime`, which is what every focus metric on the server is
/// derived from. The server clamps `endTime` to `startTime + duration`, so a
/// phone that sleeps mid-timer cannot record a multi-hour "pomodoro".
class FocusSession {
  const FocusSession({
    required this.id,
    required this.type,
    required this.duration,
    required this.status,
    required this.startTime,
    this.endTime,
    this.taskId,
    this.taskTitle,
  });

  final String id;
  final String type; // pomodoro | short-break | long-break
  final int duration; // planned, seconds
  final String status; // running | completed | cancelled
  final DateTime startTime;
  final DateTime? endTime;
  final String? taskId;
  final String? taskTitle;

  bool get isRunning => status == 'running';

  /// Measured length, or null while still running.
  Duration? get elapsed => endTime?.difference(startTime);

  static DateTime _parseInstant(dynamic v) =>
      DateTime.tryParse(asString(v))?.toLocal() ?? DateTime.now();

  factory FocusSession.fromJson(Map<String, dynamic> j) {
    final task = j['task'];
    return FocusSession(
      id: asString(j['id']),
      type: asString(j['type'], 'pomodoro'),
      duration: asInt(j['duration']),
      status: asString(j['status'], 'running'),
      startTime: _parseInstant(j['startTime']),
      endTime: j['endTime'] == null ? null : _parseInstant(j['endTime']),
      taskId: asStringOrNull(j['taskId']),
      taskTitle: task is Map ? asStringOrNull(task['title']) : null,
    );
  }
}
