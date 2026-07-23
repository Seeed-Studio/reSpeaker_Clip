import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../settings/data/permissions_provider.dart';

/// Returns `true` when Bluetooth is ready to scan/connect.
///
/// When blocked, shows a dialog guiding the user to enable Bluetooth or grant
/// permissions, then returns `false` (caller should abort the connect flow).
Future<bool> ensureBluetoothReadyForConnect(BuildContext context) async {
  var reason = await getBluetoothConnectBlockReason();

  if (reason == BluetoothConnectBlockReason.permissionDenied) {
    final granted = await SenseCraftVoiceBlePermissions.ensureGranted();
    if (granted) {
      reason = await getBluetoothConnectBlockReason();
    }
  }

  if (reason == null) return true;
  if (!context.mounted) return false;

  final l10n = AppLocalizations.of(context)!;
  final message = switch (reason) {
    BluetoothConnectBlockReason.adapterOff => l10n.bluetoothOffForConnectMessage,
    BluetoothConnectBlockReason.permissionDenied =>
      l10n.bluetoothPermissionRequiredForConnectMessage,
  };

  final goSettings = await AppDialogs.showConfirm(
    context,
    title: l10n.bluetoothRequiredTitle,
    message: message,
    cancelText: l10n.cancel,
    confirmText: l10n.openSettingsAction,
  );
  if (!goSettings || !context.mounted) return false;

  if (reason == BluetoothConnectBlockReason.adapterOff && Platform.isAndroid) {
    try {
      await SenseCraftVoiceClient().turnOnAdapter();
      if (!context.mounted) return false;
      return (await getBluetoothConnectBlockReason()) == null;
    } catch (_) {}
  }

  await openPermissionSettings();
  return false;
}
