import '../core/api_client.dart';
import '../core/json.dart';
import '../models/task_list.dart';

class ListRepository {
  ListRepository(this._api);
  final ApiClient _api;

  Future<List<TaskList>> list() async {
    final data = await _api.getJson('/lists');
    return asMapList(asMap(data)['lists']).map(TaskList.fromJson).toList();
  }

  Future<TaskList> create(String name, {String? color}) async {
    final data = await _api.postJson('/lists', body: {'name': name, if (color != null) 'color': color});
    return TaskList.fromJson(asMap(asMap(data)['list']));
  }

  Future<TaskList> update(String id, {String? name, String? color}) async {
    final data = await _api.patchJson('/lists/$id', body: {
      if (name != null) 'name': name,
      if (color != null) 'color': color,
    });
    return TaskList.fromJson(asMap(asMap(data)['list']));
  }

  Future<void> delete(String id) async {
    await _api.deleteJson('/lists/$id');
  }
}
