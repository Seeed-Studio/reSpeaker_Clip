import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../at/at_transport.dart';
import '../ble/ble_client.dart';
import '../ble/clip_file_data.dart';
import '../ble/ble_transfer_frame_handler.dart';
import '../models/device.dart';
import '../models/device_bookmark.dart';
import '../models/device_file_meta.dart';
import '../utils/crc32.dart';
import '../utils/sdk_log.dart';
import 'device_event.dart';
import 'device_runtime_info.dart';
import 'device_status.dart';
import 'session_opus_parts_merge.dart';
import 'session_resume_markers.dart';

/// Result of [RecordingSession.start]: the session ID assigned by firmware
/// and the raw JSON in case the caller wants extra fields.
class RecordingStartInfo {
  /// Session ID returned by firmware. Use this with [RecordingSession.download]
  /// to fetch the recording later.
  final String sessionId;

  /// Recording mode echoed back by firmware (when reported).
  final RecordingMode? mode;

  /// Original reply, in case the caller wants vendor-specific extra fields.
  final Map<String, dynamic> raw;

  const RecordingStartInfo({
    required this.sessionId,
    required this.mode,
    required this.raw,
  });
}

/// Result of [RecordingSession.stop]: best-effort summary of the just-stopped
/// session.
class RecordingStopInfo {
  /// Session that was stopped. Some firmwares return it on STOP; otherwise we
  /// echo the [RecordingSession.activeSessionId] cached locally.
  final String? sessionId;

  /// Reported duration in seconds, when available.
  final int? durationSeconds;

  /// Reported total file count for the session, when available.
  final int? fileCount;

  /// Original reply.
  final Map<String, dynamic> raw;

  const RecordingStopInfo({
    required this.sessionId,
    required this.durationSeconds,
    required this.fileCount,
    required this.raw,
  });
}

/// Result of a recording control command such as `AT+PAUSE` / `AT+RESUME`.
class RecordingControlInfo {
  /// Session affected by the control command, when reported.
  final String? sessionId;

  /// Duration in seconds reported by firmware, when available.
  final int? durationSeconds;

  /// Original reply.
  final Map<String, dynamic> raw;

  const RecordingControlInfo({
    required this.sessionId,
    required this.durationSeconds,
    required this.raw,
  });

  /// Best-effort parser for pause/resume replies.
  factory RecordingControlInfo.fromAtReply(Map<String, dynamic> resp) {
    final data = resp['data'];
    final dataMap =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final sessionId = RecordingSession._firstString(
      dataMap,
      resp,
      const ['session', 'session_id'],
    );
    return RecordingControlInfo(
      sessionId: sessionId,
      durationSeconds: RecordingSession._asInt(
        dataMap['duration'] ??
            dataMap['duration_s'] ??
            resp['duration'] ??
            resp['duration_s'],
      ),
      raw: resp,
    );
  }
}

/// One event during an `AT+DOWNLOAD` flow.
sealed class DownloadEvent {
  const DownloadEvent();
}

/// `AT+DOWNLOAD` was acknowledged by firmware; bytes are about to flow.
final class DownloadStarted extends DownloadEvent {
  final String sessionId;
  final int? totalFiles;
  final int? totalBytes;
  const DownloadStarted({
    required this.sessionId,
    required this.totalFiles,
    required this.totalBytes,
  });
}

/// A FILE_START frame: a new file is beginning in this transfer.
final class DownloadFileStarted extends DownloadEvent {
  final String filename;
  final int fileSize;
  const DownloadFileStarted({
    required this.filename,
    required this.fileSize,
  });
}

/// Progress update for the current file. [received] is bytes received for the
/// current file so far; [total] is the expected size (or `-1` if unknown).
final class DownloadFileProgress extends DownloadEvent {
  final String filename;
  final int received;
  final int total;
  const DownloadFileProgress({
    required this.filename,
    required this.received,
    required this.total,
  });
}

/// A complete file has been received.
final class DownloadFileCompleted extends DownloadEvent {
  final String filename;
  final Uint8List bytes;
  final int crc32;
  const DownloadFileCompleted({
    required this.filename,
    required this.bytes,
    required this.crc32,
  });
}

/// The whole transfer is complete (`TRANSFER_DONE` frame).
final class DownloadTransferDone extends DownloadEvent {
  final String sessionId;
  final int fileCount;
  const DownloadTransferDone({
    required this.sessionId,
    required this.fileCount,
  });
}

enum DownloadStartFailureKind {
  sessionNotFound,
  transferBusy,
  other,
}

extension DownloadStartFailureKindX on DownloadStartFailureKind {
  static DownloadStartFailureKind fromAtReply(Map<String, dynamic> resp) {
    final detail = RecordingSession._errorDetail(resp).toLowerCase();
    if (detail.contains('session not found') ||
        detail.contains('file not found') ||
        detail.contains('not found')) {
      return DownloadStartFailureKind.sessionNotFound;
    }
    if (detail.contains('transfer already in progress') ||
        detail.contains('already in progress') ||
        detail.contains('busy')) {
      return DownloadStartFailureKind.transferBusy;
    }
    return DownloadStartFailureKind.other;
  }
}

/// Retry behavior for the `AT+DOWNLOAD` command before file bytes start.
class DownloadStartRetryPolicy {
  /// Number of `AT+DOWNLOAD` attempts. Must be >= 1.
  final int maxAttempts;

  /// Delay between retry attempts.
  final Duration retryDelay;

  /// Retry transient "session/file not found" responses.
  final bool retrySessionNotFound;

  /// Send `AT+CANCEL` before retrying when firmware reports an active transfer.
  final bool cancelBusyTransfer;

  /// Avoid `AT+CANCEL` when `AT+GSTAT` says the device is recording/paused.
  final bool skipCancelWhenDeviceRecording;

  /// Timeout for the best-effort `AT+CANCEL`.
  final Duration cancelTimeout;

  /// Settle time after `AT+CANCEL` before retrying `AT+DOWNLOAD`.
  final Duration cancelSettleDelay;

  /// Timeout for the optional `AT+GSTAT` recording-state check.
  final Duration statusTimeout;

  const DownloadStartRetryPolicy({
    this.maxAttempts = 1,
    this.retryDelay = const Duration(milliseconds: 800),
    this.retrySessionNotFound = true,
    this.cancelBusyTransfer = false,
    this.skipCancelWhenDeviceRecording = true,
    this.cancelTimeout = const Duration(seconds: 5),
    this.cancelSettleDelay = const Duration(milliseconds: 1200),
    this.statusTimeout = const Duration(seconds: 4),
  });

  const DownloadStartRetryPolicy.resilient({
    this.maxAttempts = 4,
    this.retryDelay = const Duration(milliseconds: 800),
    this.retrySessionNotFound = true,
    this.cancelBusyTransfer = true,
    this.skipCancelWhenDeviceRecording = true,
    this.cancelTimeout = const Duration(seconds: 5),
    this.cancelSettleDelay = const Duration(milliseconds: 1200),
    this.statusTimeout = const Duration(seconds: 4),
  });

  bool shouldRetry(DownloadStartFailureKind kind) {
    return switch (kind) {
      DownloadStartFailureKind.sessionNotFound => retrySessionNotFound,
      DownloadStartFailureKind.transferBusy => cancelBusyTransfer,
      DownloadStartFailureKind.other => false,
    };
  }
}

/// A single file downloaded from the device.
class DownloadedFileArtifact {
  final String filename;
  final String path;
  final int sizeBytes;
  final int crc32;

  const DownloadedFileArtifact({
    required this.filename,
    required this.path,
    required this.sizeBytes,
    required this.crc32,
  });
}

/// Result of [RecordingSession.downloadToDirectory].
class DownloadSessionResult {
  final String sessionId;
  final String directory;
  final int? totalFiles;
  final int? totalBytes;
  final int completedFiles;
  final int completedBytes;
  final DownloadTransferDone? transferDone;
  final List<DownloadedFileArtifact> files;

  const DownloadSessionResult({
    required this.sessionId,
    required this.directory,
    required this.totalFiles,
    required this.totalBytes,
    required this.completedFiles,
    required this.completedBytes,
    required this.transferDone,
    required this.files,
  });

  bool get isComplete =>
      transferDone != null &&
      (totalFiles == null || completedFiles >= totalFiles!);
}

/// Result of downloading and merging a session into a single file.
class DownloadMergeResult {
  final DownloadSessionResult download;
  final String mergedPath;
  final int mergedBytes;
  final bool deletedRemoteSession;
  final bool deletedLocalParts;

  const DownloadMergeResult({
    required this.download,
    required this.mergedPath,
    required this.mergedBytes,
    required this.deletedRemoteSession,
    required this.deletedLocalParts,
  });
}

/// Result of merging a session and collecting bookmarks.
class DownloadFinalizeResult {
  final DownloadMergeResult merge;
  final List<DeviceBookmark> bookmarks;
  final String? bookmarksPath;
  final bool bookmarksSaved;

  const DownloadFinalizeResult({
    required this.merge,
    required this.bookmarks,
    required this.bookmarksPath,
    required this.bookmarksSaved,
  });

  String get mergedPath => merge.mergedPath;
  int get mergedBytes => merge.mergedBytes;
  bool get deletedRemoteSession => merge.deletedRemoteSession;
  bool get deletedLocalParts => merge.deletedLocalParts;
}

/// Wraps the common recording workflow:
///   1. `AT+START` → device records
///   2. `AT+STOP`  → device finishes the session and reports duration/files
///   3. `AT+LIST`  → enumerate files on device
///   4. `AT+DOWNLOAD` → pull file bytes over the file-data notify channel
///
/// Construct one [RecordingSession] per BLE connection; it is reusable for
/// multiple start/stop cycles.
class RecordingSession {
  final SenseCraftVoiceConnection connection;
  final AtTransport at;

  RecordingSession({required this.connection, required this.at});

  /// Session ID currently in progress on the device (between
  /// [start] and [stop]). `null` when idle.
  String? get activeSessionId => _activeSessionId;
  String? _activeSessionId;

  /// Broadcast stream of typed unsolicited events from the device, parsed
  /// from `at.jsonMessages`.
  ///
  /// Use this to react to the firmware's button-driven actions described in
  /// `py_test/docs/protocol.md` Appendix E:
  /// - Long-press start/stop emits a [DeviceRecordingStateEvent] with
  ///   `state: RECORDING` or `state: IDLE`.
  /// - Short-press during recording adds a bookmark and emits a
  ///   [DeviceBookmarkEvent].
  ///
  /// AT command responses **without** an `event` field are filtered out.
  /// The stream is broadcast — multiple listeners are supported and
  /// late-attached listeners only see events from the moment they subscribe.
  Stream<DeviceEvent> get deviceEvents => at.jsonMessages
      .map(parseDeviceEvent)
      .where((e) => e != null)
      .cast<DeviceEvent>();

  /// Start a new recording.
  Future<RecordingStartInfo> start({
    RecordingMode mode = RecordingMode.normal,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final cmd =
        mode == RecordingMode.enhanced ? 'AT+START=enhanced' : 'AT+START';
    final resp = await at.send(cmd, timeout: timeout);
    if (resp['ok'] != true) {
      throw RecordingException(
        'AT+START failed: ${_errorDetail(resp)}',
        raw: resp,
      );
    }
    final sid = _extractSession(resp);
    if (sid == null || sid.isEmpty) {
      throw RecordingException('AT+START did not return a session', raw: resp);
    }
    _activeSessionId = sid;
    final reportedMode = _extractRecordingMode(resp);
    SdkLog.i('RecordingSession started: session=$sid mode=$mode');
    return RecordingStartInfo(
      sessionId: sid,
      mode: reportedMode ?? mode,
      raw: resp,
    );
  }

  /// Stop the active recording.
  Future<RecordingStopInfo> stop({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final resp = await at.send('AT+STOP', timeout: timeout);
    final sid = _extractSession(resp) ?? _activeSessionId;
    final data = resp['data'];
    final m =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final dur = _asInt(m['duration']);
    final fileCount = _asInt(m['file_count']);
    _activeSessionId = null;
    SdkLog.i(
      'RecordingSession stopped: session=$sid duration=${dur}s files=$fileCount',
    );
    return RecordingStopInfo(
      sessionId: sid,
      durationSeconds: dur,
      fileCount: fileCount,
      raw: resp,
    );
  }

  /// Pause the active recording (`AT+PAUSE`).
  Future<RecordingControlInfo> pause({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resp = await at.send('AT+PAUSE', timeout: timeout);
    if (resp['ok'] != true) {
      throw RecordingException(
        'AT+PAUSE failed: ${_errorDetail(resp)}',
        raw: resp,
      );
    }
    return RecordingControlInfo.fromAtReply(resp);
  }

  /// Resume a paused recording (`AT+RESUME`).
  Future<RecordingControlInfo> resume({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resp = await at.send('AT+RESUME', timeout: timeout);
    if (resp['ok'] != true) {
      throw RecordingException(
        'AT+RESUME failed: ${_errorDetail(resp)}',
        raw: resp,
      );
    }
    final info = RecordingControlInfo.fromAtReply(resp);
    if (info.sessionId != null && info.sessionId!.isNotEmpty) {
      _activeSessionId = info.sessionId;
    }
    return info;
  }

  /// Cancel any in-flight recording **or** transfer. Best-effort — failures
  /// are logged and ignored.
  Future<void> cancel() async {
    try {
      await at.send('AT+CANCEL', timeout: const Duration(seconds: 4));
    } catch (e, st) {
      SdkLog.w('RecordingSession.cancel: AT+CANCEL failed', e, st);
    }
    _activeSessionId = null;
  }

  /// Query the device's global status (`AT+GSTAT`).
  Future<DeviceStatus> getStatus({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resp = await at.send('AT+GSTAT', timeout: timeout);
    if (resp['ok'] != true) {
      throw RecordingException(
        'AT+GSTAT failed: ${_errorDetail(resp)}',
        raw: resp,
      );
    }
    return DeviceStatus.fromAtReply(resp);
  }

  /// Read common runtime information from the connected device.
  ///
  /// This is intentionally best-effort: a timeout or unsupported command fills
  /// only the fields that could be read instead of failing the whole snapshot.
  Future<DeviceRuntimeInfo> readRuntimeInfo({
    Duration versionTimeout = const Duration(seconds: 5),
    Duration timeTimeout = const Duration(seconds: 4),
    Duration statusTimeout = const Duration(seconds: 4),
    Duration pairTimeout = const Duration(seconds: 6),
  }) async {
    Map<String, dynamic>? versionReply;
    Map<String, dynamic>? timeReply;
    Map<String, dynamic>? statusReply;
    Map<String, dynamic>? pairReply;

    String? firmware;
    Object? rawDeviceTime;
    DeviceStatus? status;
    String? pairStatus;
    String? pairAddress;

    try {
      versionReply = await at.send('AT+VERSION', timeout: versionTimeout);
      if (versionReply['ok'] == true) {
        firmware = _extractRootOrDataString(
          versionReply,
          const ['firmware', 'firmware_version', 'version'],
        );
      }
    } catch (e, st) {
      SdkLog.w('RecordingSession.readRuntimeInfo: AT+VERSION failed', e, st);
    }

    try {
      timeReply = await at.send('AT+TIME?', timeout: timeTimeout);
      if (timeReply['ok'] == true) {
        rawDeviceTime = _extractRootOrDataValue(
          timeReply,
          const ['time', 'timestamp', 'ts'],
        );
      }
    } catch (e, st) {
      SdkLog.w('RecordingSession.readRuntimeInfo: AT+TIME? failed', e, st);
    }

    try {
      statusReply = await at.send('AT+GSTAT', timeout: statusTimeout);
      if (statusReply['ok'] == true) {
        status = DeviceStatus.fromAtReply(statusReply);
        firmware ??= status.firmwareVersion;
      }
    } catch (e, st) {
      SdkLog.w('RecordingSession.readRuntimeInfo: AT+GSTAT failed', e, st);
    }

    try {
      pairReply = await at.send('AT+PAIR?', timeout: pairTimeout);
      if (pairReply['ok'] == true) {
        pairStatus = _extractRootOrDataString(
          pairReply,
          const ['value', 'status', 'pair_status', 'state'],
        );
        pairAddress = _extractRootOrDataString(
          pairReply,
          const ['addr', 'address', 'peer', 'peer_addr'],
        );
      }
    } on TimeoutException catch (e) {
      SdkLog.i('RecordingSession.readRuntimeInfo: AT+PAIR? timeout: $e');
    } catch (e, st) {
      SdkLog.w('RecordingSession.readRuntimeInfo: AT+PAIR? failed', e, st);
    }

    return DeviceRuntimeInfo(
      firmwareVersion: firmware,
      rawDeviceTime: rawDeviceTime,
      deviceTime: parseDeviceAtTime(rawDeviceTime),
      status: status,
      pairStatus: pairStatus,
      pairAddress: pairAddress,
      versionReply: versionReply,
      timeReply: timeReply,
      statusReply: statusReply,
      pairReply: pairReply,
    );
  }

  DateTime? _lastDeviceTimeSyncAt;

  /// Align the device RTC to [time] using `AT+TIME=<unix_seconds>`.
  ///
  /// Returns `true` only when firmware acknowledges the command. Set
  /// [minInterval] to throttle repeated syncs in SDK clients; pass
  /// [force] to skip that throttle.
  Future<bool> syncDeviceTime({
    DateTime? time,
    Duration timeout = const Duration(seconds: 4),
    Duration minInterval = Duration.zero,
    bool force = false,
  }) async {
    if (!force &&
        minInterval > Duration.zero &&
        _lastDeviceTimeSyncAt != null &&
        DateTime.now().difference(_lastDeviceTimeSyncAt!) < minInterval) {
      return false;
    }

    final ts = (time ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    try {
      final resp = await at.send('AT+TIME=$ts', timeout: timeout);
      final ok = resp['ok'] == true;
      if (ok) _lastDeviceTimeSyncAt = DateTime.now();
      return ok;
    } catch (e, st) {
      SdkLog.w('RecordingSession.syncDeviceTime failed', e, st);
      return false;
    }
  }

  /// Reset device-side pairing information (`AT+PAIR=reset`).
  ///
  /// Apps should still clear the phone-side bond / system Bluetooth pairing
  /// when their platform allows it.
  Future<bool> resetPairing({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final resp = await at.send('AT+PAIR=reset', timeout: timeout);
    return resp['ok'] == true;
  }

  /// Maximum byte length the firmware accepts for `AT+NAME=<value>` payload.
  /// Aligned with `py_test/docs/protocol.md` 3.3.7 AT+NAME validation rules
  /// (1–32 characters, printable UTF-8). Apps should validate user input
  /// before calling [setUserDeviceName] to surface rejections inline.
  static const int userDeviceNameMaxBytes = 32;

  /// Sentinel value defined by the protocol to clear the user-defined name.
  /// `AT+NAME=CLEAR` resets the persisted name on the device to empty.
  static const String userDeviceNameClearToken = 'CLEAR';

  /// Returns `true` when [name] is acceptable to send via [setUserDeviceName]
  /// without using the [userDeviceNameClearToken] escape.
  ///
  /// Per `protocol.md` 3.3.7:
  /// - 1–32 UTF-8 bytes (CJK counts as 3 bytes each)
  /// - No control characters (0x00–0x1F)
  /// - Empty string is rejected — use `setUserDeviceName(null)` to clear
  static bool isValidUserDeviceName(String name) {
    if (name.isEmpty) return false;
    final bytes = name.codeUnits;
    if (bytes.length > userDeviceNameMaxBytes) return false;
    for (final c in name.runes) {
      if (c < 0x20) return false;
    }
    return true;
  }

  /// Read the user-defined device name persisted on the device
  /// (`AT+NAME?`).
  ///
  /// Returns an empty string when no name is set. Throws
  /// [RecordingException] when the firmware reports `ok:false`.
  Future<String> getUserDeviceName({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final resp = await at.send('AT+NAME?', timeout: timeout);
    if (resp['ok'] != true) {
      throw RecordingException(
        'AT+NAME? failed: ${_errorDetail(resp)}',
        raw: resp,
      );
    }
    final data = resp['data'];
    if (data is Map) {
      final m = Map<String, dynamic>.from(data);
      final n = m['name'];
      if (n is String) return n;
      if (n != null) return n.toString();
    }
    // Some firmwares return the value at the root.
    final root = resp['name'] ?? resp['value'];
    if (root is String) return root;
    if (root != null) return root.toString();
    return '';
  }

  /// Persist a user-defined name on the device (`AT+NAME=<value>` /
  /// `AT+NAME=CLEAR`). Survives reboots and does not affect BLE / WiFi
  /// advertising names.
  ///
  /// Pass `null` (or empty string) to clear the stored name. Validates
  /// against the protocol rules first; throws [ArgumentError] for inputs
  /// that the firmware would reject. Throws [RecordingException] when the
  /// firmware itself returns `ok:false`.
  Future<void> setUserDeviceName(
    String? name, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String cmd;
    if (name == null || name.isEmpty) {
      cmd = 'AT+NAME=$userDeviceNameClearToken';
    } else {
      if (!isValidUserDeviceName(name)) {
        throw ArgumentError.value(
          name,
          'name',
          'AT+NAME requires 1-32 UTF-8 chars, no control characters '
              '(use null or "" to clear).',
        );
      }
      cmd = 'AT+NAME=$name';
    }
    final resp = await at.send(cmd, timeout: timeout);
    if (resp['ok'] != true) {
      throw RecordingException(
        'AT+NAME failed: ${_errorDetail(resp)}',
        raw: resp,
      );
    }
  }

  /// Add a bookmark at the current recording position (`AT+MARK`).
  ///
  /// The device may also emit a [DeviceBookmarkEvent] on [deviceEvents].
  Future<DeviceBookmarkMarkResult> mark({
    String? note,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final trimmedNote = note?.trim();
    final cmd = trimmedNote != null && trimmedNote.isNotEmpty
        ? 'AT+MARK=$trimmedNote'
        : 'AT+MARK';
    final resp = await at.send(cmd, timeout: timeout);
    final dataMap = _dataMap(resp);
    return DeviceBookmarkMarkResult(
      ok: resp['ok'] == true,
      sessionId: _firstString(dataMap, resp, const ['session', 'session_id']),
      markCount: _asInt(dataMap['mark_count'] ??
          resp['mark_count'] ??
          dataMap['count'] ??
          resp['count']),
      offsetSeconds: _asInt(dataMap['offset'] ?? resp['offset']),
      raw: resp,
    );
  }

  /// List recording files on the device. When [sessionId] is `null`, returns
  /// every file the firmware reports.
  Future<List<DeviceFileMeta>> listFiles({
    String? sessionId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final cmd = sessionId == null ? 'AT+LIST' : 'AT+LIST=$sessionId';
    final resp = await at.send(cmd, timeout: timeout);
    if (resp['ok'] != true) {
      throw RecordingException(
        'AT+LIST failed: ${_errorDetail(resp)}',
        raw: resp,
      );
    }
    return _parseFileList(resp);
  }

  /// Page through every device file using `AT+LIST` pagination.
  ///
  /// `listFiles()` intentionally keeps its historical single-request behavior;
  /// use this helper when a host app wants the complete device index.
  Future<List<DeviceFileMeta>> listAllFiles({
    int perPage = 10,
    int maxPages = 100,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final out = <DeviceFileMeta>[];
    for (var page = 1; page <= maxPages; page++) {
      final cmd = page == 1 ? 'AT+LIST' : 'AT+LIST?$page&$perPage';
      final resp = await at.send(cmd, timeout: timeout);
      if (resp['ok'] != true) {
        throw RecordingException(
          'AT+LIST failed: ${_errorDetail(resp)}',
          raw: resp,
        );
      }
      final items = _parseFileList(resp);
      out.addAll(items);
      final total = _extractTotal(resp);
      if (items.isEmpty || (total != null && out.length >= total)) break;
    }
    return out;
  }

  /// Read all bookmarks for [sessionId] using `AT+MARKS` pagination.
  ///
  /// Older firmware that does not support pagination is handled by falling
  /// back to `AT+MARKS=<sessionId>` on the first page.
  Future<List<DeviceBookmark>> listBookmarks({
    required String sessionId,
    int perPage = 10,
    int maxPages = 100,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final bookmarks = <DeviceBookmark>[];
    for (var page = 1; page <= maxPages; page++) {
      final cmd = 'AT+MARKS=$sessionId?$page&$perPage';
      var resp = await at.send(cmd, timeout: timeout);
      if (resp['ok'] != true && page == 1) {
        resp = await at.send('AT+MARKS=$sessionId', timeout: timeout);
      }
      if (resp['ok'] != true) {
        throw RecordingException(
          'AT+MARKS failed: ${_errorDetail(resp)}',
          raw: resp,
        );
      }
      final items = _bookmarkItems(resp);
      bookmarks.addAll(items.map(_parseBookmark));
      final total = _extractTotal(resp) ?? bookmarks.length;
      if (items.isEmpty || bookmarks.length >= total) break;
    }
    return bookmarks;
  }

  /// Delete a completed session from the device (`AT+DELETE=<sessionId>`).
  ///
  /// Call this only after the host has durably stored or uploaded the recording.
  Future<bool> deleteSession({
    required String sessionId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final resp = await at.send('AT+DELETE=$sessionId', timeout: timeout);
    return resp['ok'] == true;
  }

  /// Canonicalise expected session size by preferring device-reported totals
  /// when the DB snapshot looks stale.
  static int? canonicalTransferExpectedBytes({
    int? dbExpected,
    required int transferredTotal,
  }) {
    if (transferredTotal <= 0) return dbExpected;
    if (dbExpected == null || dbExpected <= 0) return transferredTotal;
    if (dbExpected > (transferredTotal * 1.05).round()) {
      return transferredTotal;
    }
    return dbExpected;
  }

  /// True when a merged file is complete enough to let the SDK erase the
  /// source session on firmware.
  static bool localMergedFileCompleteForDelete({
    required int actualSize,
    int? expectedBytes,
    int? verifiedBytes,
    double minCompletionRatio = 0.95,
  }) {
    if (actualSize <= 0) return false;
    if (minCompletionRatio <= 0 || minCompletionRatio > 1) {
      throw ArgumentError.value(
        minCompletionRatio,
        'minCompletionRatio',
        'Must be between 0 and 1.',
      );
    }
    final exp = expectedBytes ?? 0;
    if (exp > 0) {
      return actualSize >= (exp * minCompletionRatio).round();
    }
    final verified = verifiedBytes ?? 0;
    if (verified > 0) {
      return actualSize >= (verified * minCompletionRatio).round();
    }
    return false;
  }

  /// Best-effort `AT+DELETE` that first checks the merged file is complete
  /// enough and the device is not still recording the same session root.
  ///
  /// Returns `true` only when the remote delete was acknowledged. Any missing
  /// file, incomplete merge, busy recording state or transport failure is
  /// treated as a non-fatal `false`.
  Future<bool> deleteSessionAfterLocalVerification({
    required String sessionId,
    required String mergedPath,
    int? expectedBytes,
    int? verifiedBytes,
    Duration timeout = const Duration(seconds: 8),
    Duration statusTimeout = const Duration(seconds: 5),
    double minCompletionRatio = 0.95,
  }) async {
    try {
      final mergedFile = File(mergedPath);
      final exists = await mergedFile.exists();
      final actualSize = exists ? await mergedFile.length() : 0;
      final sizeOk = localMergedFileCompleteForDelete(
        actualSize: actualSize,
        expectedBytes: expectedBytes,
        verifiedBytes: verifiedBytes,
        minCompletionRatio: minCompletionRatio,
      );
      if (!(exists && sizeOk && actualSize > 0)) {
        return false;
      }

      final status = await getStatus(timeout: statusTimeout);
      final activeRoot = _sessionRoot(status.sessionId);
      final ourRoot = _sessionRoot(sessionId);
      if (status.state == 'recording' &&
          activeRoot.isNotEmpty &&
          ourRoot == activeRoot) {
        return false;
      }

      return await deleteSession(sessionId: sessionId, timeout: timeout);
    } catch (e, st) {
      SdkLog.w(
          'RecordingSession.deleteSessionAfterLocalVerification failed', e, st);
      return false;
    }
  }

  /// Stream events for an `AT+DOWNLOAD` flow.
  ///
  /// - Sends `AT+DOWNLOAD=$sessionId[:startFile]`.
  /// - Listens to the file-data notify characteristic for FILE_START / DATA /
  ///   FILE_END / TRANSFER_DONE frames.
  /// - Buffers raw DATA bytes per file and emits [DownloadFileCompleted] with
  ///   the full payload when the firmware sends FILE_END.
  ///
  /// The stream completes after [DownloadTransferDone] or on timeout / error.
  /// Cancelling the subscription does **not** send `AT+CANCEL` automatically;
  /// call [cancel] yourself if you need that.
  Stream<DownloadEvent> download({
    required String sessionId,
    String? startFile,
    Duration timeout = const Duration(minutes: 10),
    Duration startCommandTimeout = const Duration(seconds: 10),
    DownloadStartRetryPolicy retryPolicy = const DownloadStartRetryPolicy(),
  }) {
    final controller = StreamController<DownloadEvent>();

    String? currentFile;
    int currentExpected = 0;
    final fileBuf = BytesBuilder(copy: false);

    StreamSubscription<List<int>>? framesSub;
    Timer? timeoutTimer;

    Future<void> closeOnDone(Object? error, [StackTrace? st]) async {
      timeoutTimer?.cancel();
      await framesSub?.cancel();
      framesSub = null;
      if (controller.isClosed) return;
      if (error != null) {
        controller.addError(error, st);
      }
      await controller.close();
    }

    controller.onListen = () async {
      try {
        framesSub = at.fileDataBytes.listen((bytes) {
          final frame = parseClipFileDataNotify(bytes);
          switch (frame) {
            case ClipParsedFileStart():
              currentFile = frame.filename;
              currentExpected = frame.fileSize;
              fileBuf.clear();
              controller.add(DownloadFileStarted(
                filename: frame.filename,
                fileSize: frame.fileSize,
              ));
              break;
            case ClipParsedData():
              if (currentFile == null) {
                // Pre-FILE_START data is dropped; legacy firmwares without
                // FILE_START frames should use the raw `at.fileDataBytes`
                // stream directly.
                return;
              }
              fileBuf.add(frame.payload);
              controller.add(DownloadFileProgress(
                filename: currentFile!,
                received: fileBuf.length,
                total: currentExpected,
              ));
              break;
            case ClipParsedFileEnd():
              final fname = currentFile ?? '';
              final payload = fileBuf.toBytes();
              controller.add(DownloadFileCompleted(
                filename: fname,
                bytes: payload,
                crc32: frame.crc32,
              ));
              currentFile = null;
              currentExpected = 0;
              fileBuf.clear();
              break;
            case ClipParsedTransferDone():
              controller.add(DownloadTransferDone(
                sessionId: frame.sessionId,
                fileCount: frame.fileCount,
              ));
              unawaited(closeOnDone(null));
              break;
            case ClipParsedRaw():
              // Legacy / unknown frame — surface as completed file with empty
              // crc when we have a buffer; otherwise ignore so we don't pollute
              // the event stream.
              if (currentFile != null) {
                fileBuf.add(frame.bytes);
              }
              break;
            case ClipParsedInvalid():
              SdkLog.w(
                'RecordingSession.download: malformed file frame: ${frame.reason}',
              );
              break;
          }
        }, onError: (Object e, StackTrace st) {
          unawaited(closeOnDone(e, st));
        });

        timeoutTimer = Timer(timeout, () {
          unawaited(closeOnDone(
            TimeoutException('Download stalled', timeout),
            StackTrace.current,
          ));
        });

        final cmd = (startFile != null && startFile.trim().isNotEmpty)
            ? 'AT+DOWNLOAD=$sessionId:${startFile.trim()}'
            : 'AT+DOWNLOAD=$sessionId';
        final resp = await _sendDownloadStartWithRetry(
          cmd,
          timeout: startCommandTimeout,
          policy: retryPolicy,
        );
        if (resp['ok'] != true) {
          await closeOnDone(RecordingException(
            'AT+DOWNLOAD failed: ${_errorDetail(resp)}',
            raw: resp,
            code: DownloadStartFailureKindX.fromAtReply(resp).name,
          ));
          return;
        }
        final dataMap = resp['data'] is Map
            ? Map<String, dynamic>.from(resp['data'] as Map)
            : const <String, dynamic>{};
        controller.add(DownloadStarted(
          sessionId: sessionId,
          totalFiles: _asInt(dataMap['files'] ?? dataMap['file_count']),
          totalBytes: _asInt(dataMap['bytes'] ?? dataMap['size']),
        ));
      } catch (e, st) {
        await closeOnDone(e, st);
      }
    };

    controller.onCancel = () async {
      timeoutTimer?.cancel();
      await framesSub?.cancel();
    };

    return controller.stream;
  }

  /// Download one session directly into [directory].
  ///
  /// This convenience wrapper writes each completed file to disk and returns a
  /// summary of the session. It intentionally stays simpler than the app's
  /// full transfer pipeline: if you need DB merge / retry orchestration, build
  /// that above the SDK.
  Future<DownloadSessionResult> downloadToDirectory({
    required String sessionId,
    required String directory,
    String? startFile,
    Duration timeout = const Duration(minutes: 10),
    Duration startCommandTimeout = const Duration(seconds: 10),
    DownloadStartRetryPolicy retryPolicy =
        const DownloadStartRetryPolicy.resilient(),
    bool createDirectory = true,
    bool verifyCrc = true,
  }) async {
    final dir = Directory(directory);
    if (createDirectory && !await dir.exists()) {
      await dir.create(recursive: true);
    }

    final files = <DownloadedFileArtifact>[];
    int? downloadTotalFiles;
    int? downloadTotalBytes;
    var completedFiles = 0;
    var completedBytes = 0;
    DownloadTransferDone? transferDone;

    final stream = download(
      sessionId: sessionId,
      startFile: startFile,
      timeout: timeout,
      startCommandTimeout: startCommandTimeout,
      retryPolicy: retryPolicy,
    );

    try {
      await for (final event in stream) {
        switch (event) {
          case DownloadStarted(
              totalFiles: final reportedTotalFiles,
              totalBytes: final reportedTotalBytes,
            ):
            downloadTotalFiles = reportedTotalFiles;
            downloadTotalBytes = reportedTotalBytes;
            break;
          case DownloadFileCompleted(
              :final filename,
              :final bytes,
              :final crc32,
            ):
            final safe = _safeDownloadFilename(
              filename,
              fallbackIndex: completedFiles + 1,
            );
            final outPath = p.join(directory, safe);
            if (verifyCrc) {
              final localCrc = crc32Ieee(bytes);
              if (localCrc != crc32) {
                try {
                  await File(outPath).delete();
                } catch (_) {}
                throw RecordingException(
                  'Downloaded file CRC mismatch for $safe '
                  '(local=0x${localCrc.toRadixString(16)}, '
                  'device=0x${crc32.toRadixString(16)})',
                );
              }
            }
            await File(outPath).writeAsBytes(bytes, flush: true);
            final artifact = DownloadedFileArtifact(
              filename: safe,
              path: outPath,
              sizeBytes: bytes.length,
              crc32: crc32,
            );
            files.add(artifact);
            completedFiles++;
            completedBytes += bytes.length;
            break;
          case DownloadTransferDone(:final sessionId, :final fileCount):
            transferDone = DownloadTransferDone(
              sessionId: sessionId,
              fileCount: fileCount,
            );
            break;
          case DownloadFileStarted():
          case DownloadFileProgress():
            break;
        }
      }
    } catch (_) {
      await cancel();
      rethrow;
    }

    return DownloadSessionResult(
      sessionId: sessionId,
      directory: directory,
      totalFiles: downloadTotalFiles,
      totalBytes: downloadTotalBytes,
      completedFiles: completedFiles,
      completedBytes: completedBytes,
      transferDone: transferDone,
      files: files,
    );
  }

  /// Download with resume support against an existing output directory.
  ///
  /// On each attempt the SDK re-scans [directory] for completed slices and
  /// derives the next `AT+DOWNLOAD` resume point from disk + [dbReceivedBytes].
  Future<DownloadSessionResult> downloadToDirectoryWithResume({
    required String sessionId,
    required String directory,
    String? startFile,
    int dbReceivedBytes = 0,
    int maxAttempts = 3,
    Duration timeout = const Duration(minutes: 10),
    Duration startCommandTimeout = const Duration(seconds: 10),
    DownloadStartRetryPolicy retryPolicy =
        const DownloadStartRetryPolicy.resilient(),
    bool createDirectory = true,
    bool verifyCrc = true,
    Duration retryDelay = const Duration(milliseconds: 600),
  }) async {
    if (maxAttempts <= 0) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts');
    }

    DownloadSessionResult? lastResult;
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final resumeStartFile = await resolveSessionResumeStartFile(
        sessionDirPath: directory,
        preferredStartFile: startFile,
      );
      final markers = await resolveSessionResumeMarkers(
        sessionDirPath: directory,
        startFile: resumeStartFile,
        dbReceivedBytes: dbReceivedBytes,
      );
      try {
        final result = await downloadToDirectory(
          sessionId: sessionId,
          directory: directory,
          startFile: markers.startFile,
          timeout: timeout,
          startCommandTimeout: startCommandTimeout,
          retryPolicy: retryPolicy,
          createDirectory: createDirectory,
          verifyCrc: verifyCrc,
        );
        lastResult = result;
        if (result.isComplete || attempt == maxAttempts) {
          return result;
        }
        lastError = const RecordingException(
          'AT+DOWNLOAD finished without TRANSFER_DONE',
        );
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        if (attempt >= maxAttempts) {
          Error.throwWithStackTrace(e, st);
        }
      }
      await cancel();
      if (attempt < maxAttempts) {
        await Future<void>.delayed(retryDelay);
      }
    }

    if (lastResult != null) return lastResult;
    if (lastError != null) {
      Error.throwWithStackTrace(
        lastError,
        lastStack ?? StackTrace.current,
      );
    }
    throw StateError('downloadToDirectoryWithResume failed');
  }

  /// Download, merge into a single `.opus` file, and optionally delete the
  /// remote session and/or local source parts.
  Future<DownloadMergeResult> downloadMergeAndMaybeDeleteSession({
    required String sessionId,
    required String directory,
    String? startFile,
    int dbReceivedBytes = 0,
    int maxAttempts = 3,
    Duration timeout = const Duration(minutes: 10),
    Duration startCommandTimeout = const Duration(seconds: 10),
    DownloadStartRetryPolicy retryPolicy =
        const DownloadStartRetryPolicy.resilient(),
    bool createDirectory = true,
    bool verifyCrc = true,
    Duration retryDelay = const Duration(milliseconds: 600),
    String? mergedPath,
    bool deleteRemoteSessionAfterMerge = false,
    bool deleteLocalPartsAfterMerge = false,
  }) async {
    final downloadResult = await downloadToDirectoryWithResume(
      sessionId: sessionId,
      directory: directory,
      startFile: startFile,
      dbReceivedBytes: dbReceivedBytes,
      maxAttempts: maxAttempts,
      timeout: timeout,
      startCommandTimeout: startCommandTimeout,
      retryPolicy: retryPolicy,
      createDirectory: createDirectory,
      verifyCrc: verifyCrc,
      retryDelay: retryDelay,
    );
    if (!downloadResult.isComplete) {
      throw const RecordingException(
        'downloadMergeAndMaybeDeleteSession requires a complete download',
      );
    }

    final targetMergedPath =
        mergedPath ?? _defaultMergedPath(directory, sessionId);
    try {
      final mergedFile = File(targetMergedPath);
      if (await mergedFile.exists()) {
        await mergedFile.delete();
      }
    } catch (_) {}
    final merged = await mergeSessionOpusPartsInDirectory(
      directory,
      targetMergedPath,
    );
    if (merged == null) {
      throw RecordingException(
        'No session parts available to merge for $sessionId',
      );
    }

    final mergedBytes = await merged.length();
    var deletedRemoteSession = false;
    if (deleteRemoteSessionAfterMerge) {
      deletedRemoteSession = await deleteSessionAfterLocalVerification(
        sessionId: sessionId,
        mergedPath: merged.path,
        verifiedBytes: downloadResult.totalBytes,
      );
    }

    var deletedLocalParts = false;
    if (deleteLocalPartsAfterMerge) {
      deletedLocalParts = await _deleteLocalSessionParts(
        directory,
        keepPath: merged.path,
      );
    }

    return DownloadMergeResult(
      download: downloadResult,
      mergedPath: merged.path,
      mergedBytes: mergedBytes,
      deletedRemoteSession: deletedRemoteSession,
      deletedLocalParts: deletedLocalParts,
    );
  }

  /// Download, merge, fetch bookmarks, optionally save them as JSON, and
  /// optionally delete the remote session / local slices.
  Future<DownloadFinalizeResult>
      downloadMergeFetchBookmarksAndMaybeDeleteSession({
    required String sessionId,
    required String directory,
    String? startFile,
    int dbReceivedBytes = 0,
    int maxAttempts = 3,
    Duration timeout = const Duration(minutes: 10),
    Duration startCommandTimeout = const Duration(seconds: 10),
    DownloadStartRetryPolicy retryPolicy =
        const DownloadStartRetryPolicy.resilient(),
    bool createDirectory = true,
    bool verifyCrc = true,
    Duration retryDelay = const Duration(milliseconds: 600),
    String? mergedPath,
    bool deleteRemoteSessionAfterMerge = false,
    bool deleteLocalPartsAfterMerge = false,
    bool saveBookmarksJson = true,
    String? bookmarksPath,
    int bookmarksPerPage = 10,
    int bookmarksMaxPages = 100,
    Duration bookmarksTimeout = const Duration(seconds: 6),
  }) async {
    final download = await downloadToDirectoryWithResume(
      sessionId: sessionId,
      directory: directory,
      startFile: startFile,
      dbReceivedBytes: dbReceivedBytes,
      maxAttempts: maxAttempts,
      timeout: timeout,
      startCommandTimeout: startCommandTimeout,
      retryPolicy: retryPolicy,
      createDirectory: createDirectory,
      verifyCrc: verifyCrc,
      retryDelay: retryDelay,
    );
    if (!download.isComplete) {
      throw const RecordingException(
        'downloadMergeFetchBookmarksAndMaybeDeleteSession requires a complete download',
      );
    }

    final targetMergedPath =
        mergedPath ?? _defaultMergedPath(directory, sessionId);
    try {
      final mergedFile = File(targetMergedPath);
      if (await mergedFile.exists()) {
        await mergedFile.delete();
      }
    } catch (_) {}
    final merged = await mergeSessionOpusPartsInDirectory(
      directory,
      targetMergedPath,
    );
    if (merged == null) {
      throw RecordingException(
        'No session parts available to merge for $sessionId',
      );
    }

    final mergedBytes = await merged.length();
    var bookmarks = <DeviceBookmark>[];
    try {
      bookmarks = await listBookmarks(
        sessionId: sessionId,
        perPage: bookmarksPerPage,
        maxPages: bookmarksMaxPages,
        timeout: bookmarksTimeout,
      );
    } catch (e, st) {
      SdkLog.w(
        'RecordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession: '
        'AT+MARKS failed (non-fatal)',
        e,
        st,
      );
    }

    String? savedPath;
    var saved = false;
    if (saveBookmarksJson) {
      try {
        final target =
            bookmarksPath ?? bookmarksSidecarPathForMergedFile(merged.path);
        savedPath = await writeBookmarksJsonSidecar(
          path: target,
          bookmarks: bookmarks,
        );
        saved = true;
      } catch (e, st) {
        SdkLog.w(
          'RecordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession: '
          'save bookmarks json failed (non-fatal)',
          e,
          st,
        );
      }
    }

    final deletedRemoteSession = deleteRemoteSessionAfterMerge
        ? await deleteSessionAfterLocalVerification(
            sessionId: sessionId,
            mergedPath: merged.path,
            verifiedBytes: download.totalBytes ?? mergedBytes,
          )
        : false;

    var deletedLocalParts = false;
    if (deleteLocalPartsAfterMerge) {
      deletedLocalParts = await _deleteLocalSessionParts(
        directory,
        keepPath: merged.path,
      );
    }

    return DownloadFinalizeResult(
      merge: DownloadMergeResult(
        download: download,
        mergedPath: merged.path,
        mergedBytes: mergedBytes,
        deletedRemoteSession: deletedRemoteSession,
        deletedLocalParts: deletedLocalParts,
      ),
      bookmarks: bookmarks,
      bookmarksPath: savedPath,
      bookmarksSaved: saved,
    );
  }

  Future<Map<String, dynamic>> _sendDownloadStartWithRetry(
    String command, {
    required Duration timeout,
    required DownloadStartRetryPolicy policy,
  }) async {
    if (policy.maxAttempts <= 0) {
      throw ArgumentError.value(policy.maxAttempts, 'maxAttempts');
    }

    Map<String, dynamic>? lastResp;
    for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      if (attempt > 1) {
        SdkLog.i(
          'RecordingSession.download: retry AT+DOWNLOAD '
          '$attempt/${policy.maxAttempts}',
        );
        await Future<void>.delayed(policy.retryDelay);
      }

      final resp = await at.send(command, timeout: timeout);
      lastResp = resp;
      if (resp['ok'] == true) return resp;

      final kind = DownloadStartFailureKindX.fromAtReply(resp);
      if (attempt >= policy.maxAttempts || !policy.shouldRetry(kind)) {
        return resp;
      }

      if (kind == DownloadStartFailureKind.transferBusy) {
        if (policy.skipCancelWhenDeviceRecording &&
            await _deviceAppearsRecordingOrPaused(policy.statusTimeout)) {
          SdkLog.w(
            'RecordingSession.download: device is recording/paused; '
            'skip AT+CANCEL and let caller retry later',
          );
          return resp;
        }
        await _cancelBusyTransferBeforeRetry(policy);
      }
    }

    return lastResp ?? <String, dynamic>{'ok': false, 'error': 'no reply'};
  }

  Future<bool> _deviceAppearsRecordingOrPaused(Duration timeout) async {
    try {
      final resp = await at.send('AT+GSTAT', timeout: timeout);
      if (resp['ok'] != true) return false;
      final status = DeviceStatus.fromAtReply(resp);
      return status.isRecording || status.state == 'paused';
    } catch (e, st) {
      SdkLog.w(
        'RecordingSession.download: GSTAT before busy-cancel failed',
        e,
        st,
      );
      return false;
    }
  }

  Future<void> _cancelBusyTransferBeforeRetry(
    DownloadStartRetryPolicy policy,
  ) async {
    try {
      SdkLog.w(
        'RecordingSession.download: AT+DOWNLOAD busy; sending AT+CANCEL '
        'before retry',
      );
      await at.send('AT+CANCEL', timeout: policy.cancelTimeout);
    } catch (e, st) {
      SdkLog.w(
        'RecordingSession.download: AT+CANCEL before retry failed',
        e,
        st,
      );
    }
    await Future<void>.delayed(policy.cancelSettleDelay);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _errorDetail(Map<String, dynamic> resp) {
    final msg = resp['error'] ?? resp['msg'] ?? resp['message'];
    if (msg != null && '$msg'.isNotEmpty) return msg.toString();
    final data = resp['data'];
    if (data is Map && data['msg'] != null) return data['msg'].toString();
    return resp.toString();
  }

  static String? _extractSession(Map<String, dynamic> resp) {
    final root = (resp['session'] ?? '').toString().trim();
    if (root.isNotEmpty) return root;
    final data = resp['data'];
    if (data is Map) {
      final inner = (data['session'] ?? '').toString().trim();
      if (inner.isNotEmpty) return inner;
    }
    return null;
  }

  static RecordingMode? _extractRecordingMode(Map<String, dynamic> resp) {
    final data = resp['data'];
    if (data is Map) {
      final s = (data['mode'] ?? '').toString().trim().toLowerCase();
      if (s.isEmpty) return null;
      if (s == 'enhanced' || s == '1') return RecordingMode.enhanced;
      return RecordingMode.normal;
    }
    return null;
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String _safeDownloadFilename(
    String filename, {
    required int fallbackIndex,
  }) {
    final name = filename.trim().isEmpty
        ? 'part_${fallbackIndex.toString().padLeft(4, '0')}.opus'
        : filename.trim();
    final withExt = name.toLowerCase().endsWith('.opus') ? name : '$name.opus';
    return BleTransferFrameHandler.sanitizeFilename(withExt);
  }

  static String _defaultMergedPath(String directory, String sessionId) {
    final safe = BleTransferFrameHandler.sanitizeFilename(sessionId);
    final stem = safe.toLowerCase().endsWith('.opus') ? safe : '$safe.opus';
    return p.join(directory, stem);
  }

  static String bookmarksSidecarPathForMergedFile(String mergedPath) {
    final dir = p.dirname(mergedPath);
    final base = p.basenameWithoutExtension(mergedPath);
    return p.join(dir, '${base}_bookmarks.json');
  }

  static Future<String> writeBookmarksJsonSidecar({
    required String path,
    required List<DeviceBookmark> bookmarks,
  }) async {
    final file = File(path);
    final payload = jsonEncode(bookmarks.map((b) => b.toJson()).toList());
    await file.writeAsString(payload, flush: true);
    return file.path;
  }

  static String _sessionRoot(String? sessionId) {
    final s = (sessionId ?? '').trim();
    if (s.isEmpty) return '';
    final idx = s.indexOf('/');
    return idx < 0 ? s : s.substring(0, idx);
  }

  static Future<bool> _deleteLocalSessionParts(
    String directory, {
    required String keepPath,
  }) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return false;
    var deletedAny = false;
    for (final entry in dir.listSync().whereType<File>()) {
      final path = entry.path;
      final lower = path.toLowerCase();
      if (path == keepPath) continue;
      if (!lower.endsWith('.opus') && !lower.endsWith('.opus.part')) continue;
      try {
        await entry.delete();
        deletedAny = true;
      } catch (_) {}
    }
    return deletedAny;
  }

  static Map<String, dynamic> _dataMap(Map<String, dynamic> resp) {
    final data = resp['data'];
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  static Object? _extractRootOrDataValue(
    Map<String, dynamic> resp,
    List<String> keys,
  ) {
    final dataMap = _dataMap(resp);
    for (final key in keys) {
      final v = dataMap[key] ?? resp[key];
      if (v != null && v.toString().trim().isNotEmpty) return v;
    }
    return null;
  }

  static String? _extractRootOrDataString(
    Map<String, dynamic> resp,
    List<String> keys,
  ) {
    final v = _extractRootOrDataValue(resp, keys);
    final s = v?.toString().trim();
    return s == null || s.isEmpty ? null : s;
  }

  static String? _firstString(
    Map<String, dynamic> dataMap,
    Map<String, dynamic> resp,
    List<String> keys,
  ) {
    for (final key in keys) {
      final s = (dataMap[key] ?? resp[key])?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  static int? _extractTotal(Map<String, dynamic> resp) {
    final dataMap = _dataMap(resp);
    return _asInt(
        dataMap['total'] ?? resp['total'] ?? dataMap['count'] ?? resp['count']);
  }

  static List<Map<String, dynamic>> _bookmarkItems(Map<String, dynamic> resp) {
    final dataMap = _dataMap(resp);
    final rawItems =
        dataMap['bookmarks'] ?? dataMap['items'] ?? resp['bookmarks'];
    if (rawItems is! List) return const [];
    return rawItems
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList(growable: false);
  }

  static DeviceBookmark _parseBookmark(Map<String, dynamic> m) {
    return DeviceBookmark(
      offsetSeconds: _asInt(m['offset'] ?? m['offset_seconds']) ?? 0,
      note: (m['note'] ?? '').toString(),
      raw: m,
    );
  }

  static List<DeviceFileMeta> _parseFileList(Map<String, dynamic> resp) {
    final data = resp['data'];
    if (data is! Map) return const [];
    final items = data['items'] ?? data['files'];
    if (items is! List) return const [];
    final out = <DeviceFileMeta>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final path = (m['path'] ?? m['file'] ?? '').toString();
      if (path.isEmpty) continue;
      out.add(DeviceFileMeta(
        deviceId: '',
        path: path,
        name: (m['name'] ?? path.split('/').last).toString(),
        sizeBytes: _asInt(m['size'] ?? m['bytes']) ?? 0,
        durationSeconds: _asInt(m['duration']) ?? 0,
        bookmarkCount: _asInt(m['bookmark_count'] ?? m['bookmarks']) ?? 0,
        createdAt: _parseTimestamp(m['created_at'] ?? m['mtime']),
      ));
    }
    return out;
  }

  static DateTime? _parseTimestamp(Object? v) {
    if (v == null) return null;
    if (v is int) {
      // Heuristic: seconds vs milliseconds.
      final ms = v > 4102444800 ? v : v * 1000;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (v is String) {
      final parsed = DateTime.tryParse(v);
      if (parsed != null) return parsed;
      final n = int.tryParse(v);
      if (n != null) {
        final ms = n > 4102444800 ? n : n * 1000;
        return DateTime.fromMillisecondsSinceEpoch(ms);
      }
    }
    return null;
  }
}

/// Generic error thrown by [RecordingSession] when the firmware reply is
/// `ok:false` or otherwise unusable.
class RecordingException implements Exception {
  final String message;
  final Map<String, dynamic>? raw;
  final String? code;

  const RecordingException(this.message, {this.raw, this.code});

  @override
  String toString() => code == null
      ? 'RecordingException: $message'
      : 'RecordingException[$code]: $message';
}
