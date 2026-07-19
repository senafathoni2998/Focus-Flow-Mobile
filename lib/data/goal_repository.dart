import '../core/api_client.dart';
import '../core/json.dart';
import '../models/goal.dart';
import '../models/task.dart';

class GoalRepository {
  GoalRepository(this._api);
  final ApiClient _api;

  Future<List<Goal>> list() async {
    final data = await _api.getJson('/goals');
    return asMapList(asMap(data)['goals']).map(Goal.fromJson).toList();
  }

  Future<List<Goal>> archived() async {
    final data = await _api.getJson('/goals/archived');
    return asMapList(asMap(data)['goals']).map(Goal.fromJson).toList();
  }

  Future<Goal> create(Map<String, dynamic> body) async {
    final data = await _api.postJson('/goals', body: body);
    return Goal.fromJson(asMap(asMap(data)['goal']));
  }

  Future<Goal> update(String id, Map<String, dynamic> body) async {
    final data = await _api.patchJson('/goals/$id', body: body);
    return Goal.fromJson(asMap(asMap(data)['goal']));
  }

  Future<void> delete(String id) async {
    await _api.deleteJson('/goals/$id');
  }

  Future<void> adjustProgress(String id, num delta) async {
    await _api.postJson('/goals/$id/progress', body: {'delta': delta});
  }

  Future<void> setStatus(String id, String status) async {
    await _api.postJson('/goals/$id/status', body: {'status': status});
  }

  Future<List<Task>> tasks(String id) async {
    final data = await _api.getJson('/goals/$id/tasks');
    return asMapList(asMap(data)['tasks']).map(Task.fromJson).toList();
  }
}
