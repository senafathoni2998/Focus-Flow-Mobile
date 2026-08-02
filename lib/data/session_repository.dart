import '../core/api_client.dart';
import '../core/json.dart';
import '../models/focus_session.dart';

class SessionRepository {
  SessionRepository(this._api);
  final ApiClient _api;

  Future<List<FocusSession>> list({int days = 30}) async {
    final data = await _api.getJson('/sessions', query: {'days': days});
    return asMapList(asMap(data)['sessions']).map(FocusSession.fromJson).toList();
  }

  /// `duration` is in SECONDS — the server validates it as a positive int no
  /// greater than 24h, matching startSchema in sessionService.
  Future<FocusSession> start({
    String? taskId,
    String type = 'pomodoro',
    required int duration,
  }) async {
    final data = await _api.postJson('/sessions', body: {
      if (taskId != null) 'taskId': taskId,
      'type': type,
      'duration': duration,
    });
    return FocusSession.fromJson(asMap(asMap(data)['session']));
  }

  Future<FocusSession> complete(String id) async {
    final data = await _api.postJson('/sessions/$id/complete');
    return FocusSession.fromJson(asMap(asMap(data)['session']));
  }

  Future<void> cancel(String id) async {
    await _api.postJson('/sessions/$id/cancel');
  }
}
