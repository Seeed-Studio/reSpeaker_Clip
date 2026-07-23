import 'dart:math' as math;

/// Max progress shown in UI while [Recording.transferState] is `transferring`.
/// Matches [DeviceController] `_transferProgressOrNull` / `_wifiAlignedBleTransferProgress` (0.995 cap).
const double kTransferProgressDisplayMaxWhileTransferring = 0.995;

class Recording {
  final String id;
  final String? deviceId;
  final String devicePath;

  /// Device recording session id (for streaming/repair/resume).
  final String? sessionId;

  /// Client-generated, persisted id for this recording's ASR result.
  /// Used to correlate server-side artifacts (ASR/LLM sessions) to a single recording.
  final int? asrResultId;

  /// Full lifecycle state for "record -> transfer -> done".
  /// idle | recording | stopping | transferring | done | failed
  final String? recordingState;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// Temp file path while streaming (rename to localPath when done).
  final String? tmpPath;

  /// BLE MTU negotiated for this session (for diagnostics).
  final int? mtu;

  /// Last time we received any audio chunk/packet.
  final DateTime? lastPacketAt;
  final DateTime? transferStartedAt;
  final DateTime? transferFinishedAt;

  /// Server-side id/url after upload (for cloud STT/LLM, share, etc.)
  final String? remoteId;
  final String? remoteUrl;

  /// Transfer transport (ble/wifi/usb/cloud...) reserved for future.
  final String? transport;

  /// A connection/session id for debugging (e.g. BLE connection session).
  final String? connectionId;

  /// Last job ids (for correlating to jobs table / polling).
  final String? lastSttJobId;
  final String? lastSummaryJobId;
  final String? name;
  final int? sizeBytes;
  final int? durationSeconds;
  final DateTime? createdAt;

  /// Unified local file path (final path on disk).
  final String? localPath;

  /// Audio format/codec (e.g. alac/aac/wav).
  final String? format;

  /// Container (e.g. m4a/caf/wav/raw).
  final String? container;
  final int? sampleRate;
  final int? channels;
  final int? bitDepth;

  /// Streaming/transfer reliability fields.
  final int? receivedBytes;
  final int? expectedBytes;
  final int? lastSeq;
  final int? crc32;

  /// Folder id. null means "Unclassified".
  final String? folderId;

  /// Source of this file in Files filter.
  /// device | local | import (reserved for future)
  final String source;

  /// Recycle bin flag.
  final bool isDeleted;
  final DateTime? deletedAt;

  /// Whether this file still exists on device storage.
  /// - true: exists on device
  /// - false: deleted on device (but may still exist locally if downloaded)
  final bool devicePresent;

  /// Device -> App file transfer state:
  /// not_started | transferring | done | failed
  final String transferState;

  /// 0..1 (nullable when unknown)
  final double? transferProgress;
  final String? transferError;

  /// Optional error code for i18n (e.g. device_session_missing, transfer_incomplete_resume).
  final String? transferErrorCode;
  final String uploadState; // not_uploaded | uploading | uploaded | failed
  final String
      jobState; // none | queued | transcribing | summarizing | done | failed
  final String? transcript;
  final String? summary;

  /// Currently selected summary version id (if using versioned summaries).
  final String? currentSummaryId;
  final String? transcriptPath;
  final String? summaryPath;
  // Persist the selections used for STT/LLM generation (for traceability).
  final String? lastSttConfigId;
  final String? lastLlmConfigId;
  final String? lastTemplateId;
  final String? lastLanguage;
  final bool lastAutoSpeaker;
  final DateTime updatedAt;

  const Recording({
    required this.id,
    required this.deviceId,
    required this.devicePath,
    required this.sessionId,
    required this.asrResultId,
    required this.recordingState,
    required this.startedAt,
    required this.endedAt,
    required this.tmpPath,
    required this.mtu,
    required this.lastPacketAt,
    required this.transferStartedAt,
    required this.transferFinishedAt,
    required this.remoteId,
    required this.remoteUrl,
    required this.transport,
    required this.connectionId,
    required this.lastSttJobId,
    required this.lastSummaryJobId,
    required this.name,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.createdAt,
    required this.localPath,
    required this.format,
    required this.container,
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    required this.receivedBytes,
    required this.expectedBytes,
    required this.lastSeq,
    required this.crc32,
    this.folderId,
    this.source = 'device',
    this.isDeleted = false,
    this.deletedAt,
    required this.devicePresent,
    required this.transferState,
    required this.transferProgress,
    required this.transferError,
    this.transferErrorCode,
    required this.uploadState,
    required this.jobState,
    required this.transcript,
    required this.summary,
    required this.currentSummaryId,
    required this.transcriptPath,
    required this.summaryPath,
    required this.lastSttConfigId,
    required this.lastLlmConfigId,
    required this.lastTemplateId,
    required this.lastLanguage,
    required this.lastAutoSpeaker,
    required this.updatedAt,
  });
}

/// Denominator for list/banner transfer progress when both fields are set.
///
/// Uses [math.max] of positive [Recording.expectedBytes], [Recording.sizeBytes],
/// and [Recording.receivedBytes] so STOP/AT+LIST snapshots never shrink below
/// payload already received during live record-while-transfer.
int recordingTransferExpectedCapBytes(Recording r) {
  final e =
      (r.expectedBytes != null && r.expectedBytes! > 0) ? r.expectedBytes! : 0;
  final s = (r.sizeBytes != null && r.sizeBytes! > 0) ? r.sizeBytes! : 0;
  final received = (r.receivedBytes != null && r.receivedBytes! > 0)
      ? r.receivedBytes!
      : 0;
  var cap = 0;
  if (e == 0) {
    cap = s;
  } else if (s == 0) {
    cap = e;
  } else {
    cap = math.max(e, s);
  }
  if (received > cap) return received;
  return cap;
}

/// Merge AT+STOP `total_size` with bytes already tracked in DB.
///
/// Never let a fresh STOP snapshot alone shrink [expected_bytes] below what
/// live BLE pull already received or a prior transfer snapshot recorded.
int? mergeStopTransferExpectedBytes({
  required int stopSizeBytes,
  required int receivedBytes,
  int? previousExpectedBytes,
  int? previousSizeBytes,
}) {
  final candidates = <int>[
    if (stopSizeBytes > 0) stopSizeBytes,
    if (receivedBytes > 0) receivedBytes,
    if (previousExpectedBytes != null && previousExpectedBytes > 0)
      previousExpectedBytes,
    if (previousSizeBytes != null && previousSizeBytes > 0) previousSizeBytes,
  ];
  if (candidates.isEmpty) return null;
  return candidates.reduce(math.max);
}

/// Indeterminate bar while firmware total still moves, or after STOP while DB
/// [received_bytes] has not caught up to the in-flight BLE leg yet.
bool transferUiUseIndeterminateProgress({
  required Recording recording,
  required bool liveRecordWhileBleTransfer,
}) {
  if (liveRecordWhileBleTransfer) return true;
  if (recording.transferState != 'transferring') return false;

  final received = recording.receivedBytes ?? 0;
  if (recording.endedAt != null && received <= 0) return true;

  final cap = recordingTransferExpectedCapBytes(recording);
  if (cap <= 0) return received <= 0;

  if (received <= 0) return true;

  // Post-stop: STOP wrote a large expected cap but DB received is still near zero.
  if (recording.endedAt != null && received < cap * 0.02) return true;

  return false;
}

/// **Display only** — does not affect [DeviceController] download/merge/resume logic.
///
/// Show "merging" once the payload is fully received and only the local
/// concat/merge step remains (DB `merging`), for both BLE and Wi‑Fi.
/// Still suppressed while bytes are actively streaming
/// ([liveRecordWhileBleTransfer]) or while the Wi‑Fi controller owns the row.
bool transferUiLocalMergePhase({
  required Recording recording,
  required bool liveRecordWhileBleTransfer,
  /// When true, Wi‑Fi controller owns this row (`WifiTransferPhase.*`); do not infer merge from DB bytes.
  bool wifiOwnsProgressForRecording = false,
  /// When true, the device controller still has an in-flight BLE leg for this
  /// row. Suppresses the byte-based "download complete" inference so a `received`
  /// count that briefly overshoots the expected total during a resume re-pull is
  /// not mistaken for completion (would wrongly show "merging" while still pulling).
  bool transferActiveForRecording = false,
}) {
  if (liveRecordWhileBleTransfer) return false;
  if (wifiOwnsProgressForRecording) return false;
  if (recording.transferState == 'merging') return true;
  // Byte payload is fully received but the DB hasn't flipped to `merging` yet
  // (the merge job is enqueued a moment later). Treat this gap as the merge
  // phase so the UI shows "merging" the instant the download completes instead
  // of lingering on an indeterminate "syncing".
  return transferUiDownloadCompletePendingMerge(
    recording: recording,
    liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
    wifiOwnsProgressForRecording: wifiOwnsProgressForRecording,
    transferActiveForRecording: transferActiveForRecording,
  );
}

/// **Display only.** Byte payload fully received for a BLE pull while the DB
/// state is still `transferring` (the `merging` flip lands a beat later when
/// the merge job is enqueued). Bridges that gap so the list/banner can present
/// the merge phase the moment the download bytes complete.
///
/// Suppressed while bytes are still expected: record-while-transfer
/// ([liveRecordWhileBleTransfer], cap unknown/stale) and active Wi‑Fi batches
/// ([wifiOwnsProgressForRecording]).
bool transferUiDownloadCompletePendingMerge({
  required Recording recording,
  required bool liveRecordWhileBleTransfer,
  bool wifiOwnsProgressForRecording = false,
  bool transferActiveForRecording = false,
}) {
  if (liveRecordWhileBleTransfer) return false;
  if (wifiOwnsProgressForRecording) return false;
  // Still actively pulling bytes: `received` can transiently exceed the expected
  // total during a resume re-pull (carried-over count + re-downloaded slices).
  // That overshoot is NOT completion — keep showing progress, not "merging".
  if (transferActiveForRecording) return false;
  if (recording.transferState != 'transferring') return false;
  // Use the *known* total only (expected/size). Never the received-inflated
  // cap: when the total is unknown the download is not provably complete and
  // must stay an indeterminate "syncing", not jump to "merging".
  final expected =
      (recording.expectedBytes ?? 0) > 0 ? recording.expectedBytes! : 0;
  final size = (recording.sizeBytes ?? 0) > 0 ? recording.sizeBytes! : 0;
  final knownTotal = math.max(expected, size);
  if (knownTotal <= 0) return false;
  final recv = recording.receivedBytes ?? 0;
  // Wi‑Fi→BLE resume can inflate `receivedBytes` above the session total while
  // local slices are still missing — do not show "merging" until bytes are sane.
  if (recv > (knownTotal * 1.02).round()) return false;
  return recv >= knownTotal;
}

/// List / banner / sheet progress. Returns `null` for indeterminate display.
/// **Display only** — never used by transfer controllers or resume logic.
double? transferProgressForDisplay({
  required Recording recording,
  required bool liveRecordWhileBleTransfer,
  bool wifiOwnsProgressForRecording = false,
  bool transferActiveForRecording = false,
}) {
  if (transferUiUseIndeterminateProgress(
    recording: recording,
    liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
  )) {
    return null;
  }
  if (transferUiLocalMergePhase(
    recording: recording,
    liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
    wifiOwnsProgressForRecording: wifiOwnsProgressForRecording,
    transferActiveForRecording: transferActiveForRecording,
  )) {
    return null;
  }

  final received = recording.receivedBytes ?? 0;
  final cap = recordingTransferExpectedCapBytes(recording);
  final stillTransferring = recording.transferState == 'transferring';

  if (cap > 0) {
    if (transferExpectedCapLooksStale(
      receivedBytes: received,
      expectedCapBytes: cap,
      stillTransferring: stillTransferring,
    )) {
      // A device controller leg is still actively pulling THIS row: `received`
      // catching up to (or just past) a too-small `expectedBytes` snapshot
      // (multi-file session / resume re-pull / STOP cap) is NOT completion and
      // NOT merge. Hold a steady near-full determinate bar instead of flipping
      // to an indeterminate "dynamic" phase mid-transfer (the strobe the user
      // sees). Once the leg ends (active id cleared) the merge/hide path takes
      // over and the list shows "merging".
      if (transferActiveForRecording) {
        return kTransferProgressDisplayMaxWhileTransferring;
      }
      return null;
    }
    return transferProgressFromReceivedRatio(
      receivedBytes: received,
      expectedCapBytes: cap,
      stillTransferring: stillTransferring,
    );
  }

  var p = recording.transferProgress?.clamp(0.0, 1.0);
  if (stillTransferring && p != null && p < 1.0) {
    p = p.clamp(0.0, kTransferProgressDisplayMaxWhileTransferring);
  }
  return p;
}

/// True when [expectedCapBytes] is a stale snapshot but payload is still growing.
bool transferExpectedCapLooksStale({
  required int receivedBytes,
  required int expectedCapBytes,
  required bool stillTransferring,
}) {
  return stillTransferring &&
      expectedCapBytes > 0 &&
      receivedBytes >= expectedCapBytes;
}

/// Session received / expected for list & banner. While transferring, never 1.0 when
/// received has caught up to cap (total still moving on device).
double? transferProgressFromReceivedRatio({
  required int receivedBytes,
  required int expectedCapBytes,
  required bool stillTransferring,
}) {
  if (expectedCapBytes <= 0) return null;
  if (transferExpectedCapLooksStale(
    receivedBytes: receivedBytes,
    expectedCapBytes: expectedCapBytes,
    stillTransferring: stillTransferring,
  )) {
    return kTransferProgressDisplayMaxWhileTransferring;
  }
  final ratio = (receivedBytes / expectedCapBytes).clamp(0.0, 1.0);
  if (stillTransferring && ratio < 1.0) {
    return ratio.clamp(0.0, kTransferProgressDisplayMaxWhileTransferring);
  }
  return ratio;
}

/// Human-readable received size for transfer UI (recording sheet, list/banner if needed).
String formatTransferReceivedBytesUi(int bytes) {
  var b = bytes;
  if (b < 0) b = 0;
  const k = 1024.0;
  if (b < k) return '${b}B';
  final kb = b / k;
  if (kb < k) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / k;
  if (mb < k) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / k;
  return '${gb.toStringAsFixed(1)} GB';
}

/// Like [formatTransferReceivedBytesUi] but returns `null` when nothing received yet
/// (avoids "0B" while the bar is indeterminate / DB bytes lag behind slice progress).
String? formatTransferReceivedBytesUiIfPositive(int? bytes) {
  final b = bytes ?? 0;
  if (b <= 0) return null;
  return formatTransferReceivedBytesUi(b);
}
