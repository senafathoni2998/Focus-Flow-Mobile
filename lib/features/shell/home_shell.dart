import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/goals_provider.dart';
import '../../providers/habits_provider.dart';
import '../../providers/lists_provider.dart';
import '../../providers/tags_provider.dart';
import '../../providers/tasks_provider.dart';
import '../dashboard/dashboard_screen.dart';
import '../goals/goals_screen.dart';
import '../habits/habits_screen.dart';
import '../settings/settings_screen.dart';
import '../tasks/tasks_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _screens = [
    TasksScreen(),
    HabitsScreen(),
    GoalsScreen(),
    DashboardScreen(),
    SettingsScreen(),
  ];

  void _onSelect(int i) {
    setState(() => _index = i);
    // Pull fresh data for the tab being opened (cheap, keeps derived views current).
    switch (i) {
      case 0:
        ref.read(tasksControllerProvider.notifier).refresh();
        // Tags and lists were fetched once per process in their constructors with
        // no refresh path at all, so a tag created implicitly through the task
        // editor never showed up as a filter chip or a suggestion until the app was
        // restarted — and the user retyped it, creating case-variant duplicates.
        ref.read(tagsControllerProvider.notifier).refresh();
        ref.read(listsControllerProvider.notifier).refresh();
        break;
      case 4:
        // Bootstrap may have opened the app optimistically without a profile
        // (backend restarting → 502, not 401); this is the screen that shows it.
        ref.read(authControllerProvider.notifier).refreshUser();
        break;
      case 1:
        ref.read(habitsControllerProvider.notifier).refresh();
        break;
      case 2:
        ref.read(goalsControllerProvider.notifier).refresh();
        break;
      case 3:
        ref.read(dashboardControllerProvider.notifier).refresh();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onSelect,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.check_circle_outline),
              selectedIcon: Icon(Icons.check_circle),
              label: 'Tasks'),
          NavigationDestination(
              icon: Icon(Icons.local_fire_department_outlined),
              selectedIcon: Icon(Icons.local_fire_department),
              label: 'Habits'),
          NavigationDestination(
              icon: Icon(Icons.flag_outlined), selectedIcon: Icon(Icons.flag), label: 'Goals'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'Stats'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}
