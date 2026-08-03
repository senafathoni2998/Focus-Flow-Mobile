import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/features/tasks/matrix_view.dart';
import 'package:focusflow_mobile/models/task.dart';

/// The Eisenhower quadrant rules are duplicated from the web's TaskMatrixView.
/// Duplicated logic drifts — this repo has already been bitten by exactly that
/// between its Server Actions and its service layer — so these pin the two
/// predicates that must stay identical: importance is `priority == 'high'`, and
/// urgency is "due within two days, or overdue".
Task _task({
  String id = 't1',
  String priority = 'medium',
  String status = 'todo',
  DateTime? dueDate,
}) =>
    Task(
      id: id,
      title: id,
      status: status,
      priority: priority,
      dueDate: dueDate,
      isAllDay: true,
      actualMin: 0,
      tags: const [],
      reminders: const [],
    );

final _now = DateTime(2026, 8, 3, 12);
DateTime _inDays(int d) => DateTime(2026, 8, 3 + d);

void main() {
  group('quadrantOf', () {
    test('high priority due within two days is "do first"', () {
      expect(quadrantOf(_task(priority: 'high', dueDate: _inDays(2)), _now), Quadrant.doFirst);
    });

    test('an overdue high-priority task is still urgent', () {
      expect(quadrantOf(_task(priority: 'high', dueDate: _inDays(-5)), _now), Quadrant.doFirst);
    });

    test('high priority due later is "schedule"', () {
      expect(quadrantOf(_task(priority: 'high', dueDate: _inDays(3)), _now), Quadrant.schedule);
    });

    test('high priority with no date is "schedule", never urgent', () {
      expect(quadrantOf(_task(priority: 'high'), _now), Quadrant.schedule);
    });

    test('urgent but not important is "delegate"', () {
      expect(quadrantOf(_task(priority: 'low', dueDate: _inDays(1)), _now), Quadrant.delegate);
    });

    test('neither is "later"', () {
      expect(quadrantOf(_task(priority: 'low', dueDate: _inDays(30)), _now), Quadrant.later);
      expect(quadrantOf(_task(priority: 'none'), _now), Quadrant.later);
    });

    test('the urgency boundary is inclusive at two days and excludes three', () {
      expect(quadrantOf(_task(priority: 'low', dueDate: _inDays(2)), _now), Quadrant.delegate);
      expect(quadrantOf(_task(priority: 'low', dueDate: _inDays(3)), _now), Quadrant.later);
    });

    test('urgency compares calendar days, not elapsed hours', () {
      // Due at 00:30 tomorrow is 12.5 hours away but one calendar day out; the
      // web compares days, so an hours-based port would disagree with it.
      final justAfterMidnight = DateTime(2026, 8, 4, 0, 30);
      expect(quadrantOf(_task(priority: 'low', dueDate: justAfterMidnight), _now), Quadrant.delegate);
    });
  });

  group('groupByQuadrant', () {
    test('drops terminal tasks — a matrix of finished work is noise', () {
      final tasks = [
        _task(id: 'done', priority: 'high', dueDate: _inDays(0), status: 'completed'),
        _task(id: 'skipped', priority: 'high', dueDate: _inDays(0), status: 'wont-do'),
        _task(id: 'open', priority: 'high', dueDate: _inDays(0)),
      ];

      final groups = groupByQuadrant(tasks, _now);

      expect(groups[Quadrant.doFirst]!.map((t) => t.id), ['open']);
    });

    test('always returns every quadrant, so the UI has no null cases', () {
      final groups = groupByQuadrant(const [], _now);
      expect(groups.keys.toSet(), Quadrant.values.toSet());
      expect(groups.values.every((v) => v.isEmpty), isTrue);
    });

    test('preserves the incoming order within a quadrant', () {
      final tasks = [
        _task(id: 'a', priority: 'high'),
        _task(id: 'b', priority: 'high'),
        _task(id: 'c', priority: 'high'),
      ];
      expect(groupByQuadrant(tasks, _now)[Quadrant.schedule]!.map((t) => t.id), ['a', 'b', 'c']);
    });
  });
}
