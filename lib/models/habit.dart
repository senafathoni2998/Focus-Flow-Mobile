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
}
