import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/horizons.dart';
import '../../providers/auth_provider.dart';
import '../../providers/filter_provider.dart';
import '../../providers/lists_provider.dart';
import '../../providers/tags_provider.dart';
import '../../widgets/common.dart';

class TasksDrawer extends ConsumerWidget {
  const TasksDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final filter = ref.watch(taskFilterProvider);
    final counts = ref.watch(horizonCountsProvider);
    final lists = ref.watch(listsControllerProvider).value ?? const [];
    final tags = ref.watch(tagsControllerProvider).value ?? const [];
    final user = ref.watch(authControllerProvider).user;

    void setFilter(TaskFilter f) {
      ref.read(taskFilterProvider.notifier).state = f;
      Navigator.of(context).pop();
    }

    final smartSelected = filter.listId == null && filter.tagId == null;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FocusFlow', style: Theme.of(context).textTheme.titleLarge),
                  if (user != null)
                    Text(user.displayName, style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            _sectionLabel(context, 'Smart Lists'),
            for (final h in kHorizons)
              ListTile(
                dense: true,
                leading: Icon(h.icon),
                title: Text(h.label),
                trailing: (counts[h.key] ?? 0) > 0
                    ? _Badge(count: counts[h.key]!)
                    : null,
                selected: smartSelected && filter.horizon == h.key,
                selectedTileColor: scheme.secondaryContainer,
                onTap: () => setFilter(filter.copyWith(horizon: h.key, listId: null, tagId: null)),
              ),
            const Divider(),
            _sectionLabel(context, 'Lists'),
            ListTile(
              dense: true,
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('Inbox'),
              selected: filter.listId == 'inbox',
              selectedTileColor: scheme.secondaryContainer,
              onTap: () => setFilter(filter.copyWith(horizon: 'all', listId: 'inbox', tagId: null)),
            ),
            for (final l in lists)
              ListTile(
                dense: true,
                leading: Icon(Icons.list_alt, color: semanticColor(l.color)),
                title: Text(l.name),
                selected: filter.listId == l.id,
                selectedTileColor: scheme.secondaryContainer,
                onTap: () => setFilter(filter.copyWith(horizon: 'all', listId: l.id, tagId: null)),
                onLongPress: () async {
                  final ok = await confirmDialog(context,
                      title: 'Delete list',
                      message: 'Delete "${l.name}"? Its tasks move to the Inbox.');
                  if (!ok) return;
                  try {
                    await ref.read(listsControllerProvider.notifier).delete(l.id);
                    if (filter.listId == l.id) {
                      ref.read(taskFilterProvider.notifier).state = const TaskFilter();
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.add),
              title: const Text('New list'),
              onTap: () => _createList(context, ref),
            ),
            if (tags.isNotEmpty) ...[
              const Divider(),
              _sectionLabel(context, 'Tags'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in tags)
                      GestureDetector(
                        onLongPress: () async {
                          final ok = await confirmDialog(context,
                              title: 'Delete tag',
                              message: 'Delete #${tag.name}? It will be removed from all tasks.');
                          if (!ok) return;
                          try {
                            await ref.read(tagsControllerProvider.notifier).delete(tag.id);
                            if (filter.tagId == tag.id) {
                              ref.read(taskFilterProvider.notifier).state = const TaskFilter();
                            }
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                        child: FilterChip(
                          label: Text('#${tag.name}'),
                          selected: filter.tagId == tag.id,
                          onSelected: (_) => setFilter(
                              filter.copyWith(horizon: 'all', listId: null, tagId: tag.id)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _createList(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New list'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'List name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(listsControllerProvider.notifier).create(name);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$count', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    );
  }
}
