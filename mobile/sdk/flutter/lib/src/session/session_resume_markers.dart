import 'dart:io';
import 'dart:math' as math;

import 'session_opus_part_names.dart';
import 'session_opus_parts_merge.dart';

/// Immutable resume snapshot shared by BLE / Wi‑Fi / Fast Sync batch flows.
class SessionResumeMarkers {
  const SessionResumeMarkers({
    this.startFile,
    this.resumeByteOffset = 0,
    this.resumeFileIndex = 0,
  });

  /// Firmware `AT+DOWNLOAD` resume arg, e.g. `0150.opus`. `null` → from first file.
  final String? startFile;

  /// Progress floor: max(DB `receivedBytes`, complete on-disk slice bytes).
  final int resumeByteOffset;

  /// Files completed before this run (`0150.opus` → 149).
  final int resumeFileIndex;
}

/// Parse a resume marker like `0150.opus` into the count of files completed
/// before this run (149). Returns 0 for `null`, empty, or unparseable input.
int resumeFileIndexFromStartFile(String? startFile) {
  if (startFile == null) return 0;
  final s = startFile.trim().toLowerCase();
  if (s.isEmpty) return 0;
  final m = RegExp(r'^(\d{1,6})\.opus$').firstMatch(s);
  if (m == null) return 0;
  final n = int.tryParse(m.group(1) ?? '');
  if (n == null || n <= 1) return 0;
  return n - 1;
}

/// Canonical on-disk + DB byte floor for resume / handoff progress.
Future<int> resolveResumeByteFloor({
  required String sessionDirPath,
  int dbReceivedBytes = 0,
}) async {
  final disk = await sumCompleteSessionOpusSliceBytes(sessionDirPath);
  return math.max(dbReceivedBytes < 0 ? 0 : dbReceivedBytes, disk);
}

/// Build markers from an already-resolved [startFile] and session directory.
Future<SessionResumeMarkers> resolveSessionResumeMarkers({
  required String sessionDirPath,
  String? startFile,
  int dbReceivedBytes = 0,
}) async {
  final offset = await resolveResumeByteFloor(
    sessionDirPath: sessionDirPath,
    dbReceivedBytes: dbReceivedBytes,
  );
  return SessionResumeMarkers(
    startFile: startFile,
    resumeByteOffset: offset,
    resumeFileIndex: resumeFileIndexFromStartFile(startFile),
  );
}

/// Derive the next `AT+DOWNLOAD` resume file from the session directory.
///
/// Rules:
/// - If [preferredStartFile] is present, use it.
/// - If numbered slices exist with gaps, resume from the first missing index.
/// - If slices are contiguous, resume from `maxIndex + 1`.
/// - If only `part_last.opus` exists, return `null` so the caller can start
///   from the first file.
Future<String?> resolveSessionResumeStartFile({
  required String sessionDirPath,
  String? preferredStartFile,
}) async {
  if (preferredStartFile != null) {
    final s = preferredStartFile.trim();
    if (s.isNotEmpty) return s;
  }

  final dir = Directory(sessionDirPath);
  if (!await dir.exists()) return null;

  final nonEmpty = <File>[];
  for (final entry in dir.listSync()) {
    if (entry is! File) continue;
    final name = entry.path.toLowerCase();
    if (!name.endsWith('.opus') && !name.endsWith('.opus.part')) continue;
    try {
      if (await entry.length() > 0) nonEmpty.add(entry);
    } catch (_) {}
  }

  final inv = inventorySessionOpusParts(nonEmpty);
  if (inv.orderedCompleteSlices.isEmpty) return null;
  if (inv.missingIndices.isNotEmpty) {
    return '${inv.missingIndices.first.toString().padLeft(4, '0')}.opus';
  }
  return '${(inv.maxIndex + 1).toString().padLeft(4, '0')}.opus';
}
