import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
// DeviceRuntimeInfo is defined locally in device_controller.dart; hide the
// SDK's identically-named export so both can coexist.
import 'package:sensecraft_voice/sensecraft_voice.dart' hide DeviceRuntimeInfo;

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/validation/user_visible_name.dart';
import '../../../core/log/app_log.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../settings/data/permissions_provider.dart';
import '../data/device_repository.dart';
import 'device_controller.dart';

import '../../../app/theme/app_typography.dart';

/// Product: hide until the purge flow is validated on all firmware builds.
const _showPurgeDeviceSessions = false;

final _deviceByIdProvider = FutureProvider.family<Device?, String>((ref, id) async {
  // Re-fetch when device info is persisted (battery/firmware/mode/online).
  ref.watch(deviceDbRevisionProvider);
  final repo = await ref.watch(deviceRepositoryProvider.future);
  return repo.getById(id);
});
final _deviceDetailsCacheProvider = StateProvider.family<Device?, String>((ref, id) => null);
final _deviceRuntimeInfoCacheProvider =
    StateProvider.family<DeviceRuntimeInfo?, String>((ref, id) => null);

bool _runtimeTextPresent(String? value) =>
    value != null && value.trim().isNotEmpty;

bool _hasMeaningfulRuntimeInfo(DeviceRuntimeInfo? info) {
  if (info == null) return false;
  return _runtimeTextPresent(info.deviceTime) ||
      _runtimeTextPresent(info.state) ||
      info.batteryPercent != null ||
      _runtimeTextPresent(info.mode);
}

DeviceRuntimeInfo _runtimeInfoFromDevice(Device device) {
  return DeviceRuntimeInfo(
    firmware: device.firmwareVersion,
    batteryPercent: device.batteryPercent,
    mode: device.recordingMode.name,
  );
}

DeviceRuntimeInfo _mergeRuntimeInfo(
  DeviceRuntimeInfo base,
  DeviceRuntimeInfo? fresh,
) {
  if (fresh == null) return base;
  return DeviceRuntimeInfo(
    firmware:
        _runtimeTextPresent(fresh.firmware) ? fresh.firmware : base.firmware,
    deviceTime: _runtimeTextPresent(fresh.deviceTime)
        ? fresh.deviceTime
        : base.deviceTime,
    state: _runtimeTextPresent(fresh.state) ? fresh.state : base.state,
    batteryPercent: fresh.batteryPercent ?? base.batteryPercent,
    mode: _runtimeTextPresent(fresh.mode) ? fresh.mode : base.mode,
    pairStatus: _runtimeTextPresent(fresh.pairStatus)
        ? fresh.pairStatus
        : base.pairStatus,
    pairAddress: _runtimeTextPresent(fresh.pairAddress)
        ? fresh.pairAddress
        : base.pairAddress,
  );
}

class DeviceDetailsPage extends ConsumerWidget {
  final String deviceId;

  const DeviceDetailsPage({super.key, required this.deviceId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncDevice = ref.watch(_deviceByIdProvider(deviceId));

    return asyncDevice.when(
      loading: () {
        final cached = ref.read(_deviceDetailsCacheProvider(deviceId));
        if (cached != null && cached.id == deviceId) {
          return _DeviceDetailsScaffold(device: cached);
        }
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
      error: (e, _) {
        final l10n = AppLocalizations.of(context)!;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.deviceDetailsInfo)),
          body: Center(child: Text(e.toString())),
        );
      },
      data: (device) {
        // Defer cache writes to post-frame to avoid modifying providers during build
        Future(() {
          ref.read(_deviceDetailsCacheProvider(deviceId).notifier).state = device;
        });
        if (device == null) {
          final l10n = AppLocalizations.of(context)!;
          return Scaffold(
            appBar: AppBar(title: Text(l10n.deviceDetailsInfo)),
            body: Center(child: Text(l10n.deviceNotFound)),
          );
        }
        return _DeviceDetailsScaffold(device: device);
      },
    );
  }
}

class _DeviceDetailsScaffold extends ConsumerStatefulWidget {
  final Device device;

  const _DeviceDetailsScaffold({required this.device});

  @override
  ConsumerState<_DeviceDetailsScaffold> createState() => _DeviceDetailsScaffoldState();
}

class _DeviceDetailsScaffoldState extends ConsumerState<_DeviceDetailsScaffold> {
  DeviceRuntimeInfo? _runtimeInfo;
  bool _loadingRuntime = false;

  @override
  void initState() {
    super.initState();
    final cached = ref.read(_deviceRuntimeInfoCacheProvider(widget.device.id));
    final seeded = cached ?? _runtimeInfoFromDevice(widget.device);
    _runtimeInfo = _hasMeaningfulRuntimeInfo(seeded) ? seeded : null;
    // Best-effort: if this device is currently connected, load runtime info.
    // Delay to ensure BLE connection & notifications are fully ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeLoadRuntimeInfo();
    });
  }

  Future<void> _maybeLoadRuntimeInfo() async {
    final deviceState = ref.read(deviceControllerProvider);
    final asyncDevice = await ref.read(_deviceByIdProvider(widget.device.id).future);
    final isCurrentConnected = asyncDevice != null &&
        isDeviceEffectivelyOnline(asyncDevice, deviceState) &&
        deviceState.connection?.device.remoteId.toString() == widget.device.id;
    AppLog.i(
      'DeviceDetails._maybeLoadRuntimeInfo: isCurrentConnected=$isCurrentConnected '
      'currentConnId=${deviceState.connection?.device.remoteId} detailsId=${widget.device.id}',
    );
    if (_loadingRuntime) return;
    final previous = _runtimeInfo ??
        ref.read(_deviceRuntimeInfoCacheProvider(widget.device.id)) ??
        _runtimeInfoFromDevice(asyncDevice ?? widget.device);
    setState(() {
      _loadingRuntime = true;
    });
    DeviceRuntimeInfo? fresh;
    if (isCurrentConnected) {
      final notifier = ref.read(deviceControllerProvider.notifier);
      await notifier.syncDeviceTimeOnDetailsEntry();
      fresh = await notifier.readRuntimeInfo();
    }
    final merged = _mergeRuntimeInfo(previous, fresh);
    if (!mounted) return;
    setState(() {
      _runtimeInfo =
          _hasMeaningfulRuntimeInfo(merged) ? merged : _runtimeInfo ?? previous;
      _loadingRuntime = false;
    });
    if (_hasMeaningfulRuntimeInfo(merged)) {
      ref.read(_deviceRuntimeInfoCacheProvider(widget.device.id).notifier).state =
          merged;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    final device = widget.device;
    final deviceState = ref.watch(deviceControllerProvider);
    final effectivelyOnline =
        isDeviceEffectivelyOnline(device, deviceState);
    final statusText = effectivelyOnline ? l10n.online : l10n.offline;
    final sn = device.sn ?? _snFromId(device.id);
    final fw = device.firmwareVersion ?? 'v1.2.4';
    final ctrl = ref.read(deviceControllerProvider.notifier);
    final isCurrentConnected =
        effectivelyOnline &&
        deviceState.connection?.device.remoteId.toString() == device.id;

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.deviceDetailsInfo),
        actions: [
          IconButton(
            tooltip: l10n.deviceDetailsRefresh,
            onPressed: () async {
              if (!isCurrentConnected) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.deviceDetailsConnectFirstToRefresh)));
                return;
              }
              await ctrl.syncConnectedDeviceInfo();
              await _maybeLoadRuntimeInfo();
              ref.invalidate(_deviceByIdProvider(device.id));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.deviceDetailsRefreshed)));
              }
            },
            icon: const Icon(Icons.refresh),
          ),
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.deviceModificationSuccess)));
            },
            child: Text(l10n.done, style: TextStyle(color: primary, fontWeight: FontWeight.w500, fontSize: AppTypography.s14)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          children: [
            _HeroDeviceTile(),
            const SizedBox(height: 14),
            _Card(
              child: Column(
                children: [
                  _RowItem(
                    label: l10n.deviceNameLabel,
                    trailing: Row(
                      children: [
                        Expanded(
                          child: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: primary,
                              fontSize: AppTypography.s14,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _rename(context, ref, device),
                          borderRadius: BorderRadius.circular(999),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(Icons.edit, size: 18, color: primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const _Divider(),
                  _RowItem(label: l10n.snLabel, value: sn, valueColor: AppColors.textTertiary),
                  const _Divider(),
                  _RowItem(label: l10n.statusLabel, value: statusText, valueColor: primary),
                  const _Divider(),
                  _RowItem(label: l10n.modelLabel, value: device.model, valueColor: AppColors.textTertiary),
                  const _Divider(),
                  _RowItem(
                    label: l10n.batteryLabel,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          // Show battery only when online; placeholder when offline
                          effectivelyOnline && device.batteryPercent != null
                              ? '${device.batteryPercent}%'
                              : '--',
                          style: TextStyle(color: primary, fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.battery_full, size: 18, color: primary),
                      ],
                    ),
                  ),
                  const _Divider(),
                  _RowItem(
                    label: l10n.recordingModeLabel,
                    trailing: _RecordingModeSegment(
                      value: device.recordingMode,
                      onChanged: (m) => _setRecordingMode(context, ref, device, m),
                    ),
                  ),
                  const _Divider(),
                  _RowItem(
                    label: l10n.firmwareVersionLabel,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(fw, style: const TextStyle(color: AppColors.textTertiary, fontWeight: FontWeight.w500)),
                        const SizedBox(width: 8),
                        if (device.hasFirmwareUpdate) const _RedDot(),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right, color: AppColors.textTertiary,size: 28),
                      ],
                    ),
                    onTap: () => context.push('/device/${device.id}/firmware'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (isCurrentConnected) ...[
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        l10n.deviceDetailsRuntimeSectionTitle,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: AppTypography.s14,
                            ),
                      ),
                    ),
                    const _Divider(),
                    if (_loadingRuntime)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 10),
                            Text(l10n.deviceDetailsReadingAtInfo),
                          ],
                        ),
                      )
                    else if (_runtimeInfo != null) ...[
                      _RowItem(
                        label: l10n.deviceDetailsDeviceTime,
                        value: _runtimeInfo!.deviceTime ?? '--',
                      ),
                      const _Divider(),
                      _RowItem(
                        label: l10n.deviceDetailsWorkState,
                        value: _runtimeInfo!.state ?? '--',
                      ),
                      const _Divider(),
                      _RowItem(
                        label: l10n.deviceDetailsBatteryAt,
                        value: _runtimeInfo!.batteryPercent == null
                            ? '--'
                            : '${_runtimeInfo!.batteryPercent}%',
                      ),
                      const _Divider(),
                      _RowItem(
                        label: l10n.deviceDetailsModeAt,
                        value: _runtimeInfo!.mode ?? '--',
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          l10n.deviceDetailsAtInfoUnavailable,
                          style: const TextStyle(color: AppColors.textTertiary, fontSize: AppTypography.s14),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
            ],
            const SizedBox(height: 18),
            _ActionText(
              label: l10n.disconnectAction,
              onTap: () => _confirmDisconnect(context, ref),
            ),
            const SizedBox(height: 18),
            if (_showPurgeDeviceSessions) ...[
              _DangerText(
                label: l10n.purgeDeviceSessions,
                onTap: () => _confirmPurgeDeviceSessions(context, ref, device),
              ),
              const SizedBox(height: 18),
            ],
            _DangerText(
              label: l10n.resetDeviceAction,
              onTap: () => _confirmReset(context, ref, device),
            ),
            const SizedBox(height: 18),
            _DangerText(
              label: l10n.unbindDeviceAction,
              onTap: () => _confirmUnbind(context, ref, device),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroDeviceTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.r18),
      ),
      child: Center(
        child: Container(
          width: 220,
          height: 220,
          decoration: BoxDecoration(
            color: AppColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(36),
          ),
          child: const Center(
            child: Icon(Icons.mic, size: 56, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      borderRadius: BorderRadius.circular(AppRadii.r18),
      backgroundColor: AppColors.surface,
      borderColor: AppColors.border,
      child: child,
    );
  }
}

class _RowItem extends StatelessWidget {
  final String label;
  final String? value;
  final Color valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _RowItem({
    required this.label,
    this.value,
    this.valueColor = AppColors.textTertiary,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final right = trailing ??
        Text(
          value ?? '',
          style: TextStyle(color: valueColor, fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
        );

    final row = Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500, fontSize: AppTypography.s14)),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: 1,
            child: right,
          ),
        ),
      ],
    );

    if (onTap == null) return Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: row);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r12),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: row),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => const Divider(height: 1, color: AppColors.border);
}

class _RedDot extends StatelessWidget {
  const _RedDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: AppColors.danger,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
    );
  }
}

class _RecordingModeSegment extends StatelessWidget {
  final RecordingMode value;
  final ValueChanged<RecordingMode> onChanged;

  const _RecordingModeSegment({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget chip(String text, bool selected, VoidCallback onTap) {
      return Flexible(
        flex: 1,
        fit: FlexFit.loose,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.r12),
          child: Container(
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? AppColors.surface : AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(AppRadii.r12),
            ),
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s14,
                color: selected ? Colors.black : AppColors.textTertiary,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadii.r14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip(l10n.recordingModeNormal, value == RecordingMode.normal, () => onChanged(RecordingMode.normal)),
          const SizedBox(width: 6),
          chip(l10n.recordingModeEnhanced, value == RecordingMode.enhanced, () => onChanged(RecordingMode.enhanced)),
        ],
      ),
    );
  }
}

class _ActionText extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ActionText({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
      ),
    );
  }
}

class _DangerText extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DangerText({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppColors.danger, fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
      ),
    );
  }
}

/// Opens rename dialog, validates input, then [DeviceController.applyDeviceName].
///
/// When BLE is disconnected, `requireDevice: false` saves locally and queues AT+NAME
/// on the next connect ([DeviceController._reconcileDeviceNameAfterConnect]). When
/// connected, writes AT+NAME first so the firmware remains source of truth for UTF-8 limits.
Future<void> _rename(BuildContext context, WidgetRef ref, Device device) async {
  final l10n = AppLocalizations.of(context)!;
  if (!context.mounted) return;
  final ctrl = TextEditingController(text: device.name);
  final primary = Theme.of(context).colorScheme.primary;

  // Stay offline-friendly: when no live BLE link, the dialog tells the user
  // the new name will be pushed on next connect (per AT+NAME design in
  // `protocol.md` 3.3.7 — the value is persisted on the device).
  final state = ref.read(deviceControllerProvider);
  final isCurrentConnected =
      state.connection?.device.remoteId.toString() == device.id;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final screenW = MediaQuery.sizeOf(ctx).width;
      // Wider than default AlertDialog (~280) so the name field is easier to
      // read and edit; use [Dialog] so width works on all Flutter versions.
      final dialogW = (screenW - 40).clamp(312.0, 520.0);
      final tt = Theme.of(ctx).textTheme;
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.r16),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: dialogW),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.renameDeviceTitle,
                  textAlign: TextAlign.center,
                  style: tt.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 64,
                  child: TextField(
                    controller: ctrl,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    style: TextStyle(
                      fontSize: AppTypography.s16,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                      height: 1.25,
                    ),
                    cursorColor: primary,
                    textAlign: TextAlign.center,
                    textAlignVertical: TextAlignVertical.center,
                    maxLength: kUserVisibleNameMaxLength,
                    buildCounter: (
                      context, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) =>
                        null,
                    decoration: InputDecoration(
                      hintText: l10n.deviceNameHint,
                      hintStyle: TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: AppTypography.s16,
                        fontWeight: FontWeight.w400,
                        height: 1.25,
                      ),
                      isDense: false,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 0,
                      ),
                      filled: true,
                      fillColor: AppColors.surfaceSubtle,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadii.r12),
                        borderSide:
                            const BorderSide(color: AppColors.borderLight),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadii.r12),
                        borderSide:
                            const BorderSide(color: AppColors.borderLight),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadii.r12),
                        borderSide: BorderSide(color: primary, width: 1.5),
                      ),
                    ),
                  ),
                ),
                if (!isCurrentConnected) ...[
                  const SizedBox(height: 10),
                  Text(
                    l10n.renameOfflineHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppTypography.s12,
                      color: AppColors.textTertiary,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(l10n.cancel,
                          style: TextStyle(
                              color: primary,
                              fontWeight: FontWeight.w500,
                              fontSize: AppTypography.s14)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(l10n.save,
                          style: TextStyle(
                              color: primary,
                              fontWeight: FontWeight.w500,
                              fontSize: AppTypography.s14)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  if (ok != true) return;
  final name = ctrl.text.trim();
  if (name.isEmpty) return;

  final ctrlNotifier = ref.read(deviceControllerProvider.notifier);
  // requireDevice=false → allow offline rename (cached and flushed on
  // reconnect via [DeviceController._reconcileDeviceNameAfterConnect]).
  final result =
      await ctrlNotifier.applyDeviceName(name, requireDevice: false);
  if (!context.mounted) return;

  ref.read(deviceDbRevisionProvider.notifier).state++;
  ref.invalidate(_deviceByIdProvider(device.id));

  if (!result.ok) {
    final msg = switch (result.errorCode) {
      'name_invalid' => l10n.renameInvalid,
      'device_rejected' =>
        l10n.renameDeviceRejected(result.atErrorMessage ?? ''),
      'at_failed' =>
        l10n.renameAtFailed(result.atErrorMessage ?? ''),
      _ => l10n.renameFailed,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(result.savedOnDeviceToo
        ? l10n.renameSavedOnDevice
        : l10n.renameSavedLocallyWillSync),
  ));
}

Future<void> _setRecordingMode(BuildContext context, WidgetRef ref, Device device, RecordingMode mode) async {
  if (device.recordingMode == mode) return;
  final repo = await ref.read(deviceRepositoryProvider.future);
  final state = ref.read(deviceControllerProvider);
  final ctrl = ref.read(deviceControllerProvider.notifier);
  final isCurrentConnected = state.connection?.device.remoteId.toString() == device.id;
  if (isCurrentConnected) {
    final ok = await ctrl.applyRecordingMode(mode);
    if (!ok && context.mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.deviceDetailsSettingFailedRetry)));
      return;
    }
  } else {
    // Offline: only update local preference; will be reconciled after next connect.
    await repo.updateRecordingMode(device.id, mode);
    ref.read(deviceDbRevisionProvider.notifier).state++;
  }
  ref.invalidate(_deviceByIdProvider(device.id));
}

Future<void> _confirmDisconnect(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final primary = Theme.of(context).colorScheme.primary;
  final res = await showAppBottomSheet<String>(
    context,
    useRootNavigator: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.disconnectDeviceTitle, style: const TextStyle(fontSize: AppTypography.s18, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.disconnectDeviceMessage,
              style: const TextStyle(color: AppColors.textTertiary, height: 1.4, fontSize: AppTypography.s14),
            ),
          ),
          const SizedBox(height: 18),
          AppBlackPillButton(
            label: l10n.disconnectAction,
            onPressed: () {
              Navigator.of(sheetContext).pop('disconnect');
            },
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              Navigator.of(sheetContext).pop('cancel');
            },
            child: Text(l10n.cancel, style: TextStyle(color: primary, fontWeight: FontWeight.w500, fontSize: AppTypography.s14)),
          ),
          const SizedBox(height: 32),
        ],
      ),
    ),
  );

  if (res != 'disconnect') return;
  await ref.read(deviceControllerProvider.notifier).disconnect();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.disconnectSentSnack)));
  }
}

Future<void> _confirmPurgeDeviceSessions(BuildContext context, WidgetRef ref, Device device) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await AppDialogs.showDeleteConfirm(
    context,
    title: l10n.purgeDeviceSessions,
    message: l10n.purgeDeviceSessionsConfirm,
    deleteText: l10n.delete,
  );
  if (!ok || !context.mounted) return;
  final state = ref.read(deviceControllerProvider);
  final ctrl = ref.read(deviceControllerProvider.notifier);
  final isCurrentConnected =
      isDeviceEffectivelyOnline(device, state) &&
      state.connection?.device.remoteId.toString() == device.id;
  if (!isCurrentConnected) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.purgeDeviceSessionsConnectFirst)));
    }
    return;
  }
  final handle = AppDialogs.showLoading(context, message: l10n.purging);
  final success = await ctrl.purgeAllSessions();
  if (context.mounted) handle.close();
  ref.invalidate(_deviceByIdProvider(device.id));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(success ? l10n.purgeDeviceSessionsDone : l10n.purgeDeviceSessionsFailed)),
  );
}

Future<void> _confirmReset(BuildContext context, WidgetRef ref, Device device) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await AppDialogs.showConfirm(
    context,
    title: l10n.resetDeviceTitle,
    message: l10n.resetDeviceMessage,
    cancelText: l10n.cancel,
    confirmText: l10n.resetConfirm,
  );
  if (!ok) return;
  final state = ref.read(deviceControllerProvider);
  final ctrl = ref.read(deviceControllerProvider.notifier);
  final isCurrentConnected = state.connection?.device.remoteId.toString() == device.id;
  if (!isCurrentConnected) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.deviceDetailsConnectFirstToReset)));
    }
    return;
  }
  await ctrl.factoryReset();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.resetSentSnack)),
    );
  }
}

Future<void> _confirmUnbind(BuildContext context, WidgetRef ref, Device device) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await AppDialogs.showConfirm(
    context,
    title: l10n.unbindDeviceTitle,
    message: l10n.unbindDeviceMessage,
    cancelText: l10n.cancel,
    confirmText: l10n.unbindConfirm,
  );
  if (!ok || !context.mounted) return;

  final ctrl = ref.read(deviceControllerProvider.notifier);
  final hasLiveLink = ctrl.isLinked(device.id);

  await ctrl.beginUnbind(device.id);

  // 1) When BLE is up, clear pairing on the device before removing from the app.
  if (hasLiveLink) {
    final handle = AppDialogs.showLoading(context, message: l10n.unbinding);
    final pairingCleared = await ctrl.resetPairingForDevice(device.id);
    if (context.mounted) handle.close();
    if (!pairingCleared && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.unpairFailedSnack)),
      );
    }
  }

  // 2) Always tear down app + OS BLE state (even when step 1 failed or was skipped).
  await ctrl.teardownForUnbind(device.id);

  // 3) Delete from local db
  final repo = await ref.read(deviceRepositoryProvider.future);
  await repo.delete(device.id);
  ref.read(deviceDbRevisionProvider.notifier).state++;
  ref.invalidate(_deviceByIdProvider(device.id));

  if (!context.mounted) return;

  // System Bluetooth may still keep the bond after app/device unbind.
  // Guide the user to Forget / unpair in phone Bluetooth settings.
  final goSettings = await AppDialogs.showConfirm(
    context,
    title: l10n.unbindIosForgetReminderTitle,
    message: l10n.unbindIosForgetReminderMessage,
    cancelText: l10n.cancel,
    confirmText: l10n.openSettingsAction,
  );
  if (goSettings) {
    await openSystemBluetoothSettings();
  }

  if (context.mounted) {
    Navigator.of(context).pop(); // leave details page
  }

  // TODO(server): call backend unbind API once auth+backend ready.
}

String _snFromId(String id) {
  final clean = id.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  final last4 = clean.isEmpty ? '0000' : clean.padLeft(4, '0').substring(clean.length >= 4 ? clean.length - 4 : 0);
  return 'SN-2026-$last4';
}

