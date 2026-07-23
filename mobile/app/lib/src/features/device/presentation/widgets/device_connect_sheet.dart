import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../core/log/app_log.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../data/device_repository.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_pill_button.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_dialogs.dart';
import '../../../settings/data/permissions_provider.dart';
import '../bluetooth_connect_gate.dart';
import '../device_controller.dart';
import '../../../../app/theme/app_typography.dart';

/// Public, reusable bottom-sheet for:
/// - scanning nearby devices
/// - connecting
/// - success / failure result screens
///
/// This matches the "market style" modal flow from your screenshots.
class DeviceConnectSheet extends ConsumerStatefulWidget {
  const DeviceConnectSheet({super.key});

  /// Request Bluetooth permission first, then open sheet and auto-scan. Avoid "user must tap scan after granting permission".
  static Future<bool> show(BuildContext context) async {
    if (!await ensureBluetoothReadyForConnect(context)) return false;
    if (!context.mounted) return false;
    final result = await showAppBottomSheet<bool>(
      context,
      useRootNavigator: true,
      builder: (_) => const DeviceConnectSheet(),
    );
    return result ?? false;
  }

  @override
  ConsumerState<DeviceConnectSheet> createState() => _DeviceConnectSheetState();
}

enum _SheetMode { scan, connecting, success, failure, help }

/// Get saved device name by device ID (for connect/success page display, overrides BLE advertised name).
final _savedDeviceNameProvider =
    FutureProvider.family<String?, String>((ref, deviceId) async {
  if (deviceId.isEmpty) return null;
  final repo = await ref.watch(deviceRepositoryProvider.future);
  final device = await repo.getById(deviceId);
  return device?.name;
});

class _DeviceConnectSheetState extends ConsumerState<DeviceConnectSheet>
    with WidgetsBindingObserver {
  _SheetMode _mode = _SheetMode.scan;
  ScanResult? _selected;
  String? _failureMsg;
  String? _failureErrorCode;
  AppLifecycleState? _lastLifecycleState;
  /// Prevents double-tap connect / overlapping connect attempts.
  bool _connectInFlight = false;

  /// Show the location advisory at most once per sheet opening, so lifecycle
  /// resumes / adapter-on auto-rescans don't nag the user repeatedly.
  bool _locationAdvised = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // iOS: delay 300ms after sheet open before scan so view is stable; first-time permission dialog may appear meanwhile.
    final delay =
        Platform.isIOS ? const Duration(milliseconds: 300) : Duration.zero;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (delay > Duration.zero) {
        Future.delayed(delay, () {
          if (mounted) unawaited(_ensureScan());
        });
      } else {
        unawaited(_ensureScan());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When returning from inactive (e.g. permission dialog) to resumed, if on scan page and not scanning, auto-retry.
    final prev = _lastLifecycleState;
    _lastLifecycleState = state;
    if (prev == AppLifecycleState.inactive &&
        state == AppLifecycleState.resumed &&
        mounted &&
        _mode == _SheetMode.scan) {
      final st = ref.read(deviceControllerProvider);
      if (!isBluetoothAdapterDisabled(st.adapterState) && !st.isScanning) {
        AppLog.i('DeviceConnectSheet: resumed from inactive, auto-retry scan');
        unawaited(_ensureScan());
      }
    }
  }

  Future<void> _ensureScan() async {
    final client = ref.read(bleClientProvider);
    final adapter = await client.getCurrentAdapterState();
    if (!mounted) return;
    if (isBluetoothAdapterDisabled(adapter)) return;
    final ctrl = ref.read(deviceControllerProvider.notifier);
    final st = ref.read(deviceControllerProvider);
    if (!st.isScanning) {
      await ctrl.startScan();
    }
  }

  /// After an empty scan, explain (once) if location is the likely blocker and
  /// offer a one-tap fix, then rescan. No-op on iOS or when devices were found.
  Future<void> _maybeAdviseLocation() async {
    if (_locationAdvised || !mounted || _mode != _SheetMode.scan) return;
    if (!Platform.isAndroid) return;

    final st = ref.read(deviceControllerProvider);
    if (isBluetoothAdapterDisabled(st.adapterState)) return;
    if (st.results.any(_isClipNamedDevice)) return; // found a device, all good

    final issue = await diagnoseScanLocationIssue();
    if (issue == ScanLocationIssue.none || !mounted) return;
    _locationAdvised = true;

    final l10n = AppLocalizations.of(context)!;
    final message = issue == ScanLocationIssue.serviceOff
        ? l10n.scanLocationServiceOffMessage
        : l10n.scanLocationPermissionMessage;

    final proceed = await AppDialogs.showConfirm(
      context,
      title: l10n.scanLocationRequiredTitle,
      message: message,
      cancelText: l10n.cancel,
      confirmText: l10n.openSettingsAction,
    );
    if (!proceed || !mounted) return;

    if (issue == ScanLocationIssue.serviceOff) {
      await openLocationServiceSettings();
    } else {
      final granted = await requestScanLocationPermission();
      if (granted && mounted && _mode == _SheetMode.scan) {
        unawaited(ref.read(deviceControllerProvider.notifier).rescan());
      }
    }
  }

  Future<void> _requestBluetoothOn() async {
    if (!Platform.isAndroid) return;
    try {
      await ref.read(bleClientProvider).turnOnAdapter();
    } catch (e, st) {
      AppLog.w('DeviceConnectSheet: turnOnAdapter failed', e, st);
    }
  }

  Future<void> _connect(ScanResult r) async {
    if (_connectInFlight || _mode == _SheetMode.connecting) return;
    _connectInFlight = true;
    setState(() {
      _mode = _SheetMode.connecting;
      _selected = r;
      _failureMsg = null;
      _failureErrorCode = null;
    });

    try {
      final ctrl = ref.read(deviceControllerProvider.notifier);
      await ctrl.connect(r);
      if (!mounted) return;

      final st = ref.read(deviceControllerProvider);
      if (st.connection != null) {
        setState(() => _mode = _SheetMode.success);
        // UX requirement: stay on success page until user taps "Start Using".
      } else {
        final l10n = AppLocalizations.of(context)!;
        setState(() {
          _mode = _SheetMode.failure;
          _failureErrorCode = st.errorCode;
          _failureMsg = l10n.transferOrConnectionError(
            st.errorCode,
            st.error ?? l10n.connectionFailedTryAgain,
          );
        });
      }
    } finally {
      _connectInFlight = false;
    }
  }

  void _retry() {
    if (_connectInFlight) return;
    setState(() {
      _mode = _SheetMode.scan;
      _failureMsg = null;
      _failureErrorCode = null;
      _selected = null;
    });
    unawaited(_ensureScan());
  }

  /// Prefer saved device name (user custom or last connected name), otherwise BLE advertised name.
  String _getCurrentDeviceName(BuildContext context, String? savedName) {
    final defaultName = AppLocalizations.of(context)!.defaultDeviceName;
    if (_selected != null) {
      if (savedName != null && savedName.trim().isNotEmpty) {
        return savedName.trim();
      }
      return _deviceName(_selected, defaultName);
    }
    return defaultName;
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(deviceControllerProvider);

    ref.listen(
      deviceControllerProvider.select((s) => s.adapterState),
      (prev, next) {
        if (!mounted || _mode != _SheetMode.scan) return;
        if (prev != next &&
            next == BluetoothAdapterState.on &&
            !ref.read(deviceControllerProvider).isScanning) {
          unawaited(_ensureScan());
        }
      },
    );

    // When a scan cycle finishes (isScanning true -> false) with no Clip device
    // found, check whether location (permission / system switch) is the likely
    // cause and guide the user. Only fires on empty results, so successful
    // scans (incl. stock Android 12+) are never interrupted.
    ref.listen(
      deviceControllerProvider.select((s) => s.isScanning),
      (prev, next) {
        if (prev == true && next == false) {
          unawaited(_maybeAdviseLocation());
        }
      },
    );

    // Content is inside an outer container (topGap + maxHeight) controlled by show().
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 18),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _buildContent(context, st),
      ),
    );
  }

  Widget _buildContent(BuildContext context, DeviceUiState st) {
    switch (_mode) {
      case _SheetMode.scan:
        // Only show devices whose advertised name contains "Clip".
        final filteredResults = st.results.where((r) {
          return _isClipNamedDevice(r);
        }).toList();

        final bluetoothDisabled = isBluetoothAdapterDisabled(st.adapterState);

        return _ScanView(
          key: const ValueKey('scan'),
          isScanning: st.isScanning,
          bluetoothDisabled: bluetoothDisabled,
          results: bluetoothDisabled ? const [] : filteredResults,
          onCancel: () => Navigator.of(context).pop(false),
          onCantFindDevice: () {
            setState(() => _mode = _SheetMode.help);
          },
          onConnect: (r) => _connect(r),
          onRescan: () {
            final ctrl = ref.read(deviceControllerProvider.notifier);
            if (bluetoothDisabled) {
              unawaited(_requestBluetoothOn());
              return;
            }
            unawaited(ctrl.rescan());
          },
          onTurnOnBluetooth:
              Platform.isAndroid ? () => _requestBluetoothOn() : null,
        );
      case _SheetMode.connecting:
        {
          final deviceId = _selected?.device.remoteId.toString() ?? '';
          final savedName =
              ref.watch(_savedDeviceNameProvider(deviceId)).valueOrNull;
          final l10n = AppLocalizations.of(context)!;
          return _ConnectingView(
            key: const ValueKey('connecting'),
            deviceName: _getCurrentDeviceName(context, savedName),
            // Android may show a system pairing-code dialog during bond; tip
            // shown for the whole connect so it is visible before state flips.
            statusHint:
                Platform.isAndroid ? l10n.androidPairingConfirmHint : null,
            onCancel: () => Navigator.of(context).pop(false),
          );
        }
      case _SheetMode.success:
        {
          final deviceId = _selected?.device.remoteId.toString() ?? '';
          final savedName =
              ref.watch(_savedDeviceNameProvider(deviceId)).valueOrNull;
          return _SuccessView(
            key: const ValueKey('success'),
            deviceName: _getCurrentDeviceName(context, savedName),
            onStartUsing: () => Navigator.of(context).pop(true),
          );
        }
      case _SheetMode.failure:
        final l10n = AppLocalizations.of(context)!;
        final needsForget =
            l10n.isIosBluetoothForgetDeviceError(_failureErrorCode);
        return _FailureView(
          key: const ValueKey('failure'),
          message: _failureMsg ?? l10n.connectionFailed,
          showUnpairHint: !needsForget,
          onRetry: _retry,
          onOpenSettings: needsForget
              ? () => unawaited(openSystemBluetoothSettings())
              : null,
        );
      case _SheetMode.help:
        return _SetupHelpView(
          key: const ValueKey('help'),
          onTryAgain: () {
            setState(() => _mode = _SheetMode.scan);
            unawaited(_ensureScan());
          },
        );
    }
  }
}

String _deviceName(ScanResult? r, String defaultName) {
  if (r == null) return defaultName;
  final platformName = r.device.platformName.trim();
  final advName = r.advertisementData.advName.trim();
  final effectiveName = platformName.isNotEmpty ? platformName : advName;
  return effectiveName.isNotEmpty ? effectiveName : defaultName;
}

bool _isClipNamedDevice(ScanResult r) {
  final platformName = r.device.platformName.trim();
  final advName = r.advertisementData.advName.trim();
  final effectiveName = platformName.isNotEmpty ? platformName : advName;
  return effectiveName.toLowerCase().contains('clip');
}

String _fakeSn(ScanResult r) {
  // Demo SN style: RSP-2026-xxxx
  final id = r.device.remoteId.toString();
  final hex = id.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  final padded = hex.padLeft(4, '0');
  final start = mathMax(0, padded.length - 4);
  final last4 = padded.substring(start);
  return 'RSP-2026-$last4';
}

int mathMax(int a, int b) => a > b ? a : b;

class _SearchingRippleIcon extends StatefulWidget {
  final Color primary;
  final bool isScanning;
  const _SearchingRippleIcon({required this.primary, required this.isScanning});

  @override
  State<_SearchingRippleIcon> createState() => _SearchingRippleIconState();
}

class _SearchingRippleIconState extends State<_SearchingRippleIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.isScanning) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _SearchingRippleIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isScanning && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isScanning && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static Widget _buildCore(double coreSize, Color primary) {
    return Container(
      width: coreSize,
      height: coreSize,
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(coreSize / 2),
      ),
      child: Center(
        child: Container(
          width: 44,
          height: 74,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Center(
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const coreSize = 92.0;
    const canvasSize = 160.0;

    if (!widget.isScanning) {
      return SizedBox(
        width: canvasSize,
        height: canvasSize,
        child: Center(child: _buildCore(coreSize, widget.primary)),
      );
    }

    Widget wave(double phase) {
      final t = (_controller.value + phase) % 1.0;
      final scale = 1.0 + (t * 1.25); // 1.0 -> 2.25
      final alpha = ((1.0 - t) * 0.22).clamp(0.0, 0.22);
      return Transform.scale(
        scale: scale,
        child: SizedBox(
          width: coreSize,
          height: coreSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.primary.withValues(alpha: alpha * 0.35),
              border: Border.all(
                color: widget.primary.withValues(alpha: alpha),
                width: 2,
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: canvasSize,
      height: canvasSize,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              wave(0.00),
              wave(0.33),
              wave(0.66),
              _buildCore(coreSize, widget.primary),
            ],
          );
        },
      ),
    );
  }
}

class _ScanView extends StatelessWidget {
  final bool isScanning;
  final bool bluetoothDisabled;
  final List<ScanResult> results;
  final VoidCallback onCancel;
  final VoidCallback onCantFindDevice;
  final Future<void> Function(ScanResult) onConnect;
  final VoidCallback onRescan;
  final VoidCallback? onTurnOnBluetooth;

  const _ScanView({
    super.key,
    required this.isScanning,
    required this.bluetoothDisabled,
    required this.results,
    required this.onCancel,
    required this.onCantFindDevice,
    required this.onConnect,
    required this.onRescan,
    this.onTurnOnBluetooth,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    final listCount = results.length.clamp(0, 20);
    final hasAny = listCount > 0;
    // Rough sizing so sheet height follows content (but never gets too tall).
    final rowExtent = 86.0; // approx per item (card + spacing)
    // Cap list at 260 so a long device list doesn't crowd the rest of the
    // sheet on small phones; ListView inside is itself scrollable.
    final desiredListHeight =
        hasAny ? (listCount * rowExtent).clamp(86.0, 260.0) : 0.0;
    // Account for gesture nav bar / home indicator: the sheet uses
    // SafeArea(bottom: false) intentionally so the background extends behind
    // the system inset, but we still need to keep our content above it.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return SingleChildScrollView(
      key: const ValueKey('scan'),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (bluetoothDisabled) ...[
            const Icon(Icons.bluetooth_disabled,
                size: 96, color: AppColors.gray200),
            const SizedBox(height: 28),
            Text(
              l10n.bluetoothDisabledTitle,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              l10n.bluetoothDisabledHint,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            if (onTurnOnBluetooth != null) ...[
              const SizedBox(height: 28),
              AppBlackPillButton(
                label: l10n.turnOnBluetooth,
                onPressed: onTurnOnBluetooth,
              ),
            ],
            const SizedBox(height: 32),
          ] else ...[
            // Hero icon: show ripple animation only when scanning
            _SearchingRippleIcon(primary: primary, isScanning: isScanning),
            const SizedBox(height: 32),
            Text(
              l10n.searchingForDevices,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.ensureDeviceOn,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
          ],

          if (!bluetoothDisabled)
          Row(
            children: [
              Text(
                l10n.devicesFound,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500,
                  fontSize: AppTypography.s12,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onRescan,
                borderRadius: BorderRadius.circular(AppRadii.pill),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      if (isScanning)
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.4, color: primary),
                        )
                      else
                        Icon(Icons.refresh, color: primary, size: 18),
                      const SizedBox(width: 10),
                      Text(
                        isScanning ? l10n.scanningChip : l10n.rescan,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              // letterSpacing: 1.5,
                              color: primary,
                              fontWeight: FontWeight.w500,
                              fontSize: AppTypography.s14,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (!bluetoothDisabled) const SizedBox(height: 10),

          if (!bluetoothDisabled && !hasAny) ...[
            const SizedBox(height: 24),
            // const Text('No devices found yet.', style: TextStyle(color: AppColors.textTertiary, fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
            const SizedBox(height: 18),
          ] else if (!bluetoothDisabled) ...[
            SizedBox(
              height: desiredListHeight,
              child: ListView.separated(
                padding: const EdgeInsets.only(top: 10, bottom: 24),
                itemCount: listCount,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final r = results[index];
                  return _DeviceRowWithSavedName(
                    result: r,
                    defaultName: l10n.defaultDeviceName,
                    primary: primary,
                    snLabel: l10n.snLabel,
                    onConnect: () => onConnect(r),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          if (!bluetoothDisabled)
            TextButton.icon(
              onPressed: onCantFindDevice,
              icon: Icon(Icons.help_outline,
                  size: 18, color: AppColors.textSecondary),
              label: Text(
                l10n.canNotFindDevice,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s14,
                      color: AppColors.textSecondary,
                    ),
              ),
            ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: Center(
              child: TextButton(
                onPressed: onCancel,
                child: Text(
                  l10n.cancel,
                  style: TextStyle(
                      fontSize: AppTypography.s14,
                      color: AppColors.textTertiary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupHelpView extends StatelessWidget {
  final VoidCallback onTryAgain;
  const _SetupHelpView({super.key, required this.onTryAgain});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;

    Widget stepChip(String text) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: primary,
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s12,
                letterSpacing: 1.2,
              ),
        ),
      );
    }

    Widget card({
      required IconData icon,
      required Widget title,
      Widget? subtitle,
      Widget? trailing,
    }) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(AppRadii.r18),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(AppRadii.r14),
              ),
              child: Icon(icon, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  if (subtitle != null) ...[
                    const SizedBox(height: 6),
                    subtitle,
                  ],
                  if (trailing != null) ...[
                    const SizedBox(height: 10),
                    trailing,
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      key: const ValueKey('help'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Text(
          l10n.setupHelp,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 18),
        stepChip(l10n.step1),
        const SizedBox(height: 10),
        card(
          icon: Icons.wb_sunny_outlined,
          title: Text(
            l10n.longPressRecording,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
          ),
          subtitle: Text(
            l10n.notLightingUpHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic,
                ),
          ),
        ),
        const SizedBox(height: 18),
        stepChip(l10n.step2),
        const SizedBox(height: 10),
        card(
          icon: Icons.phone_iphone,
          title: Text(
            l10n.bringDeviceClose,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
          ),
          trailing: Row(
            children: [
              Icon(Icons.bolt, size: 16, color: primary),
              const SizedBox(width: 6),
              Text(
                l10n.keepWithinMeters,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: primary,
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s12,
                      letterSpacing: 1.1,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(AppRadii.r18),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Row(
            children: [
              Icon(Icons.mail_outline, color: primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.needMoreHelp,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                'support@seeed.cc',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Colors.blue,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        AppBlackPillButton(
          label: l10n.gotItTryAgain,
          onPressed: onTryAgain,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Device row: show saved name first, otherwise BLE advertised name.
class _DeviceRowWithSavedName extends ConsumerWidget {
  final ScanResult result;
  final String defaultName;
  final Color primary;
  final String snLabel;
  final VoidCallback onConnect;

  const _DeviceRowWithSavedName({
    required this.result,
    required this.defaultName,
    required this.primary,
    required this.snLabel,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deviceId = result.device.remoteId.toString();
    final savedName = ref.watch(_savedDeviceNameProvider(deviceId)).valueOrNull;
    final name = (savedName != null && savedName.trim().isNotEmpty)
        ? savedName.trim()
        : _deviceName(result, defaultName);
    return _DeviceRow(
      name: name,
      sn: _fakeSn(result),
      primary: primary,
      snLabel: snLabel,
      onConnect: onConnect,
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final String name;
  final String sn;
  final Color primary;
  final String snLabel;
  final VoidCallback onConnect;

  const _DeviceRow({
    required this.name,
    required this.sn,
    required this.primary,
    required this.snLabel,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      borderRadius: BorderRadius.circular(AppRadii.r18),
      backgroundColor: AppColors.surfaceSubtle,
      borderColor: AppColors.borderLight,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.r14),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Icon(Icons.mic_none, color: primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontSize: AppTypography.s16,
                      ),
                ),
                const SizedBox(height: 4),
                Text('$snLabel :  $sn',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textTertiary,
                        fontSize: AppTypography.s12)),
              ],
            ),
          ),
          SizedBox(
            width: 110,
            height: 48,
            child: AppPrimaryPillButton(
              label: AppLocalizations.of(context)!.connect,
              onPressed: onConnect,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectingView extends StatelessWidget {
  final String deviceName;
  final String? statusHint;
  final VoidCallback onCancel;

  const _ConnectingView({
    super.key,
    required this.deviceName,
    this.statusHint,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final hint = statusHint?.trim();
    return IntrinsicHeight(
      child: Column(
        key: const ValueKey('connecting'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          SizedBox(
            width: 110,
            height: 110,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(55),
                  ),
                ),
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Center(
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                          color: primary,
                          borderRadius: BorderRadius.circular(999)),
                    ),
                  ),
                ),
                SizedBox(
                  width: 110,
                  height: 110,
                  child:
                      CircularProgressIndicator(color: primary, strokeWidth: 3),
                ),
              ],
            ),
          ),
          const SizedBox(height: 48),
          Text(
            AppLocalizations.of(context)!.connecting,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            deviceName,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textSecondary),
          ),
          if (hint != null && hint.isNotEmpty) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.35,
                    ),
              ),
            ),
          ],
          const SizedBox(height: 40), // Fixed spacing instead of Spacer
          Padding(
            padding: const EdgeInsets.only(bottom: 32),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onCancel,
                child: Text(
                  AppLocalizations.of(context)!.cancel,
                  style: TextStyle(
                      fontSize: AppTypography.s14,
                      color: AppColors.textSecondary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  final String deviceName;
  final VoidCallback onStartUsing;

  const _SuccessView(
      {super.key, required this.deviceName, required this.onStartUsing});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return IntrinsicHeight(
      child: Column(
        key: const ValueKey('success'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(60),
                  ),
                ),
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: BorderRadius.circular(37),
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 40),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Text(
            AppLocalizations.of(context)!.connectedSuccessfully,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surfaceSubtle,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mic, color: primary, size: 18),
                const SizedBox(width: 10),
                Text(deviceName,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(height: 64), // Fixed spacing instead of Spacer
          AppBlackPillButton(
            label: AppLocalizations.of(context)!.startUsing,
            onPressed: onStartUsing,
          ),
          const SizedBox(height: 32), // Bottom padding
        ],
      ),
    );
  }
}

class _FailureView extends StatelessWidget {
  final String message;
  final bool showUnpairHint;
  final VoidCallback onRetry;
  final VoidCallback? onOpenSettings;

  const _FailureView({
    super.key,
    required this.message,
    required this.onRetry,
    this.showUnpairHint = true,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    const danger = AppColors.danger;
    final l10n = AppLocalizations.of(context)!;
    return IntrinsicHeight(
      child: Column(
        key: const ValueKey('failure'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(60),
                  ),
                ),
                Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    color: danger,
                    borderRadius: BorderRadius.circular(37),
                  ),
                  child: const Icon(Icons.error_outline,
                      color: Colors.white, size: 40),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Text(
            l10n.connectionFailed,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                ),
                if (showUnpairHint) ...[
                  const SizedBox(height: 12),
                  Text(
                    l10n.connectionFailedUnpairHint,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 40),
          if (onOpenSettings != null) ...[
            AppBlackPillButton(
              label: l10n.forgetDeviceInSettingsAction,
              onPressed: onOpenSettings,
            ),
            const SizedBox(height: 12),
            AppOutlinedPillButton(
              label: l10n.retry,
              onPressed: onRetry,
            ),
          ] else
            AppBlackPillButton(
              label: l10n.retry,
              onPressed: onRetry,
            ),
          const SizedBox(height: 32), // Bottom padding
        ],
      ),
    );
  }
}
