import '../core/api_client.dart';
import '../core/json.dart';
import '../models/task.dart';

class TaskRepository {
  TaskRepository(this._api);
  final ApiClient _api;

  Future<List<Task>> list() async {
    final data = await _api.getJson('/tasks');
    return asMapList(asMap(data)['tasks']).map(Task.fromJson).toList();
  }

  Future<Task> create(Map<String, dynamic> body) async {
    final data = await _api.postJson('/tasks', body: body);
    return Task.fromJson(asMap(asMap(data)['task']));
  }

  Future<Task> update(String id, Map<String, dynamic> body) async {
    final data = await _api.patchJson('/tasks/$id', body: body);
    return Task.fromJson(asMap(asMap(data)['task']));
  }

  /// Returns the task after completion; `recurred` is true when a recurring task
  /// rolled forward instead of completing.
  Future<({Task task, bool recurred})> complete(String id) async {
    final data = asMap(await _api.postJson('/tasks/$id/complete'));
    return (task: Task.fromJson(asMap(data['task'])), recurred: asBool(data['recurred']));
  }

  Future<void> delete(String id) async {
    await _api.deleteJson('/tasks/$id');
  }

  Future<Task> reorder({required String id, required String newStatus, required int newOrder}) async {
    final data = await _api.postJson('/tasks/reorder',
        body: {'id': id, 'newStatus': newStatus, 'newOrder': newOrder});
    return Task.fromJson(asMap(asMap(data)['task']));
  }
}
