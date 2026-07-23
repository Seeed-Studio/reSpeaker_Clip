import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/device_repository.dart';
import 'device_controller.dart';
import 'wifi_transfer_controller.dart';

final _deviceByIdProvider = FutureProvider.family<Device?, String>((ref, id) async {
  ref.watch(deviceDbRevisionProvider);
  final repo = await ref.watch(deviceRepositoryProvider.future);
  return repo.getById(id);
});

/// WiFi transfer management page.
///
/// Flow: enable device hotspot → connect phone WiFi → download via HTTP → cleanup.
class WifiTransferPage extends ConsumerStatefulWidget {
  final String deviceId;
  final String? sessionId;
  final String? recordingId;

  const WifiTransferPage({
    super.key,
    required this.deviceId,
    this.sessionId,
    this.recordingId,
  });

  @override
  ConsumerState<WifiTransferPage> createState() => _WifiTransferPageState();
}

class _WifiTransferPageState extends ConsumerState<WifiTransferPage> {
  bool _started = false;

  bool get _isConnected {
    final state = ref.read(deviceControllerProvider);
    return state.connection?.device.remoteId.toString() == widget.deviceId;
  }

  Future<void> _startTransfer() async {
    if (_started) return;
    final sid = widget.sessionId;
    final rid = widget.recordingId;
    if (sid == null || rid == null) return;

    setState(() => _started = true);

    await ref.read(wifiTransferControllerProvider.notifier).transferSession(
      recordingId: rid,
      sessionId: sid,
    );
  }

  Future<void> _cancelTransfer() async {
    await ref.read(wifiTransferControllerProvider.notifier).cancel();
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    // Reset controller state on leave if not actively transferring.
    Future.microtask(() {
      try {
        ref.read(wifiTransferControllerProvider.notifier).reset();
      } catch (_) {}
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final asyncDevice = ref.watch(_deviceByIdProvider(widget.deviceId));
    final wifiState = ref.watch(wifiTransferControllerProvider);

    final deviceName = asyncDevice.valueOrNull?.name ?? widget.deviceId;

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        title: Text(l10n.wifiTransferTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: wifiState.isActive ? null : () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildInfoCard(deviceName, wifiState),
              const SizedBox(height: 24),
              _buildPhaseIndicator(wifiState),
              const SizedBox(height: 24),
              if (wifiState.phase == WifiTransferPhase.transferring)
                _buildProgressSection(wifiState),
              if (wifiState.error != null) _buildErrorSection(context, wifiState),
              const Spacer(),
              _buildActions(context, wifiState),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(String deviceName, WifiTransferState wifiState) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.br12,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi, color: wifiState.isActive ? AppColors.brandPrimary : AppColors.textTertiary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  deviceName,
                  style: const TextStyle(
                    fontSize: AppTypography.s16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (wifiState.hotspot != null) ...[
            const SizedBox(height: 12),
            _buildInfoRow('SSID', wifiState.hotspot!.ssid),
            const SizedBox(height: 4),
            _buildInfoRow('IP', '${wifiState.hotspot!.ip}:${wifiState.hotspot!.port}'),
          ],
          if (widget.sessionId != null) ...[
            const SizedBox(height: 4),
            _buildInfoRow('Session', widget.sessionId!),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(fontSize: AppTypography.s12, color: AppColors.textTertiary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: AppTypography.s12, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _buildPhaseIndicator(WifiTransferState wifiState) {
    final phases = [
      (WifiTransferPhase.enablingHotspot, 'Enable Hotspot', Icons.settings_input_antenna),
      (WifiTransferPhase.connectingWifi, 'Connect WiFi', Icons.wifi),
      (WifiTransferPhase.verifyingConnection, 'Verify', Icons.check_circle_outline),
      (WifiTransferPhase.transferring, 'Transfer', Icons.download),
      (WifiTransferPhase.mergingFiles, 'Merge', Icons.merge_type),
      (WifiTransferPhase.disablingHotspot, 'Cleanup', Icons.wifi_off),
    ];

    final currentIndex = phases.indexWhere((p) => p.$1 == wifiState.phase);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.br12,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Transfer Steps',
            style: TextStyle(
              fontSize: AppTypography.s14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          ...phases.asMap().entries.map((entry) {
            final idx = entry.key;
            final (phase, label, icon) = entry.value;

            Color iconColor;
            Color textColor;
            if (wifiState.phase == WifiTransferPhase.completed) {
              iconColor = AppColors.brandPrimary;
              textColor = AppColors.textSecondary;
            } else if (wifiState.phase == WifiTransferPhase.failed && idx <= currentIndex) {
              iconColor = idx == currentIndex ? AppColors.danger : AppColors.brandPrimary;
              textColor = idx == currentIndex ? AppColors.danger : AppColors.textSecondary;
            } else if (idx < currentIndex) {
              iconColor = AppColors.brandPrimary;
              textColor = AppColors.textSecondary;
            } else if (idx == currentIndex) {
              iconColor = AppColors.accentBlue;
              textColor = AppColors.textPrimary;
            } else {
              iconColor = AppColors.textTertiary;
              textColor = AppColors.textTertiary;
            }

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  if (idx == currentIndex && wifiState.isActive)
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: iconColor),
                    )
                  else
                    Icon(
                      idx < currentIndex || wifiState.phase == WifiTransferPhase.completed
                          ? Icons.check_circle
                          : icon,
                      size: 20,
                      color: iconColor,
                    ),
                  const SizedBox(width: 12),
                  Text(label, style: TextStyle(fontSize: AppTypography.s14, color: textColor)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildProgressSection(WifiTransferState wifiState) {
    final fileText = wifiState.totalFiles > 0
        ? '${wifiState.fileIndex + 1} / ${wifiState.totalFiles}'
        : '...';
    final mbReceived = (wifiState.receivedBytes / (1024 * 1024)).toStringAsFixed(1);
    final progressPercent = (wifiState.progress * 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.br12,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'File $fileText',
                style: const TextStyle(fontSize: AppTypography.s14, color: AppColors.textSecondary),
              ),
              Text(
                '$mbReceived MB · $progressPercent%',
                style: const TextStyle(fontSize: AppTypography.s14, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: wifiState.progress,
              minHeight: 6,
              backgroundColor: AppColors.surfaceMuted,
              color: AppColors.brandPrimary,
            ),
          ),
          if (wifiState.currentFile != null) ...[
            const SizedBox(height: 8),
            Text(
              wifiState.currentFile!,
              style: const TextStyle(fontSize: AppTypography.s12, color: AppColors.textTertiary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorSection(
      BuildContext context, WifiTransferState wifiState) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.danger.withOpacity(0.06),
        borderRadius: AppRadii.br12,
        border: Border.all(color: AppColors.danger.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              wifiState.error ?? l10n.errorUnknown,
              style: const TextStyle(fontSize: AppTypography.s12, color: AppColors.danger),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, WifiTransferState wifiState) {
    final l10n = AppLocalizations.of(context)!;
    if (wifiState.phase == WifiTransferPhase.completed) {
      return AppPrimaryPillButton(
        label: l10n.done,
        onPressed: () => context.pop(),
      );
    }

    if (wifiState.phase == WifiTransferPhase.failed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppPrimaryPillButton(
            label: l10n.retry,
            onPressed: () {
              ref.read(wifiTransferControllerProvider.notifier).reset();
              setState(() => _started = false);
            },
          ),
          const SizedBox(height: 12),
          AppOutlinedPillButton(
            label: l10n.guideBackLabel,
            onPressed: () => context.pop(),
          ),
        ],
      );
    }

    if (wifiState.isActive) {
      return AppOutlinedPillButton(
        label: l10n.cancel,
        foregroundColor: AppColors.danger,
        borderColor: AppColors.danger.withOpacity(0.3),
        onPressed: _cancelTransfer,
      );
    }

    // Idle: show start button.
    final canStart = _isConnected && widget.sessionId != null && widget.recordingId != null;
    return AppPrimaryPillButton(
      label: l10n.wifiTransferStart,
      onPressed: canStart ? _startTransfer : null,
    );
  }
}
