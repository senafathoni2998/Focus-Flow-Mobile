import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/offline/queue_flusher.dart';
import '../../core/offline/queue_op.dart';
import '../../providers/write_queue_provider.dart';
import '../../widgets/common.dart';

/// Where writes go when they could not be sent.
///
/// The one rule this screen exists to enforce: NOTHING IS EVER AUTO-DISCARDED.
/// A task someone typed is theirs; if the server refused it, they get told why
/// and decide what happens to it. "Copy text" is what makes that literally true
/// even when the change itself is unsalvageable.
class UnsentChangesScreen extends ConsumerWidget {
  const UnsentChangesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<QueuedOp> pending = ref.watch(pendingOpsProvider);
    final List<QueuedOp> dead = ref.watch(deadOpsProvider);
    final FlushState state = ref.watch(queueStateProvider);
    final bool corrupted = ref.watch(queueCorruptedProvider);
    final int dropped = ref.watch(droppedDeadProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unsent changes'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Try now',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(queueFlusherProvider).flush(force: true),
          ),
        ],
      ),
      body: pending.isEmpty && dead.isEmpty
          ? (corrupted
              // Never claim everything is saved when we know it is not. A queue
              // file we could not read was moved aside rather than deleted, so
              // the work still exists on the device even though the app can no
              // longer act on it.
              ? EmptyState(
                  icon: Icons.report_outlined,
                  title: 'Some unsent changes could not be recovered',
                  subtitle:
                      'A saved queue file could not be read, so it was set aside '
                      'rather than deleted. Anything it held was not sent.',
                )
              : const EmptyState(
                  icon: Icons.cloud_done_outlined,
                  title: 'Everything is saved',
                  subtitle: 'Changes you make without a connection will wait here.',
                ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: <Widget>[
                if (dropped > 0)
                  // The cap is real, so say it happened rather than letting the
                  // oldest failures disappear behind a count that never moved.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Text(
                      '$dropped older failure${dropped == 1 ? ' was' : 's were'} '
                      'dropped to make room.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                if (dead.isNotEmpty) ...<Widget>[
                  _SectionHeader(
                    title: 'Not saved',
                    subtitle: dead.length == 1
                        ? '1 change the server refused. Nothing was discarded.'
                        : '${dead.length} changes the server refused. Nothing was discarded.',
                  ),
                  for (final QueuedOp op in dead)
                    _DeadRow(op: op),
                ],
                if (pending.isNotEmpty) ...<Widget>[
                  _SectionHeader(
                    title: 'Waiting to send',
                    subtitle: state == FlushState.pausedAuth
                        ? 'Sign in again to send these.'
                        : 'These go out as soon as there is a connection.',
                  ),
                  for (final QueuedOp op in pending)
                    ListTile(
                      leading: Icon(
                        op.id == ref.watch(inFlightOpIdProvider)
                            ? Icons.cloud_sync
                            : Icons.schedule,
                        size: 20,
                      ),
                      title: Text(op.summary),
                      subtitle: Text(_age(op.createdAtMs)),
                    ),
                ],
              ],
            ),
    );
  }
}

String _age(int ms) {
  if (ms <= 0) return 'just now';
  final Duration d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: text.titleSmall),
          const SizedBox(height: 2),
          Text(subtitle,
              style: text.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }
}

class _DeadRow extends ConsumerWidget {
  const _DeadRow({required this.op});
  final QueuedOp op;

  String get _why {
    switch (op.reason) {
      case DeadReason.orphaned:
        return 'The task it belongs to was never created.';
      case DeadReason.unconfirmed:
        return op.errorMessage ?? "We couldn't confirm this was saved.";
      case DeadReason.expired:
        return 'This waited too long without a connection.';
      case DeadReason.rejected:
      case null:
        return op.errorMessage ?? 'The server refused this change.';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      isThreeLine: true,
      leading: Icon(Icons.error_outline, color: scheme.error, size: 20),
      title: Text(op.summary),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(_why),
          Text(_age(op.diedAtMs ?? op.createdAtMs),
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline)),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (String action) async {
          final QueueFlusher queue = ref.read(queueFlusherProvider);
          switch (action) {
            case 'retry':
              await queue.retryDead(op.id);
            case 'copy':
              await Clipboard.setData(ClipboardData(text: _plainText(op)));
              if (context.mounted) showInfo(context, 'Copied');
            case 'discard':
              final bool ok = await confirmDialog(
                context,
                title: 'Discard this change?',
                message:
                    'It will not be sent, and there is no way to get it back.',
                confirmLabel: 'Discard',
                destructive: true,
              );
              if (ok) await queue.discardDead(op.id);
          }
        },
        itemBuilder: (BuildContext _) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'retry', child: Text('Try again')),
          PopupMenuItem<String>(value: 'copy', child: Text('Copy text')),
          PopupMenuItem<String>(value: 'discard', child: Text('Discard')),
        ],
      ),
    );
  }
}

/// Everything the user actually typed, so it survives even if the change never
/// can. This is the difference between "we lost your task" and "here it is,
/// paste it wherever you like".
String _plainText(QueuedOp op) {
  final Map<String, dynamic>? body = op.body;
  if (body == null) return op.summary;
  final StringBuffer sb = StringBuffer();
  for (final String key in const <String>['title', 'description']) {
    final Object? v = body[key];
    if (v is String && v.trim().isNotEmpty) sb.writeln(v.trim());
  }
  final Object? tags = body['tags'];
  if (tags is List && tags.isNotEmpty) {
    sb.writeln(tags.whereType<String>().map((String t) => '#$t').join(' '));
  }
  final String out = sb.toString().trim();
  return out.isEmpty ? op.summary : out;
}
