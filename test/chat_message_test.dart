import 'package:flutter_test/flutter_test.dart';
import 'package:focusflow_mobile/models/chat_message.dart';

/// The server keeps no conversation state, so the transcript the client sends is
/// the model's entire memory of the exchange. Getting what goes in it wrong means
/// the assistant answers a conversation that never happened.
void main() {
  group('ChatMessage', () {
    test('sends only the fields the API reads', () {
      const m = ChatMessage(role: 'user', content: 'hi', pending: true, failed: true);
      // pending/failed are local UI state and have no meaning to the server.
      expect(m.toHistoryJson(), {'role': 'user', 'content': 'hi'});
    });

    test('knows which side it belongs on', () {
      expect(const ChatMessage(role: 'user', content: 'x').isUser, isTrue);
      expect(const ChatMessage(role: 'assistant', content: 'x').isUser, isFalse);
    });

    test('copyWith keeps the role, which decides how it is rendered and sent', () {
      const m = ChatMessage(role: 'assistant', content: '', pending: true);
      final done = m.copyWith(content: 'hello', pending: false);
      expect(done.role, 'assistant');
      expect(done.content, 'hello');
      expect(done.pending, isFalse);
    });
  });

  group('ChatReply', () {
    test('reads the reply text', () {
      expect(ChatReply.fromJson({'message': 'Done.'}).message, 'Done.');
    });

    test('falls back rather than showing an empty bubble', () {
      expect(ChatReply.fromJson({}).message, 'Done.');
    });

    test('surfaces the tool name, which decides what gets refreshed', () {
      // Without this the screen behind the chat would contradict what the
      // assistant just said it did.
      final r = ChatReply.fromJson({
        'message': 'Added it.',
        'functionCall': {'name': 'createTask'},
      });
      expect(r.functionName, 'createTask');
    });

    test('tolerates a turn with no tool call', () {
      expect(ChatReply.fromJson({'message': 'You have 3 tasks.'}).functionName, isNull);
    });

    test('tolerates a malformed functionCall instead of throwing mid-conversation', () {
      expect(ChatReply.fromJson({'message': 'x', 'functionCall': 'nope'}).functionName, isNull);
    });
  });
}
