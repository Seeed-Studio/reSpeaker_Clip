import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
// WifiBatchItem / WifiBleFallbackReason are defined locally in
// wifi_transfer_controller.dart; hide the SDK's identically-named exports.
import 'package:sensecraft_voice/sensecraft_voice.dart'
    hide WifiBatchItem, WifiBleFallbackReason;

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/log/app_log.dart';
import '../../../../core/widgets/app_dialogs.dart';
import '../../data/recordings_repository.dart';
import '../../domain/recording.dart';
import '../../../device/presentation/device_controller.dart';
import '../../../device/presentation/wifi_transfer_controller.dart';

String? effectiveSessionId(Recording r) {
  final s = (r.sessionId ?? '').trim();
  if (s.isNotEmpty) return s;
  final p = r.devicePath.trim();
  if (p.isEmpty) return null;
  return p.contains('/') ? p.split('/').first : p;
}

/// User closed the sheet (scrim / drag / close control) — stop BLE wait without error snackbar.
class _FastSyncClosedByUser implements Exception {
  const _FastSyncClosedByUser();
}

/// Sheet can be dismissed anytime; **manual** close runs [WifiTransferController.cancel] (turns off device AP).
/// When Wi‑Fi **connects** and transfer starts, the sheet closes **without** sending Wi‑Fi off.
class FastSyncWifiSheet extends ConsumerStatefulWidget {
  const FastSyncWifiSheet({super.key, required this.recording});

  final Recording recording;

  @override
  ConsumerState<FastSyncWifiSheet> createState() => _FastSyncWifiSheetState();
}

class _FastSyncWifiSheetState extends ConsumerState<FastSyncWifiSheet> {
  static const Duration _bleIdleTimeout = Duration(seconds: 25);

  String? _localStatus;
  bool _running = true;
  Object? _fatalError;
  bool _userDismissedSheet = false;
  bool _userRequestedClose = false;

  /// Popped because UDP/transfer phase started — [PopScope] must not call [WifiTransferController.cancel].
  bool _suppressWifiCancelOnPop = false;
  bool _didAutoPopForTransferStart = false;
  bool _resumeBleAfterCloseScheduled = false;

  /// Set when Wi‑Fi could not deliver and we fall back to BLE; drives the
  /// post-run dialog (instead of an error) while BLE keeps the "fast sync" going.
  WifiBleFallbackReason? _bleFallbackReason;

  /// Device hotspot credentials captured at fallback time, so the "rejoin Wi‑Fi"
  /// dialog can show the user the exact SSID + password to connect to manually
  /// (the controller state is cleared before the dialog shows).
  String? _fallbackSsid;
  String? _fallbackPassword;

  /// Root navigator captured while the sheet is mounted, so the unified Wi‑Fi
  /// fallback dialog can be shown even after the sheet has auto-popped (it pops
  /// the moment Wi‑Fi transfer starts, so it must not own the dialog).
  NavigatorState? _rootNavigator;

  void _rememberHotspotCredentials(WifiHotspotInfo? hs) {
    if (hs == null) return;
    final ssid = hs.ssid.trim();
    final password = hs.password.trim();
    if (ssid.isNotEmpty) _fallbackSsid = ssid;
    if (password.isNotEmpty) _fallbackPassword = password;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ignore: discarded_futures
      _run();
    });
  }

  Future<void> _waitBleTransferIdle() async {
    final end = DateTime.now().add(_bleIdleTimeout);
    while (mounted && DateTime.now().isBefore(end)) {
      if (_userRequestedClose) throw const _FastSyncClosedByUser();
      final id = ref.read(deviceControllerProvider).activeTransferRecordingId;
      if (id == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    throw TimeoutException('BLE transfer did not stop');
  }

  /// Single unified dialog shown when Wi‑Fi fast sync did not complete (for ANY
  /// reason — phone on another Wi‑Fi, never joined the hotspot, or lossy link).
  /// Bluetooth has already taken over; this just tells the user and offers the
  /// device hotspot [ssid] + [password] + a shortcut to Wi‑Fi settings so they
  /// can make the next sync faster. Shown on the root navigator so it survives
  /// the sheet auto-popping. Both buttons dismiss it (never "sticks").
  Future<void> _showWifiFallbackDialog(
    BuildContext dialogContext,
    AppLocalizations l10n,
    String? ssid,
    String? password, {
    required WifiBleFallbackReason reason,
    FutureOr<void> Function()? onContinueExtra,
  }) async {
    final showCreds =
        (ssid != null && ssid.trim().isNotEmpty) ||
            (password != null && password.trim().isNotEmpty);
    final (title, message) = switch (reason) {
      WifiBleFallbackReason.phoneWifiDisconnected => (
          l10n.fastSyncWifiDisconnectedTitle,
          l10n.fastSyncWifiDisconnectedMessage,
        ),
      WifiBleFallbackReason.phoneOnOtherWifi => (
          l10n.fastSyncWifiVerifyTimeoutTitle,
          l10n.fastSyncWifiVerifyTimeoutMessage,
        ),
      WifiBleFallbackReason.transferFailed => (
          l10n.fastSyncWifiFailedTitle,
          l10n.fastSyncWifiFailedMessage,
        ),
    };
    await AppDialogs.showConfirmWithContent(
      dialogContext,
      title: title,
      cancelText: l10n.fastSyncOpenAppSettings,
      confirmText: l10n.continueAction,
      onSecondaryExtra: () =>
          AppSettings.openAppSettings(type: AppSettingsType.wifi),
      onPrimaryExtra: onContinueExtra,
      content: Builder(
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: const TextStyle(
                fontSize: AppTypography.s14,
                color: AppColors.textSecondary,
                height: 1.35,
              ),
            ),
            if (showCreds &&
                reason != WifiBleFallbackReason.phoneWifiDisconnected) ...[
              const SizedBox(height: 16),
              if (ssid != null && ssid.trim().isNotEmpty)
                _credRow(ctx, l10n.fastSyncDeviceWifiNetworkLabel, ssid, l10n),
              if (password != null && password.trim().isNotEmpty) ...[
                if (ssid != null && ssid.trim().isNotEmpty)
                  const SizedBox(height: 8),
                _credRow(
                    ctx, l10n.fastSyncDeviceWifiPasswordLabel, password, l10n),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// A label + monospace value row with a copy button (SSID / Wi‑Fi password).
  Widget _credRow(
      BuildContext ctx, String label, String value, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.copy_rounded, size: 18),
            tooltip: l10n.fastSyncCopied,
            onPressed: () {
              // ignore: discarded_futures
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                SnackBar(
                  content: Text(l10n.fastSyncCopied),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _run() async {
    if (!mounted) return;
    _rootNavigator = Navigator.of(context, rootNavigator: true);
    final l10n = AppLocalizations.of(context)!;
    final rec = widget.recording;
    final device = ref.read(deviceControllerProvider.notifier);
    final wifi = ref.read(wifiTransferControllerProvider.notifier);
    var wifiOk = false;
    var suppressFailureSnack = false;

    try {
      if (_userRequestedClose) return;
      final sessionId = effectiveSessionId(rec);
      if (sessionId == null || sessionId.isEmpty) {
        if (mounted) setState(() => _fatalError = l10n.fastSyncNoSession);
        return;
      }

      final rs = await device.getRecordingStatus();
      if (rs != null && (rs.state == 'recording' || rs.state == 'paused')) {
        if (mounted) {
          setState(() => _fatalError = l10n.fastSyncUnavailableWhileRecording);
        }
        return;
      }

      device.startWifiHandoff(rec.id);
      try {
        // [cancelTransfer] returns false when there is no BLE pull for this recording.
        // After the user dismisses Fast Sync without joining Wi‑Fi, firmware is often
        // already IDLE — treating "nothing to cancel" as failure blocks the next Fast Sync.
        final hadBlePull =
            ref.read(deviceControllerProvider).activeTransferRecordingId ==
                rec.id;
        if (hadBlePull) {
          if (mounted) setState(() => _localStatus = l10n.fastSyncStoppingBle);
          // Free the BLE link (disable fileData CCCD) before AT+CANCEL so the
          // command reply is not stuck behind fileData notifications on Android
          // or queued on iOS. keepPendingOnTimeout: the download loop still
          // honours `cancelRequested`, and [_waitBleTransferIdle] (25s) waits
          // for the transfer to actually unregister before we move on to Wi‑Fi.
          final cancelled = await device.cancelTransfer(
            rec.id,
            errorCode: 'wifi_handoff',
            keepPendingOnTimeout: true,
          );
          if (!cancelled) {
            // Android often returns false while the download loop is still
            // honouring cancelRequested; [_waitBleTransferIdle] is the real gate.
            AppLog.w(
              '[FastSync] cancelTransfer returned false for ${rec.id}; '
              'waiting for BLE idle anyway',
            );
          }
          await _waitBleTransferIdle();
        }

        if (!mounted) return;

        if (Platform.isIOS) {
          final agreed = await AppDialogs.showConfirm(
            context,
            title: l10n.fastSyncIosLocalNetworkTitle,
            message: l10n.fastSyncIosLocalNetworkMessage,
            cancelText: l10n.cancel,
            confirmText: l10n.continueAction,
            barrierDismissible: false,
          );
          if (!mounted) return;
          if (agreed != true) {
            suppressFailureSnack = true;
            throw const _FastSyncClosedByUser();
          }
        }

        if (mounted) {
          setState(() => _localStatus = l10n.fastSyncLaunchingWifi);
        }

        final conn = ref.read(deviceControllerProvider).connection;
        final deviceIdForDb = (rec.deviceId ?? '').trim().isNotEmpty
            ? rec.deviceId!.trim()
            : (conn?.device.remoteId.toString() ?? '');
        if (deviceIdForDb.isEmpty) {
          throw StateError('Missing device id for Wi‑Fi batch');
        }

        final recRepo = await ref.read(recordingsRepositoryProvider.future);
        final pending = await recRepo.listTransfersToResume(deviceIdForDb);
        final ordered = <Recording>[];
        final seenIds = <String>{};
        void addRec(Recording r) {
          if (r.isDeleted) return;
          if (!seenIds.add(r.id)) return;
          ordered.add(r);
        }

        addRec(rec);
        for (final r in pending) {
          if (r.id != rec.id) addRec(r);
        }

        final seenSessions = <String>{};
        final batchItems = <WifiBatchItem>[];
        for (final r in ordered) {
          final sid = effectiveSessionId(r);
          if (sid == null || sid.isEmpty) continue;
          if (!seenSessions.add(sid)) continue;
          final markers = await device.resolveSessionResumeMarkersForSession(
            sessionId: sid,
            dbReceivedBytes: r.receivedBytes ?? 0,
          );
          batchItems.add(
            WifiBatchItem(
              recordingId: r.id,
              sessionId: sid,
              expectedBytes: r.expectedBytes,
              startFile: markers.startFile,
              resumeByteOffset: markers.resumeByteOffset,
              deleteAfterSync: true,
            ),
          );
        }

        if (batchItems.isEmpty) {
          throw StateError('No sessions to sync over Wi‑Fi');
        }

        AppLog.i(
          '[FastSync] BLE handoff done → WiFi batch ${batchItems.length} session(s), '
          'first=${batchItems.first.sessionId}',
        );

        final batchResult = await wifi.transferWifiBatch(
          items: batchItems,
          notifyOnComplete: true,
        );
        wifiOk = batchResult.isOverallSuccess;
        _bleFallbackReason = batchResult.bleFallbackReason;
        AppLog.i(
          '[FastSync] transferWifiBatch ok=$wifiOk '
          'succeeded=${batchResult.succeeded} failed=${batchResult.failed} '
          'cancelled=${batchResult.userCancelled} abortedRec=${batchResult.abortedForRecording} '
          'bleFallback=${_bleFallbackReason?.name ?? 'none'}',
        );
        if (_bleFallbackReason != null) {
          // Wi‑Fi could not deliver (phone on another Wi‑Fi, or associated but the
          // data path is lossy). Not a hard error — fall back to BLE. Proactively
          // turn the device AP off over BLE so a later Fast Sync can enable it
          // again (otherwise firmware can stay in WIFI_SYNC and reject AT+WIFI=ON),
          // and prompt the user via a dialog (not the progress banner). BLE resume
          // is scheduled in the finally below.
          suppressFailureSnack = true;
          // Prefer credentials bundled with the batch result — provider state may
          // already be cleared by the time we read it here. Also merge any values
          // captured earlier while the sheet was still showing the AP SSID.
          _rememberHotspotCredentials(batchResult.fallbackHotspot);
          AppLog.i(
            '[FastSync] fallback creds ssid=${_fallbackSsid ?? "(none)"} '
            'pwdLen=${_fallbackPassword?.length ?? 0}',
          );
          // AP is already torn down in [transferWifiBatch] → [_cleanup]; do not
          // call [forceDisableDeviceWifiAp] again here (extra AT+WIFI=OFF races).
        }
      } finally {
        device.endWifiHandoff();
      }
    } on _FastSyncClosedByUser {
      AppLog.i('[FastSync] user closed sheet during handoff');
    } catch (e, st) {
      AppLog.w('FastSyncWifiSheet failed', e, st);
      if (mounted) setState(() => _fatalError = e);
    } finally {
      // Resume BLE whenever Wi‑Fi did not fully succeed (failed / fell back /
      // partial), regardless of whether the sheet auto-popped. Schedule this
      // FIRST using notifiers captured at [_run] start — never touch [ref] here
      // because the sheet may have auto-popped during `transferring` and this
      // [State] is already disposed (was crashing at ref.read → no BLE resume).
      if (!_resumeBleAfterCloseScheduled && !_userRequestedClose && !wifiOk) {
        _resumeBleAfterCloseScheduled = true;
        unawaited(
          device.resumeBleTransfersAfterFastSyncDismiss(
            preferredRecordingId: rec.id,
            // Wi‑Fi handoff may leave a stuck BLE leg registered; force cancel
            // so resume can claim the slot (same as the fallback dialog Continue).
            forceRestart: _bleFallbackReason != null,
          ),
        );
      }
      try {
        wifi.clearEndedState();
      } catch (_) {}

      // Close the sheet if it's still up (it may have already auto-popped the
      // moment Wi‑Fi entered `transferring`). On a hard error (no BLE fallback)
      // surface a snackbar before popping.
      if (mounted) {
        setState(() => _running = false);
        if (_bleFallbackReason == null) {
          final err = _fatalError;
          if (!suppressFailureSnack &&
              !_userDismissedSheet &&
              (err != null || !wifiOk)) {
            final messenger = ScaffoldMessenger.maybeOf(context);
            final msg = err != null ? err.toString() : l10n.fastSyncFailed;
            final iosLocalNetworkHint =
                Platform.isIOS && err != null && msg.contains('Local Network');
            messenger?.showSnackBar(
              SnackBar(
                content: Text(msg),
                action: iosLocalNetworkHint
                    ? SnackBarAction(
                        label: l10n.fastSyncOpenAppSettings,
                        onPressed: () {
                          // ignore: discarded_futures
                          openAppSettings();
                        },
                      )
                    : null,
              ),
            );
          }
        }
        _suppressWifiCancelOnPop = true; // Wi‑Fi already ended/AP disabled.
        Navigator.of(context).maybePop();
      }

      // Whenever Wi‑Fi fell back to BLE, show ONE unified guidance dialog. It is
      // rendered on the ROOT navigator (captured while mounted) so it survives the
      // sheet auto-popping during `transferring`, and so it never blocks the
      // sheet's own dismissal ("popup won't dismiss"). BLE keeps syncing meanwhile.
      if (_bleFallbackReason != null &&
          !_userRequestedClose &&
          _rootNavigator != null) {
        final ssid = _fallbackSsid;
        final password = _fallbackPassword;
        final rootContext = _rootNavigator!.context;
        // The root navigator is captured while mounted and outlives this State,
        // so using its context here (after the sheet may have popped) is safe.
        // ignore: use_build_context_synchronously
        final dialog = _showWifiFallbackDialog(
          rootContext,
          l10n,
          ssid,
          password,
          reason: _bleFallbackReason!,
          onContinueExtra: () => device.resumeBleTransfersAfterFastSyncDismiss(
            preferredRecordingId: rec.id,
            forceRestart: true,
          ),
        );
        unawaited(dialog);
      }
    }
  }

  String _wifiPhaseLine(AppLocalizations l10n, WifiTransferPhase p) {
    switch (p) {
      case WifiTransferPhase.idle:
        return l10n.fastSyncPreparing;
      case WifiTransferPhase.enablingHotspot:
        return l10n.fastSyncEnablingHotspot;
      case WifiTransferPhase.connectingWifi:
        return l10n.fastSyncJoiningWifi;
      case WifiTransferPhase.verifyingConnection:
        return l10n.fastSyncVerifyingUdp;
      case WifiTransferPhase.transferring:
        return l10n.fastSyncTransferring;
      case WifiTransferPhase.mergingFiles:
        return l10n.fastSyncMerging;
      case WifiTransferPhase.disablingHotspot:
        return l10n.fastSyncRestoringWifi;
      case WifiTransferPhase.completed:
        return l10n.fastSyncDone;
      case WifiTransferPhase.failed:
        return l10n.fastSyncFailed;
    }
  }

  /// Prefer Wi‑Fi controller phases once they target this recording; otherwise show BLE handoff hints.
  String _statusLine(AppLocalizations l10n, WifiTransferState wifi) {
    if (_running && wifi.isActive) {
      return _wifiPhaseLine(l10n, wifi.phase);
    }
    if (wifi.recordingId == widget.recording.id) {
      return _wifiPhaseLine(l10n, wifi.phase);
    }
    if (_localStatus != null) {
      return _localStatus!;
    }
    if (_running) {
      return _wifiPhaseLine(l10n, wifi.phase);
    }
    return l10n.fastSyncPreparing;
  }

  static bool _phaseIsConnecting(WifiTransferPhase p) {
    return p == WifiTransferPhase.idle ||
        p == WifiTransferPhase.enablingHotspot ||
        p == WifiTransferPhase.connectingWifi ||
        p == WifiTransferPhase.verifyingConnection;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final wifi = ref.watch(wifiTransferControllerProvider);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final accent = Theme.of(context).colorScheme.primary;

    ref.listen(wifiTransferControllerProvider, (prev, next) {
      if (next.recordingId == widget.recording.id) {
        _rememberHotspotCredentials(next.hotspot);
      }
      if (!mounted || !_running || _didAutoPopForTransferStart) return;
      if (next.recordingId != widget.recording.id) return;
      // Auto-close as soon as Wi‑Fi reaches the data phase (`transferring`) or the
      // merge phase: the connection is established and the rest runs in the
      // background, with live progress on the home transfer banner. Keeping the
      // sheet up through `transferring` made it linger on "Transferring over
      // Wi‑Fi…" even on healthy runs. If the run later fails / falls back, the
      // unified Wi‑Fi fallback dialog is shown on the ROOT navigator from the
      // finally below, so it survives this pop. NOTE: do NOT treat `completed` as
      // progress — the controller sets `completed` at the end of BOTH success and
      // failure batches, so popping on it would race that fallback dialog.
      final p = next.phase;
      final realProgress = p == WifiTransferPhase.mergingFiles ||
          p == WifiTransferPhase.transferring;
      if (!realProgress) return;
      _didAutoPopForTransferStart = true;
      _suppressWifiCancelOnPop = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).maybePop();
      });
    });

    ref.listen(deviceControllerProvider, (prev, next) {
      if (!mounted || !_running) return;
      final lostDevice = prev?.connection != null && next.connection == null;
      if (!lostDevice) return;
      final w = ref.read(wifiTransferControllerProvider);
      if (!w.isActive) return;
      final p = w.phase;
      if (p == WifiTransferPhase.enablingHotspot ||
          p == WifiTransferPhase.connectingWifi ||
          p == WifiTransferPhase.verifyingConnection) {
        ref.read(wifiTransferControllerProvider.notifier).cancel();
      }
    });

    final status = _statusLine(l10n, wifi);
    final forThis = wifi.recordingId == widget.recording.id;
    final showSpinner = _fatalError == null &&
        _running &&
        (!forThis || _phaseIsConnecting(wifi.phase));

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        final skipWifiOff = _suppressWifiCancelOnPop;
        _suppressWifiCancelOnPop = false;
        if (skipWifiOff) {
          return;
        }
        _userDismissedSheet = true;
        _userRequestedClose = true;
        unawaited(ref.read(wifiTransferControllerProvider.notifier).cancel());
        final deviceNotifier = ref.read(deviceControllerProvider.notifier);
        deviceNotifier.endWifiHandoff();
        // BLE was cancelled for handoff; handoff gate is off — pick up transferring/failed rows again.
        if (!_resumeBleAfterCloseScheduled) {
          _resumeBleAfterCloseScheduled = true;
          unawaited(
            deviceNotifier.resumeBleTransfersAfterFastSyncDismiss(
              preferredRecordingId: widget.recording.id,
            ),
          );
        }
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    l10n.fastSyncSheetTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: AppTypography.s16,
                        ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.brandPrimary,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.fastSyncCloseTurnOffWifi),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.fastSyncDismissHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 28),
            if (_fatalError != null) ...[
              Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error, size: 40),
              const SizedBox(height: 12),
              Text(
                _fatalError.toString(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
              ),
            ] else ...[
              if (showSpinner) ...[
                Center(
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
              Text(
                status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
              ),
              if (wifi.hotspot != null && forThis) ...[
                const SizedBox(height: 10),
                Text(
                  wifi.hotspot!.ssid,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
