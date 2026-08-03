import '../core/api_client.dart';
import '../core/json.dart';
import '../models/saved_filter.dart';

class SavedFilterRepository {
  SavedFilterRepository(this._api);
  final ApiClient _api;

  Future<List<SavedFilter>> list() async {
    final data = await _api.getJson('/saved-filters');
    return asMapList(asMap(data)['savedFilters']).map(SavedFilter.fromJson).toList();
  }

  Future<SavedFilter> create({required String name, required String query}) async {
    final data = await _api.postJson('/saved-filters', body: {'name': name, 'query': query});
    return SavedFilter.fromJson(asMap(asMap(data)['savedFilter']));
  }

  Future<void> delete(String id) async {
    await _api.deleteJson('/saved-filters/$id');
  }
}
