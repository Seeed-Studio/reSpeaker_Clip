import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
// The app keeps its own copies of these session helpers under core/audio/;
// hide the SDK's identically-named exports so both can coexist.
import 'package:sensecraft_voice/sensecraft_voice.dart'
    hide
        SessionResumeMarkers,
        resumeFileIndexFromStartFile,
        resolveResumeByteFloor,
        resolveSessionResumeMarkers,
        kSessionOpusMergeBufferBytes,
        kSessionOpusMergeProgressEveryBytes,
        mergeSessionOpusPartFiles,
        mergeSessionOpusPartsInDirectory,
        sumCompleteSessionOpusSliceBytes,
        sumSessionOpusPartBytes;

import '../../../core/db/account_db_key.dart';
import '../../../core/storage/account_storage_paths.dart';
import '../../../core/audio/session_merge_queue.dart';
import '../../../core/audio/session_opus_parts_merge.dart';
import '../../../core/audio/session_resume_markers.dart';
import '../../../core/log/app_log.dart';
import '../../../core/observability/sentry_service.dart';
import '../../recordings/data/recordings_repository.dart';
import '../../recordings/presentation/recordings_controller.dart';
import 'device_controller.dart';

/// WiFi transfer lifecycle phases.
enum WifiTransferPhase {
  idle,
  enablingHotspot,
  connectingWifi,
  verifyingConnection,
  transferring,
  mergingFiles,
  disablingHotspot,
  completed,
  failed,
}

/// UI state for WiFi transfer.
class WifiTransferState {
  final WifiTransferPhase phase;
  final WifiHotspotInfo? hotspot;
  final String? error;

  /// Recording this Wi‑Fi run applies to (for list/banner coordination).
  final String? recordingId;

  /// Bytes already received before this UDP run (e.g. after BLE handoff).
  final int resumeByteOffset;

  /// Current file being downloaded (e.g. "0003.opus").
  final String? currentFile;

  /// File-level progress: fileIndex / totalFiles.
  final int fileIndex;
  final int totalFiles;

  /// Byte-level progress.
  final int receivedBytes;
  final int totalBytes;

  /// Files already completed before this WiFi run (BLE leg + any prior failed Wi‑Fi attempts).
  /// Parsed from `AT+DOWNLOAD=...:NNNN.opus` resume marker → `N-1`. `0` for fresh sessions.
  /// Required so [progress] reflects whole-session position and not just this run's file count
  /// (otherwise BLE→Wi‑Fi handoff bars reset to 0% even when 149/2620 files are already on disk).
  final int resumeFileIndex;

  /// Local merge progress, only meaningful while [phase] == [WifiTransferPhase.mergingFiles].
  /// `mergeTotalBytes == 0` means total is unknown (caller did not pre-stat parts).
  final int mergedBytes;
  final int mergeTotalBytes;

  /// Overall progress 0.0 .. 1.0.
  double get progress {
    if (totalFiles > 0 && phase == WifiTransferPhase.transferring) {
      final completedFiles = resumeFileIndex + fileIndex;
      final filePart = completedFiles / totalFiles;
      if (totalBytes > 0) {
        final bytePart = receivedBytes / totalBytes;
        return (filePart + bytePart / totalFiles).clamp(0.0, 1.0);
      }
      return filePart.clamp(0.0, 1.0);
    }
    if (phase == WifiTransferPhase.completed) return 1.0;
    return 0.0;
  }

  /// 0.0 .. 1.0 fraction of the local part-merge step. 0 when total is unknown.
  double get mergeFraction {
    if (mergeTotalBytes <= 0) return 0.0;
    return (mergedBytes / mergeTotalBytes).clamp(0.0, 1.0);
  }

  bool get isActive =>
      phase != WifiTransferPhase.idle &&
      phase != WifiTransferPhase.completed &&
      phase != WifiTransferPhase.failed;

  const WifiTransferState({
    this.phase = WifiTransferPhase.idle,
    this.hotspot,
    this.error,
    this.recordingId,
    this.resumeByteOffset = 0,
    this.currentFile,
    this.fileIndex = 0,
    this.totalFiles = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.resumeFileIndex = 0,
    this.mergedBytes = 0,
    this.mergeTotalBytes = 0,
  });

  /// Bytes received in session including any BLE progress before this run.
  int get cumulativeReceivedBytes => resumeByteOffset + receivedBytes;

  WifiTransferState copyWith({
    WifiTransferPhase? phase,
    WifiHotspotInfo? hotspot,
    String? error,
    String? recordingId,
    int? resumeByteOffset,
    String? currentFile,
    int? fileIndex,
    int? totalFiles,
    int? receivedBytes,
    int? totalBytes,
    int? resumeFileIndex,
    int? mergedBytes,
    int? mergeTotalBytes,
  }) {
    return WifiTransferState(
      phase: phase ?? this.phase,
      hotspot: hotspot ?? this.hotspot,
      error: error,
      recordingId: recordingId ?? this.recordingId,
      resumeByteOffset: resumeByteOffset ?? this.resumeByteOffset,
      currentFile: currentFile ?? this.currentFile,
      fileIndex: fileIndex ?? this.fileIndex,
      totalFiles: totalFiles ?? this.totalFiles,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      resumeFileIndex: resumeFileIndex ?? this.resumeFileIndex,
      mergedBytes: mergedBytes ?? this.mergedBytes,
      mergeTotalBytes: mergeTotalBytes ?? this.mergeTotalBytes,
    );
  }
}

/// One recording to pull while the device hotspot stays on ([WifiTransferController.transferWifiBatch]).
class WifiBatchItem {
  const WifiBatchItem({
    required this.recordingId,
    required this.sessionId,
    this.expectedBytes,
    this.startFile,
    this.resumeByteOffset = 0,
    this.deleteAfterSync = true,
  });

  final String recordingId;
  final String sessionId;
  final int? expectedBytes;
  final String? startFile;
  final int resumeByteOffset;
  final bool deleteAfterSync;
}

/// Why a Wi‑Fi fast-sync batch should fall back to BLE. Data is always intact on
/// the device, so BLE can finish the pull; the UI just keeps showing "fast sync".
enum WifiBleFallbackReason {
  /// UDP routing failed immediately (phone Wi‑Fi off, wrong network, errno 101).
  phoneWifiDisconnected,

  /// Hotspot join / UDP verify timed out — phone may not have joined the AP yet.
  phoneOnOtherWifi,

  /// Verify passed (UDP ping OK) but the bulk transfer failed: every file NACKed
  /// (CRC mismatch / `TRANSFER_DONE file_count=0`). The phone associated with the
  /// AP but the data path never really carried packets (lossy link / OS routed
  /// data back to the internet Wi‑Fi). Fall back to BLE.
  transferFailed,
}

enum WifiVerifyFailureKind {
  /// Phone cannot route to 192.168.4.1 (Wi‑Fi disabled, left device AP, etc.).
  networkUnreachable,

  /// Ping/join retries exhausted without a routing error — AP may not be joined yet.
  timedOut,
}

/// Thrown from [WifiTransferController.transferWifiBatch] verify phase only.
class WifiVerifyFailure implements Exception {
  const WifiVerifyFailure(this.kind, {required this.hotspot});

  final WifiVerifyFailureKind kind;
  final WifiHotspotInfo hotspot;

  @override
  String toString() => '$_kWifiSetupFailurePrefix ${kind.name}';
}

/// Result of [WifiTransferController.transferWifiBatch].
class WifiFastSyncBatchResult {
  const WifiFastSyncBatchResult({
    this.succeeded = 0,
    this.failed = 0,
    this.userCancelled = false,
    this.abortedForRecording = false,
    this.bleFallbackReason,
    this.fallbackHotspot,
  });

  final int succeeded;
  final int failed;
  final bool userCancelled;
  final bool abortedForRecording;

  /// Non-null when Wi‑Fi could not deliver and the caller should fall back to BLE
  /// (keeping the "fast sync" UI). See [WifiBleFallbackReason].
  final WifiBleFallbackReason? bleFallbackReason;

  /// Device AP credentials captured at the end of the batch (before provider state
  /// is cleared). Used by the fallback dialog so SSID + password survive cleanup.
  final WifiHotspotInfo? fallbackHotspot;

  bool get shouldFallBackToBle => bleFallbackReason != null;

  /// At least one session merged; no per-item failure; user did not cancel mid-batch.
  bool get isOverallSuccess => succeeded > 0 && failed == 0 && !userCancelled;
}

typedef WifiBatchResolveStartFile = Future<String?> Function(
  String recordingId,
  String sessionId,
);

final wifiTransferControllerProvider =
    NotifierProvider<WifiTransferController, WifiTransferState>(
        WifiTransferController.new);

/// Prefix for [StateError] when only Wi‑Fi join / UDP reachability failed (BLE can still sync).
const String _kWifiSetupFailurePrefix = 'Wi‑Fi setup:';

bool _isWifiSetupOnlyFailure(Object e) =>
    e is WifiVerifyFailure || e.toString().contains(_kWifiSetupFailurePrefix);

bool _isWifiPreTransferPhase(WifiTransferPhase phase) =>
    phase == WifiTransferPhase.enablingHotspot ||
    phase == WifiTransferPhase.connectingWifi ||
    phase == WifiTransferPhase.verifyingConnection;

class WifiTransferController extends Notifier<WifiTransferState> {
  bool _wifiTransferCancelled = false;
  WifiFastSyncSession? _fastSync;

  /// Periodic [WifiFastSyncSession.forceWifiUsage] while the phone is on the
  /// no-internet device AP. Android OEMs often unbind mid-transfer and route
  /// UDP via cellular / another Wi‑Fi; re-binding keeps the sync path alive.
  Timer? _forceWifiKeepAlive;
  // Short cadence: some OEMs route off the no-internet AP within ~10s, so re-bind
  // often to recover fast. The tick itself is logged only on failure (empty
  // reason) to avoid flooding the log file at this frequency.
  static const Duration _forceWifiKeepAliveInterval = Duration(seconds: 3);

  /// Mid-download stall flag. Set when [onOverallProgress] stops updating for
  /// [_wifiProgressStallTimeout] — does **not** ping the shared UDP socket
  /// (that would race the download recv loop). Read by [shouldCancel].
  bool _wifiLinkLostDuringTransfer = false;
  Timer? _wifiProgressStallWatchdog;
  DateTime _wifiLastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _wifiProgressStallCheckInterval = Duration(seconds: 5);
  /// Faster than the SDK's ~60s download stall, but long enough for FILE_END /
  /// inter-file gaps on a healthy link.
  static const Duration _wifiProgressStallTimeout = Duration(seconds: 35);

  @override
  WifiTransferState build() {
    ref.onDispose(() {
      _stopForceWifiKeepAlive();
      _stopWifiProgressStallWatchdog();
    });
    return const WifiTransferState();
  }

  void _stopForceWifiKeepAlive() {
    _forceWifiKeepAlive?.cancel();
    _forceWifiKeepAlive = null;
  }

  void _stopWifiProgressStallWatchdog() {
    _wifiProgressStallWatchdog?.cancel();
    _wifiProgressStallWatchdog = null;
  }

  /// Best-effort re-bind. Safe to call when [_fastSync] is null.
  Future<void> _rebindForceWifiUsage({String reason = ''}) async {
    final session = _fastSync;
    if (session == null) return;
    try {
      await session.forceWifiUsage(true);
      if (reason.isNotEmpty) {
        AppLog.i('[WiFi] forceWifiUsage(true) — $reason');
      }
    } catch (e, st) {
      AppLog.w('[WiFi] forceWifiUsage(true) failed ($reason)', e, st);
    }
  }

  void _startForceWifiKeepAlive() {
    _stopForceWifiKeepAlive();
    // Immediate bind, then every [_forceWifiKeepAliveInterval].
    unawaited(_rebindForceWifiUsage(reason: 'keep-alive start'));
    _forceWifiKeepAlive = Timer.periodic(_forceWifiKeepAliveInterval, (_) {
      // Empty reason → only failures are logged, not every 3s tick.
      unawaited(_rebindForceWifiUsage());
      // Keep handoff TTL alive while Wi‑Fi is still working.
      ref.read(deviceControllerProvider.notifier).touchWifiHandoff();
    });
  }

  void _noteWifiTransferProgress() {
    _wifiLastProgressAt = DateTime.now();
  }

  /// Watch for stalled UDP progress without sending AT on the download socket.
  void _startWifiProgressStallWatchdog() {
    _stopWifiProgressStallWatchdog();
    _wifiLinkLostDuringTransfer = false;
    _noteWifiTransferProgress();
    _wifiProgressStallWatchdog =
        Timer.periodic(_wifiProgressStallCheckInterval, (_) {
      if (_wifiTransferCancelled || _wifiLinkLostDuringTransfer) return;
      final idle = DateTime.now().difference(_wifiLastProgressAt);
      if (idle >= _wifiProgressStallTimeout) {
        _wifiLinkLostDuringTransfer = true;
        AppLog.w(
          '[WiFi] no UDP progress for ${idle.inSeconds}s — treating as link loss '
          '(cancel download; will probe after exit)',
        );
      }
    });
  }

  /// Update local-merge copy progress for the banner ([mergeFraction]).
  void updateMergeProgress(int mergedBytes) {
    if (state.phase != WifiTransferPhase.mergingFiles) return;
    final total = state.mergeTotalBytes;
    final capped =
        total > 0 ? mergedBytes.clamp(0, total) : (mergedBytes < 0 ? 0 : mergedBytes);
    if (capped == state.mergedBytes) return;
    state = state.copyWith(mergedBytes: capped);
  }

  /// Ensure [mergeTotalBytes] is set once prepare knows the concat size.
  void ensureMergeTotalBytes(int totalBytes) {
    if (state.phase != WifiTransferPhase.mergingFiles) return;
    if (totalBytes <= 0 || state.mergeTotalBytes > 0) return;
    state = state.copyWith(mergeTotalBytes: totalBytes);
  }

  /// Quick reachability probe (UDP AT+GSTAT) used after a mid-transfer failure
  /// to tell apart "phone auto-switched off the device AP" (unreachable) from a
  /// connected-but-lossy link (still reachable).
  ///
  /// When the first probe fails, re-binds Wi‑Fi usage once and retries — some
  /// OEMs drop [forceWifiUsage] mid-session while the phone is still associated
  /// with the device AP; a re-bind can restore UDP routing without falling back
  /// to BLE.
  Future<({bool ok, bool networkUnreachable})> _wifiReachabilityProbe(
    WifiTransferClient udpClient,
  ) async {
    try {
      final r = await udpClient.pingDetailed();
      if (r.ok) return (ok: true, networkUnreachable: false);
      if (r.networkUnreachable) return (ok: false, networkUnreachable: true);
      await _rebindForceWifiUsage(reason: 'reachability probe retry');
      final r2 = await udpClient.pingDetailed();
      if (r2.ok) return (ok: true, networkUnreachable: false);
      return (ok: false, networkUnreachable: r2.networkUnreachable);
    } catch (_) {}
    return (ok: false, networkUnreachable: false);
  }

  Future<bool> _deviceIsRecordingOrPaused() async {
    try {
      final rs = await ref
          .read(deviceControllerProvider.notifier)
          .getRecordingStatus();
      if (rs == null) return false;
      return rs.state == 'recording' || rs.state == 'paused';
    } catch (_) {
      return false;
    }
  }

  /// Bytes to persist when Wi‑Fi falls back to BLE. Merge validation must use
  /// [diskMergeBytes] (complete slices only); the progress bar must not drop
  /// below what the user already saw when a partial Wi‑Fi re-download overwrote
  /// earlier BLE slices (e.g. stall mid‑`0001.opus` after 39% overall).
  Future<int> _wifiBleFallbackProgressBytes({
    required String recordingId,
    required int diskMergeBytes,
    required int resumeByteOffset,
    required int udpSessionBytes,
    required int itemResumeOffset,
    int? expectedBytes,
  }) async {
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final row = await recRepo.getById(recordingId);
    final dbReceived = row?.receivedBytes ?? 0;
    final sessionProgress = resumeByteOffset + udpSessionBytes;
    var peak = [
      diskMergeBytes,
      sessionProgress,
      itemResumeOffset,
      resumeByteOffset,
      dbReceived,
    ].reduce(math.max);
    final exp = (expectedBytes ?? 0) > 0
        ? expectedBytes!
        : (row?.expectedBytes ?? 0);
    if (exp > 0 && peak > exp) {
      final capped = math.max(diskMergeBytes, math.min(peak, exp));
      AppLog.i(
        '[WiFi] fallback progress capped $peak → $capped (expected=$exp '
        'disk=$diskMergeBytes session=$sessionProgress)',
      );
      peak = capped;
    } else if (peak != diskMergeBytes) {
      AppLog.i(
        '[WiFi] fallback progress peak=$peak '
        '(disk=$diskMergeBytes session=$sessionProgress db=$dbReceived '
        'itemOffset=$itemResumeOffset resumeOffset=$resumeByteOffset)',
      );
    }
    return peak;
  }

  Future<void> _markWifiBleFallbackResume(
    String recordingId, {
    int? receivedBytes,
    int? expectedBytes,
  }) async {
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    await recRepo.updateTransfer(
      id: recordingId,
      state: 'transferring',
      error: 'Wi‑Fi sync incomplete; continuing over Bluetooth.',
      errorCode: 'wifi_fast_sync_fallback',
      recordingState: 'transferring',
      receivedBytes: receivedBytes,
      expectedBytes:
          expectedBytes != null && expectedBytes > 0 ? expectedBytes : null,
      clearTransferFinishedAt: true,
    );
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(recordingId));
  }

  /// Persist peak session progress when Wi‑Fi stops mid‑UDP (user turned Wi‑Fi off,
  /// link dropped, etc.) so BLE resume does not snap back to 0%.
  Future<void> _markWifiMidTransferBleFallback({
    required String deviceId,
    required WifiBatchItem item,
  }) async {
    final recordingId = item.recordingId;
    final sessionId = item.sessionId;
    try {
      final accountKey = requireAccountDbKey(ref);
      final sessionDir = await AccountStoragePaths.deviceSessionDirectory(
        accountKey: accountKey,
        deviceId: deviceId,
        sessionId: sessionId,
      );
      final diskBytes = await sumCompleteSessionOpusSliceBytes(sessionDir);
      final wifiState = state;
      final resumeOffset = wifiState.resumeByteOffset;
      final udpRunBytes = wifiState.receivedBytes;

      final sessionTotals = await _querySessionTotals(sessionId);
      final listSize = sessionTotals?.sizeBytes ?? 0;
      var mergeExpected = 0;
      final expectedBytes = item.expectedBytes;
      if (expectedBytes != null && expectedBytes > mergeExpected) {
        mergeExpected = expectedBytes;
      }
      if (listSize > mergeExpected) mergeExpected = listSize;

      final fallbackProgress = await _wifiBleFallbackProgressBytes(
        recordingId: recordingId,
        diskMergeBytes: diskBytes,
        resumeByteOffset: resumeOffset,
        udpSessionBytes: udpRunBytes,
        itemResumeOffset: item.resumeByteOffset,
        expectedBytes: mergeExpected > 0 ? mergeExpected : expectedBytes,
      );
      AppLog.i(
        '[WiFi] mid-transfer BLE fallback recording=$recordingId '
        'peak=$fallbackProgress disk=$diskBytes resume=$resumeOffset '
        'udpRun=$udpRunBytes itemOffset=${item.resumeByteOffset}',
      );
      await _markWifiBleFallbackResume(
        recordingId,
        receivedBytes: fallbackProgress,
        expectedBytes: mergeExpected > 0 ? mergeExpected : expectedBytes,
      );
    } catch (e, st) {
      AppLog.w(
        '[WiFi] mid-transfer fallback progress failed recording=$recordingId',
        e,
        st,
      );
      await _markWifiBleFallbackResume(recordingId);
    }
  }

  Future<void> _applyWifiItemFailureDb(
    String recordingId,
    Object e, {
    WifiVerifyFailureKind? verifyKind,
  }) async {
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final phaseAtFailure = state.phase;
    final setupOnly = _isWifiSetupOnlyFailure(e) ||
        _isWifiPreTransferPhase(phaseAtFailure) ||
        (phaseAtFailure != WifiTransferPhase.transferring &&
            phaseAtFailure != WifiTransferPhase.mergingFiles);
    if (setupOnly) {
      final kind = e is WifiVerifyFailure
          ? e.kind
          : verifyKind;
      final errorCode = kind == WifiVerifyFailureKind.networkUnreachable
          ? 'wifi_fast_sync_disconnected'
          : 'wifi_fast_sync_unreachable';
      await recRepo.updateTransfer(
        id: recordingId,
        state: 'transferring',
        error: e.toString(),
        errorCode: errorCode,
        recordingState: 'transferring',
        clearTransferFinishedAt: true,
      );
    } else {
      await recRepo.updateTransfer(
        id: recordingId,
        state: 'failed',
        error: e.toString(),
        errorCode: 'wifi_transfer_failed',
        transferFinishedAt: DateTime.now(),
        recordingState: 'failed',
      );
    }
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(recordingId));
  }

  /// One UDP download + merge. `null` = user cancelled ([_finalizeUserCancelledTransfer] ran).
  ///
  /// When [showMergingPhase] is true (typically the last batch item), set
  /// [WifiTransferPhase.mergingFiles] after enqueue so the banner/step UI reflects
  /// local concat. Earlier batch items stay on [WifiTransferPhase.transferring]
  /// because the controller immediately moves to the next UDP download.
  Future<bool?> _wifiDownloadAndMergeOneItem({
    required String deviceId,
    required WifiBatchItem item,
    required bool notifyOnComplete,
    bool showMergingPhase = false,
  }) async {
    final recordingId = item.recordingId;
    final sessionId = item.sessionId;
    final expectedBytes = item.expectedBytes;
    final startFile = item.startFile;

    final accountKey = requireAccountDbKey(ref);
    final sessionDir = await AccountStoragePaths.deviceSessionDirectory(
      accountKey: accountKey,
      deviceId: deviceId,
      sessionId: sessionId,
    );

    // Reconcile resume markers with on-disk reality BEFORE we start UDP / write any state.
    // Shared [resolveSessionResumeMarkers] keeps BLE / Wi‑Fi / batch on one byte + file-index floor.
    final markers = await resolveSessionResumeMarkers(
      sessionDirPath: sessionDir,
      startFile: startFile,
      dbReceivedBytes: item.resumeByteOffset,
    );
    final resumeByteOffset = markers.resumeByteOffset;
    final resumeFileIndex = markers.resumeFileIndex;
    if (resumeFileIndex > 0 ||
        resumeByteOffset != item.resumeByteOffset) {
      AppLog.i(
        '[WiFi] resume marker recording=$recordingId session=$sessionId '
        'startFile=$startFile resumeFileIndex=$resumeFileIndex '
        'resumeByteOffset=$resumeByteOffset (item=${item.resumeByteOffset})',
      );
    }

    state = state.copyWith(
      phase: WifiTransferPhase.transferring,
      recordingId: recordingId,
      resumeByteOffset: resumeByteOffset,
      receivedBytes: 0,
      totalBytes: 0,
      fileIndex: 0,
      totalFiles: 0,
      resumeFileIndex: resumeFileIndex,
      mergedBytes: 0,
      mergeTotalBytes: 0,
    );
    AppLog.i('[WiFi] batch item UDP recording=$recordingId session=$sessionId');

    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final startedAt = DateTime.now();

    final initialProgress = (expectedBytes != null && expectedBytes > 0)
        ? (resumeByteOffset / expectedBytes).clamp(0.0, 0.99)
        : 0.0;
    await recRepo.updateTransfer(
      id: recordingId,
      state: 'transferring',
      progress: initialProgress,
      receivedBytes: resumeByteOffset > 0 ? resumeByteOffset : null,
      expectedBytes:
          expectedBytes != null && expectedBytes > 0 ? expectedBytes : null,
      transferStartedAt: startedAt,
      recordingState: 'transferring',
      // BLE handoff sets [wifi_handoff] on cancel; clear once UDP path is live.
      error: '',
      errorCode: '',
    );
    bumpRecordingsLists(ref);

    // UDP `onProgress` fires per ~1KB DATA frame (e.g. ~200 callbacks per 200KB file).
    // Without throttling, fire-and-forget [updateTransfer] calls flood sqflite's serialized
    // write queue and produce "database has been locked for 0:00:10" warnings while the
    // [done] write at the end of merge gets stuck behind the backlog. In‑memory `state`
    // still updates every frame so the UI banner is smooth.
    DateTime lastDbWriteAt = DateTime.fromMillisecondsSinceEpoch(0);
    int lastDbWriteFileIdx = -1;
    const dbWriteMinInterval = Duration(milliseconds: 250);
    // Serialize throttled progress writes. Fire-and-forget updates can finish *after* the
    // final `state: done` write and overwrite `transfer_state` back to `transferring`
    // (stuck top banner / list progress).
    var progressWriteChain = Future<void>.value();

    final udpClient = _fastSync!.transferClient!;
    _startWifiProgressStallWatchdog();
    ref.read(deviceControllerProvider.notifier).touchWifiHandoff();
    final int totalBytes;
    try {
      totalBytes = await udpClient.downloadSession(
      sessionId: sessionId,
      sessionDir: sessionDir,
      startFile: startFile,
      onFileProgress: (received, total) {
        _noteWifiTransferProgress();
        state = state.copyWith(
          receivedBytes: received,
          totalBytes: total > 0 ? total : 0,
        );
      },
      onOverallProgress: (fileIdx, totalFiles, overallBytes) {
        _noteWifiTransferProgress();
        state = state.copyWith(
          fileIndex: fileIdx,
          totalFiles: totalFiles,
          receivedBytes: overallBytes,
        );

        final cum = resumeByteOffset + overallBytes;
        double? progress;
        if (expectedBytes != null && expectedBytes > 0) {
          progress = (cum / expectedBytes).clamp(0.0, 0.99);
        } else if (totalFiles > 0) {
          // Include files completed BEFORE this WiFi run (BLE leg) so DB-backed list/banner
          // does not snap from 5%→0% the moment Wi‑Fi takes over.
          progress = ((resumeFileIndex + fileIdx) / totalFiles).clamp(0.0, 0.99);
        }

        // Throttle: persist on file boundaries or when min interval elapsed.
        final now = DateTime.now();
        final crossedFile = fileIdx != lastDbWriteFileIdx;
        if (!crossedFile && now.difference(lastDbWriteAt) < dbWriteMinInterval) {
          return;
        }
        lastDbWriteAt = now;
        lastDbWriteFileIdx = fileIdx;

        progressWriteChain = progressWriteChain.then(
          (_) => recRepo.updateTransfer(
            id: recordingId,
            state: 'transferring',
            progress: progress,
            receivedBytes: cum,
            expectedBytes: expectedBytes != null && expectedBytes > 0
                ? expectedBytes
                : null,
          ),
        ).catchError((_) {});
      },
      shouldCancel: () =>
          _wifiTransferCancelled || _wifiLinkLostDuringTransfer,
    );
    } finally {
      _stopWifiProgressStallWatchdog();
    }

    await progressWriteChain;

    // True cumulative bytes = COMPLETE on-disk slice sum AFTER this UDP run, NOT
    // `resumeByteOffset + totalBytes`. Wi‑Fi writes each slice by filename and
    // OVERWRITES any BLE-leg copy of the same 0001..N files. When `startFile` is
    // null the firmware re-sends the whole session, so adding the pre-run offset
    // double-counts (e.g. 289194 bytes on disk reported as 578388). That inflated
    // total then drives `expectedBytes`, and `prepareSessionOpusMerge` refuses
    // forever with "parts not ready" (mergeTotalEst < 90% of expected) — the
    // recording is stuck in transferring/merging and never reaches `done`.
    //
    // Use the COMPLETE-slice sum (not sumSessionOpusPartBytes): a half-finished
    // BLE `0002.opus.part` left next to the Wi‑Fi-completed `0002.opus` of the
    // same index would otherwise be added on top (e.g. 370224 reported as 492543)
    // and re-trigger the same stuck-merge. This matches exactly what the merge
    // concatenates, for BOTH a true resume (BLE 0001..0149 + Wi‑Fi 0150..N) and a
    // full re-download (same files overwritten).
    final diskAfterBytes = await sumCompleteSessionOpusSliceBytes(sessionDir);
    final cumulativeBytes =
        diskAfterBytes > 0 ? diskAfterBytes : (resumeByteOffset + totalBytes);
    if (cumulativeBytes != resumeByteOffset + totalBytes) {
      AppLog.i(
        '[WiFi] cumulative bytes from disk=$cumulativeBytes '
        '(resumeOffset=$resumeByteOffset + udp=$totalBytes would double-count) '
        'recording=$recordingId',
      );
    }

    // Stall / Wi‑Fi-off often fires while waiting for TRANSFER_DONE after all
    // slices are already on disk. Prefer merge over BLE fallback when complete.
    if (_wifiLinkLostDuringTransfer && !_wifiTransferCancelled) {
      final exp = (expectedBytes != null && expectedBytes > 0)
          ? expectedBytes
          : 0;
      final looksComplete = cumulativeBytes > 0 &&
          ((exp > 0 && cumulativeBytes >= (exp * 0.9).round()) ||
              (exp <= 0 && cumulativeBytes >= resumeByteOffset + totalBytes &&
                  totalBytes > 0));
      if (looksComplete) {
        AppLog.w(
          '[WiFi] UDP stalled/cancelled but disk looks complete '
          'recording=$recordingId bytes=$cumulativeBytes expected=$exp — merge',
        );
      } else {
        AppLog.w(
          '[WiFi] UDP aborted by progress stall / link loss '
          'recording=$recordingId session=$sessionId '
          'disk=$cumulativeBytes expected=$exp',
        );
        throw StateError('Wi‑Fi link lost mid-transfer (AP unreachable)');
      }
    }

    if (_wifiTransferCancelled) {
      AppLog.i(
          '[WiFi] user cancelled after UDP download recording=$recordingId');
      await _finalizeUserCancelledTransfer(
        recordingId: recordingId,
        transferStartedAt: startedAt,
        expectedBytes: expectedBytes,
        cumulativePayloadBytes: cumulativeBytes,
        notifyOnComplete: notifyOnComplete,
      );
      return null;
    }

    // UDP download produced no bytes (likely firmware rejected `AT+DOWNLOAD`, e.g.
    // because a BLE pull is still active). Going through the [mergingFiles] phase
    // here would paint the top banner at 100% (see [transfer_progress_banner] —
    // `WifiTransferPhase.mergingFiles` with no live BLE renders `p = 1.0`) while
    // nothing was actually transferred. Fail fast so the row goes back to the
    // normal "failed → resync" UI and BLE can re-arm.
    if (cumulativeBytes <= 0) {
      AppLog.w(
        '[WiFi] UDP download produced 0 bytes recording=$recordingId session=$sessionId '
        '— marking transfer failed (likely firmware busy with another transfer).',
      );
      state = state.copyWith(
        phase: WifiTransferPhase.failed,
        receivedBytes: 0,
        error: 'Wi‑Fi UDP download returned 0 bytes',
      );
      await recRepo.updateTransfer(
        id: recordingId,
        state: 'failed',
        errorCode: 'wifi_download_empty',
        error: 'Wi‑Fi UDP download produced no data',
        transferStartedAt: startedAt,
        transferFinishedAt: DateTime.now(),
        recordingState: 'failed',
      );
      bumpRecordingsLists(ref);
      ref.invalidate(recordingByIdProvider(recordingId));
      if (notifyOnComplete) {
        ref.read(transferCompletedEventProvider.notifier).state =
            TransferCompletedEvent(recordingId: recordingId, success: false);
      }
      return false;
    }

    final finalCum = cumulativeBytes;
    final canonicalExpected = DeviceController.canonicalTransferExpectedBytes(
      dbExpected: expectedBytes,
      transferredTotal: finalCum,
    );

    // Completeness floor for the merge gate. NEVER use [canonicalExpected] here:
    // it shrinks `expected` down to whatever we happened to receive this run, so
    // a Wi‑Fi leg that lost UDP packets (firmware `TRANSFER_DONE file_count=0`,
    // no `.opus` written, only a stale BLE `part_last` left on disk) passes the
    // 90%% byte gate against its OWN tiny total and silently finalizes a truncated
    // file. Take the largest of the STOP/DB size and the device's `AT+LIST` size
    // as the true session size so [prepareSessionOpusMerge] refuses to mark a
    // short merge `done` and the row stays `transferring` for BLE/Wi‑Fi resume.
    final sessionTotals = await _querySessionTotals(sessionId);
    final listSize = sessionTotals?.sizeBytes ?? 0;
    final listFiles = sessionTotals?.files ?? 0;
    var completenessExpected = 0;
    if (expectedBytes != null && expectedBytes > completenessExpected) {
      completenessExpected = expectedBytes;
    }
    if (listSize > completenessExpected) completenessExpected = listSize;
    final mergeExpected =
        completenessExpected > 0 ? completenessExpected : canonicalExpected;

    AppLog.i(
      '[WiFi] UDP done recording=$recordingId session=$sessionId '
      'bytes=$finalCum mergeExpected=$mergeExpected '
      '(dbExpected=${expectedBytes ?? 0} listSize=$listSize listFiles=$listFiles) '
      '— enqueue background merge',
    );
    final queue = ref.read(sessionMergeQueueProvider);
    final enqueued = await queue.enqueue(SessionMergeJob(
      recordingId: recordingId,
      deviceId: deviceId,
      sessionId: sessionId,
      receivedBytes: finalCum,
      expectedBytes: mergeExpected,
      expectedTotalFiles: listFiles > 1 ? listFiles : null,
      transferStartedAt: startedAt,
      deleteAfterSync: item.deleteAfterSync,
      notifyOnComplete: notifyOnComplete,
      strictSliceValidation: true,
      source: 'wifi',
      suppressBleResumeAfterWifi: true,
      onCopyProgress: showMergingPhase
          ? (copied) {
              ensureMergeTotalBytes(finalCum > 0 ? finalCum : 0);
              updateMergeProgress(copied);
            }
          : null,
    ));
    if (!enqueued) {
      AppLog.w(
        '[WiFi] background merge not enqueued recording=$recordingId '
        '(parts not ready or validation failed)',
      );
      final fallbackProgress = await _wifiBleFallbackProgressBytes(
        recordingId: recordingId,
        diskMergeBytes: finalCum,
        resumeByteOffset: resumeByteOffset,
        udpSessionBytes: totalBytes,
        itemResumeOffset: item.resumeByteOffset,
        expectedBytes: (mergeExpected ?? 0) > 0 ? mergeExpected : expectedBytes,
      );
      await _markWifiBleFallbackResume(
        recordingId,
        receivedBytes: fallbackProgress,
        expectedBytes: (mergeExpected ?? 0) > 0 ? mergeExpected : expectedBytes,
      );
      return false;
    }
    // List row shows `merging` via DB. Only the last batch item flips the Wi‑Fi
    // controller into [mergingFiles] — earlier items must stay `transferring` so
    // the next UDP download owns the banner.
    if (showMergingPhase) {
      state = state.copyWith(
        phase: WifiTransferPhase.mergingFiles,
        mergedBytes: 0,
        mergeTotalBytes: finalCum > 0 ? finalCum : 0,
      );
    } else {
      state = state.copyWith(
        phase: WifiTransferPhase.transferring,
        mergedBytes: 0,
        mergeTotalBytes: 0,
      );
    }
    return true;
  }

  /// Enable hotspot once, verify UDP once, then download/merge each item. Always disables hotspot at the end
  /// (unless user cancel path already cleaned up). Stops early if the device starts recording/paused between items.
  Future<WifiFastSyncBatchResult> transferWifiBatch({
    required List<WifiBatchItem> items,
    WifiBatchResolveStartFile? resolveStartFile,
    bool notifyOnComplete = true,
  }) async {
    if (items.isEmpty) {
      return const WifiFastSyncBatchResult();
    }

    final deviceState = ref.read(deviceControllerProvider);
    final conn = deviceState.connection;
    final at = _getAtTransport(conn);
    if (conn == null || at == null) {
      AppLog.w('[WiFi] transferWifiBatch aborted: BLE not connected');
      state = state.copyWith(
        phase: WifiTransferPhase.failed,
        error: 'BLE not connected',
      );
      return const WifiFastSyncBatchResult();
    }

    try {
      final rs = await ref
          .read(deviceControllerProvider.notifier)
          .getRecordingStatus();
      if (rs != null && (rs.state == 'recording' || rs.state == 'paused')) {
        AppLog.w(
            '[WiFi] transferWifiBatch aborted: device is recording or paused');
        state = state.copyWith(
          phase: WifiTransferPhase.failed,
          error: 'Device is recording; stop recording before Wi‑Fi sync.',
        );
        return const WifiFastSyncBatchResult();
      }
    } catch (_) {}

    final deviceId = conn.device.remoteId.toString();
    final first = items.first;
    _wifiTransferCancelled = false;

    var succeeded = 0;
    var failed = 0;
    var userCancelled = false;
    var abortedForRecording = false;
    WifiBleFallbackReason? bleFallbackReason;
    WifiHotspotInfo? batchHotspot;

    try {
      AppLog.i(
        '[WiFi] transferWifiBatch ${items.length} item(s) first=${first.recordingId} '
        'session=${first.sessionId}',
      );

      state = state.copyWith(
        phase: WifiTransferPhase.enablingHotspot,
        recordingId: first.recordingId,
        resumeByteOffset: first.resumeByteOffset,
        receivedBytes: 0,
        totalBytes: 0,
        fileIndex: 0,
        totalFiles: 0,
        resumeFileIndex: 0,
        mergedBytes: 0,
        mergeTotalBytes: 0,
      );
      _fastSync = WifiFastSyncSession(at: at);
      batchHotspot = await _fastSync!.enableHotspot();
      final hotspot = batchHotspot;
      state = state.copyWith(hotspot: hotspot);
      AppLog.i('[WiFi] Phase enablingHotspot done: $hotspot');

      state = state.copyWith(phase: WifiTransferPhase.connectingWifi);
      AppLog.i('[WiFi] Phase connectingWifi (OS will prompt / join AP)');
      final joinApiOk = await _fastSync!.connectPhone();
      if (joinApiOk) {
        AppLog.i('[WiFi] join API reported success for ${hotspot.ssid}');
      } else {
        AppLog.w(
          '[WiFi] join API reported false — will still try UDP (manual join / iOS NEHotspot quirk)',
        );
      }

      // Keep process traffic bound to the device AP for the rest of this batch.
      // connectPhone already forceWifiUsage(true) on success; this covers the
      // manual-join path and starts the periodic re-bind for OEM unbind mid-transfer.
      _startForceWifiKeepAlive();

      state = state.copyWith(phase: WifiTransferPhase.verifyingConnection);
      AppLog.i('[WiFi] Phase verifyingConnection (UDP AT+GSTAT, retries)');
      final udpClient = _fastSync!.transferClient!;
      final maxPingAttempts =
          joinApiOk ? (Platform.isIOS ? 18 : 10) : (Platform.isIOS ? 32 : 20);
      final pingGap = Platform.isIOS
          ? const Duration(seconds: 3)
          : const Duration(seconds: 2);
      if (Platform.isIOS) {
        AppLog.i(
            '[WiFi] iOS verify: up to $maxPingAttempts UDP pings, ${pingGap.inSeconds}s apart');
      }
      var pingOk = false;
      var verifyFailedUnreachable = false;
      for (var attempt = 0; attempt < maxPingAttempts; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(pingGap);
          // Re-bind before each retry — Android may have routed off the AP
          // between attempts when the hotspot has no internet.
          await _rebindForceWifiUsage(
            reason: 'verify retry ${attempt + 1}/$maxPingAttempts',
          );
        }
        final pingResult = await udpClient.pingDetailed();
        pingOk = pingResult.ok;
        if (pingOk) {
          if (!joinApiOk) {
            AppLog.i(
              '[WiFi] UDP OK on attempt ${attempt + 1} after join API was false '
              '(user joined "${hotspot.ssid}" manually or association was delayed)',
            );
          }
          break;
        }
        if (pingResult.networkUnreachable) {
          verifyFailedUnreachable = true;
          AppLog.w(
            '[WiFi] device AP unreachable on attempt ${attempt + 1} '
            '(phone Wi‑Fi off or not on "${hotspot.ssid}") — skip further UDP pings',
          );
          break;
        }
        if (attempt == 0 || attempt == maxPingAttempts - 1) {
          AppLog.w(
            '[WiFi] UDP ping fail attempt ${attempt + 1}/$maxPingAttempts '
            '${hotspot.ip}:${hotspot.port}',
          );
        }
      }
      if (!pingOk) {
        throw WifiVerifyFailure(
          verifyFailedUnreachable
              ? WifiVerifyFailureKind.networkUnreachable
              : WifiVerifyFailureKind.timedOut,
          hotspot: hotspot,
        );
      }
      AppLog.i(
          '[WiFi] Phase verifyingConnection done — UDP OK ${hotspot.ip}:${hotspot.port}');

      for (var i = 0; i < items.length; i++) {
        if (_wifiTransferCancelled) {
          userCancelled = true;
          break;
        }
        if (await _deviceIsRecordingOrPaused()) {
          AppLog.w(
            '[WiFi] Batch stopped: device recording/paused '
            '(${items.length - i} item(s) not started — hotspot will close)',
          );
          abortedForRecording = true;
          break;
        }

        final item = items[i];
        try {
          String? sf = item.startFile;
          if (sf == null && resolveStartFile != null) {
            sf = await resolveStartFile(item.recordingId, item.sessionId);
          }
          final resolved = WifiBatchItem(
            recordingId: item.recordingId,
            sessionId: item.sessionId,
            expectedBytes: item.expectedBytes,
            startFile: sf,
            resumeByteOffset: item.resumeByteOffset,
            deleteAfterSync: item.deleteAfterSync,
          );

          try {
            final ok = await _wifiDownloadAndMergeOneItem(
              deviceId: deviceId,
              item: resolved,
              notifyOnComplete: notifyOnComplete,
              showMergingPhase: i == items.length - 1,
            );
            if (ok == null) {
              userCancelled = true;
              break;
            }
            if (ok) {
              succeeded++;
            } else {
              failed++;
              // [_wifiDownloadAndMergeOneItem] already marked BLE fallback with peak progress.
            }
          } catch (e, st) {
            AppLog.e('[WiFi] batch item failed recording=${item.recordingId}',
                e, st);
            failed++;
            await _markWifiMidTransferBleFallback(
              deviceId: deviceId,
              item: resolved,
            );
            if (_isWifiSetupOnlyFailure(e)) {
              bleFallbackReason =
                  WifiBleFallbackReason.phoneWifiDisconnected;
              break;
            }
            // A mid-transfer failure (e.g. "No UDP AT response") usually means the
            // phone's OS quietly switched off the no-internet device AP back to the
            // saved internet Wi‑Fi, so UDP to 192.168.4.1 no longer routes. Re-bind
            // once (OEM may have dropped forceWifiUsage while still associated),
            // then probe: if the recorder is unreachable, it's an auto-switch
            // (actionable by the user) — stop the batch and surface the rejoin
            // prompt instead of hammering every remaining file through a dead path.
            await _rebindForceWifiUsage(reason: 'mid-transfer item failure');
            final probe = await _wifiReachabilityProbe(udpClient);
            if (!probe.ok) {
              bleFallbackReason = probe.networkUnreachable
                  ? WifiBleFallbackReason.phoneWifiDisconnected
                  : WifiBleFallbackReason.phoneOnOtherWifi;
              AppLog.w(
                '[WiFi] recorder unreachable after item failure — phone likely '
                'auto-switched Wi‑Fi; stop batch and prompt rejoin '
                '(networkUnreachable=${probe.networkUnreachable})',
              );
              break;
            }
          }
        } catch (e, st) {
          AppLog.e(
              '[WiFi] batch resolve/start failed recording=${item.recordingId}',
              e,
              st);
          failed++;
          await _applyWifiItemFailureDb(item.recordingId, e);
          if (_isWifiSetupOnlyFailure(e)) {
            bleFallbackReason = WifiBleFallbackReason.phoneOnOtherWifi;
            break;
          }
        }
      }

      // Verify passed (we entered the item loop) but nothing synced over Wi‑Fi:
      // every file NACKed / `TRANSFER_DONE file_count=0`. The phone associated
      // with the AP yet the data path never carried packets — treat as a BLE
      // fallback so the caller resumes BLE promptly and tells the user, instead
      // of silently stalling until a later GSTAT poll re-arms BLE.
      if (bleFallbackReason == null &&
          succeeded == 0 &&
          failed > 0 &&
          !userCancelled &&
          !abortedForRecording) {
        // Pick the right prompt: if the recorder is still reachable the link was
        // simply too lossy (move closer); if not, the phone dropped the device AP
        // (auto-switched back to internet Wi‑Fi) and the user must rejoin it.
        final probe = await _wifiReachabilityProbe(udpClient);
        bleFallbackReason = probe.ok
            ? WifiBleFallbackReason.transferFailed
            : (probe.networkUnreachable
                ? WifiBleFallbackReason.phoneWifiDisconnected
                : WifiBleFallbackReason.phoneOnOtherWifi);
        AppLog.w(
          '[WiFi] transferWifiBatch: associated with AP but 0 files delivered — '
          'recorderReachable=${probe.ok} reason=$bleFallbackReason '
          'first=${first.recordingId}',
        );
      }

      state = state.copyWith(phase: WifiTransferPhase.disablingHotspot);
      await _cleanup();
      state = state.copyWith(phase: WifiTransferPhase.completed);

      return WifiFastSyncBatchResult(
        succeeded: succeeded,
        failed: failed,
        userCancelled: userCancelled,
        abortedForRecording: abortedForRecording,
        bleFallbackReason: bleFallbackReason,
        fallbackHotspot: _hotspotForFallbackDialog(batchHotspot),
      );
    } catch (e, st) {
      // A "Wi‑Fi setup:" failure means the phone never reached the device AP
      // (still on another Wi‑Fi / hotspot join or UDP ping failed). That is the
      // expected "switch to BLE" path, not a real transfer error — don't shout
      // to Sentry or flip the row to a hard failure; the caller falls back to
      // BLE and keeps showing the fast‑sync UI.
      final setupOnly = _isWifiSetupOnlyFailure(e);
      if (setupOnly) {
        if (e is WifiVerifyFailure) {
          bleFallbackReason =
              e.kind == WifiVerifyFailureKind.networkUnreachable
                  ? WifiBleFallbackReason.phoneWifiDisconnected
                  : WifiBleFallbackReason.phoneOnOtherWifi;
        } else {
          bleFallbackReason = WifiBleFallbackReason.phoneOnOtherWifi;
        }
        AppLog.w(
          '[WiFi] transferWifiBatch: device AP unreachable (phone not on device '
          'Wi‑Fi?) — falling back to BLE first=${first.recordingId}: $e',
        );
      } else {
        AppLog.e(
            '[WiFi] transferWifiBatch failed first=${first.recordingId}', e, st);
        unawaited(
          SentryService.captureWifiBatchFailure(
            recordingId: first.recordingId,
            sessionId: first.sessionId,
            phase: state.phase.name,
            error: e,
          ),
        );
      }
      await _applyWifiItemFailureDb(first.recordingId, e);
      state = state.copyWith(
        phase: WifiTransferPhase.failed,
        error: e.toString(),
      );
      await _cleanup();
      if (notifyOnComplete && !setupOnly) {
        ref.read(transferCompletedEventProvider.notifier).state =
            TransferCompletedEvent(
                recordingId: first.recordingId, success: false);
      }
      return WifiFastSyncBatchResult(
        succeeded: succeeded,
        failed: failed + 1,
        userCancelled: userCancelled,
        abortedForRecording: abortedForRecording,
        bleFallbackReason: bleFallbackReason,
        fallbackHotspot: _hotspotForFallbackDialog(batchHotspot),
      );
    }
  }

  /// Full WiFi transfer flow for a session (single item); see [transferWifiBatch] for batching.
  Future<bool> transferSession({
    required String recordingId,
    required String sessionId,
    int? expectedBytes,
    String? startFile,
    int resumeByteOffset = 0,
    bool deleteAfterSync = true,
    bool notifyOnComplete = true,
  }) async {
    final r = await transferWifiBatch(
      items: [
        WifiBatchItem(
          recordingId: recordingId,
          sessionId: sessionId,
          expectedBytes: expectedBytes,
          startFile: startFile,
          resumeByteOffset: resumeByteOffset,
          deleteAfterSync: deleteAfterSync,
        ),
      ],
      notifyOnComplete: notifyOnComplete,
    );
    return r.isOverallSuccess;
  }

  /// Cancel ongoing WiFi transfer.
  ///
  /// While UDP [downloadSession] is running, cleanup is deferred until the loop
  /// sends `AT+CANCEL` and exits — otherwise [dispose] would race and break cancel.
  Future<void> cancel() async {
    _wifiTransferCancelled = true;
    final p = state.phase;
    if (p == WifiTransferPhase.transferring ||
        p == WifiTransferPhase.mergingFiles) {
      AppLog.i('[WiFi] cancel deferred until transfer/merge stops (phase=$p)');
      return;
    }
    await _cleanup();
    state = const WifiTransferState();
  }

  /// Cooperative shutdown + wait until [state] is idle (after [transferWifiBatch] unwinds).
  ///
  /// Used when the user taps **Resync** to fall back to BLE while Fast Sync still holds
  /// [DeviceController.startWifiHandoff] / an active batch.
  Future<bool> cancelAndAwaitFullyIdle({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (!state.isActive) return true;
    await cancel();
    final deadline = DateTime.now().add(timeout);
    while (state.isActive && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (state.isActive) {
      AppLog.w(
        '[WiFi] cancelAndAwaitFullyIdle: still active after ${timeout.inSeconds}s '
        '(phase=${state.phase})',
      );
    }
    return !state.isActive;
  }

  Future<void> _finalizeUserCancelledTransfer({
    required String recordingId,
    required DateTime transferStartedAt,
    int? expectedBytes,
    required int cumulativePayloadBytes,
    required bool notifyOnComplete,
  }) async {
    try {
      final recRepo = await ref.read(recordingsRepositoryProvider.future);
      await recRepo.updateTransfer(
        id: recordingId,
        state: 'failed',
        error: 'Wi‑Fi sync closed by user',
        errorCode: 'wifi_user_closed',
        transferStartedAt: transferStartedAt,
        transferFinishedAt: DateTime.now(),
        recordingState: 'failed',
        receivedBytes:
            cumulativePayloadBytes > 0 ? cumulativePayloadBytes : null,
        expectedBytes:
            expectedBytes != null && expectedBytes > 0 ? expectedBytes : null,
      );
      bumpRecordingsLists(ref);
      ref.invalidate(recordingByIdProvider(recordingId));
    } catch (e, st) {
      AppLog.w('[WiFi] _finalizeUserCancelledTransfer DB update failed', e, st);
    }
    state = state.copyWith(phase: WifiTransferPhase.disablingHotspot);
    await _cleanup();
    if (notifyOnComplete) {
      ref.read(transferCompletedEventProvider.notifier).state =
          TransferCompletedEvent(recordingId: recordingId, success: false);
    }
    // Sheet may already be disposed — reset provider so list/banner do not stay on failed.
    state = const WifiTransferState();
  }

  /// Reset to idle state.
  void reset() {
    state = const WifiTransferState();
  }

  /// Clears phase UI after a completed/failed run (hotspot already disabled in [transferSession]).
  void clearEndedState() {
    state = const WifiTransferState();
  }

  AtTransport? _getAtTransport(dynamic conn) {
    if (conn == null) return null;
    return AtTransport(
      commandRx: conn.commandRx,
      responseTx: conn.responseTx,
      fileData: conn.fileData,
      mtu: conn.mtu,
    );
  }

  /// Authoritative session size / file count from the device (`AT+LIST`), used
  /// as the merge completeness floor. Queried over BLE after the UDP run (BLE
  /// stays connected through the handoff) so a Wi‑Fi leg that received 0 valid
  /// files cannot be merged into a truncated `done` file. Non-fatal: returns
  /// `null` on any error and the caller falls back to the DB / canonical size.
  Future<({int sizeBytes, int files})?> _querySessionTotals(
      String sessionId) async {
    try {
      final conn = ref.read(deviceControllerProvider).connection;
      final at = _getAtTransport(conn);
      if (at == null) return null;
      final resp =
          await at.send('AT+LIST=$sessionId', timeout: const Duration(seconds: 6));
      if (resp['ok'] != true) return null;
      final data = resp['data'];
      if (data is! Map) return null;
      int asInt(Object? v) {
        if (v is int) return v;
        if (v is num) return v.toInt();
        return int.tryParse('${v ?? ''}') ?? 0;
      }

      return (
        sizeBytes: asInt(data['size'] ?? data['bytes']),
        files: asInt(data['files'] ?? data['total']),
      );
    } catch (e, st) {
      AppLog.w('[WiFi] AT+LIST session totals query failed (non-fatal)', e, st);
      return null;
    }
  }

  /// Hotspot credentials to show in the BLE-fallback dialog. Prefer the batch-local
  /// copy captured at enable time — provider [state.hotspot] may already be cleared
  /// by the time the sheet reads it.
  WifiHotspotInfo? _hotspotForFallbackDialog(WifiHotspotInfo? batchHotspot) {
    final hs = batchHotspot ?? state.hotspot;
    if (hs == null || hs.ssid.trim().isEmpty) return null;
    return hs;
  }

  Future<void> _cleanup() async {
    _stopForceWifiKeepAlive();
    _stopWifiProgressStallWatchdog();
    try {
      final bleAlive =
          ref.read(deviceControllerProvider).connection != null;
      await _fastSync?.teardown(
        disconnectPhone: true,
        disableHotspot: bleAlive,
      );
      if (!bleAlive) {
        AppLog.w(
            '[WiFi] cleanup: BLE link gone, skipped AT+WIFI=OFF (saves ~16s timeout)');
      }
    } catch (e) {
      AppLog.w('WiFi cleanup failed (non-fatal)', e);
    }
    _fastSync = null;
  }
}
