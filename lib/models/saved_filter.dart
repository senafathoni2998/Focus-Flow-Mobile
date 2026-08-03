import '../core/json.dart';

/// A named view: the canonical URL query string the web uses for its saved views.
///
/// The query is kept as an opaque string rather than parsed into fields on the
/// wire, because it is the SAME string the web writes — the server canonicalises
/// it, so a view saved on either client is byte-identical to the same view saved
/// on the other. Two encodings of "the same filter" would drift the first time
/// one side gained an option.
class SavedFilter {
  const SavedFilter({
    required this.id,
    required this.name,
    required this.query,
    this.order = 0,
  });

  final String id;
  final String name;
  final String query;
  final int order;

  factory SavedFilter.fromJson(Map<String, dynamic> j) => SavedFilter(
        id: asString(j['id']),
        name: asString(j['name']),
        query: asString(j['query']),
        order: asInt(j['order']),
      );
}
