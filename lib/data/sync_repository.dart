import '../core/api_client.dart';
import '../core/json.dart';

/// One delta from `GET /api/v1/sync`.
///
/// Every collection here arrives in the SAME shape its list endpoint returns —
/// that is what makes merging it into what the controllers already hold safe.
/// It was not always true: the endpoint used to emit raw database rows, which
/// blanked a task's actualMin, shifted its all-day date by a timezone, zeroed a
/// habit's streak and showed every goal at 0%.
class SyncDelta {
  const SyncDelta({
    required this.serverTime,
    required this.full,
    required this.tasks,
    required this.lists,
    required this.tags,
    required this.deleted,
  });

  /// The cursor to send next time. A SERVER clock, never the device's — a phone
  /// running a few minutes fast would otherwise skip every change in that
  /// window, permanently and with no error to show for it.
  final String serverTime;

  /// True when there was no cursor: replace rather than merge.
  final bool full;

  final List<Map<String, dynamic>> tasks;
  final List<Map<String, dynamic>> lists;
  final List<Map<String, dynamic>> tags;

  /// `(entityType, entityId)` pairs from the server's tombstones — the only way
  /// a delta can tell a client that something is gone, since a deleted row
  /// simply stops appearing.
  final List<({String type, String id})> deleted;

  static SyncDelta fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> changed = asMap(j['changed']);
    final List<({String type, String id})> deleted = <({String type, String id})>[];
    for (final Map<String, dynamic> d in asMapList(j['deleted'])) {
      final String type = asString(d['entityType']);
      final String id = asString(d['entityId']);
      if (type.isNotEmpty && id.isNotEmpty) deleted.add((type: type, id: id));
    }
    return SyncDelta(
      serverTime: asString(j['serverTime']),
      full: asBool(j['full']),
      tasks: asMapList(changed['tasks']),
      lists: asMapList(changed['lists']),
      tags: asMapList(changed['tags']),
      deleted: deleted,
    );
  }
}

class SyncRepository {
  SyncRepository(this._api);
  final ApiClient _api;

  /// Pass null on a first sync to get everything.
  Future<SyncDelta> since(String? cursor) async {
    final data = await _api.getJson(
      '/sync',
      query: cursor == null ? null : <String, dynamic>{'since': cursor},
    );
    return SyncDelta.fromJson(asMap(data));
  }
}
