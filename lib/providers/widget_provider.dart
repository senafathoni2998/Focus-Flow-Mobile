import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/home_widget.dart';
import 'filter_provider.dart';
import 'tasks_provider.dart';

final homeWidgetServiceProvider = Provider<HomeWidgetService>((ref) => HomeWidgetService());

/// Keeps the home-screen widget in step with the task list.
///
/// Watches the same data the UI does — pending offline writes included — so the
/// widget updates on exactly the events the user can see: a load, a refresh, a
/// completion, a delete, or a task typed with no signal. There is no separate
/// polling loop to drift out of sync with the app.
final widgetSyncProvider = Provider<void>((ref) {
  // The AsyncValue is still consulted, but only for its loading/error state:
  // publish real data or nothing. An error or a first load would otherwise
  // blank the widget to "nothing due", which is indistinguishable from
  // genuinely being done for the day.
  final tasks = ref.watch(tasksControllerProvider);
  if (tasks.value == null) return;

  // The CONTENT comes from the overlay. A task created offline is due today as
  // much as any other, and one ticked off offline must stop showing.
  final list = ref.watch(allTasksProvider);

  ref
      .read(homeWidgetServiceProvider)
      .push(buildWidgetSnapshot(list, DateTime.now()));
});
