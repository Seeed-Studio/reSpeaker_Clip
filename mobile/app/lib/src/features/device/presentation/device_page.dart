import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../../core/widgets/app_pill_button.dart';
import 'device_controller.dart';

Future<void> _purgeDeviceSessions(
  BuildContext context,
  WidgetRef ref,
  DeviceController ctrl,
) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await AppDialogs.showDeleteConfirm(
    context,
    title: l10n.purgeDeviceSessions,
    message: l10n.purgeDeviceSessionsConfirm,
    deleteText: l10n.delete,
  );
  if (!ok || !context.mounted) return;
  final handle = AppDialogs.showLoading(context, message: l10n.purging);
  final success = await ctrl.purgeAllSessions();
  if (context.mounted) handle.close();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(success ? l10n.purgeDeviceSessionsDone : l10n.purgeDeviceSessionsFailed)),
  );
}

class DevicePage extends ConsumerWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(deviceControllerProvider);
    final ctrl = ref.read(deviceControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.device)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AppCard(
            padding: const EdgeInsets.all(16),
            borderColor: AppColors.borderLight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${l10n.deviceProtocolSummary}\n${l10n.deviceMtuLabel(state.mtu, (state.mtu - 3).clamp(1, 999))}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 120,
                      height: 48,
                      child: AppBlackPillButton(
                        label: state.isScanning ? l10n.scanning : l10n.startScan,
                        onPressed: state.isScanning ? null : () => ctrl.rescan(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (state.connection != null)
                      AppOutlinedPillButton(
                        label: l10n.disconnect,
                        onPressed: () => ctrl.disconnect(),
                        fullWidth: false,
                      ),
                  ],
                ),
                if (state.connection == null &&
                    (state.error != null || state.errorCode != null)) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.transferOrConnectionError(state.errorCode, state.error),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),

          if (state.connection != null) ...[
            const SizedBox(height: 12),
            AppCard(
              padding: const EdgeInsets.all(16),
              borderColor: AppColors.borderLight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.atDebug),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(
                        width: 120,
                        height: 48,
                        child: AppBlackPillButton(
                          label: 'AT+VERSION',
                          onPressed: () => ctrl.sendAt('AT+VERSION'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      AppOutlinedPillButton(
                        label: 'AT+GSTAT',
                        onPressed: () => ctrl.sendAt('AT+GSTAT'),
                        fullWidth: false,
                      ),
                      const SizedBox(width: 12),
                      AppOutlinedPillButton(
                        label: 'AT+PAIR?',
                        onPressed: () => ctrl.sendAt('AT+PAIR?'),
                        fullWidth: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      AppOutlinedPillButton(
                        label: l10n.purgeDeviceSessions,
                        onPressed: () => _purgeDeviceSessions(context, ref, ctrl),
                        fullWidth: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.lastResponseLabel(state.lastResponse ?? l10n.noValue)),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),
          Text(l10n.scanResultsCount(state.results.length), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...state.results.map((r) {
            final name = r.device.platformName.isNotEmpty ? r.device.platformName : l10n.noName;
            return AppCard(
              padding: EdgeInsets.zero,
              borderColor: AppColors.borderLight,
              child: ListTile(
                title: Text(name),
                subtitle: Text('${r.device.remoteId}  RSSI ${r.rssi}'),
                trailing: SizedBox(
                  width: 88,
                  height: 48,
                  child: AppBlackPillButton(
                    label: l10n.connect,
                    onPressed: state.connection != null ? null : () => ctrl.connect(r),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

