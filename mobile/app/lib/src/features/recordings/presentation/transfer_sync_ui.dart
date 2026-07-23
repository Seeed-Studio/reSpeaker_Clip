import '../../../core/l10n/app_localizations.dart';
import '../../device/presentation/wifi_transfer_controller.dart';
import '../domain/recording.dart';

/// Shared rules for list-row sync subtitle and [TransferProgressBanner] bar/label.
class TransferSyncStatusPresentation {
  const TransferSyncStatusPresentation({
    this.isMerging = false,
    this.liveRecordTransfer = false,
    this.progressRatio,
    this.receivedBytes,
    this.expectedBytes,
    this.stillTransferring = true,
  });

  final bool isMerging;
  final bool liveRecordTransfer;
  final double? progressRatio;
  final int? receivedBytes;
  final int? expectedBytes;
  final bool stillTransferring;

  bool get indeterminateProgress => progressRatio == null;

  bool get preferPercentLabel {
    if (isMerging || liveRecordTransfer) return false;
    final p = progressRatio;
    if (p == null || p <= 0.01) return false;
    if ((receivedBytes ?? 0) <= 0) return false;
    final cap = expectedBytes ?? 0;
    if (cap <= 0) return false;
    return !transferExpectedCapLooksStale(
      receivedBytes: receivedBytes ?? 0,
      expectedCapBytes: cap,
      stillTransferring: stillTransferring,
    );
  }

  int get percentForLabel =>
      (100 * (progressRatio ?? 0)).floor().clamp(0, 99);

  /// Progress bar fill; `null` = indeterminate.
  double? get progressBarTarget {
    if (indeterminateProgress) return null;
    final p = progressRatio!;
    if (stillTransferring) return p.clamp(0.0, 0.99);
    return p >= 1.0 ? 1.0 : p;
  }

  String statusLabel(AppLocalizations l10n) {
    if (isMerging) return l10n.fastSyncMerging;
    if (preferPercentLabel) return l10n.syncingPercent(percentForLabel);
    final bytes = formatTransferReceivedBytesUiIfPositive(receivedBytes);
    if (bytes != null) return '${l10n.syncing} ($bytes)';
    return l10n.syncing;
  }
}

TransferSyncStatusPresentation resolveTransferSyncStatusForListItem({
  required String? transferState,
  required double? transferProgress,
  required int? receivedBytes,
  required int? expectedBytes,
  required bool liveDeviceTransfer,
  required bool localMerging,
}) {
  final stillTransferring =
      transferState == 'transferring' || transferState == 'merging';
  if (localMerging) {
    return TransferSyncStatusPresentation(
      isMerging: true,
      stillTransferring: stillTransferring,
    );
  }
  if (liveDeviceTransfer) {
    return TransferSyncStatusPresentation(
      liveRecordTransfer: true,
      receivedBytes: receivedBytes,
      stillTransferring: stillTransferring,
    );
  }
  final cap = expectedBytes ?? 0;
  final stale = transferExpectedCapLooksStale(
    receivedBytes: receivedBytes ?? 0,
    expectedCapBytes: cap,
    stillTransferring: transferState == 'transferring',
  );
  return TransferSyncStatusPresentation(
    progressRatio: stale ? null : transferProgress,
    receivedBytes: receivedBytes,
    expectedBytes: stale || cap <= 0 ? null : cap,
    stillTransferring: stillTransferring,
  );
}

TransferSyncStatusPresentation resolveTransferSyncStatusPresentation({
  required Recording recording,
  required bool liveRecordWhileBleTransfer,
  bool wifiOwnsProgressForRecording = false,
  bool transferActiveForRecording = false,
  WifiTransferState? liveWifi,
}) {
  final stillTransferring = recording.transferState == 'transferring' ||
      recording.transferState == 'merging';

  if (transferUiLocalMergePhase(
    recording: recording,
    liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
    wifiOwnsProgressForRecording: wifiOwnsProgressForRecording,
    transferActiveForRecording: transferActiveForRecording,
  )) {
    return TransferSyncStatusPresentation(
      isMerging: true,
      stillTransferring: stillTransferring,
    );
  }

  final expectedCap = recordingTransferExpectedCapBytes(recording);
  final wifiActive = liveWifi != null &&
      liveWifi.recordingId == recording.id &&
      liveWifi.isActive;

  if (wifiActive) {
    final w = liveWifi;
    if (w.phase == WifiTransferPhase.mergingFiles &&
        w.mergeTotalBytes > 0) {
      return TransferSyncStatusPresentation(
        isMerging: true,
        progressRatio: w.mergeFraction.clamp(0.0, 0.99),
        receivedBytes: w.mergedBytes,
        expectedBytes: w.mergeTotalBytes,
        stillTransferring: stillTransferring,
      );
    }
    final indeterminatePhase = w.phase == WifiTransferPhase.enablingHotspot ||
        w.phase == WifiTransferPhase.connectingWifi ||
        w.phase == WifiTransferPhase.verifyingConnection ||
        w.phase == WifiTransferPhase.mergingFiles ||
        w.phase == WifiTransferPhase.disablingHotspot;
    if (indeterminatePhase) {
      final received = w.cumulativeReceivedBytes > 0
          ? w.cumulativeReceivedBytes
          : recording.receivedBytes;
      return TransferSyncStatusPresentation(
        receivedBytes: received,
        stillTransferring: stillTransferring,
      );
    }
    if (w.phase == WifiTransferPhase.transferring) {
      final received = w.cumulativeReceivedBytes;
      if (liveRecordWhileBleTransfer) {
        return TransferSyncStatusPresentation(
          liveRecordTransfer: true,
          receivedBytes: received,
          stillTransferring: stillTransferring,
        );
      }
      if (expectedCap > 0) {
        return _fromReceivedAndCap(
          recording: recording,
          receivedBytes: received,
          expectedCapBytes: expectedCap,
          stillTransferring: stillTransferring,
          liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
        );
      }
      final ratio = w.totalFiles > 0 ? w.progress.clamp(0.0, 1.0) : null;
      return TransferSyncStatusPresentation(
        progressRatio: ratio,
        receivedBytes: received,
        stillTransferring: stillTransferring,
      );
    }
    return TransferSyncStatusPresentation(
      receivedBytes: recording.receivedBytes,
      stillTransferring: stillTransferring,
    );
  }

  if (liveRecordWhileBleTransfer) {
    return TransferSyncStatusPresentation(
      liveRecordTransfer: true,
      receivedBytes: recording.receivedBytes,
      stillTransferring: stillTransferring,
    );
  }

  if (transferUiUseIndeterminateProgress(
    recording: recording,
    liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
  )) {
    return TransferSyncStatusPresentation(
      receivedBytes: recording.receivedBytes,
      expectedBytes: expectedCap > 0 ? expectedCap : null,
      stillTransferring: stillTransferring,
    );
  }

  if (expectedCap > 0) {
    return _fromReceivedAndCap(
      recording: recording,
      receivedBytes: recording.receivedBytes ?? 0,
      expectedCapBytes: expectedCap,
      stillTransferring: stillTransferring,
      liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
      transferActiveForRecording: transferActiveForRecording,
    );
  }

  final ratio = transferProgressForDisplay(
    recording: recording,
    liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
    wifiOwnsProgressForRecording: wifiOwnsProgressForRecording,
    transferActiveForRecording: transferActiveForRecording,
  );
  return TransferSyncStatusPresentation(
    progressRatio: ratio,
    receivedBytes: recording.receivedBytes,
    stillTransferring: stillTransferring,
  );
}

TransferSyncStatusPresentation _fromReceivedAndCap({
  required Recording recording,
  required int receivedBytes,
  required int expectedCapBytes,
  required bool stillTransferring,
  required bool liveRecordWhileBleTransfer,
  bool transferActiveForRecording = false,
}) {
  final stale = transferExpectedCapLooksStale(
    receivedBytes: receivedBytes,
    expectedCapBytes: expectedCapBytes,
    stillTransferring: recording.transferState == 'transferring',
  );
  final forcedIndeterminate = transferUiUseIndeterminateProgress(
    recording: recording,
    liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
  );
  if (stale || forcedIndeterminate) {
    // Active BLE leg + stale cap (received caught up to a too-small snapshot):
    // not real completion/merge — keep a steady near-full determinate bar so the
    // banner does not flip to an indeterminate "dynamic" phase mid-transfer.
    if (transferActiveForRecording && stale && !forcedIndeterminate) {
      return TransferSyncStatusPresentation(
        progressRatio: kTransferProgressDisplayMaxWhileTransferring,
        receivedBytes: receivedBytes,
        expectedBytes: expectedCapBytes,
        stillTransferring: stillTransferring,
      );
    }
    return TransferSyncStatusPresentation(
      receivedBytes: receivedBytes,
      stillTransferring: stillTransferring,
    );
  }
  final ratio = transferProgressFromReceivedRatio(
    receivedBytes: receivedBytes,
    expectedCapBytes: expectedCapBytes,
    stillTransferring: recording.transferState == 'transferring',
  );
  return TransferSyncStatusPresentation(
    progressRatio: ratio,
    receivedBytes: receivedBytes,
    expectedBytes: expectedCapBytes,
    stillTransferring: stillTransferring,
  );
}
