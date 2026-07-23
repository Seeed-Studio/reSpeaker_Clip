/// Bookmark metadata stored on the device for a recording session.
class DeviceBookmark {
  /// Offset from the beginning of the recording, in seconds.
  final int offsetSeconds;

  /// Optional note attached to the bookmark.
  final String note;

  /// Original bookmark payload for firmware-specific fields.
  final Map<String, dynamic> raw;

  const DeviceBookmark({
    required this.offsetSeconds,
    required this.note,
    required this.raw,
  });

  Map<String, dynamic> toJson() => {
        'offset': offsetSeconds,
        'note': note,
      };
}

/// Result of `AT+MARK`.
class DeviceBookmarkMarkResult {
  /// Whether firmware acknowledged the mark.
  final bool ok;

  /// Session ID reported by firmware, if present.
  final String? sessionId;

  /// Total bookmark count after this mark, if present.
  final int? markCount;

  /// Offset from recording start, if present.
  final int? offsetSeconds;

  /// Original AT reply.
  final Map<String, dynamic> raw;

  const DeviceBookmarkMarkResult({
    required this.ok,
    required this.sessionId,
    required this.markCount,
    required this.offsetSeconds,
    required this.raw,
  });
}
