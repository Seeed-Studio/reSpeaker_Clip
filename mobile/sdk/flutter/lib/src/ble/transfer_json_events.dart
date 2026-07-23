/// Parsed BLE transfer JSON notify events (`file_complete`, `transfer_complete`).
sealed class TransferJsonEvent {
  const TransferJsonEvent();
}

final class TransferJsonFileComplete extends TransferJsonEvent {
  final String filename;
  final String sessionId;
  const TransferJsonFileComplete(this.filename, {this.sessionId = ''});
}

final class TransferJsonTransferComplete extends TransferJsonEvent {
  final int files;
  final String sessionId;
  const TransferJsonTransferComplete(this.files, {this.sessionId = ''});
}

final class TransferJsonOther extends TransferJsonEvent {
  final String event;
  const TransferJsonOther(this.event);
}

/// Parses AT JSON messages for legacy (non-framed) transfer notifications.
class TransferJsonEventParser {
  TransferJsonEventParser._();

  static int? parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  /// Some firmwares wrap the event inside `data`: `{"ok":true,"data":{"event":"..."}}`.
  static TransferJsonEvent? parse(Map<String, dynamic> msg) {
    final data = msg['data'];
    final dataMap = data is Map
        ? Map<String, dynamic>.from(data)
        : const <String, dynamic>{};
    final event = (msg['event'] ?? dataMap['event'] ?? '').toString();
    if (event.isEmpty) return null;
    final sessionId = (msg['session'] ??
            msg['session_id'] ??
            dataMap['session'] ??
            dataMap['session_id'] ??
            '')
        .toString()
        .trim();

    switch (event) {
      case 'file_complete':
        final filename =
            (msg['filename'] ?? dataMap['filename'] ?? '').toString();
        return TransferJsonFileComplete(filename, sessionId: sessionId);
      case 'transfer_complete':
        final files = parseInt(msg['files'] ?? dataMap['files']) ?? 0;
        return TransferJsonTransferComplete(files, sessionId: sessionId);
      default:
        return TransferJsonOther(event);
    }
  }
}

/// Policy helpers for ambiguous `transfer_complete(files=0)` during live record.
class TransferJsonTransferCompletePolicy {
  TransferJsonTransferCompletePolicy._();

  static bool looksLikeSessionComplete({
    required int fileCompleteCount,
    required int deviceTotalFiles,
    required int receivedBytes,
    required int deviceSessionBytes,
  }) {
    final haveAllSlices =
        deviceTotalFiles > 0 && fileCompleteCount >= deviceTotalFiles;
    final haveAllBytes = deviceSessionBytes > 0 &&
        receivedBytes >=
            (deviceSessionBytes - 2048).clamp(0, deviceSessionBytes);
    return haveAllSlices || haveAllBytes;
  }

  static bool shouldIgnoreEmptyTransferComplete({
    required int receivedBytes,
    required int files,
  }) =>
      receivedBytes == 0 && files == 0;
}
