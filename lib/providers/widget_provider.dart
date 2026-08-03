import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/home_widget.dart';
import 'tasks_provider.dart';

final homeWidgetServiceProvider = Provider<HomeWidgetService>((ref) => HomeWidgetService());

/// Keeps the home-screen widget in step with the task list.
///
/// Watches the same provider the UI does, so the widget updates on exactly the
/// events the user can see: a load, a refresh, a completion, a delete. There is
/// no separate polling loop to drift out of sync with the app.
final widgetSyncProvider = Provider<void>((ref) {
  final tasks = ref.watch(tasksControllerProvider);
  // Only publish real data. An error or a first load would otherwise blank the
  // widget to "nothing due", which is indistinguishable from genuinely being
  // done for the day.
  final list = tasks.value;
  if (list == null) return;

  ref
      .read(homeWidgetServiceProvider)
      .push(buildWidgetSnapshot(list, DateTime.now()));
});
