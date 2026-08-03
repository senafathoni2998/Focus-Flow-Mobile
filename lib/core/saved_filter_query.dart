import '../providers/filter_provider.dart';

/// Translate between the app's [TaskFilter] and the URL query string that a
/// saved view is stored as.
///
/// The stored form is the WEB's query string, because both clients read the same
/// rows. That means this is a lossy bridge in both directions and the mapping has
/// to be explicit about it:
///
///  - `q` (search) is deliberately NOT saved. On the web it is part of the URL,
///    but a saved view that also pins a search term is almost never what someone
///    means by "save this view", and restoring it would silently hide tasks.
///  - The web's `status` / `priority` multi-selects have no mobile equivalent
///    yet. They are preserved on round-trip only in the sense that mobile does
///    not rewrite a saved view it did not create — applying one just ignores the
///    keys it cannot honour, rather than pretending they were applied.
///  - `list=inbox` is the web's own encoding for "no list", so it maps straight
///    onto the mobile sentinel of the same name.
const _sortAliases = <String, String>{
  // Web sort keys -> mobile sort keys. `manual` is the web's default and is
  // simply the stored order, which is what mobile calls `default`.
  'manual': 'default',
  'due': 'due',
  'priority': 'priority',
  'title': 'title',
};

String _mobileSortToWeb(String sort) =>
    _sortAliases.entries.firstWhere((e) => e.value == sort, orElse: () => const MapEntry('manual', 'default')).key;

/// Build the canonical query string for [filter]. Keys are emitted in the same
/// order the server canonicalises to, so a view saved here matches one saved on
/// the web byte for byte.
String encodeFilter(TaskFilter filter) {
  final parts = <String, String>{};
  if (filter.horizon != 'all') parts['horizon'] = filter.horizon;
  if (filter.listId != null) parts['list'] = filter.listId!;
  if (filter.tagId != null) parts['tags'] = filter.tagId!;
  if (filter.sort != 'default') parts['sort'] = _mobileSortToWeb(filter.sort);

  final keys = parts.keys.toList()..sort();
  return keys.map((k) => '$k=${Uri.encodeQueryComponent(parts[k]!)}').join('&');
}

/// Apply a stored query on top of the CURRENT filter.
///
/// Keys the saved view does not mention are reset to their defaults, so applying
/// a view is idempotent — otherwise leftovers from the previous view would leak
/// in and the same saved view would show different tasks depending on what you
/// were looking at before.
TaskFilter decodeFilter(String query, {required TaskFilter base}) {
  final params = Uri.splitQueryString(query);

  final rawSort = params['sort'];
  return base.copyWith(
    horizon: params['horizon'] ?? 'all',
    listId: params['list'],
    tagId: params['tags']?.split(',').first,
    sort: rawSort == null ? 'default' : (_sortAliases[rawSort] ?? 'default'),
    // Search is never stored, so applying a view always clears it.
    search: '',
  );
}

/// True when [filter] is exactly what [query] describes — used to highlight the
/// saved view you are currently looking at.
bool filterMatchesQuery(TaskFilter filter, String query) =>
    encodeFilter(filter) == query;
