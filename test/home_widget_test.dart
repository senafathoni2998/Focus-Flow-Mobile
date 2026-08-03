import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/core/home_widget.dart';
import 'package:focusflow_mobile/models/task.dart';

/// The snapshot IS the widget's entire content, and it has to agree with what the
/// app's Today list shows — a widget that contradicts the app it belongs to is
/// worse than no widget at all.
Task _t(String id, {DateTime? due, String status = 'todo', String? parent}) => Task(
      id: id,
      title: id,
      status: status,
      priority: 'medium',
      dueDate: due,
      isAllDay: true,
      actualMin: 0,
      parentTaskId: parent,
      tags: const [],
      reminders: const [],
    );

final _now = DateTime(2026, 8, 3, 14, 30);
DateTime _day(int offset, {int hour = 9}) => DateTime(2026, 8, 3 + offset, hour);

void main() {
  group('buildWidgetSnapshot', () {
    test('counts today and overdue together, which is what "due today" means here', () {
      final s = buildWidgetSnapshot([
        _t('overdue', due: _day(-3)),
        _t('today', due: _day(0)),
        _t('tomorrow', due: _day(1)),
      ], _now);

      expect(s.count, 2);
      expect(s.titles, ['overdue', 'today']);
    });

    test('puts overdue before today, matching the Today list ordering', () {
      final s = buildWidgetSnapshot([
        _t('today', due: _day(0)),
        _t('older', due: _day(-5)),
        _t('recent', due: _day(-1)),
      ], _now);

      expect(s.titles, ['older', 'recent', 'today']);
    });

    test('excludes closed tasks', () {
      final s = buildWidgetSnapshot([
        _t('done', due: _day(0), status: 'completed'),
        _t('skipped', due: _day(0), status: 'wont-do'),
        _t('open', due: _day(0)),
      ], _now);

      expect(s.count, 1);
      expect(s.titles, ['open']);
    });

    test('excludes subtasks, which surface inside their parent', () {
      final s = buildWidgetSnapshot([
        _t('child', due: _day(0), parent: 'p1'),
        _t('parent', due: _day(0)),
      ], _now);

      expect(s.titles, ['parent']);
    });

    test('excludes undated tasks — a due-today widget cannot place them', () {
      final s = buildWidgetSnapshot([_t('someday'), _t('today', due: _day(0))], _now);
      expect(s.titles, ['today']);
    });

    test('keeps the full count but only as many titles as the layout has slots', () {
      final s = buildWidgetSnapshot(
        List.generate(9, (i) => _t('t$i', due: _day(0, hour: i + 1))),
        _now,
      );

      expect(s.count, 9);
      expect(s.titles, hasLength(kWidgetTitleSlots));
    });

    test('a task due later today still counts', () {
      // 23:59 today is inside the window even though it is hours away.
      final s = buildWidgetSnapshot([_t('tonight', due: DateTime(2026, 8, 3, 23, 59))], _now);
      expect(s.count, 1);
    });

    test('an empty day reports zero rather than nothing at all', () {
      final s = buildWidgetSnapshot([], _now);
      expect(s.count, 0);
      expect(s.titles, isEmpty);
      expect(s.updatedLabel, isNotEmpty);
    });

    test('stamps the time it was taken, since the widget is never live', () {
      expect(buildWidgetSnapshot([], _now).updatedLabel, 'Updated 14:30');
    });

    test('serialises to the shape the Kotlin provider reads', () {
      final json = jsonDecode(buildWidgetSnapshot([_t('a', due: _day(0))], _now).toJson());
      expect(json['count'], 1);
      expect(json['titles'], ['a']);
      expect(json['updatedLabel'], 'Updated 14:30');
    });
  });
}
