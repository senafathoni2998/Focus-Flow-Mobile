import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/dashboard.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../widgets/common.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardControllerProvider);
    final user = ref.watch(authControllerProvider).user;

    return Scaffold(
      appBar: AppBar(title: const Text('Overview')),
      body: state.when(
        loading: () => const LoadingCenter(),
        error: (e, _) => ErrorRetry(
            message: '$e', onRetry: () => ref.read(dashboardControllerProvider.notifier).load()),
        data: (d) => RefreshIndicator(
          onRefresh: () => ref.read(dashboardControllerProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Hi${user?.name != null && user!.name!.isNotEmpty ? ', ${user.name}' : ''} 👋',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                _summaryLine(d),
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.5,
                children: [
                  _StatTile(label: 'Overdue', value: '${d.overdue}', icon: Icons.warning_amber_rounded, color: Colors.red),
                  _StatTile(label: 'Due today', value: '${d.dueToday}', icon: Icons.today, color: Colors.orange),
                  _StatTile(label: 'To do', value: '${d.statusCount('todo')}', icon: Icons.radio_button_unchecked, color: Colors.blue),
                  _StatTile(label: 'In progress', value: '${d.statusCount('in-progress')}', icon: Icons.timelapse, color: Colors.indigo),
                  _StatTile(label: 'Done today', value: '${d.completedToday}', icon: Icons.check_circle, color: Colors.green),
                  _StatTile(label: 'Done this week', value: '${d.completedThisWeek}', icon: Icons.event_available, color: Colors.teal),
                  _StatTile(label: 'Focus (7d)', value: _hm(d.focusMinutesThisWeek), icon: Icons.timer, color: Colors.purple),
                  _StatTile(label: 'Active goals', value: '${d.activeGoals}', icon: Icons.flag, color: Colors.pink),
                ],
              ),
              const SizedBox(height: 16),
              // Denominator is this week's completions plus the work still open —
              // NOT `d.total`, which counts every task ever created, so the bar
              // shrank forever as the archive grew and a productive week read as
              // almost no progress. byStatus was already in the payload.
              _ProgressBanner(
                done: d.completedThisWeek,
                total: d.completedThisWeek + d.openTasks,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _summaryLine(DashboardSummary d) {
    if (d.overdue > 0) return 'You have ${d.overdue} overdue and ${d.dueToday} due today.';
    if (d.dueToday > 0) return '${d.dueToday} task(s) due today. You\'ve got this.';
    return 'Nothing overdue — nice and clear.';
  }

  String _hm(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h ${m}m';
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, required this.icon, required this.color});
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 22),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _ProgressBanner extends StatelessWidget {
  const _ProgressBanner({required this.done, required this.total});
  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Weekly completion', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 10,
              backgroundColor: scheme.surfaceContainer,
            ),
          ),
          const SizedBox(height: 8),
          // Show the denominator: a bare "12 completed this week" gave no way to
          // tell whether the bar was reading a good week or a bad one.
          Text('$done of $total done this week',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
