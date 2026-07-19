import '../core/api_client.dart';
import '../core/json.dart';
import '../models/habit.dart';

class HabitRepository {
  HabitRepository(this._api);
  final ApiClient _api;

  Future<List<Habit>> list() async {
    final data = await _api.getJson('/habits');
    return asMapList(asMap(data)['habits']).map(Habit.fromJson).toList();
  }

  Future<Habit> create(Map<String, dynamic> body) async {
    final data = await _api.postJson('/habits', body: body);
    return Habit.fromJson(asMap(asMap(data)['habit']));
  }

  Future<Habit> update(String id, Map<String, dynamic> body) async {
    final data = await _api.patchJson('/habits/$id', body: body);
    return Habit.fromJson(asMap(asMap(data)['habit']));
  }

  Future<void> delete(String id) async {
    await _api.deleteJson('/habits/$id');
  }

  Future<void> archive(String id, bool archived) async {
    await _api.postJson('/habits/$id/archive', body: {'archived': archived});
  }

  /// Adjust a check-in by [delta] (default +1) for [date] (defaults to today).
  /// Returns the habit with recomputed stats.
  Future<Habit> checkIn(String id, {int delta = 1, String? date}) async {
    final data = await _api.postJson('/habits/$id/checkin', body: {
      'delta': delta,
      if (date != null) 'date': date,
    });
    return Habit.fromJson(asMap(asMap(data)['habit']));
  }
}
