import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/data/sync_repository.dart';

/// The delta is how the app learns what changed while it was busy draining the
/// queue — including the deletions, which no list endpoint can express.

void main() {
  group('SyncDelta.fromJson', () {
    test('reads the envelope the server actually sends', () {
      final SyncDelta d = SyncDelta.fromJson(<String, dynamic>{
        'serverTime': '2026-08-05T10:00:00.000Z',
        'full': false,
        'changed': <String, dynamic>{
          'tasks': <Map<String, dynamic>>[
            <String, dynamic>{'id': 't1', 'title': 'Buy milk'}
          ],
          'lists': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'l1', 'name': 'Work'}
          ],
          'tags': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'tag1', 'name': 'errands'}
          ],
          // Present in the payload, not consumed here — the queue only writes
          // tasks and lists, so nothing else can be stale from a drain.
          'habits': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'h1'}
          ],
        },
        'deleted': <Map<String, dynamic>>[
          <String, dynamic>{'entityType': 'task', 'entityId': 'gone1'},
          <String, dynamic>{'entityType': 'list', 'entityId': 'gone2'},
        ],
      });

      expect(d.serverTime, '2026-08-05T10:00:00.000Z');
      expect(d.full, isFalse);
      expect(d.tasks.single['id'], 't1');
      expect(d.lists.single['id'], 'l1');
      expect(d.tags.single['id'], 'tag1');
      expect(d.deleted.length, 2);
      expect(d.deleted.first.type, 'task');
      expect(d.deleted.first.id, 'gone1');
    });

    test('a first sync is marked full, and carries no tombstones', () {
      // The server skips tombstones without a cursor on purpose: a client
      // starting empty has nothing to delete, so shipping every tombstone the
      // account ever accumulated would be pure noise.
      final SyncDelta d = SyncDelta.fromJson(<String, dynamic>{
        'serverTime': '2026-08-05T10:00:00.000Z',
        'full': true,
        'changed': <String, dynamic>{'tasks': <Map<String, dynamic>>[]},
        'deleted': <Map<String, dynamic>>[],
      });
      expect(d.full, isTrue);
      expect(d.deleted, isEmpty);
      expect(d.lists, isEmpty);
    });

    test('a malformed tombstone is dropped, not turned into a phantom id', () {
      // An entry missing its type or id would otherwise become ('', '') and
      // match nothing — or worse, match a row whose id happens to be empty.
      final SyncDelta d = SyncDelta.fromJson(<String, dynamic>{
        'serverTime': 'x',
        'full': false,
        'changed': <String, dynamic>{},
        'deleted': <dynamic>[
          <String, dynamic>{'entityType': 'task'},
          <String, dynamic>{'entityId': 'no-type'},
          'not an object',
          <String, dynamic>{'entityType': 'task', 'entityId': 'good'},
        ],
      });
      expect(d.deleted.length, 1);
      expect(d.deleted.single.id, 'good');
    });

    test('a response missing whole sections does not throw', () {
      // Tolerance here is the difference between "the reconcile did nothing" and
      // "the app crashed after the user's writes went out".
      final SyncDelta d = SyncDelta.fromJson(<String, dynamic>{});
      expect(d.tasks, isEmpty);
      expect(d.lists, isEmpty);
      expect(d.tags, isEmpty);
      expect(d.deleted, isEmpty);
      expect(d.full, isFalse);
    });
  });
}
