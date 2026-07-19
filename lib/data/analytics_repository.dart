import '../core/api_client.dart';
import '../core/json.dart';
import '../models/dashboard.dart';

class AnalyticsRepository {
  AnalyticsRepository(this._api);
  final ApiClient _api;

  Future<DashboardSummary> dashboard() async {
    final data = await _api.getJson('/analytics');
    return DashboardSummary.fromJson(asMap(data));
  }
}
