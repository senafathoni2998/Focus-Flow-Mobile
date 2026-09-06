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
          Builder(builder: (context) {
            // Stated on the row rather than only in a README nobody re-reads.
            // Over plain http the bearer token is readable by anyone on the same
            // network, and no amount of client-side care changes that — the
            // manifest's host allowlist narrows WHERE it can be sent, not who
            // can read it on the way. The app still works; the user is told.
            final bool cleartext = Uri.tryParse(baseUrl)?.scheme == 'http';
            final scheme = Theme.of(context).colorScheme;
            return ListTile(
              leading: Icon(cleartext ? Icons.lock_open : Icons.dns_outlined,
                  color: cleartext ? scheme.error : null),
              title: const Text('Server URL'),
              subtitle: Text(
                cleartext
                    ? '$baseUrl\nNot encrypted — anyone on this network can read '
                        'your sign-in token. Put TLS in front of the backend and '
                        'use https.'
                    : baseUrl,
                style: cleartext ? TextStyle(color: scheme.error) : null,
              ),
              isThreeLine: cleartext,
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => showServerUrlDialog(context, ref),
            );
          }),
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
          const SizedBox(height: 8),
          // Google Play requires an in-app way to delete the account for any app
          // that can create one. Quieter than Sign out on purpose — a text
          // button, not a filled one — and it asks for the password again.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton.icon(
              onPressed: () => _deleteAccount(context, ref),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Delete account'),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
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

/// Explain what is about to happen, then ask for the password.
///
/// The unsent count is part of the explanation, not an afterthought: those
/// writes are the one thing deletion destroys that the server never had.
Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
  final unsent = ref.read(unsentCountProvider);
  final email = ref.read(authControllerProvider).user?.email ?? 'this account';
  final controller = TextEditingController();
  // Captured before any await: once the account is gone the auth state flips
  // and this screen is replaced, so its own context can no longer show anything.
  final messenger = ScaffoldMessenger.maybeOf(context);

  final password = await showDialog<String>(
    context: context,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: const Text('Delete account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Permanently deletes $email and everything in it — tasks, habits and '
              'check-ins, goals, focus sessions, reminders. This cannot be undone.',
            ),
            if (unsent > 0) ...[
              const SizedBox(height: 8),
              Text(
                '$unsent unsent change${unsent == 1 ? '' : 's'} on this phone will be '
                'discarded too.',
                style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Your password'),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim().isEmpty ? null : v),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            onPressed: () {
              final v = controller.text;
              Navigator.of(ctx).pop(v.trim().isEmpty ? null : v);
            },
            child: const Text('Delete permanently'),
          ),
        ],
      );
    },
  );
  controller.dispose();
  if (password == null) return;

  try {
    await ref.read(authControllerProvider.notifier).deleteAccount(password);
    messenger?.showSnackBar(const SnackBar(content: Text('Account deleted')));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
