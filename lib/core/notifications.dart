import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Device notifications for due reminders.
///
/// Delivery is FOREGROUND-ONLY by design: [ReminderPoller] asks the server which
/// reminders have fired while the app is running and raises them locally. Waking
/// a closed app needs a push transport (FCM) plus a server that can reach Google,
/// which is a different feature with a different threat model for a self-hosted
/// backend. Scheduling them locally instead was rejected too — reminders are
/// edited from the web, so a phone holding a week of pre-scheduled alarms would
/// happily fire ones the user had already deleted.
///
/// Every failure path here is swallowed: notifications are an enhancement, and a
/// device that refuses them (permission denied, OEM restrictions) must not break
/// the rest of the app.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'focusflow_reminders';
  static const _channelName = 'Task reminders';
  static const _channelDescription = 'Alerts for tasks whose reminder time has arrived.';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      // Uses the launcher icon, so no extra drawable has to be added to the
      // generated android/ project.
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: android));

      // Android 13+ requires an explicit runtime grant.
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();

      _ready = true;
    } catch (e) {
      debugPrint('[notifications] init failed: $e');
    }
  }

  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[notifications] show failed: $e');
    }
  }
}

/// Stable, non-colliding notification id derived from the reminder id.
int notificationIdFor(String reminderId) => reminderId.hashCode & 0x7fffffff;
