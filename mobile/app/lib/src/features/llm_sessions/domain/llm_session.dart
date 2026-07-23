import 'llm_session_message.dart';

class LlmSession {
  final String sessionId;
  final String title;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Optional: embedded messages for history sheet preview.
  /// - From `/api/v1/llm/sessions?include_messages=true`
  /// - Not stored in SQLite (in-memory only)
  final List<LlmSessionMessage>? messages;

  const LlmSession({
    required this.sessionId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messages,
  });

  LlmSession copyWith({
    String? sessionId,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<LlmSessionMessage>? messages,
  }) {
    return LlmSession(
      sessionId: sessionId ?? this.sessionId,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
    );
  }
}
