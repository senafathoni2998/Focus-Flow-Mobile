import '../core/api_client.dart';
import '../core/json.dart';
import '../models/chat_message.dart';

class ChatRepository {
  ChatRepository(this._api);
  final ApiClient _api;

  /// Send a turn. `history` is the prior transcript — the server keeps no
  /// conversation state, so it has to travel with each request.
  Future<ChatReply> send({
    required String message,
    required List<ChatMessage> history,
  }) async {
    final data = await _api.postJson('/chat', body: {
      'message': message,
      // Only completed turns: a pending or failed one has no assistant reply and
      // would leave the model reading a conversation that never happened.
      'history': history
          .where((m) => !m.pending && !m.failed)
          .map((m) => m.toHistoryJson())
          .toList(),
    });
    return ChatReply.fromJson(asMap(data));
  }
}
