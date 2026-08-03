import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat_message.dart';
import '../../providers/chat_provider.dart';

/// The AI assistant.
///
/// Talks to POST /api/v1/chat, which runs the SAME core the web assistant does —
/// same prompt, same tools, same dispatch — with only the data layer swapped. It
/// can therefore create and complete tasks, adjust goals and check in habits, so
/// the controller refreshes the affected lists once a turn reports a tool call.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    // After the frame, or the new message has not been laid out yet and the
    // scroll lands short of it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _scrollToEnd();
    await ref.read(chatControllerProvider.notifier).send(text);
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatControllerProvider);
    final sending = ref.read(chatControllerProvider.notifier).isSending;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Assistant'),
        actions: [
          if (messages.isNotEmpty)
            IconButton(
              tooltip: 'Clear conversation',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => ref.read(chatControllerProvider.notifier).clear(),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? _Empty(scheme: scheme)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => _Bubble(message: messages[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Ask, or tell it what to do…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Disabled while a turn is in flight: the server keeps no
                  // conversation state, so a second send would race the first
                  // and be answered without it.
                  IconButton.filled(
                    onPressed: sending ? null : _send,
                    icon: sending
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'Ask about your tasks, or just say what you want done —\n'
              '"add buy milk tomorrow", "what\'s overdue?", "I read 20 more pages".',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.isUser;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: message.failed
              ? scheme.errorContainer
              : mine
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: message.pending
            ? const SizedBox(
                width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(message.content),
      ),
    );
  }
}
