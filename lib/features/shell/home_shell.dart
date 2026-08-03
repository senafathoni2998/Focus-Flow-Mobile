import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/goals_provider.dart';
import '../../providers/habits_provider.dart';
import '../../providers/lists_provider.dart';
import '../../providers/tags_provider.dart';
import '../../providers/providers.dart';
import '../../providers/write_queue_provider.dart';
import '../../providers/share_provider.dart';
import '../../providers/tasks_provider.dart';
import '../dashboard/dashboard_screen.dart';
import '../goals/goals_screen.dart';
import '../habits/habits_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/unsent_changes_screen.dart';
import '../tasks/task_editor_screen.dart';
import '../tasks/tasks_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  /// Guards against opening the editor twice for one share: build() and the
  /// ref.listen below can both reach _consumePendingShare in the same frame,
  /// and the pending value is not cleared until the post-frame callback runs.
  bool _openingShare = false;

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

  /// Open the editor for a share, and only then clear it.
  ///
  /// Clearing first would lose the text if the push failed; clearing after means
  /// the worst case is the editor opening twice, which the user can simply
  /// cancel. Consumed here rather than in the provider because this is the first
  /// point at which a Navigator exists AND the user is known to be signed in.
  void _consumePendingShare() {
    if (_openingShare) return;
    final pending = ref.read(pendingSharedTaskProvider);
    if (pending == null) return;
    _openingShare = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _openingShare = false;
        return;
      }
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TaskEditorScreen(
          presetTitle: pending.title,
          presetDescription: pending.description,
        ),
      ));
      ref.read(pendingSharedTaskProvider.notifier).state = null;
      _openingShare = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Fires for a share that arrives while the app is already open...
    ref.listen(pendingSharedTaskProvider, (_, next) {
      if (next != null) _consumePendingShare();
    });
    // ...and this covers the cold start, where the share was already waiting
    // before this widget existed.
    _consumePendingShare();

    // Showing data read from disk because the server was unreachable. Said out
    // loud: a screen that looks completely normal while being hours stale is the
    // worst way for an offline cache to behave.
    final servingCache = ref.watch(servingCacheProvider);
    final unsent = ref.watch(unsentCountProvider);
    final failed = ref.watch(failedCountProvider);
    // Stale reads and unsent writes are different problems and get different
    // wording. Showing only the read banner while writes pile up unsent would be
    // the more dangerous silence of the two.
    final showBanner = servingCache || unsent > 0;
    final bannerText = failed > 0
        ? "$failed change${failed == 1 ? '' : 's'} couldn't be saved"
        : unsent > 0
            ? (servingCache
                ? 'Offline — $unsent change${unsent == 1 ? '' : 's'} waiting'
                : 'Sending $unsent change${unsent == 1 ? '' : 's'}…')
            : 'Offline — showing saved data';

    return Scaffold(
      body: Column(
        children: [
          if (showBanner)
            Material(
              color: failed > 0
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        failed > 0
                            ? Icons.error_outline
                            : (unsent > 0
                                ? Icons.cloud_upload_outlined
                                : Icons.cloud_off_outlined),
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          bannerText,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (unsent > 0)
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const UnsentChangesScreen()),
                          ),
                          child: const Text('View'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(child: IndexedStack(index: _index, children: _screens)),
        ],
      ),
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
