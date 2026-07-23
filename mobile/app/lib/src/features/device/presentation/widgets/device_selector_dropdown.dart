import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/widgets/app_dialogs.dart';
import '../../../settings/data/permissions_provider.dart';
import '../bluetooth_connect_gate.dart';
import '../device_controller.dart';
import 'device_connect_sheet.dart';
import '../../../../app/theme/app_typography.dart';

/// Device selector dropdown widget.
/// Shows current device in header, opens dropdown on tap.
class DeviceSelectorDropdown extends ConsumerStatefulWidget {
  const DeviceSelectorDropdown({super.key});

  @override
  ConsumerState<DeviceSelectorDropdown> createState() =>
      _DeviceSelectorDropdownState();
}

class _DeviceSelectorDropdownState
    extends ConsumerState<DeviceSelectorDropdown> {
  final _anchorKey = GlobalKey();
  static const _kAddValue = '__add_device__';
  static const _kSelectPrefix = '__select__::';
  static const _kDetailsPrefix = '__details__::';

  @override
  Widget build(BuildContext context) {
    final deviceState = ref.watch(deviceControllerProvider);
    final devicesAsync = ref.watch(devicesListProvider);
    final currentDeviceId = deviceState.connection?.device.remoteId.toString();
    // When the managed device disconnects, `state.connection` becomes null but
    // the controller intentionally keeps `lastConnectedDeviceId` set and keeps
    // operating on that device (auto-reconnect, transfer resume, active
    // recording). The header must follow that same device so the title stays
    // aligned with the actual foreground logic — falling back to
    // `devices.first` here would silently flip the title to a *different*
    // device the app isn't actually using.
    final effectiveDeviceId = currentDeviceId ?? deviceState.lastConnectedDeviceId;

    return devicesAsync.when(
      loading: () => _buildHeader(
        context,
        null,
        deviceState: deviceState,
        isLoading: true,
        hasAnyDevice: true,
      ),
      error: (_, __) => _buildHeader(
        context,
        null,
        deviceState: deviceState,
        hasAnyDevice: true,
      ),
      data: (devices) {
        Device? current;
        if (effectiveDeviceId != null && devices.isNotEmpty) {
          // Prefer the controller's foreground device (live or
          // last-connected); only fall back to `devices.first` if that device
          // is no longer in the list (e.g. removed/forgotten).
          current = devices
                  .where((d) => d.id == effectiveDeviceId)
                  .firstOrNull ??
              devices.first;
        } else if (devices.isNotEmpty) {
          current = devices.first;
        }

        // If no devices yet: show "Add Device" (tap goes to bind flow).
        return _buildHeader(
          context,
          current,
          deviceState: deviceState,
          hasAnyDevice: devices.isNotEmpty,
          onTap: () => _onTapHeader(context, devices, currentDeviceId),
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    Device? current, {
    required DeviceUiState deviceState,
    required bool hasAnyDevice,
    bool isLoading = false,
    VoidCallback? onTap,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    final l10n = AppLocalizations.of(context)!;
    final name = hasAnyDevice
        ? (current?.name ?? l10n.defaultDeviceName)
        : l10n.addDevice;
    final isOnline =
        current != null && isDeviceEffectivelyOnline(current, deviceState);
    final battery = isOnline ? current.batteryPercent : null;
    final nameStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
          fontSize: AppTypography.s14,
        );

    final widths = _headerWidthBudget(
      context,
      isOnline: isOnline,
      hasChevron: hasAnyDevice,
    );

    return ConstrainedBox(
      key: _anchorKey,
      constraints: BoxConstraints(maxWidth: widths.pillMax),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isLoading ? null : (onTap ?? () {}),
          borderRadius: BorderRadius.circular(AppRadii.r16),
          child: Container(
            height: 44,
            clipBehavior: Clip.hardEdge,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.r16),
              border: Border.all(color: AppColors.border, width: .5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(hasAnyDevice ? Icons.mic : Icons.add,
                    color: primary, size: 20),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: widths.nameMax),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: nameStyle,
                  ),
                ),
                if (isOnline || hasAnyDevice) ...[
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isOnline)
                        SizedBox(
                          width: _kHeaderBatterySlotWidth,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            switchInCurve: Curves.easeOut,
                            switchOutCurve: Curves.easeIn,
                            child: Text(
                              battery != null ? '$battery%' : '--',
                              key: ValueKey<int?>(battery),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: AppColors.textSecondary,
                                    fontWeight: FontWeight.w500,
                                    fontSize: AppTypography.s12,
                                  ),
                            ),
                          ),
                        ),
                      if (isOnline && hasAnyDevice) const SizedBox(width: 4),
                      if (hasAnyDevice)
                        InkWell(
                          onTap: () => _openMenu(context),
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(Icons.keyboard_arrow_down,
                                color: AppColors.textSecondary, size: 20),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onTapHeader(
      BuildContext context, List<Device> devices, String? currentId) async {
    if (devices.isEmpty) {
      if (!await ensureBluetoothReadyForConnect(context)) return;
      if (!context.mounted) return;
      await DeviceConnectSheet.show(context);
      return;
    }
    // Requirement: tapping the device name/icon opens the device list popup.
    await _openMenu(context);
  }

  Future<void> _openMenu(BuildContext context) async {
    final devicesAsync = ref.read(devicesListProvider);
    final deviceState = ref.read(deviceControllerProvider);
    final currentId = deviceState.connection?.device.remoteId.toString();

    final devices = await devicesAsync.when(
      data: (d) async => d,
      loading: () async => const <Device>[],
      error: (_, __) async => const <Device>[],
    );
    if (!context.mounted) return;
    if (devices.isEmpty) {
      if (!await ensureBluetoothReadyForConnect(context)) return;
      if (!context.mounted) return;
      await DeviceConnectSheet.show(context);
      return;
    }

    final anchorCtx = _anchorKey.currentContext;
    if (anchorCtx == null) return;
    final box = anchorCtx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;

    // Snapshot the navigator *before* showMenu. The PopupMenuItem callbacks
    // capture this State's [context], and if the user navigates away (or the
    // shell rebuilds) while the menu is open, calling `Navigator.of(context)`
    // from the tap handler walks an inactive Element whose `state` is null,
    // triggering "Null check operator used on a null value" in
    // StatefulElement.state. Using a captured NavigatorState avoids the walk.
    final navigator = Navigator.of(context);

    void popMenu(String value) {
      if (!navigator.mounted) return;
      navigator.pop(value);
    }

    final selected = await showMenu<String>(
      context: context,
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.r16)),
      position: RelativeRect.fromLTRB(
        // Keep the original placement: right under the header.
        pos.dx,
        pos.dy + size.height + 8,
        16,
        0,
      ),
      items: [
        for (final d in devices)
          PopupMenuItem<String>(
            enabled:
                false, // handle taps inside to support "arrow enters details"
            child: _DeviceMenuRow(
              device: d,
              isCurrent: d.id == currentId,
              isOnline: isDeviceEffectivelyOnline(d, deviceState),
              // On row tap:
              // - If current "connected and online" device => go to details
              // - Other devices (including offline current device) => trigger reconnect/switch logic
              onSelect: () {
                if (d.id == currentId &&
                    isDeviceEffectivelyOnline(d, deviceState)) {
                  popMenu('$_kDetailsPrefix${d.id}');
                } else {
                  popMenu('$_kSelectPrefix${d.id}');
                }
              },
              onDetails: () => popMenu('$_kDetailsPrefix${d.id}'),
            ),
          ),
        PopupMenuItem<String>(
          enabled: false,
          height: 8,
          child: const Divider(
            height: 1,
            thickness: .5,
            color: AppColors.border,
          ),
        ),
        const PopupMenuItem<String>(
          value: _kAddValue,
          child: _AddDeviceMenuRow(),
        ),
      ],
    );

    if (!context.mounted || selected == null) return;
    if (selected == _kAddValue) {
      if (!await ensureBluetoothReadyForConnect(context)) return;
      if (!context.mounted) return;
      await DeviceConnectSheet.show(context);
      return;
    }
    if (selected.startsWith(_kDetailsPrefix)) {
      final id = selected.substring(_kDetailsPrefix.length);
      context.push('/device/$id');
      return;
    }

    if (selected.startsWith(_kSelectPrefix)) {
      final id = selected.substring(_kSelectPrefix.length);
      final target = devices.firstWhere((d) => d.id == id);
      if (!await ensureBluetoothReadyForConnect(context)) return;
      if (!context.mounted) return;
      await _switchDevice(context, target);
      return;
    }
  }

  Future<void> _showConnectionFailedFeedback(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final st = ref.read(deviceControllerProvider);
    if (l10n.isIosBluetoothForgetDeviceError(st.errorCode)) {
      final goSettings = await AppDialogs.showConfirm(
        context,
        title: l10n.connectionFailedIosForgetTitle,
        message: l10n.transferOrConnectionError(st.errorCode),
        cancelText: l10n.cancel,
        confirmText: l10n.forgetDeviceInSettingsAction,
      );
      if (goSettings) {
        await openSystemBluetoothSettings();
      }
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.connectionFailedScanAndAdd),
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
        backgroundColor: Theme.of(context).colorScheme.error,
        action: SnackBarAction(
          label: l10n.addDevice,
          textColor: Colors.white,
          onPressed: () => DeviceConnectSheet.show(context),
        ),
      ),
    );
  }

  Future<void> _switchDevice(BuildContext context, Device target) async {
    final ctrl = ref.read(deviceControllerProvider.notifier);

    // Fast-switch path: when the target already lives in the controller's
    // background pool, `connectById` just promotes it (no GATT round-trip,
    // typical latency <200ms). Skip the "Connecting to ..." snackbar in that
    // case — flashing one would make the swap feel slow / glitchy.
    final isWarmSwitch = ctrl.isLinked(target.id);

    if (!isWarmSwitch && context.mounted) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.connectingTo(target.name)),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    // Fast path: direct connect by remoteId, no scan. `connectById` internally
    // demotes the previously active device to the background pool (so the
    // previous device stays online and is itself a warm switch target). Typical
    // latency: ~150ms when the target was warm, ~1-3s on a fresh direct-connect.
    final directOk =
        await ctrl.connectById(target.id, displayName: target.name);
    if (directOk) {
      if (context.mounted && !isWarmSwitch) {
        // For fresh connects we still surface the "Connected to ..." feedback;
        // for warm switches the dropdown already updated, no toast needed.
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.connectedTo(target.name)),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
      return;
    }

    // Bond/key mismatch is not fixed by rescan — guide the user to Forget.
    if (context.mounted) {
      final st = ref.read(deviceControllerProvider);
      final l10n = AppLocalizations.of(context)!;
      if (l10n.isIosBluetoothForgetDeviceError(st.errorCode)) {
        await _showConnectionFailedFeedback(context);
        return;
      }
    }

    // Fallback: scan, then connect via the discovered ScanResult. Triggered
    // when direct connect fails — device out of range, bond lost, or the
    // platform requires a fresh advertisement.
    if (!context.mounted) return;
    await ctrl.startScan(timeout: const Duration(seconds: 12));
    ScanResult? found;
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      final s = ref.read(deviceControllerProvider);
      found = s.results
          .where((r) => r.device.remoteId.toString() == target.id)
          .firstOrNull;
      if (found != null) break;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    final newState = ref.read(deviceControllerProvider);
    found ??= newState.results
        .where((r) => r.device.remoteId.toString() == target.id)
        .firstOrNull;

    if (found != null) {
      await ctrl.connect(found);
      final finalState = ref.read(deviceControllerProvider);
      if (finalState.connection != null) {
        if (context.mounted) {
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.connectedTo(target.name)),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
      } else {
        if (context.mounted) {
          await _showConnectionFailedFeedback(context);
        }
      }
    } else {
      if (context.mounted) {
        await _showConnectionFailedFeedback(context);
      }
    }
  }
}

class _DeviceMenuRow extends StatelessWidget {
  final Device device;
  final bool isCurrent;
  final bool isOnline;
  final VoidCallback onSelect;
  final VoidCallback onDetails;

  const _DeviceMenuRow({
    required this.device,
    required this.isCurrent,
    required this.isOnline,
    required this.onSelect,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 320,
      child: InkWell(
        onTap: onSelect, // whole row selects/switches
        borderRadius: BorderRadius.circular(AppRadii.r12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surfaceSubtle,
                  borderRadius: BorderRadius.circular(AppRadii.r12),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Icon(Icons.mic, color: primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _ellipsisDeviceName(
                            device.name,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  fontSize: AppTypography.s14,
                                  color: AppColors.textPrimary,
                                ),
                          ),
                        ),
                        if (isOnline)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: primary.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(AppRadii.r6),
                            ),
                            child: Text(
                              l10n.online,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: primary,
                                    // fontWeight: FontWeight.w00,
                                    fontSize: AppTypography.s12,
                                    letterSpacing: 0.8,
                                  ),
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceMuted,
                              borderRadius: BorderRadius.circular(AppRadii.r6),
                            ),
                            child: Text(
                              l10n.offline,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: AppColors.textTertiary,
                                    // fontWeight: FontWeight.w600,
                                    fontSize: AppTypography.s12,
                                    letterSpacing: 0.8,
                                  ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        // Only show battery when online; do not show cached battery for offline device.
                        if (isOnline && device.batteryPercent != null) ...[
                          Icon(Icons.battery_full,
                              size: 14, color: primary.withValues(alpha: 0.9)),
                          const SizedBox(width: 4),
                          Text(
                            '${device.batteryPercent}%',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: AppColors.textSecondary,
                                    fontSize: AppTypography.s12),
                          ),
                        ] else ...[
                          const SizedBox(width: 0, height: 0),
                        ],
                        if (!isOnline && device.lastSeen != null) ...[
                          const SizedBox(width: 10),
                          Text(
                            l10n.lastSeenLabel(
                                _DeviceListItem.formatLastSeenLocalized(
                                    l10n, device.lastSeen!)),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                    color: AppColors.textTertiary,
                                    fontSize: AppTypography.s12),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Arrow tap enters details page.
              InkWell(
                onTap: onDetails,
                borderRadius: BorderRadius.circular(AppRadii.pill),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: const Icon(Icons.chevron_right,
                      color: AppColors.textTertiary, size: 28),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddDeviceMenuRow extends StatelessWidget {
  const _AddDeviceMenuRow();

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 320,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, color: primary),
            const SizedBox(width: 8),
            Text(
              AppLocalizations.of(context)!.addDevice,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                  fontSize: AppTypography.s14),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceListItem extends StatelessWidget {
  final Device device;
  final bool isCurrent;
  final VoidCallback onTap;

  const _DeviceListItem({
    required this.device,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    final isOnline = device.isOnline;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Stack(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSubtle,
                    borderRadius: BorderRadius.circular(AppRadii.r12),
                    border: Border.all(color: AppColors.borderLight),
                  ),
                  child: Icon(Icons.mic, color: primary, size: 22),
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _ellipsisDeviceName(
                          device.name,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                        ),
                      ),
                      if (isCurrent)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(AppRadii.r4),
                          ),
                          child: Text(
                            l10n.currentLabel,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: primary,
                                  fontWeight: FontWeight.w500,
                                  fontSize: AppTypography.s14,
                                  letterSpacing: 0.5,
                                ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isOnline
                              ? primary.withValues(alpha: 0.1)
                              : AppColors.surfaceMuted,
                          borderRadius: BorderRadius.circular(AppRadii.r4),
                        ),
                        child: Text(
                          isOnline ? l10n.online : l10n.offline,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: isOnline
                                        ? primary
                                        : AppColors.textSecondary,
                                    // fontWeight: FontWeight.w500,
                                    fontSize: AppTypography.s12,
                                    letterSpacing: 1,
                                  ),
                        ),
                      ),
                      // Only show battery when device online; do not show cached battery when offline.
                      if (isOnline && device.batteryPercent != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${device.batteryPercent}%',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.textSecondary,
                                    fontSize: AppTypography.s12,
                                  ),
                        ),
                      ],
                      if (!isOnline && device.lastSeen != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          l10n.lastSeenLabel(
                              _formatLastSeen(l10n, device.lastSeen!)),
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.textTertiary,
                                    fontSize: AppTypography.s12,
                                  ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right,
                color: AppColors.textTertiary, size: 28),
          ],
        ),
      ),
    );
  }

  String _formatLastSeen(AppLocalizations l10n, DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);
    if (diff.inDays > 0) return l10n.lastSeenDaysAgo(diff.inDays);
    if (diff.inHours > 0) return l10n.lastSeenHoursAgo(diff.inHours);
    if (diff.inMinutes > 0) return l10n.lastSeenMinutesAgo(diff.inMinutes);
    return l10n.lastSeenJustNow;
  }

  static String formatLastSeenLocalized(
      AppLocalizations l10n, DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);
    if (diff.inDays > 0) return l10n.lastSeenDaysAgo(diff.inDays);
    if (diff.inHours > 0) return l10n.lastSeenHoursAgo(diff.inHours);
    if (diff.inMinutes > 0) return l10n.lastSeenMinutesAgo(diff.inMinutes);
    return l10n.lastSeenJustNow;
  }
}

/// Fixed slot for battery text (e.g. "100%"), sits next to the chevron.
const double _kHeaderBatterySlotWidth = 34;

/// Horizontal decoration border on the header pill (width 0.5 each side).
const double _kHeaderBorderTotalWidth = 1;

class _HeaderWidthBudget {
  const _HeaderWidthBudget({required this.pillMax, required this.nameMax});

  /// Max width of the whole pill; short names shrink below this.
  final double pillMax;
  final double nameMax;
}

/// Short names use intrinsic width; long names cap at half screen minus chrome.
_HeaderWidthBudget _headerWidthBudget(
  BuildContext context, {
  required bool isOnline,
  required bool hasChevron,
}) {
  final screenW = MediaQuery.sizeOf(context).width;
  final chrome = _headerNonNameWidth(
    isOnline: isOnline,
    hasChevron: hasChevron,
  );
  final pillMax = screenW * 0.5;
  final nameMax = math.max(
    0.0,
    pillMax - chrome - _kHeaderBorderTotalWidth,
  );
  return _HeaderWidthBudget(pillMax: pillMax, nameMax: nameMax);
}

/// Total pill width budget including horizontal padding and chrome.
double _headerNonNameWidth({
  required bool isOnline,
  required bool hasChevron,
}) {
  return 24 + _headerInnerChromeWidth(isOnline: isOnline, hasChevron: hasChevron);
}

/// Chrome inside horizontal padding (icon, gap, trailing: battery + chevron).
double _headerInnerChromeWidth({
  required bool isOnline,
  bool hasChevron = false,
}) {
  var w = 20.0 + 8; // mic icon + gap before name
  if (isOnline || hasChevron) w += 8; // gap before trailing cluster
  if (isOnline) w += _kHeaderBatterySlotWidth;
  if (isOnline && hasChevron) w += 4; // battery beside chevron
  if (hasChevron) w += 24; // chevron tap target
  return w;
}

/// Single-line device display name used in device list rows.
Widget _ellipsisDeviceName(String name, {TextStyle? style}) {
  return Text(
    name,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: style,
  );
}

// Helper extension
extension ListExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
