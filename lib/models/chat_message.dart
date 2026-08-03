import '../core/json.dart';

/// One turn in the assistant conversation.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.pending = false,
    this.failed = false,
  });

  /// 'user' | 'assistant' — the two the API accepts in `history`.
  final String role;
  final String content;

  /// Shown while the reply is in flight.
  final bool pending;

  /// The send failed. Kept in the transcript rather than deleted, so the user
  /// can see what they typed instead of losing it to a dropped connection.
  final bool failed;

  bool get isUser => role == 'user';

  ChatMessage copyWith({String? content, bool? pending, bool? failed}) => ChatMessage(
        role: role,
        content: content ?? this.content,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
      );

  /// Only the fields the API reads. `pending`/`failed` are local UI state.
  Map<String, dynamic> toHistoryJson() => {'role': role, 'content': content};
}

/// What the assistant did, if anything, alongside its reply.
class ChatReply {
  const ChatReply({required this.message, this.functionName});

  final String message;

  /// The tool it invoked. Used to decide which caches to refresh — the
  /// assistant can create and complete tasks, so the lists it touched have to be
  /// re-read or the screen behind the chat goes stale.
  final String? functionName;

  factory ChatReply.fromJson(Map<String, dynamic> j) {
    final call = j['functionCall'];
    return ChatReply(
      message: asString(j['message'], 'Done.'),
      functionName: call is Map ? asStringOrNull(call['name']) : null,
    );
  }
}
