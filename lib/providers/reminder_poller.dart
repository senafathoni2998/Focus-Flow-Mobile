import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notifications.dart';
import 'auth_provider.dart';
import 'providers.dart';

/// Polls `/reminders/due` while the app is in the foreground and raises a device
/// notification for each newly fired reminder, then marks it dispatched so it is
/// never shown twice.
///
/// This mirrors the web app's in-app dispatcher. The server already caps the
/// query at 5 rows within the last 24 hours, so a phone that has been closed for
/// a fortnight gets the recent handful rather than a wall of stale alerts.
///
/// Only runs while authenticated: polling with no session would just burn
/// battery on 401s.
class ReminderPoller {
  ReminderPoller(this._ref) {
    _ref.listen<AuthState>(
      authControllerProvider,
      (_, next) => next.isAuthenticated ? start() : stop(),
      fireImmediately: true,
    );
  }

  static const _interval = Duration(minutes: 1);

  final Ref _ref;
  Timer? _timer;
  bool _inFlight = false;
  final Set<String> _shown = {};

  void start() {
    if (_timer != null) return;
    unawaited(NotificationService.instance.init());
    _timer = Timer.periodic(_interval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _shown.clear();
  }

  Future<void> _poll() async {
    // A slow request must not stack up behind the next tick.
    if (_inFlight) return;
    _inFlight = true;
    try {
      final repo = _ref.read(reminderRepositoryProvider);
      final due = await repo.due();
      if (due.isEmpty) return;

      final fresh = due.where((r) => !_shown.contains(r.id)).toList();
      if (fresh.isEmpty) return;

      // Claim them server-side FIRST. If the notification then fails to render,
      // a silent miss beats the alternative: marking after showing means a crash
      // in between replays the same alert on every future poll.
      for (final r in fresh) {
        _shown.add(r.id);
      }
      await repo.dispatch(fresh.map((r) => r.id).toList());

      for (final r in fresh) {
        await NotificationService.instance.show(
          id: notificationIdFor(r.id),
          title: 'Reminder',
          body: r.taskTitle,
        );
      }
    } catch (e) {
      debugPrint('[reminders] poll failed: $e');
      // Transient — the next tick retries. Ids added to _shown for a request that
      // failed before dispatch stay claimed locally, which only costs one missed
      // banner rather than a duplicate.
    } finally {
      _inFlight = false;
    }
  }

  void dispose() => stop();
}

final reminderPollerProvider = Provider<ReminderPoller>((ref) {
  final poller = ReminderPoller(ref);
  ref.onDispose(poller.dispose);
  return poller;
});
