import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/account_db_key.dart';
import '../log/app_log.dart';
import '../observability/sentry_service.dart';
import '../storage/account_storage_paths.dart';
import 'raw_opus_utils.dart';
import 'session_merge_executor.dart';
import '../../features/device/presentation/device_controller.dart';
import '../../features/recordings/data/recordings_repository.dart';
import '../../features/recordings/presentation/recordings_controller.dart';

/// One background merge job after BLE/Wi‑Fi payload is complete.
class SessionMergeJob {
  SessionMergeJob({
    required this.recordingId,
    required this.deviceId,
    required this.sessionId,
    required this.receivedBytes,
    this.expectedBytes,
    this.transferStartedAt,
    this.fallbackDurationSeconds,
    this.deleteAfterSync = true,
    this.notifyOnComplete = true,
    this.strictSliceValidation = true,
    this.source = 'ble',
    this.suppressBleResumeAfterWifi = false,
    this.expectedTotalFiles,
    this.onCopyProgress,
  });

  final String recordingId;
  final String deviceId;
  final String sessionId;
  final int receivedBytes;
  final int? expectedBytes;
  final DateTime? transferStartedAt;
  final int? fallbackDurationSeconds;
  /// Firmware-declared slice count for the session (`AT+DOWNLOAD`/`AT+LIST`).
  ///
  /// When known, the merge refuses to finish unless every slice `1..N` is
  /// present (no internal gap and no truncated tail), preventing a "done"
  /// recording that is silently shorter than what was captured.
  final int? expectedTotalFiles;
  final bool deleteAfterSync;
  final bool notifyOnComplete;
  final bool strictSliceValidation;
  final String source;
  final bool suppressBleResumeAfterWifi;
  /// Optional local-concat progress (Wi‑Fi banner [mergeFraction]).
  final void Function(int copiedBytes)? onCopyProgress;
}

/// Serial background queue: merge + duration probe without holding BLE/UDP.
class SessionMergeQueue {
  SessionMergeQueue(this.ref);

  final Ref ref;
  final List<SessionMergeJob> _pending = [];
  final Set<String> _activeRecordingIds = {};
  final Set<String> _activeSessionKeys = {};
  Future<void>? _chain;

  static String _sessionKey(String deviceId, String sessionId) =>
      '$deviceId|$sessionId';

  bool isMergingRecording(String recordingId) =>
      _activeRecordingIds.contains(recordingId);

  /// Enqueue merge; returns false when parts are not ready or validation failed.
  Future<bool> enqueue(SessionMergeJob job) async {
    if (_activeRecordingIds.contains(job.recordingId)) {
      AppLog.d(
        'SessionMergeQueue: skip duplicate recordingId=${job.recordingId}',
      );
      return true;
    }
    final sessionKey = _sessionKey(job.deviceId, job.sessionId);
    if (_activeSessionKeys.contains(sessionKey)) {
      AppLog.d(
        'SessionMergeQueue: skip duplicate session=$sessionKey',
      );
      return true;
    }

    final String accountKey;
    try {
      accountKey = requireAccountDbKey(ref);
    } catch (_) {
      AppLog.w(
        'SessionMergeQueue: account key not ready, skip enqueue recordingId=${job.recordingId}',
      );
      return false;
    }
    final sessionDir = Directory(
      await AccountStoragePaths.deviceSessionDirectory(
        accountKey: accountKey,
        deviceId: job.deviceId,
        sessionId: job.sessionId,
      ),
    );
    final prepare = await prepareSessionOpusMerge(
      sessionDir: sessionDir,
      receivedBytes: job.receivedBytes,
      expectedBytes: job.expectedBytes,
      strictSliceValidation: job.strictSliceValidation,
      expectedTotalFiles: job.expectedTotalFiles,
    );

    return await withFreshRecordingsRepo(ref, (recRepo) async {
    switch (prepare) {
      case SessionMergeNotReady(:final errorCode, :final progress):
        await recRepo.updateTransfer(
          id: job.recordingId,
          state: 'transferring',
          progress: progress,
          errorCode: errorCode,
          error: '',
          receivedBytes: job.receivedBytes,
          expectedBytes:
              job.expectedBytes != null && job.expectedBytes! > 0
                  ? job.expectedBytes
                  : null,
          transferStartedAt: job.transferStartedAt,
          recordingState: 'transferring',
        );
        bumpRecordingsLists(ref);
        ref.invalidate(recordingByIdProvider(job.recordingId));
        return false;
      case SessionMergePrepareFailed(
          :final errorCode,
          :final error,
          :final markFailed,
          :final progress,
        ):
        await recRepo.updateTransfer(
          id: job.recordingId,
          state: markFailed ? 'failed' : 'transferring',
          progress: progress ?? (markFailed ? 0.0 : null),
          errorCode: errorCode,
          error: error ?? '',
          receivedBytes: job.receivedBytes,
          expectedBytes:
              job.expectedBytes != null && job.expectedBytes! > 0
                  ? job.expectedBytes
                  : null,
          transferStartedAt: job.transferStartedAt,
          transferFinishedAt: markFailed ? DateTime.now() : null,
          recordingState: markFailed ? 'failed' : 'transferring',
        );
        bumpRecordingsLists(ref);
        ref.invalidate(recordingByIdProvider(job.recordingId));
        if (markFailed && job.notifyOnComplete) {
          ref.read(transferCompletedEventProvider.notifier).state =
              TransferCompletedEvent(
            recordingId: job.recordingId,
            success: false,
          );
        }
        return false;
      case SessionMergePrepareReady():
        break;
    }

    // Payload is fully received for this recording; only the local concat/merge
    // step remains. Show "merging" (indeterminate) for both BLE and Wi‑Fi until
    // the job finishes → `done`. The list/banner suppress this while bytes are
    // still actively streaming (liveRecordWhileBleTransfer).
    final expected = job.expectedBytes;
    await recRepo.updateTransfer(
      id: job.recordingId,
      state: 'merging',
      progress: 1.0,
      receivedBytes: job.receivedBytes,
      expectedBytes: expected != null && expected > 0 ? expected : null,
      transferStartedAt: job.transferStartedAt,
      recordingState: 'merging',
      error: '',
      errorCode: '',
    );
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(job.recordingId));

    _pending.add(job);
    _pump();
    return true;
    });
  }

  /// Re-enqueue rows stuck in `merging` after app restart.
  Future<void> resumeStuckMerges() async {
    await withFreshRecordingsRepo(ref, (recRepo) async {
    final stuck = await recRepo.listMergingTransfers();
    if (stuck.isEmpty) return;
    AppLog.i('SessionMergeQueue: resume ${stuck.length} stuck merge(s)');
    for (final rec in stuck) {
      final deviceId = rec.deviceId ?? '';
      final sessionId = rec.devicePath.trim();
      if (deviceId.isEmpty || sessionId.isEmpty) continue;
      if (_activeRecordingIds.contains(rec.id)) continue;
      if (_pending.any((j) => j.recordingId == rec.id)) continue;
      final job = SessionMergeJob(
        recordingId: rec.id,
        deviceId: deviceId,
        sessionId: sessionId,
        receivedBytes: rec.receivedBytes ?? 0,
        expectedBytes: rec.expectedBytes,
        transferStartedAt: rec.transferStartedAt,
        fallbackDurationSeconds: rec.durationSeconds,
        deleteAfterSync: true,
        notifyOnComplete: false,
        strictSliceValidation: true,
        source: 'resume',
      );
      _pending.add(job);
    }
    _pump();
    });
  }

  void _pump() {
    _chain ??= _drain();
    unawaited(_chain);
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      final job = _pending.removeAt(0);
      final sessionKey = _sessionKey(job.deviceId, job.sessionId);
      _activeRecordingIds.add(job.recordingId);
      _activeSessionKeys.add(sessionKey);
      try {
        await _runJob(job);
      } catch (e, st) {
        AppLog.e(
          'SessionMergeQueue: job failed recording=${job.recordingId}',
          e,
          st,
        );
        try {
          await withFreshRecordingsRepo(ref, (recRepo) async {
            await recRepo.updateTransfer(
              id: job.recordingId,
              state: 'failed',
              error: e.toString(),
              errorCode: 'merge_failed',
              transferFinishedAt: DateTime.now(),
              recordingState: 'failed',
            );
            bumpRecordingsLists(ref);
            ref.invalidate(recordingByIdProvider(job.recordingId));
          });
        } catch (_) {}
      } finally {
        _activeRecordingIds.remove(job.recordingId);
        _activeSessionKeys.remove(sessionKey);
      }
    }
    _chain = null;
  }

  Future<void> _runJob(SessionMergeJob job) async {
    final accountKey = requireAccountDbKey(ref);
    final sessionDir = Directory(
      await AccountStoragePaths.deviceSessionDirectory(
        accountKey: accountKey,
        deviceId: job.deviceId,
        sessionId: job.sessionId,
      ),
    );
    final mergedPath = await AccountStoragePaths.deviceSessionOpusFile(
      accountKey: accountKey,
      deviceId: job.deviceId,
      sessionId: job.sessionId,
    );

    final prepare = await prepareSessionOpusMerge(
      sessionDir: sessionDir,
      receivedBytes: job.receivedBytes,
      expectedBytes: job.expectedBytes,
      strictSliceValidation: job.strictSliceValidation,
      expectedTotalFiles: job.expectedTotalFiles,
    );
    if (prepare is! SessionMergePrepareReady) {
      AppLog.w(
        'SessionMergeQueue: prepare no longer ready recording=${job.recordingId}',
      );
      return;
    }

    final perform = await performSessionOpusMerge(
      ready: prepare,
      mergedPath: mergedPath,
      recordingId: job.recordingId,
      expectedBytes: job.expectedBytes,
      fallbackDurationSeconds: job.fallbackDurationSeconds,
      onCopyProgress: job.onCopyProgress,
    );

    await withFreshRecordingsRepo(ref, (recRepo) async {
    if (!perform.success) {
      await recRepo.updateTransfer(
        id: job.recordingId,
        state: 'failed',
        progress: 0.0,
        errorCode: perform.errorCode.isNotEmpty
            ? perform.errorCode
            : 'no_valid_audio',
        receivedBytes: job.receivedBytes,
        expectedBytes:
            job.expectedBytes != null && job.expectedBytes! > 0
                ? job.expectedBytes
                : null,
        transferStartedAt: job.transferStartedAt,
        transferFinishedAt: DateTime.now(),
        recordingState: 'failed',
      );
      bumpRecordingsLists(ref);
      ref.invalidate(recordingByIdProvider(job.recordingId));
      if (job.notifyOnComplete) {
        ref.read(transferCompletedEventProvider.notifier).state =
            TransferCompletedEvent(
          recordingId: job.recordingId,
          success: false,
        );
      }
      return;
    }

    final firmwareExpected = job.expectedBytes;
    final mergedLooksComplete = job.source == 'local_parts' ||
        firmwareExpected == null ||
        firmwareExpected <= 0 ||
        perform.mergedBytes >= (firmwareExpected * 0.9).round();
    if (!mergedLooksComplete ||
        perform.errorCode == 'possibly_incomplete_transfer') {
      AppLog.e(
        'SessionMergeQueue: refuse done — merged=${perform.mergedBytes} '
        'expected=$firmwareExpected recording=${job.recordingId}',
      );
      unawaited(
        SentryService.captureMergeRefused(
          recordingId: job.recordingId,
          mergedBytes: perform.mergedBytes,
          expectedBytes: firmwareExpected,
          source: job.source,
        ),
      );
      await recRepo.updateTransfer(
        id: job.recordingId,
        state: 'transferring',
        progress: firmwareExpected != null && firmwareExpected > 0
            ? (job.receivedBytes / firmwareExpected).clamp(0.0, 0.99)
            : null,
        localPath: mergedPath,
        sizeBytes: perform.mergedBytes,
        receivedBytes: job.receivedBytes,
        expectedBytes: firmwareExpected,
        transferStartedAt: job.transferStartedAt,
        recordingState: 'transferring',
        durationSeconds: perform.durationSeconds,
        error: perform.error.isNotEmpty
            ? perform.error
            : 'Merged file smaller than expected; re-sync required.',
        errorCode: perform.errorCode.isNotEmpty
            ? perform.errorCode
            : 'possibly_incomplete_transfer',
      );
      bumpRecordingsLists(ref);
      ref.invalidate(recordingByIdProvider(job.recordingId));
      return;
    }

    final doneExpected = DeviceController.canonicalTransferExpectedBytes(
      dbExpected: job.expectedBytes,
      transferredTotal: perform.mergedBytes,
    );

    await recRepo.updateTransfer(
      id: job.recordingId,
      state: 'done',
      progress: 1.0,
      localPath: mergedPath,
      sizeBytes: perform.mergedBytes,
      receivedBytes: job.receivedBytes,
      expectedBytes: doneExpected,
      transferStartedAt: job.transferStartedAt,
      transferFinishedAt: DateTime.now(),
      recordingState: 'done',
      durationSeconds: perform.durationSeconds,
      error: perform.error,
      errorCode: perform.errorCode,
    );
    AppLog.i(
      'SessionMergeQueue: done recording=${job.recordingId} '
      'bytes=${perform.mergedBytes} source=${job.source}',
    );
    ref
        .read(deviceControllerProvider.notifier)
        .abortStaleDownloadForRecording(job.recordingId);
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(job.recordingId));

    // Only Wi‑Fi fast-sync jobs set [SessionMergeJob.suppressBleResumeAfterWifi].
    // BLE merges already call suppress at enqueue time in [mergeAllParts]; applying
    // it again here for every source blocked resume of peer rows after any merge.
    if (job.suppressBleResumeAfterWifi) {
      ref
          .read(deviceControllerProvider.notifier)
          .suppressBleResumeAfterWifiFastSync(
        job.recordingId,
        ttl: const Duration(seconds: 15),
      );
    }

    ref.read(deviceControllerProvider.notifier).schedulePostMergeBleCleanup(
          recordingId: job.recordingId,
          sessionId: job.sessionId,
          mergedPath: mergedPath,
          expectedBytes: firmwareExpected ?? doneExpected,
          verifiedBytes: firmwareExpected,
          deleteAfterSync: job.deleteAfterSync,
          fetchBookmarks: true,
        );

    if (job.notifyOnComplete) {
      ref.read(transferCompletedEventProvider.notifier).state =
          TransferCompletedEvent(
        recordingId: job.recordingId,
        success: true,
      );
    }
    });
  }
}

final sessionMergeQueueProvider = Provider<SessionMergeQueue>((ref) {
  return SessionMergeQueue(ref);
});

final resumeStuckSessionMergesProvider = FutureProvider<void>((ref) async {
  await ref.read(sessionMergeQueueProvider).resumeStuckMerges();
});

/// One-time fix: older merges stored duration via a 32 kbps byte estimate
/// (`bytes / 4000`), which underreports VBR Opus (e.g. 16 h shown as ~11 h).
/// Re-probe done device recordings using the frame-accurate scan and correct
/// any duration that differs meaningfully.
final reprobeMergedDurationsProvider = FutureProvider<void>((ref) async {
  const flagKey = 'merged_duration_reprobe_v1';
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(flagKey) == true) return;

  var updated = 0;
  try {
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final rows = await recRepo.listDoneDeviceRecordingsWithLocalPath();
    for (final rec in rows) {
      final path = rec.localPath;
      if (path == null || !path.toLowerCase().endsWith('.opus')) continue;
      final f = File(path);
      if (!await f.exists()) continue;
      final len = await f.length();
      if (len <= 0) continue;

      final probed = await scanRawOpusDurationSeconds(path);
      if (probed == null || probed <= 0) continue;

      final old = rec.durationSeconds ?? 0;
      final delta = (probed - old).abs();
      if (old <= 0 || delta > (old * 0.03).ceil()) {
        await recRepo.updateDeviceRecordingMeta(
          id: rec.id,
          durationSeconds: probed,
        );
        updated++;
        AppLog.i(
          'reprobeMergedDurations: ${rec.id} duration ${old}s -> ${probed}s '
          '(bytes=$len)',
        );
      }
    }
  } catch (e, st) {
    AppLog.w('reprobeMergedDurations failed', e, st);
  } finally {
    await prefs.setBool(flagKey, true);
  }

  if (updated > 0) {
    AppLog.i('reprobeMergedDurations: corrected $updated recording duration(s)');
    bumpRecordingsLists(ref);
  }
});
