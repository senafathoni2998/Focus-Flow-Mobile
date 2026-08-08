import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/providers.dart';
import '../../widgets/common.dart';
import '../../providers/write_queue_provider.dart';
import '../../widgets/server_url_dialog.dart';
import 'unsent_changes_screen.dart';
import '../archived/archived_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final baseUrl = ref.watch(apiBaseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(user?.name?.isNotEmpty == true ? user!.name! : 'FocusFlow user'),
            subtitle: Text(user?.email ?? ''),
          ),
          const Divider(),
          _SectionHeader('Data'),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Archived'),
            subtitle: const Text('Restore goals and habits you put away'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ArchivedScreen()),
            ),
          ),
          const Divider(),
          _SectionHeader('Server'),
          Consumer(builder: (context, ref, _) {
            final unsent = ref.watch(unsentCountProvider);
            if (unsent == 0) return const SizedBox.shrink();
            final failed = ref.watch(failedCountProvider);
            final scheme = Theme.of(context).colorScheme;
            return ListTile(
              leading: Icon(
                failed > 0 ? Icons.error_outline : Icons.cloud_upload_outlined,
                color: failed > 0 ? scheme.error : null,
              ),
              title: Text('Unsent changes ($unsent)'),
              subtitle: Text(failed > 0
                  ? "$failed couldn't be saved — nothing was discarded"
                  : 'Waiting for a connection'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UnsentChangesScreen()),
              ),
            );
          }),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server URL'),
            subtitle: Text(baseUrl),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => showServerUrlDialog(context, ref),
          ),
          const Divider(),
          _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('FocusFlow Mobile'),
            subtitle: Text('Android client for the self-hosted FocusFlow app · v1.0.0'),
          ),
          const Divider(),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () async {
                final unsent = ref.read(unsentCountProvider);
                if (unsent > 0) {
                  final choice = await _confirmSignOutWithUnsent(
                      context, unsent, ref.read(failedCountProvider));
                  if (choice == null) return;
                  await ref
                      .read(authControllerProvider.notifier)
                      .logout(discardUnsent: choice);
                  return;
                }
                final ok = await confirmDialog(
                  context,
                  title: 'Sign out?',
                  message: 'You will need to sign in again.',
                  confirmLabel: 'Sign out',
                  destructive: false,
                );
                if (ok) await ref.read(authControllerProvider.notifier).logout();
              },
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// Signing out with work still unsent.
///
/// Returns null to cancel, false to KEEP the queue, true to discard it.
///
/// Keeping is the default and the safe answer: the file stays scoped to this
/// account, so no other user can read or send it, and it drains the moment they
/// sign back in. Destroying someone's typed work because they signed out on a
/// shared phone is exactly the loss this whole feature exists to prevent — so
/// discarding is offered, never assumed.
Future<bool?> _confirmSignOutWithUnsent(
    BuildContext context, int unsent, int failed) {
  // The wording distinguishes the two, because they behave differently and the
  // dialog used to promise the same thing for both. A pending change really is
  // sent on the next sign-in; a FAILED one is never retried on its own — it
  // waits in Unsent changes for the user to decide. Saying "they will be sent"
  // about a dead letter is a promise the app does not keep.
  final int waiting = unsent - failed;
  final String body;
  if (failed == 0) {
    body = waiting == 1
        ? 'It will be sent the next time you sign in to this account.'
        : 'They will be sent the next time you sign in to this account.';
  } else if (waiting == 0) {
    body = failed == 1
        ? 'It could not be saved and will not be retried on its own. It will '
            'still be here, in Unsent changes, when you sign back in.'
        : 'They could not be saved and will not be retried on their own. They '
            'will still be here, in Unsent changes, when you sign back in.';
  } else {
    body = '$waiting will be sent the next time you sign in. $failed could not '
        'be saved and will be waiting in Unsent changes.';
  }
  final String plural = unsent == 1 ? '' : 's';
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('You have $unsent unsent change$plural'),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error),
          child: const Text('Discard and sign out'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
}
