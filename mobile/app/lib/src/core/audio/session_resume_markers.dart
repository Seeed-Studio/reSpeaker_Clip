import 'dart:math' as math;

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
