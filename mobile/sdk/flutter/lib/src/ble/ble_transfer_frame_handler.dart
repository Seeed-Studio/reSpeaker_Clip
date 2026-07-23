import 'dart:typed_data';

import '../utils/crc32.dart';
import 'clip_file_data.dart';

/// Mutable BLE file-transfer framing state for one `AT+DOWNLOAD` leg.
class BleTransferFrameState {
  bool useFraming = false;
  String? currentFilename;
  int currentFileDeclaredSize = 0;
  int bytesThisFile = 0;
  int fileCrc = 0;
  int nextSeq = 0;
  int fileCompleteCount = 0;
}

/// Result of feeding one BLE file-data notification through
/// [BleTransferFrameHandler.handle].
sealed class BleTransferFrameResult {
  const BleTransferFrameResult();
}

/// Malformed typed frame — log and continue.
final class BleTransferFrameInvalid extends BleTransferFrameResult {
  final String reason;
  const BleTransferFrameInvalid(this.reason);
}

/// Legacy firmware: entire notify body is raw bytes (no binary framing).
final class BleTransferFrameRaw extends BleTransferFrameResult {
  final Uint8List bytes;
  const BleTransferFrameRaw(this.bytes);
}

/// Raw chunk received while framed mode is active — should be ignored.
final class BleTransferFrameUnexpectedRaw extends BleTransferFrameResult {
  final int length;
  const BleTransferFrameUnexpectedRaw(this.length);
}

final class BleTransferFrameFileStart extends BleTransferFrameResult {
  final String filename;
  final int fileSize;
  const BleTransferFrameFileStart({
    required this.filename,
    required this.fileSize,
  });
}

final class BleTransferFrameData extends BleTransferFrameResult {
  final int seq;
  final Uint8List payload;
  final bool duplicateSeq;
  final bool seqJump;
  final bool orphanBeforeFileStart;
  const BleTransferFrameData({
    required this.seq,
    required this.payload,
    required this.duplicateSeq,
    required this.seqJump,
    this.orphanBeforeFileStart = false,
  });
}

/// FILE_END with matching CRC — slice complete.
final class BleTransferFrameFileEndOk extends BleTransferFrameResult {
  final String filename;
  final int localCrc32;
  final int deviceCrc32;
  final int fileCompleteCount;
  final int declaredFileSize;
  final int bytesThisFile;
  final bool usedFraming;
  const BleTransferFrameFileEndOk({
    required this.filename,
    required this.localCrc32,
    required this.deviceCrc32,
    required this.fileCompleteCount,
    required this.declaredFileSize,
    required this.bytesThisFile,
    required this.usedFraming,
  });
}

/// Stale FILE_END for an already-completed slice — ignore.
final class BleTransferFrameFileEndStale extends BleTransferFrameResult {
  final String filename;
  final int deviceCrc32;
  const BleTransferFrameFileEndStale({
    required this.filename,
    required this.deviceCrc32,
  });
}

/// CRC mismatch — discard partial file and resync from [resyncStartFile].
final class BleTransferFrameFileEndCrcMismatch extends BleTransferFrameResult {
  final String filename;
  final int localCrc32;
  final int deviceCrc32;
  final String resyncStartFile;
  const BleTransferFrameFileEndCrcMismatch({
    required this.filename,
    required this.localCrc32,
    required this.deviceCrc32,
    required this.resyncStartFile,
  });
}

final class BleTransferFrameTransferDone extends BleTransferFrameResult {
  final String sessionId;
  final int fileCount;
  const BleTransferFrameTransferDone({
    required this.sessionId,
    required this.fileCount,
  });
}

/// Parses Clip BLE file-data frames and maintains [BleTransferFrameState].
///
/// Host apps map [BleTransferFrameResult] to DB / file I/O. Protocol-specific
/// leg control (continuous mode, spurious TRANSFER_DONE) stays in the app.
class BleTransferFrameHandler {
  const BleTransferFrameHandler._();

  /// Sanitize a device filename for local filesystem use.
  static String sanitizeFilename(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'part.opus';
    final replaced = n.replaceAll(RegExp(r'[\\/]+'), '_');
    final safe = replaced.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return safe.isEmpty ? 'part.opus' : safe;
  }

  /// Guess filename when DATA arrives before FILE_START (resume / mid-slice).
  static String orphanFilenameBeforeFileStart({
    required String? effectiveStartFile,
    required int fileCompleteCount,
  }) {
    final t = effectiveStartFile?.trim();
    if (t != null && t.isNotEmpty) return t;
    return '${(fileCompleteCount + 1).toString().padLeft(4, '0')}.opus';
  }

  static int? partNumberFromFilename(String name) {
    final m = RegExp(r'^(\d{4})\.opus$').firstMatch(name.trim().toLowerCase());
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Feed one notification payload; updates [state] in place.
  static BleTransferFrameResult handle({
    required List<int> bytes,
    required BleTransferFrameState state,
    String? effectiveStartFile,
  }) {
    final parsed = parseClipFileDataNotify(bytes);

    if (parsed is ClipParsedInvalid) {
      return BleTransferFrameInvalid(parsed.reason);
    }

    if (parsed is ClipParsedRaw) {
      if (state.useFraming) {
        return BleTransferFrameUnexpectedRaw(parsed.bytes.length);
      }
      return BleTransferFrameRaw(parsed.bytes);
    }

    state.useFraming = true;

    if (parsed is ClipParsedFileStart) {
      state.currentFilename = parsed.filename;
      state.currentFileDeclaredSize = parsed.fileSize;
      state.bytesThisFile = 0;
      state.fileCrc = 0;
      state.nextSeq = 0;
      return BleTransferFrameFileStart(
        filename: parsed.filename,
        fileSize: parsed.fileSize,
      );
    }

    if (parsed is ClipParsedData) {
      var orphanBeforeFileStart = false;
      if (state.currentFilename == null) {
        orphanBeforeFileStart = true;
        final guess = orphanFilenameBeforeFileStart(
          effectiveStartFile: effectiveStartFile,
          fileCompleteCount: state.fileCompleteCount,
        );
        state.currentFilename = sanitizeFilename(guess);
        state.nextSeq = parsed.seq;
        state.fileCrc = 0;
      }

      var duplicateSeq = false;
      var seqJump = false;
      if (parsed.seq != state.nextSeq) {
        if (parsed.seq < state.nextSeq) {
          duplicateSeq = true;
          return BleTransferFrameData(
            seq: parsed.seq,
            payload: parsed.payload,
            duplicateSeq: true,
            seqJump: false,
            orphanBeforeFileStart: orphanBeforeFileStart,
          );
        }
        seqJump = true;
        state.nextSeq = parsed.seq;
      }
      state.nextSeq = parsed.seq + 1;

      if (state.currentFileDeclaredSize > 0) {
        state.bytesThisFile += parsed.payload.length;
      }
      state.fileCrc = crc32Ieee(parsed.payload, state.fileCrc);

      return BleTransferFrameData(
        seq: parsed.seq,
        payload: parsed.payload,
        duplicateSeq: duplicateSeq,
        seqJump: seqJump,
        orphanBeforeFileStart: orphanBeforeFileStart,
      );
    }

    if (parsed is ClipParsedFileEnd) {
      final crcLocal = state.fileCrc & 0xffffffff;
      final crcDev = parsed.crc32 & 0xffffffff;
      final fn = state.currentFilename ?? '';

      if (crcLocal != crcDev) {
        final fnPart = partNumberFromFilename(fn);
        if (fnPart != null && fnPart <= state.fileCompleteCount) {
          _resetCurrentFile(state);
          return BleTransferFrameFileEndStale(
            filename: fn,
            deviceCrc32: crcDev,
          );
        }

        final resync =
            '${(state.fileCompleteCount + 1).toString().padLeft(4, '0')}.opus';
        _resetCurrentFile(state);
        return BleTransferFrameFileEndCrcMismatch(
          filename: fn,
          localCrc32: crcLocal,
          deviceCrc32: crcDev,
          resyncStartFile: resync,
        );
      }

      final declaredSize = state.currentFileDeclaredSize;
      final bytesThisFile = state.bytesThisFile;
      final usedFraming = state.useFraming;
      _resetCurrentFile(state);
      state.fileCompleteCount++;

      return BleTransferFrameFileEndOk(
        filename: fn,
        localCrc32: crcLocal,
        deviceCrc32: crcDev,
        fileCompleteCount: state.fileCompleteCount,
        declaredFileSize: declaredSize,
        bytesThisFile: bytesThisFile,
        usedFraming: usedFraming,
      );
    }

    if (parsed is ClipParsedTransferDone) {
      return BleTransferFrameTransferDone(
        sessionId: parsed.sessionId,
        fileCount: parsed.fileCount,
      );
    }

    return const BleTransferFrameInvalid('unhandled frame type');
  }

  static void _resetCurrentFile(BleTransferFrameState state) {
    state.currentFilename = null;
    state.currentFileDeclaredSize = 0;
    state.bytesThisFile = 0;
    state.fileCrc = 0;
    state.nextSeq = 0;
  }
}
