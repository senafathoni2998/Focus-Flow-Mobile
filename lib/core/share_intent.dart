import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Text shared into the app, split into the two fields a task actually has.
@immutable
class SharedTask {
  const SharedTask({required this.title, this.description});
  final String title;
  final String? description;

  @override
  bool operator ==(Object other) =>
      other is SharedTask && other.title == title && other.description == description;

  @override
  int get hashCode => Object.hash(title, description);
}

/// Maximum title length before the rest is pushed into the description.
///
/// Shared text is frequently a whole paragraph. Dropping all of it into the
/// title produces a task you cannot read in a list, and truncating it silently
/// loses the part that mattered — so the first line becomes the title and
/// everything else is kept as the detail.
const int kMaxSharedTitleLength = 120;

/// Split shared text into a title and an optional description.
///
/// Pure and separately tested: this is the part that decides what the user ends
/// up looking at, and it has to behave the same for a bare URL, a page title
/// plus URL, and a pasted paragraph.
SharedTask? parseSharedText(String? raw) {
  final text = raw?.trim();
  if (text == null || text.isEmpty) return null;

  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return null;

  final first = lines.first;
  final rest = lines.skip(1).join('\n').trim();

  // A first line short enough to read is the title; the remainder is detail.
  if (first.length <= kMaxSharedTitleLength) {
    return SharedTask(title: first, description: rest.isEmpty ? null : rest);
  }

  // One long run of text: cut at the last word boundary that fits so the title
  // stays readable, and keep the WHOLE original as the description rather than
  // only the tail — the split point is arbitrary and the user may want the lot.
  final head = first.substring(0, kMaxSharedTitleLength);
  final lastSpace = head.lastIndexOf(' ');
  final title = (lastSpace > kMaxSharedTitleLength ~/ 2 ? head.substring(0, lastSpace) : head).trim();
  return SharedTask(title: '$title…', description: text);
}

/// Bridges the Android share sheet to the app.
///
/// Cold start and warm share arrive by different routes (see MainActivity), so
/// both are funnelled into one stream the UI can listen to without caring which
/// happened.
class ShareIntentService {
  ShareIntentService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('focusflow/share');

  final MethodChannel _channel;
  final _controller = StreamController<SharedTask>.broadcast();

  Stream<SharedTask> get shares => _controller.stream;

  /// Start listening, and drain anything that arrived before Dart was ready.
  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') {
        final parsed = parseSharedText(call.arguments as String?);
        if (parsed != null) _controller.add(parsed);
      }
    });

    try {
      final initial = await _channel.invokeMethod<String>('getInitialSharedText');
      final parsed = parseSharedText(initial);
      if (parsed != null) _controller.add(parsed);
    } on MissingPluginException {
      // Running somewhere without the host side (tests, another platform).
    } catch (e) {
      debugPrint('[share] initial read failed: $e');
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller.close();
  }
}
