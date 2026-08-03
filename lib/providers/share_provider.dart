import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/share_intent.dart';

/// The share bridge, alive for the life of the app.
final shareIntentServiceProvider = Provider<ShareIntentService>((ref) {
  final service = ShareIntentService();
  ref.onDispose(service.dispose);
  return service;
});

/// The most recent share that has not been turned into a task yet.
///
/// Held in state rather than acted on the instant it arrives, because a share
/// can land while the user is signed out — the Android share sheet does not know
/// or care about the app's auth state. Parking it here means it survives until
/// there is somewhere to put it, instead of being dropped on the login screen.
final pendingSharedTaskProvider = StateProvider<SharedTask?>((ref) => null);

/// Starts the bridge and funnels every share into [pendingSharedTaskProvider].
final shareListenerProvider = Provider<void>((ref) {
  final service = ref.watch(shareIntentServiceProvider);
  final sub = service.shares.listen((task) {
    ref.read(pendingSharedTaskProvider.notifier).state = task;
  });
  ref.onDispose(sub.cancel);
  // Fire-and-forget: the cold-start read resolves into the same stream.
  service.start();
});
