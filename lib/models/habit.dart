import '../core/date_format.dart';
import '../core/json.dart';

class HabitCheckIn {
  HabitCheckIn({required this.id, required this.date, required this.amount});
  final String id;
  final DateTime date;
  final double amount;

  factory HabitCheckIn.fromJson(Map<String, dynamic> j) => HabitCheckIn(
        id: asString(j['id']),
        date: Dates.parse(j['date']) ?? DateTime.now(),
        amount: asDouble(j['amount'], 1),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        // Local, because that is what Dates.parse hands back — the two have to
        // agree or a round trip through the overlay would drift.
        'date': date.toIso8601String(),
        'amount': amount,
      };
}

/// Server-computed habit statistics (from `habitStats.ts`).
class HabitStats {
  HabitStats({
    required this.currentStreak,
    required this.bestStreak,
    required this.totalDays,
    required this.monthlyRate,
    required this.todayDone,
    required this.todayAmount,
    required this.streakUnit,
    required this.weeklyProgress,
  });

  final int currentStreak;
  final int bestStreak;
  final int totalDays;
  final int monthlyRate; // 0-100
  final bool todayDone;
  final double todayAmount;
  final String streakUnit; // "day" | "week"
  final int weeklyProgress;

  factory HabitStats.fromJson(Map<String, dynamic> j) => HabitStats(
        currentStreak: asInt(j['currentStreak']),
        bestStreak: asInt(j['bestStreak']),
        totalDays: asInt(j['totalDays']),
        monthlyRate: asInt(j['monthlyRate']),
        todayDone: asBool(j['todayDone']),
        todayAmount: asDouble(j['todayAmount']),
        streakUnit: asString(j['streakUnit'], 'day'),
        weeklyProgress: asInt(j['weeklyProgress']),
      );

  static HabitStats empty() => HabitStats(
        currentStreak: 0,
        bestStreak: 0,
        totalDays: 0,
        monthlyRate: 0,
        todayDone: false,
        todayAmount: 0,
        streakUnit: 'day',
        weeklyProgress: 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'currentStreak': currentStreak,
        'bestStreak': bestStreak,
        'totalDays': totalDays,
        'monthlyRate': monthlyRate,
        'todayDone': todayDone,
        'todayAmount': todayAmount,
        'streakUnit': streakUnit,
        'weeklyProgress': weeklyProgress,
      };
}

class Habit {
  Habit({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    required this.frequencyType,
    required this.weekdays,
    required this.weeklyTarget,
    required this.goalType,
    this.targetAmount,
    this.unit,
    this.archived = false,
    this.order,
    required this.stats,
    this.checkIns = const [],
  });

  final String id;
  final String name;
  final String icon;
  final String color;
  final String frequencyType; // daily | weekly
  final List<int> weekdays;
  final int weeklyTarget;
  final String goalType; // achieve | amount
  final double? targetAmount;
  final String? unit;
  final bool archived;
  final int? order;
  final HabitStats stats;
  final List<HabitCheckIn> checkIns;

  bool get isAmount => goalType == 'amount';

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: asString(j['id']),
        name: asString(j['name']),
        icon: asString(j['icon'], '✅'),
        color: asString(j['color'], 'primary'),
        frequencyType: asString(j['frequencyType'], 'daily'),
        weekdays: asIntList(j['weekdays']),
        weeklyTarget: asInt(j['weeklyTarget'], 1),
        goalType: asString(j['goalType'], 'achieve'),
        targetAmount: asDoubleOrNull(j['targetAmount']),
        unit: asStringOrNull(j['unit']),
        archived: asBool(j['archived']),
        order: j['order'] == null ? null : asInt(j['order']),
        stats: j['stats'] is Map ? HabitStats.fromJson(asMap(j['stats'])) : HabitStats.empty(),
        checkIns: asMapList(j['checkIns']).map(HabitCheckIn.fromJson).toList(),
      );

  /// The inverse of [Habit.fromJson], for the offline overlay — which folds
  /// pending writes in JSON space so a PATCH body can be applied with the
  /// server's own key-presence semantics.
  ///
  /// `stats` is emitted even though it is entirely server-derived, and that is
  /// the whole reason this method needs care: [Habit.fromJson] substitutes
  /// [HabitStats.empty] when `stats` is absent, so dropping it here would blank
  /// every streak and month-rate to zero the moment ANY habit write was pending.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'icon': icon,
        'color': color,
        'frequencyType': frequencyType,
        'weekdays': weekdays,
        'weeklyTarget': weeklyTarget,
        'goalType': goalType,
        'targetAmount': targetAmount,
        'unit': unit,
        'archived': archived,
        'order': order,
        'stats': stats.toJson(),
        // Always empty in practice — every habit endpoint computes `stats` from
        // the check-ins and then strips them, because the client has no reader
        // for up to 1200 rows per habit. Emitted anyway so this stays a true
        // inverse rather than one that happens to work.
        'checkIns': checkIns.map((HabitCheckIn c) => c.toJson()).toList(),
      };
}
