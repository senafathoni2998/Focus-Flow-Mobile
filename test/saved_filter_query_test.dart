import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/saved_filter_query.dart';
import 'package:focusflow_mobile/providers/filter_provider.dart';

/// A saved view is stored as the WEB's canonical query string, because both
/// clients read the same rows. This bridge is lossy on purpose, and these tests
/// pin which losses are intended — an undocumented one would silently change
/// which tasks a saved view shows.
void main() {
  group('encodeFilter', () {
    test('a default filter encodes to nothing at all', () {
      expect(encodeFilter(const TaskFilter()), '');
    });

    test('omits the search term', () {
      // A view that also pins a search would silently hide tasks when applied.
      expect(encodeFilter(const TaskFilter(search: 'report')), '');
    });

    test('emits keys in sorted order so both clients agree byte for byte', () {
      final q = encodeFilter(const TaskFilter(horizon: 'thisMonth', listId: 'l1', sort: 'priority'));
      expect(q, 'horizon=thisMonth&list=l1&sort=priority');
    });

    test("maps mobile's default sort onto the web's 'manual', and omits it", () {
      expect(encodeFilter(const TaskFilter(sort: 'default')), '');
      expect(encodeFilter(const TaskFilter(sort: 'due')), 'sort=due');
    });

    test('encodes values that need escaping', () {
      expect(encodeFilter(const TaskFilter(listId: 'a b&c')), 'list=a+b%26c');
    });
  });

  group('decodeFilter', () {
    test('round-trips everything it claims to store', () {
      const original = TaskFilter(horizon: 'next7', listId: 'l1', tagId: 'g1', sort: 'due');
      final restored = decodeFilter(encodeFilter(original), base: const TaskFilter());

      expect(restored.horizon, 'next7');
      expect(restored.listId, 'l1');
      expect(restored.tagId, 'g1');
      expect(restored.sort, 'due');
    });

    test('is idempotent: keys the view omits are reset, not inherited', () {
      // Applying a view while looking at another one must not leak the previous
      // list/tag through, or the same saved view shows different tasks depending
      // on where you came from.
      const current = TaskFilter(horizon: 'today', listId: 'old', tagId: 'oldtag', sort: 'due');
      final restored = decodeFilter('horizon=thisMonth', base: current);

      expect(restored.horizon, 'thisMonth');
      expect(restored.listId, isNull);
      expect(restored.tagId, isNull);
      expect(restored.sort, 'default');
    });

    test('always clears the search term', () {
      const current = TaskFilter(search: 'leftover');
      expect(decodeFilter('horizon=today', base: current).search, '');
    });

    test('ignores web-only keys rather than pretending they were applied', () {
      final restored = decodeFilter('horizon=today&status=todo,in-progress&priority=high',
          base: const TaskFilter());
      expect(restored.horizon, 'today');
    });

    test('falls back to defaults for an unknown sort', () {
      expect(decodeFilter('sort=bogus', base: const TaskFilter()).sort, 'default');
    });

    test('takes the first tag when the web stored several', () {
      expect(decodeFilter('tags=a,b,c', base: const TaskFilter()).tagId, 'a');
    });
  });

  group('filterMatchesQuery', () {
    test('recognises the view you are currently looking at', () {
      const f = TaskFilter(horizon: 'thisMonth', sort: 'priority');
      expect(filterMatchesQuery(f, encodeFilter(f)), isTrue);
    });

    test('a differing search does not break the match, since it is not stored', () {
      const saved = TaskFilter(horizon: 'thisMonth');
      const typing = TaskFilter(horizon: 'thisMonth', search: 'abc');
      expect(filterMatchesQuery(typing, encodeFilter(saved)), isTrue);
    });

    test('a different horizon does not match', () {
      expect(filterMatchesQuery(const TaskFilter(horizon: 'today'), 'horizon=thisMonth'), isFalse);
    });
  });
}
