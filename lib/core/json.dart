/// Defensive JSON coercion helpers — JSON numbers may arrive as int or double,
/// and optional fields may be absent or null, so parse tolerantly.
int asInt(dynamic v, [int d = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? d;
  return d;
}

double asDouble(dynamic v, [double d = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? d;
  return d;
}

double? asDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

bool asBool(dynamic v, [bool d = false]) => v is bool ? v : d;

String asString(dynamic v, [String d = '']) => v?.toString() ?? d;

String? asStringOrNull(dynamic v) => v?.toString();

List<int> asIntList(dynamic v) =>
    v is List ? v.map((e) => asInt(e)).toList() : <int>[];

List<Map<String, dynamic>> asMapList(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
    : <Map<String, dynamic>>[];

Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
