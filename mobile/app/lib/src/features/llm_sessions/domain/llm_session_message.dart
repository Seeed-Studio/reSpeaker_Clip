class LlmSessionMessage {
  final int id;
  final String sessionId;
  final String role;
  final String content;
  final DateTime? createdAt;

  const LlmSessionMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.createdAt,
  });
}
