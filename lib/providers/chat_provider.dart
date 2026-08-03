import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import 'dashboard_provider.dart';
import 'goals_provider.dart';
import 'habits_provider.dart';
import 'providers.dart';
import 'tasks_provider.dart';

/// Tool names that change data the rest of the app is showing.
///
/// The assistant can create and complete tasks, adjust goals and check in
/// habits. Without refreshing afterwards, closing the chat would reveal a list
/// that contradicts what it just told you it did.
const _mutatingTools = {
  'createTask', 'updateTask', 'deleteTask',
  'createGoal', 'updateGoal', 'adjustGoalProgress', 'setGoalStatus', 'deleteGoal',
  'createHabit', 'checkInHabit', 'deleteHabit',
};

class ChatController extends StateNotifier<List<ChatMessage>> {
  ChatController(this._ref) : super(const []);

  final Ref _ref;
  bool _sending = false;

  bool get isSending => _sending;

  Future<void> send(String text) async {
    final message = text.trim();
    if (message.isEmpty || _sending) return;
    _sending = true;

    // The user's turn goes in immediately, plus a placeholder so the transcript
    // reads as a conversation rather than freezing until the reply lands.
    final history = List<ChatMessage>.from(state);
    state = [
      ...state,
      ChatMessage(role: 'user', content: message),
      const ChatMessage(role: 'assistant', content: '', pending: true),
    ];

    try {
      final reply = await _ref.read(chatRepositoryProvider).send(
            message: message,
            history: history,
          );
      state = [
        ...state.sublist(0, state.length - 1),
        ChatMessage(role: 'assistant', content: reply.message),
      ];
      if (reply.functionName != null && _mutatingTools.contains(reply.functionName)) {
        await _refreshTouched();
      }
    } catch (e) {
      // Keep the user's message visible and mark the reply as failed. Removing
      // the turn would lose what they typed to a dropped connection.
      state = [
        ...state.sublist(0, state.length - 1),
        ChatMessage(role: 'assistant', content: e.toString(), failed: true),
      ];
    } finally {
      _sending = false;
      // Nudge listeners so the send button re-enables.
      state = [...state];
    }
  }

  Future<void> _refreshTouched() async {
    // Cheap and broad on purpose: the reply names ONE tool, but a single turn can
    // cascade (completing a recurring task moves its date and can move a linked
    // goal's percent), so refreshing narrowly would still leave something stale.
    await Future.wait([
      _ref.read(tasksControllerProvider.notifier).refresh(),
      _ref.read(goalsControllerProvider.notifier).refresh(),
      _ref.read(habitsControllerProvider.notifier).refresh(),
      _ref.read(dashboardControllerProvider.notifier).refresh(),
    ]);
  }

  void clear() => state = const [];
}

final chatControllerProvider =
    StateNotifierProvider<ChatController, List<ChatMessage>>((ref) => ChatController(ref));
