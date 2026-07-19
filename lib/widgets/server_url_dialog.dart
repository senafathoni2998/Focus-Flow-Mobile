import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../providers/providers.dart';

/// Lets the user point the app at their FocusFlow backend. Persisted so it
/// survives restarts. Reachable from the login screen and Settings.
Future<void> showServerUrlDialog(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController(text: ref.read(apiBaseProvider));
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Server URL'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The origin of your FocusFlow backend (no /api path).\n'
                '• Android emulator → http://10.0.2.2:3000\n'
                '• Physical device → http://<your-computer-LAN-IP>:3000',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: 'http://10.0.2.2:3000',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (!AppConfig.isValidOrigin(value)) {
                  setState(() => error = 'Enter a valid http(s) URL');
                  return;
                }
                Navigator.pop(ctx, value);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
    },
  );

  if (result != null) {
    ref.read(apiBaseProvider.notifier).state = result;
    await ref.read(tokenStorageProvider).setBaseUrl(result);
  }
}
