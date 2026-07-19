import '../core/api_client.dart';
import '../core/json.dart';
import '../models/reminder.dart';

class ReminderRepository {
  ReminderRepository(this._api);
  final ApiClient _api;

  Future<List<DueReminder>> due() async {
    final data = await _api.getJson('/reminders/due');
    return asMapList(asMap(data)['reminders']).map(DueReminder.fromJson).toList();
  }

  Future<void> dispatch(List<String> ids) async {
    if (ids.isEmpty) return;
    await _api.postJson('/reminders/dispatch', body: {'ids': ids});
  }
}
