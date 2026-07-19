import 'package:intl/intl.dart';

/// Date helpers bridging the app's storage conventions and display.
///
/// - All-day due dates are sent to the API as bare `yyyy-MM-dd` (the calendar day
///   the user picked); the backend anchors them at its local midnight — the same
///   convention the web app uses.
/// - Reminders are absolute instants, sent as UTC ISO-8601 (`...Z`) so the server
///   resolves the exact moment regardless of its timezone.
class Dates {
  /// `yyyy-MM-dd` from a local date (for all-day due/start dates and check-ins).
  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// UTC ISO-8601 (with `Z`) — for reminder trigger instants.
  static String utcIso(DateTime d) => d.toUtc().toIso8601String();

  /// Parse a server ISO date string into a LOCAL DateTime (null-safe).
  static DateTime? parse(dynamic iso) {
    if (iso == null) return null;
    if (iso is DateTime) return iso.toLocal();
    final s = iso.toString();
    if (s.isEmpty) return null;
    final d = DateTime.tryParse(s);
    return d?.toLocal();
  }

  static DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  /// A friendly relative label for an all-day due date.
  static String relativeDay(DateTime due, DateTime now) {
    final sod = startOfDay(now);
    final d = startOfDay(due);
    final diff = d.difference(sod).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff == -1) return 'Yesterday';
    if (diff < 0) return DateFormat.MMMd().format(due); // overdue -> plain date
    if (diff < 7) return DateFormat.EEEE().format(due); // within a week -> weekday
    if (due.year == now.year) return DateFormat.MMMd().format(due);
    return DateFormat.yMMMd().format(due);
  }

  /// "Jul 20, 2:30 PM" — for a reminder instant.
  static String dateTimeLabel(DateTime d) => DateFormat('MMM d, h:mm a').format(d);

  /// "Jul 20" / "Jul 20, 2027" — a plain date.
  static String dayLabel(DateTime d, {int? contextYear}) {
    final y = contextYear ?? DateTime.now().year;
    return d.year == y ? DateFormat.MMMd().format(d) : DateFormat.yMMMd().format(d);
  }
}
