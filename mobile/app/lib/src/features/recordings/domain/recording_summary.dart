class RecordingSummaryVersion {
  final String id;
  final String recordingId;

  /// 1-based version number (V1, V2, ...)
  final int version;

  /// Display title, e.g. localized "Summary V2"
  final String title;
  final String content;
  final String? remoteSessionId;
  final int? remoteMessageId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const RecordingSummaryVersion({
    required this.id,
    required this.recordingId,
    required this.version,
    required this.title,
    required this.content,
    required this.remoteSessionId,
    required this.remoteMessageId,
    required this.createdAt,
    required this.updatedAt,
  });
}
