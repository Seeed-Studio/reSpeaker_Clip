import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'session_opus_part_names.dart';

/// 1 MB buffer — same sweet spot as Wi‑Fi merge (few syscalls on eMMC/UFS).
const int kSessionOpusMergeBufferBytes = 1024 * 1024;

/// Throttle merge progress callbacks (~30–50 updates per 160 MB session).
const int kSessionOpusMergeProgressEveryBytes = 4 * 1024 * 1024;

/// Concatenate sorted [parts] into [mergedPath] using [RandomAccessFile] + reusable buffer.
Future<File?> mergeSessionOpusPartFiles(
  List<File> parts,
  String mergedPath, {
  bool Function()? shouldCancel,
  void Function(int copiedBytes)? onProgress,
}) async {
  if (parts.isEmpty) return null;

  final buf = Uint8List(kSessionOpusMergeBufferBytes);
  final mergedFile = File(mergedPath);
  final mergedRaf = await mergedFile.open(mode: FileMode.write);
  var total = 0;
  var lastReported = 0;
  try {
    for (final f in parts) {
      if (shouldCancel?.call() == true) return null;
      final len = await f.length();
      if (len <= 0) continue;
      final raf = await f.open(mode: FileMode.read);
      try {
        while (true) {
          if (shouldCancel?.call() == true) return null;
          final n = await raf.readInto(buf);
          if (n <= 0) break;
          await mergedRaf.writeFrom(buf, 0, n);
          total += n;
          if (onProgress != null &&
              total - lastReported >= kSessionOpusMergeProgressEveryBytes) {
            lastReported = total;
            onProgress(total);
          }
        }
      } finally {
        await raf.close();
      }
    }
  } finally {
    await mergedRaf.flush();
    await mergedRaf.close();
  }
  if (total > 0 && onProgress != null && total != lastReported) {
    onProgress(total);
  }
  return total > 0 ? mergedFile : null;
}

/// List `.opus` / `.opus.part` under [sessionDirPath], sort by basename, merge.
Future<File?> mergeSessionOpusPartsInDirectory(
  String sessionDirPath,
  String mergedPath, {
  bool Function()? shouldCancel,
  void Function(int copiedBytes)? onProgress,
}) async {
  final sessionDir = Directory(sessionDirPath);
  if (!await sessionDir.exists()) return null;

  final parts = sessionDir.listSync().whereType<File>().where((f) {
    final lower = f.path.toLowerCase();
    return lower.endsWith('.opus') || lower.endsWith('.opus.part');
  }).toList()
    ..sort((a, b) => compareSessionOpusPartFilename(
          p.basename(a.path),
          p.basename(b.path),
        ));

  return mergeSessionOpusPartFiles(
    parts,
    mergedPath,
    shouldCancel: shouldCancel,
    onProgress: onProgress,
  );
}

/// Sum bytes of the COMPLETE, de-duplicated `NNNN.opus` slices only — i.e. exactly
/// the set the merge will concatenate ([SessionOpusSliceInventory.orderedCompleteSlices]).
///
/// Unlike [sumSessionOpusPartBytes] this ignores `.opus.part` fragments and counts
/// each slice index once. Required for the Wi‑Fi cumulative-byte calculation: when a
/// slice exists BOTH as a stale BLE `0002.opus.part` and a Wi‑Fi-completed `0002.opus`,
/// the naive sum double-counts that slice, inflating `expectedBytes` so the merge
/// refuses forever ("parts not ready" → recording stuck in transferring/merging).
Future<int> sumCompleteSessionOpusSliceBytes(String sessionDirPath) async {
  try {
    final dir = Directory(sessionDirPath);
    if (!await dir.exists()) return 0;
    final nonEmpty = <File>[];
    for (final entry in dir.listSync()) {
      if (entry is! File) continue;
      final lower = p.basename(entry.path).toLowerCase();
      if (!lower.endsWith('.opus') && !lower.endsWith('.opus.part')) continue;
      try {
        if (await entry.length() > 0) nonEmpty.add(entry);
      } catch (_) {}
    }
    final inv = inventorySessionOpusParts(nonEmpty);
    var total = 0;
    for (final f in inv.orderedCompleteSlices) {
      try {
        total += await f.length();
      } catch (_) {}
    }
    return total;
  } catch (_) {
    return 0;
  }
}

/// Cheap stat of all merge-eligible part files (for progress total).
Future<int> sumSessionOpusPartBytes(String sessionDirPath) async {
  try {
    final dir = Directory(sessionDirPath);
    if (!await dir.exists()) return 0;
    var total = 0;
    for (final entry in dir.listSync()) {
      if (entry is File) {
        final lower = p.basename(entry.path).toLowerCase();
        if (lower.endsWith('.opus') || lower.endsWith('.opus.part')) {
          try {
            total += await entry.length();
          } catch (_) {}
        }
      }
    }
    return total;
  } catch (_) {
    return 0;
  }
}
