import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/goals_provider.dart';
import '../../providers/habits_provider.dart';
import '../../widgets/common.dart';

/// Everything the user has tucked away, with a way back.
///
/// Both archive actions were previously one-way from the phone: `/goals/archived`
/// and `archivedGoalsProvider` existed but had ZERO consumers — no screen ever
/// watched them — and habits had no archived endpoint at all. So an archived item
/// simply vanished, recoverable only from the web app.
///
/// One screen for both rather than a section inside each board: this is where you
/// go when something is missing, and you rarely remember whether the thing you
/// lost was a goal or a habit.
class ArchivedScreen extends ConsumerWidget {
  const ArchivedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(archivedGoalsProvider);
    final habits = ref.watch(archivedHabitsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Archived')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(archivedGoalsProvider);
          ref.invalidate(archivedHabitsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text('Goals', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            goals.when(
              loading: () => const _SectionLoading(),
              error: (e, _) => _SectionError(message: e.toString()),
              data: (list) => list.isEmpty
                  ? const _SectionEmpty(label: 'No archived goals.')
                  : Column(
                      children: [
                        for (final g in list)
                          _ArchivedTile(
                            leading: g.icon,
                            title: g.title,
                            onRestore: () async {
                              await ref
                                  .read(goalsControllerProvider.notifier)
                                  .setStatus(g.id, 'active');
                              ref.invalidate(archivedGoalsProvider);
                            },
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 28),
            Text('Habits', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            habits.when(
              loading: () => const _SectionLoading(),
              error: (e, _) => _SectionError(message: e.toString()),
              data: (list) => list.isEmpty
                  ? const _SectionEmpty(label: 'No archived habits.')
                  : Column(
                      children: [
                        for (final h in list)
                          _ArchivedTile(
                            leading: h.icon,
                            title: h.name,
                            onRestore: () async {
                              await ref
                                  .read(habitsControllerProvider.notifier)
                                  .unarchive(h.id);
                              ref.invalidate(archivedHabitsProvider);
                            },
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArchivedTile extends StatefulWidget {
  const _ArchivedTile({
    required this.leading,
    required this.title,
    required this.onRestore,
  });

  final String leading;
  final String title;
  final Future<void> Function() onRestore;

  @override
  State<_ArchivedTile> createState() => _ArchivedTileState();
}

class _ArchivedTileState extends State<_ArchivedTile> {
  bool _busy = false;

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      await widget.onRestore();
      if (mounted) showInfo(context, 'Restored');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Text(widget.leading, style: const TextStyle(fontSize: 22)),
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _busy
          ? const SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : TextButton(onPressed: _restore, child: const Text('Restore')),
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      );
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Text(label, style: TextStyle(color: Theme.of(context).colorScheme.outline));
}

class _SectionError extends StatelessWidget {
  const _SectionError({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
}
