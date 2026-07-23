import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'raw_opus_utils.dart';
import 'session_opus_part_names.dart';
import 'session_opus_parts_merge.dart';

/// Outcome of validating local opus parts before merge.
sealed class SessionMergePrepareResult {
  const SessionMergePrepareResult();
}

/// Parts not ready — keep [transfer_state] transferring and resume download later.
class SessionMergeNotReady extends SessionMergePrepareResult {
  const SessionMergeNotReady({
    this.errorCode = 'transfer_incomplete_resume',
    this.progress,
  });

  final String errorCode;
  final double? progress;
}

/// Validation failed — mark transfer failed (or keep transferring for gap errors).
class SessionMergePrepareFailed extends SessionMergePrepareResult {
  const SessionMergePrepareFailed({
    required this.errorCode,
    this.error,
    this.markFailed = true,
    this.progress,
  });

  final String errorCode;
  final String? error;
  final bool markFailed;
  final double? progress;
}

/// Ready to merge in background.
class SessionMergePrepareReady extends SessionMergePrepareResult {
  const SessionMergePrepareReady({
    required this.partsForSink,
    required this.mergeParts,
    required this.mergeTotalEst,
    this.mergeWithSliceGaps = false,
    this.gapMissingSlices = const [],
  });

  final List<File> partsForSink;
  final List<File> mergeParts;
  final int mergeTotalEst;
  final bool mergeWithSliceGaps;
  final List<int> gapMissingSlices;
}

/// Result of streaming parts into the merged file + duration probe.
class SessionMergePerformResult {
  const SessionMergePerformResult({
    required this.success,
    this.mergedBytes = 0,
    this.durationSeconds,
    this.errorCode = '',
    this.error = '',
    this.mergeWithSliceGaps = false,
    this.gapMissingSlices = const [],
  });

  final bool success;
  final int mergedBytes;
  final int? durationSeconds;
  final String errorCode;
  final String error;
  final bool mergeWithSliceGaps;
  final List<int> gapMissingSlices;
}

(String message, String code)? undersizedMergedTransferNote({
  required int mergedBytes,
  required int? expectedBytes,
  required String recordingId,
}) {
  final exp = expectedBytes ?? 0;
  if (exp <= 0 || mergedBytes >= (exp * 0.9).round()) return null;
  AppLog.e(
    'POSSIBLY INCOMPLETE TRANSFER (recordingId=$recordingId): merged=$mergedBytes bytes < 90%% of expected=$exp. '
    'Device reported transfer done but payload is short — verify playback or re-sync.',
  );
  return (
    'Merged file smaller than expected; recording may be incomplete.',
    'possibly_incomplete_transfer',
  );
}

/// Inspect [sessionDir] and decide whether background merge can start.
Future<SessionMergePrepareResult> prepareSessionOpusMerge({
  required Directory sessionDir,
  required int receivedBytes,
  int? expectedBytes,
  bool strictSliceValidation = true,
  int? expectedTotalFiles,
}) async {
  if (!sessionDir.existsSync()) {
    return const SessionMergeNotReady();
  }

  final parts = sessionDir.listSync().whereType<File>().where((f) {
    final lower = f.path.toLowerCase();
    return lower.endsWith('.opus') ||
        lower.endsWith('.opus.part') ||
        lower.endsWith('.tmp');
  }).toList()
    ..sort((a, b) => compareSessionOpusPartFilename(
          p.basename(a.path),
          p.basename(b.path),
        ));

  final partSizes = <String, int>{};
  for (final f in parts) {
    try {
      partSizes[p.basename(f.path)] = await f.length();
    } catch (e) {
      if (e is PathNotFoundException ||
          e.toString().contains('No such file')) {
        continue;
      }
      rethrow;
    }
  }

  final nonEmptyParts = <File>[];
  for (final f in parts) {
    var len = partSizes[p.basename(f.path)] ?? 0;
    if (len <= 0) {
      // A just-closed slice can momentarily stat as 0 bytes due to filesystem
      // write-behind (notably iOS after IOSink.close()). Re-check once before
      // treating it as empty so we never delete a valid slice — especially the
      // final one — and silently shorten the merged file.
      try {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        len = await f.length();
      } catch (_) {}
    }
    if (len > 0) {
      partSizes[p.basename(f.path)] = len;
      nonEmptyParts.add(f);
    } else {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  final inventory = inventorySessionOpusParts(nonEmptyParts);
  var mergeWithSliceGaps = false;
  List<int> gapMissingSlices = const [];
  final missing = inventory.missingIndices;
  final exp = expectedBytes ?? 0;

  if (inventory.duplicateIndices.isNotEmpty) {
    return SessionMergePrepareFailed(
      errorCode: 'transfer_gap_missing_slices',
      error:
          'Duplicate slice files (${inventory.duplicateIndices.take(5).join(", ")}) in session folder. Re-sync.',
      markFailed: false,
      progress: exp > 0 ? (receivedBytes / exp).clamp(0.0, 0.99) : null,
    );
  }

  // Slice-count completeness: when the firmware told us how many slices the
  // session has, a missing FINAL slice would otherwise pass (`missingIndices`
  // only catches holes *below* the highest local slice) and the merged file
  // would be silently shorter than the recording. BUT the firmware total can be
  // inflated by one during record-while-transfer / reconnect (e.g. total=5 for a
  // 4-slice session), so a slice-count shortfall alone is not proof of loss.
  // Treat BYTES as authoritative: only refuse when slices are short AND the
  // merged bytes are also short of the expected session size.
  if (strictSliceValidation &&
      expectedTotalFiles != null &&
      expectedTotalFiles > 0) {
    final haveAllSlices =
        inventory.maxIndex >= expectedTotalFiles && missing.isEmpty;
    final sliceBytesSoFar = inventory.orderedCompleteSlices.fold<int>(
      0,
      (s, f) => s + (partSizes[p.basename(f.path)] ?? 0),
    );
    final bytesShort = exp > 0 && sliceBytesSoFar < (exp * 0.9).round();
    if (!haveAllSlices && bytesShort) {
      AppLog.w(
        'prepareSessionOpusMerge: slice count + bytes short — present=${inventory.orderedCompleteSlices.length} '
        'maxIndex=${inventory.maxIndex} expectedTotal=$expectedTotalFiles '
        'internalMissing=${missing.length} sliceBytes=$sliceBytesSoFar exp=$exp',
      );
      return SessionMergeNotReady(
        errorCode: 'transfer_incomplete_resume',
        progress: exp > 0 ? (receivedBytes / exp).clamp(0.0, 0.99) : null,
      );
    }
  }

  if (strictSliceValidation) {
    if (missing.isNotEmpty) {
      final allowGaps = missing.length <= 2;
      if (!allowGaps) {
        AppLog.w(
          'prepareSessionOpusMerge: strict validation failed — '
          'present=${inventory.orderedCompleteSlices.length} max=${inventory.maxIndex} '
          'missing=${missing.length}',
        );
        return SessionMergePrepareFailed(
          errorCode: 'transfer_gap_missing_slices',
          error:
              'Missing ${missing.length} slice(s) in session (e.g. ${missing.take(5).join(", ")}). Re-sync or clear session folder.',
          markFailed: false,
          progress: exp > 0 ? (receivedBytes / exp).clamp(0.0, 0.99) : null,
        );
      }
      mergeWithSliceGaps = true;
      gapMissingSlices = missing;
    }
  } else if (missing.isNotEmpty) {
    mergeWithSliceGaps = true;
    gapMissingSlices = missing;
    AppLog.w(
      'prepareSessionOpusMerge: non-strict merge with ${missing.length} missing slice(s) '
      '(max=${inventory.maxIndex}, present=${inventory.orderedCompleteSlices.length})',
    );
  }

  final partsForSink = inventory.orderedCompleteSlices;
  final mergeParts = inventory.allArtifacts;

  final hasCompleteSlice = partsForSink.any(
    (f) => isCanonicalCompleteSessionOpusSlice(p.basename(f.path).toLowerCase()),
  );
  final mergeTotalEst = partsForSink.fold<int>(
    0,
    (s, f) => s + (partSizes[p.basename(f.path)] ?? 0),
  );

  if (!hasCompleteSlice && partsForSink.isEmpty) {
    return SessionMergeNotReady(
      progress: exp > 0 ? (receivedBytes / exp).clamp(0.0, 0.99) : null,
    );
  }
  if (strictSliceValidation && exp > 0 && mergeTotalEst < (exp * 0.9).round()) {
    return SessionMergeNotReady(
      errorCode: 'transfer_incomplete_resume',
      progress: (receivedBytes / exp).clamp(0.0, 0.99),
    );
  }
  if (partsForSink.isEmpty) {
    return const SessionMergePrepareFailed(
      errorCode: 'no_valid_audio',
      markFailed: true,
    );
  }

  if (mergeWithSliceGaps && gapMissingSlices.isNotEmpty) {
    AppLog.w(
      'prepareSessionOpusMerge: will merge with gaps — missing indices '
      '${gapMissingSlices.take(20).join(", ")}${gapMissingSlices.length > 20 ? "…" : ""} '
      '(${gapMissingSlices.length} total, mergeBytes=$mergeTotalEst)',
    );
  }

  AppLog.i(
    'prepareSessionOpusMerge: ready slices=${partsForSink.length} '
    'maxIndex=${inventory.maxIndex} mergeBytes=$mergeTotalEst strict=$strictSliceValidation',
  );

  return SessionMergePrepareReady(
    partsForSink: partsForSink,
    mergeParts: mergeParts,
    mergeTotalEst: mergeTotalEst,
    mergeWithSliceGaps: mergeWithSliceGaps,
    gapMissingSlices: gapMissingSlices,
  );
}

/// Concatenate [ready.partsForSink] into [mergedPath], probe duration, delete parts.
Future<SessionMergePerformResult> performSessionOpusMerge({
  required SessionMergePrepareReady ready,
  required String mergedPath,
  required String recordingId,
  int? expectedBytes,
  int? fallbackDurationSeconds,
  void Function(int copiedBytes)? onCopyProgress,
  bool Function()? shouldCancel,
}) async {
  final mergeStarted = DateTime.now();
  AppLog.i(
    'performSessionOpusMerge: copy start recording=$recordingId '
    'parts=${ready.partsForSink.length}',
  );
  final mergedOut = await mergeSessionOpusPartFiles(
    ready.partsForSink,
    mergedPath,
    shouldCancel: shouldCancel,
    onProgress: onCopyProgress,
  );
  var total = 0;
  if (mergedOut != null) {
    total = await mergedOut.length();
  }
  AppLog.i(
    'performSessionOpusMerge: copy done recording=$recordingId '
    'elapsedMs=${DateTime.now().difference(mergeStarted).inMilliseconds} '
    'bytes=$total',
  );

  if (total <= 0) {
    return const SessionMergePerformResult(
      success: false,
      errorCode: 'no_valid_audio',
    );
  }

  int? durationSec;
  try {
    durationSec = await resolveMergedOpusDurationSeconds(mergedPath, total);
  } catch (_) {}
  if (durationSec == null) {
    if (fallbackDurationSeconds != null && fallbackDurationSeconds > 0) {
      durationSec = fallbackDurationSeconds;
    } else if (total > 0) {
      durationSec = estimateRawOpusDurationSecondsFromBytes(total);
    }
  }

  var expWarn = expectedBytes ?? 0;
  final incompleteNote = undersizedMergedTransferNote(
    mergedBytes: total,
    expectedBytes: expWarn > 0 ? expWarn : null,
    recordingId: recordingId,
  );
  var errMsg = incompleteNote != null ? incompleteNote.$1 : '';
  var errCode = incompleteNote != null ? incompleteNote.$2 : '';
  if (ready.mergeWithSliceGaps && ready.gapMissingSlices.isNotEmpty) {
    errCode = 'transfer_merged_missing_slice';
    errMsg =
        'Merged with ${ready.gapMissingSlices.length} missing slice(s); audio may be shorter than recorded.';
    AppLog.e(
      'performSessionOpusMerge: merged with ${ready.gapMissingSlices.length} missing slice(s) '
      'recording=$recordingId durationSec=$durationSec bytes=$total',
    );
  }

  for (final f in ready.mergeParts) {
    try {
      await f.delete();
    } catch (_) {}
  }

  return SessionMergePerformResult(
    success: true,
    mergedBytes: total,
    durationSeconds: durationSec,
    errorCode: errCode,
    error: errMsg,
    mergeWithSliceGaps: ready.mergeWithSliceGaps,
    gapMissingSlices: ready.gapMissingSlices,
  );
}

int? canonicalTransferExpectedBytes({
  int? dbExpected,
  required int transferredTotal,
}) {
  if (transferredTotal <= 0) return dbExpected;
  if (dbExpected == null || dbExpected <= 0) return transferredTotal;
  if (dbExpected > (transferredTotal * 1.05).round()) return transferredTotal;
  return dbExpected;
}
