import 'dart:math' as math;

/// BLE / Wi‑Fi aligned transfer progress (0.995 cap until session merge completes).
///
/// Mirrors the algebra used by the reference App transfer UI so SDK callers
/// and dogfooding apps stay consistent.
class TransferProgress {
  TransferProgress._();

  static double? wifiAligned({
    required bool framedMode,
    required int currentFileDeclaredSize,
    required int bytesThisFile,
    required int receivedSession,
    required int? expectedSession,
    required int filesCompleted,
    required int deviceTotalFiles,
    required int deviceSessionBytes,
  }) {
    double? r;
    if (expectedSession != null && expectedSession > 0) {
      final uncapped = receivedSession / expectedSession;
      // Stale STOP/download snapshot: session still growing (live record) or
      // received ahead of expected — use file/session branches instead.
      if (uncapped <= 1.05 || deviceTotalFiles <= 0) {
        r = uncapped.clamp(0.0, 0.995);
      }
    }
    if (r == null && deviceTotalFiles > 0 && deviceSessionBytes > 0) {
      final filePart = filesCompleted / deviceTotalFiles;
      final bytePart = (receivedSession / deviceSessionBytes).clamp(0.0, 1.0);
      r = (filePart + bytePart / deviceTotalFiles).clamp(0.0, 0.995);
    } else if (deviceTotalFiles > 0) {
      if (framedMode && currentFileDeclaredSize > 0) {
        final inFlight =
            (bytesThisFile / currentFileDeclaredSize).clamp(0.0, 1.0);
        final denom = math.max(
          deviceTotalFiles,
          filesCompleted + (inFlight > 0 ? 1 : 0),
        );
        r = ((filesCompleted + inFlight) / denom).clamp(0.0, 0.995);
      } else {
        r = (filesCompleted / deviceTotalFiles).clamp(0.0, 0.995);
      }
    } else if (framedMode && currentFileDeclaredSize > 0) {
      r = (bytesThisFile / currentFileDeclaredSize).clamp(0.0, 0.995);
    }
    return r;
  }

  /// Same algebra as [wifiAligned] but without the 0.995 clamp — for logs only.
  static double uncappedRatio({
    required bool framedMode,
    required int currentFileDeclaredSize,
    required int bytesThisFile,
    required int receivedSession,
    required int? expectedSession,
    required int filesCompleted,
    required int deviceTotalFiles,
    required int deviceSessionBytes,
  }) {
    if (expectedSession != null && expectedSession > 0) {
      return receivedSession / expectedSession;
    }
    if (deviceTotalFiles > 0 && deviceSessionBytes > 0) {
      final filePart = filesCompleted / deviceTotalFiles;
      final bytePart = (receivedSession / deviceSessionBytes).clamp(0.0, 1.0);
      return filePart + bytePart / deviceTotalFiles;
    }
    if (deviceTotalFiles > 0) {
      if (framedMode && currentFileDeclaredSize > 0) {
        final inFlight =
            (bytesThisFile / currentFileDeclaredSize).clamp(0.0, 1.0);
        final denom = math.max(
          deviceTotalFiles,
          filesCompleted + (inFlight > 0 ? 1 : 0),
        );
        return (filesCompleted + inFlight) / denom;
      }
      return filesCompleted / deviceTotalFiles;
    }
    if (framedMode && currentFileDeclaredSize > 0) {
      return bytesThisFile / currentFileDeclaredSize;
    }
    return 0;
  }

  /// Which branch [wifiAligned] used first — useful when progress stalls near 99%.
  static String branchLabel({
    required bool framedMode,
    required int currentFileDeclaredSize,
    required int bytesThisFile,
    required int receivedSession,
    required int? expectedSession,
    required int filesCompleted,
    required int deviceTotalFiles,
    required int deviceSessionBytes,
  }) {
    if (expectedSession != null && expectedSession > 0) {
      final uncapped = receivedSession / expectedSession;
      if (uncapped <= 1.05 || deviceTotalFiles <= 0) {
        return 'expectedSession';
      }
    }
    if (deviceTotalFiles > 0 && deviceSessionBytes > 0) {
      return 'files+sessionBytes';
    }
    if (deviceTotalFiles > 0) {
      if (framedMode && currentFileDeclaredSize > 0) {
        return 'files+sliceBytes';
      }
      return 'filesOnly';
    }
    if (framedMode && currentFileDeclaredSize > 0) {
      return 'sliceBytes';
    }
    return 'null';
  }

  /// Firmware TRANSFER_DONE / JSON `transfer_complete` [files] equals session file count.
  static bool sessionTransferBytesComplete({
    required int eventFileCount,
    required int fileCompleteCount,
    required int deviceTotalFilesFromDownload,
  }) {
    final n = deviceTotalFilesFromDownload;
    if (n <= 0) return false;
    return eventFileCount >= n || fileCompleteCount >= n;
  }
}
