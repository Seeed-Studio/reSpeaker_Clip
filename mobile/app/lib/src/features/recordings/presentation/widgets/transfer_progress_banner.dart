import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/widgets/app_card.dart';
import '../../domain/recording.dart';
import '../../utils/recording_display_name.dart';
import '../transfer_sync_ui.dart';
import '../../../device/presentation/device_controller.dart';
import '../../../device/presentation/wifi_transfer_controller.dart';

/// BLE list banner shared with [recordings_page] row.
/// - Known total (expectedBytes / sizeBytes): same as Wi‑Fi — [Recording.receivedBytes] / total for determinate bar.
/// - Unknown total: prefer DB [transferProgress] (matches firmware slice/file); else indeterminate.
///   [DeviceController] writes DB as soon as [AT+DOWNLOAD] returns `files`/`bytes` so throttled progress is not an empty indeterminate bar forever.
/// - **Live record + transfer**: when [liveRecordWhileBleTransfer] is true (BLE pulling this row while firmware records/pauses), total still moves — do not use received/total or 0.995 cap; use **indeterminate** bar; subtitle shows bytes received only, not "of total".

/// Pass-through wrapper (keeps the same constructor as the old ticker).
///
/// Deferred BLE sync for `device_recording_resume_later` is **not** polled from the list UI anymore.
/// [DeviceController] resumes incomplete transfers when recording ends ([stopRecording], hardware STOP
/// notify, or BLE `state_change` / GSTAT-shaped notify → idle).
class DeferredTransferResumeTicker extends StatelessWidget {
  const DeferredTransferResumeTicker({
    super.key,
    required this.recording,
    required this.hasDevice,
    required this.child,
  });

  final Recording recording;
  final bool hasDevice;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class TransferProgressBanner extends StatefulWidget {
  final Recording recording;
  final Color primary;
  final bool hasDevice;

  /// When false, show Wi‑Fi icon (Fast Sync / UDP path active for this item).
  final bool useBleTransport;

  /// In-memory Fast Sync state for this [recording] (DB updates lag during Wi‑Fi setup / merge).
  final WifiTransferState? liveWifi;
  final Future<void> Function() onRetrySync;
  final VoidCallback? onFastSync;

  /// From home [DeviceUiState]: true only when pulling this row and firmware is recording/paused.
  final bool liveRecordWhileBleTransfer;

  /// When true, hide resync / fast-sync actions (e.g. device is recording).
  final bool suppressResync;

  /// True while the device controller still has an in-flight BLE leg for this
  /// row. Suppresses the byte-based "download complete" merge inference so a
  /// transient `received` overshoot during a resume re-pull keeps showing live
  /// progress instead of flipping to "merging".
  final bool transferActiveForRecording;

  const TransferProgressBanner({
    super.key,
    required this.recording,
    required this.primary,
    required this.hasDevice,
    this.useBleTransport = true,
    this.liveWifi,
    required this.onRetrySync,
    this.onFastSync,
    this.liveRecordWhileBleTransfer = false,
    this.suppressResync = false,
    this.transferActiveForRecording = false,
  });

  @override
  State<TransferProgressBanner> createState() => _TransferProgressBannerState();
}

class _TransferProgressBannerState extends State<TransferProgressBanner>
    with SingleTickerProviderStateMixin {
  /// After [rawShowResync] becomes false, keep resync **action** (tap + solid style) on briefly so
  /// DB/Wi‑Fi frames do not strobe; the pill itself stays in a **fixed slot** and never disappears.
  static const Duration _kResyncActiveLinger = Duration(milliseconds: 720);

  /// Fixed tray widths (tight for narrow phones; outer [FittedBox] still scales down if needed).
  static const double _kResyncTrayWidth = 108;
  static const double _kFastSyncTrayWidth = 114;

  static const Duration _kDockDuration = Duration(milliseconds: 320);

  /// Floating “restore transfer” control: same horizontal band as the list transfer card
  /// on [RecordingsPage] (below device row + filter/sort row, [SafeArea] already applied in body).
  static const double _kFabSizeOuter = 54;

  /// Distance from the top safe inset to FAB top (tune if header layout changes).
  static const double _kFabTopFromSafeArea = 106;

  late final AnimationController _dockController;

  OverlayEntry? _dockFabOverlay;

  bool _lingerResyncActive = false;
  bool _retrying = false;
  Timer? _resyncLingerTimer;

  @override
  void initState() {
    super.initState();
    _dockController = AnimationController(
      vsync: this,
      duration: _kDockDuration,
    );
    _dockController.addStatusListener(_onDockStatus);
  }

  void _onDockStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed) {
      _ensureDockFabOverlay();
      setState(() {});
    } else if (status == AnimationStatus.dismissed) {
      _removeDockFabOverlay();
    }
  }

  void _removeDockFabOverlay() {
    _dockFabOverlay?.remove();
    _dockFabOverlay?.dispose();
    _dockFabOverlay = null;
  }

  void _ensureDockFabOverlay() {
    if (_dockFabOverlay != null || !mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _dockFabOverlay = OverlayEntry(
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        final top = mq.padding.top + _kFabTopFromSafeArea;
        return Positioned(
          top: top,
          right: 16,
          child: Semantics(
            button: true,
            label: AppLocalizations.of(ctx)!.transferBannerRestoreTip,
            child: Container(
              width: _kFabSizeOuter,
              height: _kFabSizeOuter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.30),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                    spreadRadius: -2,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.14),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Material(
                color: widget.primary,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                elevation: 0,
                shadowColor: Colors.transparent,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _expandFromFab,
                  child: SizedBox(
                    width: _kFabSizeOuter,
                    height: _kFabSizeOuter,
                    child: Icon(
                      widget.useBleTransport ? Icons.bluetooth : Icons.wifi,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_dockFabOverlay!);
  }

  void _expandFromFab() {
    if (!mounted) return;
    _removeDockFabOverlay();
    _dockController.value = 0;
    setState(() {});
  }

  @override
  void dispose() {
    _resyncLingerTimer?.cancel();
    _dockController.removeStatusListener(_onDockStatus);
    _removeDockFabOverlay();
    _dockController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TransferProgressBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recording.id != widget.recording.id) {
      _resyncLingerTimer?.cancel();
      _resyncLingerTimer = null;
      _lingerResyncActive = false;
      _removeDockFabOverlay();
      _dockController.value = 0;
    }
  }

  void _updateResyncLinger(bool rawWant) {
    if (!mounted) return;
    if (rawWant) {
      _resyncLingerTimer?.cancel();
      _resyncLingerTimer = null;
      if (!_lingerResyncActive) {
        setState(() => _lingerResyncActive = true);
      }
      return;
    }
    if (!_lingerResyncActive) return;
    _resyncLingerTimer ??= Timer(_kResyncActiveLinger, () {
      _resyncLingerTimer = null;
      if (!mounted) return;
      setState(() => _lingerResyncActive = false);
    });
  }

  bool _isRetryableTransferRecovery(Recording recording) {
    if (recording.transferState == 'failed') return true;
    if (recording.transferState != 'transferring') return false;
    switch ((recording.transferErrorCode ?? '').trim()) {
      case 'device_disconnected_resume':
      case 'device_disconnected_resume_after_reconnect':
      case 'transfer_incomplete_resume':
      case 'stalled_no_data_3min':
      case 'device_recording_resume_later':
      case 'wifi_fast_sync_fallback':
      case 'wifi_fast_sync_unreachable':
      case 'wifi_fast_sync_disconnected':
      case 'wifi_transfer_failed':
      case 'possibly_incomplete_transfer':
      case 'transfer_merged_missing_slice':
      case 'transfer_gap_missing_slices':
      case 'merge_failed':
      case 'no_valid_audio':
        return true;
      default:
        return false;
    }
  }

  Future<void> _handleRetrySync() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetrySync();
    } finally {
      if (mounted) {
        setState(() => _retrying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dockController.isCompleted) {
      return const SizedBox.shrink();
    }

    final recording = widget.recording;
    if (recording.transferState == 'done' ||
        recording.transferState == 'failed') {
      return const SizedBox.shrink();
    }
    if (!widget.hasDevice && widget.liveWifi == null) {
      return const SizedBox.shrink();
    }
    // Post-stop clip shorter than one Opus slice: 0 B received while waiting
    // for the first download leg after STOP — keep the bar visible through
    // cancel/retry gaps (display only).
    final postStopAwaitingFirstBytes = recording.endedAt != null &&
        (recording.receivedBytes ?? 0) <= 0;
    final xferStillActive = recording.transferState == 'transferring' &&
        (widget.liveWifi != null ||
            widget.liveRecordWhileBleTransfer ||
            // Device controller still holds an in-flight BLE leg for this row:
            // a momentary DB `transferProgress >= 1.0` (overshoot / final slice)
            // must NOT self-hide the banner while bytes are still moving.
            widget.transferActiveForRecording ||
            postStopAwaitingFirstBytes);
    if ((recording.transferProgress ?? 0) >= 1.0 &&
        widget.liveWifi == null &&
        !xferStillActive &&
        recording.transferState != 'merging' &&
        !transferUiLocalMergePhase(
          recording: recording,
          liveRecordWhileBleTransfer: widget.liveRecordWhileBleTransfer,
          transferActiveForRecording: widget.transferActiveForRecording,
        )) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final title = resolveRecordingDisplayTitle(recording);
    final liveDeviceXfer = widget.liveRecordWhileBleTransfer;
    final wifiOwnsRow = widget.liveWifi != null &&
        widget.liveWifi!.recordingId == recording.id &&
        widget.liveWifi!.isActive;
    final syncUi = resolveTransferSyncStatusPresentation(
      recording: recording,
      liveRecordWhileBleTransfer: liveDeviceXfer,
      wifiOwnsProgressForRecording: wifiOwnsRow,
      transferActiveForRecording: widget.transferActiveForRecording,
      liveWifi: widget.liveWifi,
    );
    final stillTransferring = recording.transferState == 'transferring' ||
        recording.transferState == 'merging';

    // During BLE live pull while the device is still recording/paused, manual resync
    // is meaningless — the stream is ongoing. Parent may also set [suppressResync]
    // when firmware records on this device (even if another row was in the banner).
    final suppressResyncDuringLiveRecord = widget.suppressResync ||
        (liveDeviceXfer &&
            recording.endedAt == null &&
            recording.transferState != 'failed');

    final wifiPhase = widget.liveWifi?.phase;
    final isWifiMerging = wifiPhase == WifiTransferPhase.mergingFiles;
    final isBleMerging = !wifiOwnsRow &&
        transferUiLocalMergePhase(
          recording: recording,
          liveRecordWhileBleTransfer: liveDeviceXfer,
          transferActiveForRecording: widget.transferActiveForRecording,
        );
    final isLocalMerging = isWifiMerging || isBleMerging;
    final isWifiDisablingHotspot =
        wifiPhase == WifiTransferPhase.disablingHotspot;
    final retryableRecovery = _isRetryableTransferRecovery(recording);

    // Resync is only an error-recovery action. Do not let a healthy BLE/Wi-Fi
    // transfer be interrupted by an accidental "resync" tap.
    final rawShowResync = widget.hasDevice &&
        !suppressResyncDuringLiveRecord &&
        !wifiOwnsRow &&
        !isLocalMerging &&
        retryableRecovery;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateResyncLinger(rawShowResync);
    });

    final resyncInteractive = rawShowResync && !_retrying;
    final resyncEmphasized = resyncInteractive || _lingerResyncActive;
    final hasFastSyncSlot = widget.onFastSync != null;

    // Phase-aware section title. During post-download merge / hotspot teardown, show the phase
    // label instead of "Transferring" so the user knows work is still in progress.
    final headerLabel = isLocalMerging
        ? l10n.fastSyncMerging
        : isWifiDisablingHotspot
            ? l10n.fastSyncRestoringWifi
            : l10n.transferring;

    final card = AppCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderRadius: BorderRadius.circular(AppRadii.r18),
      borderColor: widget.primary.withValues(alpha: 0.18),
      backgroundColor: widget.primary.withValues(alpha: 0.10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                widget.useBleTransport ? Icons.bluetooth : Icons.wifi,
                color: widget.primary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  headerLabel,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.hasDevice)
                // Do not wrap in [Flexible]: alongside [Expanded] it can get ~0 width and the inner
                // [Row] overflows. Trailing [FittedBox] receives the true remaining width here.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!suppressResyncDuringLiveRecord) ...[
                        SizedBox(
                          width: _kResyncTrayWidth,
                          height: 34,
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: _ActionPillButton(
                                onTap: resyncInteractive
                                    ? () => unawaited(_handleRetrySync())
                                    : null,
                                icon: Icons.refresh,
                                label: l10n.resync,
                                fontWeight: FontWeight.w500,
                                emphasized: resyncEmphasized,
                              ),
                            ),
                          ),
                        ),
                        if (hasFastSyncSlot && widget.useBleTransport)
                          const SizedBox(width: 4),
                      ],
                      if (hasFastSyncSlot &&
                          widget.useBleTransport &&
                          !suppressResyncDuringLiveRecord) ...[
                        SizedBox(
                          width: _kFastSyncTrayWidth,
                          height: 34,
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: _ActionPillButton(
                                onTap: widget.onFastSync,
                                icon: Icons.rocket_launch_rounded,
                                label: l10n.fastSync,
                                fontWeight: FontWeight.w600,
                                emphasized: true,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: () =>
                            _dockController.forward(from: _dockController.value),
                        icon: Icon(Icons.close, color: widget.primary, size: 20),
                        tooltip: l10n.transferBannerMinimizeTip,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(32, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _AnimatedTransferProgress(
            key: ValueKey<String>(recording.id),
            targetValue: syncUi.progressRatio,
            primary: widget.primary,
            l10n: l10n,
            stillTransferring: stillTransferring,
            title: title,
            statusLabel: syncUi.statusLabel(l10n),
            receivedBytes: syncUi.receivedBytes ?? recording.receivedBytes,
            showSpeed:
                (syncUi.receivedBytes ?? recording.receivedBytes ?? 0) > 0 &&
                    !isLocalMerging,
          ),
          ..._transferSubtitleWidgets(
            context,
            l10n,
            recording,
            widget.liveWifi,
            hasDevice: widget.hasDevice,
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final bannerW = constraints.maxWidth;
        return AnimatedBuilder(
          animation: _dockController,
          builder: (context, dockChild) {
            final t =
                Curves.easeOutCubic.transform(_dockController.value);
            // Slide fully past the right edge; floating restore control is an [Overlay] FAB.
            final dx = t * (bannerW + 24);
            return ClipRect(
              clipBehavior: Clip.hardEdge,
              child: Transform.translate(
                offset: Offset(dx, 0),
                child: dockChild,
              ),
            );
          },
          child: card,
        );
      },
    );
  }
}

/// Single pill used for resync / fast sync; [emphasized] false = dimmed but same layout footprint.
class _ActionPillButton extends StatelessWidget {
  const _ActionPillButton({
    required this.onTap,
    required this.icon,
    required this.label,
    required this.fontWeight,
    required this.emphasized,
  });

  final VoidCallback? onTap;
  final IconData icon;
  final String label;
  final FontWeight fontWeight;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final fg = emphasized ? Colors.white : Colors.white.withValues(alpha: 0.5);
    final bg = emphasized ? Colors.black : Colors.black.withValues(alpha: 0.2);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg, size: 15),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: fontWeight,
                  fontSize: AppTypography.s12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Subtitle under the progress bar (DB [Recording.transferErrorCode]).
///
/// [wifi_handoff] is set when BLE is cancelled for Fast Sync; hide it once
/// [liveWifi] is in UDP transfer or merge so we do not show "switching to Wi‑Fi"
/// alongside Wi‑Fi throughput.
List<Widget> _transferSubtitleWidgets(
  BuildContext context,
  AppLocalizations l10n,
  Recording recording,
  WifiTransferState? liveWifi, {
  required bool hasDevice,
}) {
  final ec = (recording.transferErrorCode ?? '').trim();
  if (ec.isEmpty ||
      ec == 'user_cancelled' ||
      isBenignTransferPauseCode(ec)) {
    return const [];
  }
  if (hasDevice && isDisconnectResumePauseCode(ec)) {
    return const [];
  }
  if (ec == 'wifi_handoff' &&
      liveWifi != null &&
      (liveWifi.phase == WifiTransferPhase.transferring ||
          liveWifi.phase == WifiTransferPhase.mergingFiles)) {
    return const [];
  }
  return [
    const SizedBox(height: 8),
    Text(
      l10n.transferOrConnectionError(recording.transferErrorCode, null),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.textSecondary,
            height: 1.35,
          ),
    ),
  ];
}

class _AnimatedTransferProgress extends StatefulWidget {
  final double? targetValue;
  final Color primary;
  final AppLocalizations l10n;
  final String title;
  final String statusLabel;

  /// When true, never show 100% or a full bar until [transferState] is done (avoids 0.995→round→100%).
  final bool stillTransferring;
  final int? receivedBytes;
  final bool showSpeed;

  const _AnimatedTransferProgress({
    super.key,
    required this.targetValue,
    required this.primary,
    required this.l10n,
    required this.title,
    required this.statusLabel,
    this.stillTransferring = false,
    this.receivedBytes,
    this.showSpeed = false,
  });

  @override
  State<_AnimatedTransferProgress> createState() =>
      _AnimatedTransferProgressState();
}

class _AnimatedTransferProgressState extends State<_AnimatedTransferProgress>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  double _displayValue = 0;

  /// Highest shown determinate progress this widget instance; avoids bar animating backward on noisy ratios.
  double _progressFloor = 0;
  Timer? _speedTimer;
  int? _lastSampleBytes;
  DateTime? _lastSampleAt;
  String? _speedLabel;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    final rawTv =
        widget.targetValue == null ? 0.0 : widget.targetValue!.clamp(0.0, 1.0);
    final initTv = widget.stillTransferring && rawTv < 1.0
        ? rawTv.clamp(0.0, 0.99)
        : rawTv;
    _progressFloor = initTv;
    _displayValue = initTv;
    _animation = Tween<double>(begin: initTv, end: initTv).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _restartSpeedTimer();
  }

  void _restartSpeedTimer() {
    _speedTimer?.cancel();
    if (!widget.showSpeed) {
      _speedLabel = null;
      _lastSampleBytes = null;
      _lastSampleAt = null;
      return;
    }
    _lastSampleBytes = widget.receivedBytes;
    _lastSampleAt = DateTime.now();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final cur = widget.receivedBytes;
      final prevB = _lastSampleBytes;
      final prevT = _lastSampleAt;
      _lastSampleBytes = cur;
      _lastSampleAt = now;
      // No fresh receivedBytes this tick: keep showing last rate (BLE/UI can pause updates).
      if (prevB == null || cur == null || prevT == null) return;
      final dt = now.difference(prevT).inMilliseconds;
      if (dt < 200) return;
      final dBytes = cur - prevB;
      if (dBytes <= 0) return;
      final bps = dBytes / (dt / 1000.0);
      if (mounted) setState(() => _speedLabel = _formatSpeed(bps));
    });
  }

  @override
  void didUpdateWidget(_AnimatedTransferProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showSpeed != widget.showSpeed) {
      _restartSpeedTimer();
    }

    if (widget.targetValue == null) {
      _progressFloor = 0.0;
      const tv = 0.0;
      if ((tv - _displayValue).abs() > 1e-6) {
        _animation = Tween<double>(begin: _displayValue, end: tv).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
        );
        _displayValue = tv;
        _controller.forward(from: 0);
      }
      return;
    }

    final rb = widget.receivedBytes ?? 0;
    final orb = oldWidget.receivedBytes ?? 0;
    if (orb > 0 && rb + 8192 < orb) {
      _progressFloor = 0.0;
      _displayValue = 0.0;
      _animation = Tween<double>(begin: 0, end: 0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
      );
      _controller.value = 0;
    }

    var tv = widget.targetValue!.clamp(0.0, 1.0);
    if (widget.stillTransferring) {
      if (tv >= 1.0) {
        tv = 0.99;
      } else {
        tv = tv.clamp(0.0, 0.99);
      }
      if (_progressFloor > 0.99) {
        _progressFloor = 0.99;
      }
    }
    // Multi-file BLE: after FILE_END, progress uses a fresh per-slice ratio (drops from ~1 to ~0)
    // while session receivedBytes keeps increasing. Old logic kept _progressFloor → bar stuck at 100%.
    const regressionThreshold = 0.04;
    // Bytes still advancing but ratio fell (new slice or DB caught up): always drop floor — avoids
    // stale parent [targetValue] briefly matching old floor so the bar never unlocks.
    if (widget.stillTransferring &&
        rb > orb &&
        tv < _progressFloor - 0.002 &&
        rb >= orb - 4096) {
      _progressFloor = tv;
    } else if (tv < _progressFloor - regressionThreshold && rb >= orb - 4096) {
      _progressFloor = tv;
    } else if (tv + 0.008 < _progressFloor) {
      tv = _progressFloor;
    } else {
      _progressFloor = math.max(_progressFloor, tv);
    }

    if ((tv - _displayValue).abs() > 1e-6) {
      _animation = Tween<double>(begin: _displayValue, end: tv).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
      );
      _displayValue = tv;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final isIndeterminate = widget.targetValue == null;
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final p = isIndeterminate ? null : _animation.value;
        final double? barValue = p == null
            ? null
            : widget.stillTransferring
                ? p.clamp(0.0, 0.99)
                : p;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: barValue,
                minHeight: 10,
                backgroundColor: Colors.white.withValues(alpha: 0.65),
                valueColor: AlwaysStoppedAnimation<Color>(widget.primary),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (current, previous) {
                      return Stack(
                        fit: StackFit.passthrough,
                        alignment: Alignment.centerLeft,
                        children: [...previous, if (current != null) current],
                      );
                    },
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.statusLabel,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: widget.primary,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
            if (widget.showSpeed &&
                (_speedLabel != null && _speedLabel!.isNotEmpty)) ...[
              const SizedBox(height: 6),
              Text(
                widget.l10n.transferSpeedLabel(_speedLabel!),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
          ],
        );
      },
    );
  }
}

String _formatSpeed(double bytesPerSecond) {
  const k = 1024.0;
  if (bytesPerSecond < k) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  final kb = bytesPerSecond / k;
  if (kb < k) return '${kb.toStringAsFixed(1)} KB/s';
  final mb = kb / k;
  return '${mb.toStringAsFixed(2)} MB/s';
}
