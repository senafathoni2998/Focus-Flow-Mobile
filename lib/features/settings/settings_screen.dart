import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/server_url_dialog.dart';
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
