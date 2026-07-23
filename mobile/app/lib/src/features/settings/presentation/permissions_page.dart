import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/l10n/app_localizations.dart';
import '../data/permissions_provider.dart';
import 'settings_widgets.dart';

class PermissionsPage extends ConsumerStatefulWidget {
  const PermissionsPage({super.key});

  @override
  ConsumerState<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends ConsumerState<PermissionsPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(appPermissionStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final statusAsync = ref.watch(appPermissionStatusProvider);

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Text(l10n.permissions),
      ),
      body: statusAsync.when(
        data: (status) => ListView(
          children: [
            SettingsSectionLabel(l10n.permissions),
            SettingsCard(
              children: [
                _PermissionTile(
                  title: l10n.bluetooth,
                  granted: status.bluetoothGranted,
                  enabledLabel: l10n.enabled,
                  notEnabledLabel: l10n.notEnabled,
                  onTap: () => openPermissionSettings(),
                ),
                _PermissionTile(
                  title: l10n.microphone,
                  granted: status.microphoneGranted,
                  enabledLabel: l10n.enabled,
                  notEnabledLabel: l10n.notEnabled,
                  onTap: () => openPermissionSettings(),
                ),
                _PermissionTile(
                  title: l10n.notifications,
                  granted: status.notificationGranted,
                  enabledLabel: l10n.enabled,
                  notEnabledLabel: l10n.notEnabled,
                  onTap: () => openPermissionSettings(),
                ),
              ],
            ),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ListView(
          children: [
            SettingsSectionLabel(l10n.permissions),
            SettingsCard(
              children: [
                SettingsTile(title: l10n.bluetooth, value: '—', onTap: () => openPermissionSettings()),
                SettingsTile(title: l10n.microphone, value: '—', onTap: () => openPermissionSettings()),
                SettingsTile(title: l10n.notifications, value: '—', onTap: () => openPermissionSettings()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  final String title;
  final bool granted;
  final String enabledLabel;
  final String notEnabledLabel;
  final VoidCallback onTap;

  const _PermissionTile({
    required this.title,
    required this.granted,
    required this.enabledLabel,
    required this.notEnabledLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      title: title,
      value: granted ? enabledLabel : notEnabledLabel,
      onTap: onTap,
    );
  }
}
