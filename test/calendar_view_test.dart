import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/features/tasks/calendar_view.dart';
import 'package:focusflow_mobile/models/task.dart';

Task _task(String id, DateTime? due) => Task(
      id: id,
      title: id,
      status: 'todo',
      priority: 'medium',
      dueDate: due,
      isAllDay: true,
      actualMin: 0,
      tags: const [],
      reminders: const [],
    );

void main() {
  group('groupByDueDay', () {
    test('keys by LOCAL calendar day, not by UTC instant', () {
      // 23:30 local is the same calendar day to the user even though it is
      // already tomorrow in UTC. Keying off toIso8601String() would file this
      // under the wrong day for anyone east of UTC.
      final late = DateTime(2026, 8, 3, 23, 30);
      final groups = groupByDueDay([_task('t', late)]);
      expect(groups.keys.single, '2026-08-03');
    });

    test('zero-pads month and day so keys sort lexicographically', () {
      final groups = groupByDueDay([_task('t', DateTime(2026, 1, 5))]);
      expect(groups.keys.single, '2026-01-05');
    });

    test('collects several tasks under one day, in the order given', () {
      final d = DateTime(2026, 8, 3);
      final groups = groupByDueDay([_task('a', d), _task('b', d)]);
      expect(groups['2026-08-03']!.map((t) => t.id), ['a', 'b']);
    });

    test('drops undated tasks rather than inventing a slot for them', () {
      // A calendar cannot honestly place them; the drawer's No Date smart list is
      // where they belong.
      final groups = groupByDueDay([_task('none', null), _task('dated', DateTime(2026, 8, 3))]);
      expect(groups.keys, ['2026-08-03']);
    });

    test('separates adjacent days', () {
      final groups = groupByDueDay([
        _task('a', DateTime(2026, 8, 3, 23, 59)),
        _task('b', DateTime(2026, 8, 4, 0, 1)),
      ]);
      expect(groups.keys.toSet(), {'2026-08-03', '2026-08-04'});
    });
  });
}
