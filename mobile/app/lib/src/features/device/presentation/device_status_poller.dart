import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../settings/data/permissions_provider.dart';
import '../data/device_repository.dart';
import 'device_controller.dart';

/// Global poller to keep device status fresh when user leaves the recording UI.
///
/// Strategy:
/// - Battery level is pushed via BLE (0x180F/0x2A19), no AT polling needed.
/// - AT+GSTAT only as fallback (when device has no BLE battery service), call once every 10 minutes.
class DeviceStatusPoller extends ConsumerStatefulWidget {
  const DeviceStatusPoller({super.key});

  @override
  ConsumerState<DeviceStatusPoller> createState() => _DeviceStatusPollerState();
}

class _DeviceStatusPollerState extends ConsumerState<DeviceStatusPoller> with WidgetsBindingObserver {
  Timer? _ticker;
  bool _foreground = true;
  DateTime _nextPollAt = DateTime.fromMillisecondsSinceEpoch(0);
  /// Same reconnect SnackBar again within this window is skipped (BLE flapping).
  static const Duration _reconnectSnackDebounce = Duration(seconds: 2);
  String? _lastReconnectSnackKind;
  DateTime? _lastReconnectSnackAt;

  bool _allowReconnectSnack(String kind) {
    final now = DateTime.now();
    if (_lastReconnectSnackKind == kind && _lastReconnectSnackAt != null) {
      if (now.difference(_lastReconnectSnackAt!) < _reconnectSnackDebounce) {
        return false;
      }
    }
    _lastReconnectSnackKind = kind;
    _lastReconnectSnackAt = now;
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      // When app resumes from background, if previously disconnected try auto-reconnect (firmware-first, resume recording/sync).
      final st = ref.read(deviceControllerProvider);
      if (st.connection == null && st.lastConnectedDeviceId != null) {
        ref.read(deviceControllerProvider.notifier).kickAutoReconnect();
      }
      // After iOS screen off progressRefreshTimer is paused, record-while-transfer progress bar stalls; force refresh on resume.
      ref.read(deviceControllerProvider.notifier).refreshTransferProgressUI();
      // iOS freezes GATT file notifies in background — nudge stalled mid-file
      // pulls so we re-issue AT+DOWNLOAD instead of sitting at ~92%.
      ref
          .read(deviceControllerProvider.notifier)
          .nudgeStalledBleTransfersAfterAppResume();
      // Poll ASAP when coming back.
      _nextPollAt = DateTime.fromMillisecondsSinceEpoch(0);
      _tick();
    }
  }

  Future<void> _tick() async {
    if (!mounted) return;
    if (!_foreground) return;

    final st = ref.read(deviceControllerProvider);
    if (st.connection == null) return;

    final ctrl = ref.read(deviceControllerProvider.notifier);
    await ctrl.maybeSyncDeviceTimeWhenIdle();

    final now = DateTime.now();
    if (now.isBefore(_nextPollAt)) return;

    // Claim next poll slot immediately to avoid concurrent AT+GSTAT when multiple _tick overlap
    _nextPollAt = now.add(const Duration(minutes: 10));

    await ctrl.pollGstatAndPersist();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.listen(deviceControllerProvider, (prev, next) {
      if (l10n == null) return;
      if (!context.mounted) return;
      // DeviceUiState has no custom ==; any field change notifies listeners. Only react to
      // reconnectStatus *transitions* so we do not spam SnackBars while status stays success.
      final prevStatus = prev?.reconnectStatus ?? 'idle';
      final nextStatus = next.reconnectStatus;
      if (nextStatus == 'reconnecting' && prevStatus != 'reconnecting') {
        if (!_allowReconnectSnack('reconnecting')) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.deviceDisconnectedReconnecting),
            duration: const Duration(seconds: 3),
          ),
        );
      } else if (nextStatus == 'success' && prevStatus != 'success' && next.connection != null) {
        // Prefer DB [Device.name] (user rename / last known display name). BLE
        // [platformName] can lag until AT+NAME propagates or the stack refreshes adv data.
        final conn = next.connection!;
        final deviceId = conn.device.remoteId.toString();
        Future.microtask(() async {
          var displayName = '';
          try {
            final repo = await ref.read(deviceRepositoryProvider.future);
            final device = await repo.getById(deviceId);
            displayName = (device?.name ?? '').trim();
          } catch (_) {}
          if (displayName.isEmpty) {
            displayName = conn.device.platformName.trim();
          }
          if (displayName.isEmpty) {
            displayName = l10n.defaultDeviceName;
          }
          if (!context.mounted) return;
          if (!_allowReconnectSnack('success')) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.connectedTo(displayName)),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        });
      } else if (nextStatus == 'failed' && prevStatus != 'failed') {
        // GATT may still be up while AT stabilization failed — avoid false alarm.
        if (next.connection != null) return;
        if (!_allowReconnectSnack('failed')) return;
        if (l10n.isIosBluetoothForgetDeviceError(next.errorCode)) {
          unawaited(() async {
            final goSettings = await AppDialogs.showConfirm(
              context,
              title: l10n.connectionFailedIosForgetTitle,
              message: l10n.transferOrConnectionError(next.errorCode),
              cancelText: l10n.cancel,
              confirmText: l10n.forgetDeviceInSettingsAction,
            );
            if (goSettings) {
              await openSystemBluetoothSettings();
            }
          }());
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.reconnectFailed),
                const SizedBox(height: 6),
                Text(
                  l10n.connectionFailedUnpairHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                ),
              ],
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });
    return const SizedBox.shrink();
  }
}

