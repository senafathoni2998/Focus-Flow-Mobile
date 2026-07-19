import '../core/api_client.dart';
import '../core/json.dart';
import '../models/task.dart';

class TagRepository {
  TagRepository(this._api);
  final ApiClient _api;

  Future<List<Tag>> list() async {
    final data = await _api.getJson('/tags');
    return asMapList(asMap(data)['tags']).map(Tag.fromJson).toList();
  }

  Future<void> delete(String id) async {
    await _api.deleteJson('/tags/$id');
  }
}
