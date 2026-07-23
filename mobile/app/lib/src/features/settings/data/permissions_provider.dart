import 'dart:async';
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

/// Live permission / capability state for the Permissions settings screen.
class AppPermissionStatus {
  const AppPermissionStatus({
    required this.bluetoothGranted,
    required this.microphoneGranted,
    required this.notificationGranted,
  });

  /// System Bluetooth adapter on AND (on Android) BLE runtime permissions granted.
  final bool bluetoothGranted;
  final bool microphoneGranted;
  final bool notificationGranted;
}

bool _isBluetoothAdapterOn(BluetoothAdapterState state) =>
    state == BluetoothAdapterState.on;

/// Why connect / scan cannot start (used before device list connect flows).
enum BluetoothConnectBlockReason {
  adapterOff,
  permissionDenied,
}

/// Returns a block reason when Bluetooth is not ready; `null` when OK to connect.
Future<BluetoothConnectBlockReason?> getBluetoothConnectBlockReason() async {
  BluetoothAdapterState adapter = BluetoothAdapterState.unknown;
  try {
    adapter = await FlutterBluePlus.adapterState.first
        .timeout(const Duration(seconds: 2));
  } catch (_) {}

  if (!_isBluetoothAdapterOn(adapter)) {
    return BluetoothConnectBlockReason.adapterOff;
  }

  if (Platform.isAndroid) {
    try {
      if (!await _androidBluetoothPermissionsGranted()) {
        return BluetoothConnectBlockReason.permissionDenied;
      }
    } catch (_) {
      return BluetoothConnectBlockReason.permissionDenied;
    }
  }

  return null;
}

Future<bool> isBluetoothReadyForConnect() async =>
    (await getBluetoothConnectBlockReason()) == null;

Future<bool> _androidBluetoothPermissionsGranted() async {
  final scan = await Permission.bluetoothScan.status;
  final connect = await Permission.bluetoothConnect.status;
  return (scan.isGranted || scan.isLimited) &&
      (connect.isGranted || connect.isLimited);
}

Future<AppPermissionStatus> _readAppPermissionStatus({
  BluetoothAdapterState? adapterState,
}) async {
  var adapter = adapterState ?? BluetoothAdapterState.unknown;
  if (adapter == BluetoothAdapterState.unknown) {
    try {
      adapter = await FlutterBluePlus.adapterState.first
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
  final adapterOn = _isBluetoothAdapterOn(adapter);

  var bluetooth = false;
  try {
    if (Platform.isAndroid) {
      bluetooth = adapterOn && await _androidBluetoothPermissionsGranted();
    } else if (Platform.isIOS) {
      bluetooth = adapterOn;
    }
  } catch (_) {}

  var microphone = false;
  try {
    final mic = await Permission.microphone.status;
    microphone = mic.isGranted || mic.isLimited;
  } catch (_) {}

  var notification = false;
  try {
    final notif = await Permission.notification.status;
    notification =
        notif.isGranted || notif.isLimited || notif.isProvisional;
  } catch (_) {}

  return AppPermissionStatus(
    bluetoothGranted: bluetooth,
    microphoneGranted: microphone,
    notificationGranted: notification,
  );
}

/// Re-reads mic/notification permissions and listens to [FlutterBluePlus.adapterState]
/// so the Bluetooth row updates when the user toggles system Bluetooth.
final appPermissionStatusProvider =
    StreamProvider<AppPermissionStatus>((ref) async* {
  yield await _readAppPermissionStatus();

  await for (final adapter in FlutterBluePlus.adapterState) {
    yield await _readAppPermissionStatus(adapterState: adapter);
  }
});

/// Open app or system settings so the user can grant permissions
Future<void> openPermissionSettings() async {
  await openAppSettings();
}

/// Location-related reason a BLE scan likely found nothing on Android.
///
/// BLE scanning on Android <= 11 (and some OEM ROMs even on 12+) requires the
/// system location switch to be on and, on some devices, location permission
/// granted — even though this app declares `BLUETOOTH_SCAN` without deriving
/// location. This enum lets the UI explain an otherwise-silent empty scan.
enum ScanLocationIssue {
  /// Location looks fine, or the platform is iOS (not applicable).
  none,

  /// The app lacks location permission.
  permissionDenied,

  /// The system location master switch is off.
  serviceOff,
}

/// Best-effort diagnosis of a location-related cause for an empty BLE scan.
///
/// Returns [ScanLocationIssue.none] on iOS or when location looks ready. Never
/// throws. Intended to be called only after a scan finished with no results, so
/// devices whose scans work (e.g. stock Android 12+) are never nagged.
Future<ScanLocationIssue> diagnoseScanLocationIssue() async {
  if (!Platform.isAndroid) return ScanLocationIssue.none;
  try {
    final service = await Permission.location.serviceStatus;
    if (service == ServiceStatus.disabled) {
      return ScanLocationIssue.serviceOff;
    }
    final perm = await Permission.locationWhenInUse.status;
    if (!(perm.isGranted || perm.isLimited)) {
      return ScanLocationIssue.permissionDenied;
    }
  } catch (_) {}
  return ScanLocationIssue.none;
}

/// Open the system location settings so the user can toggle the master switch.
Future<void> openLocationServiceSettings() async {
  try {
    await AppSettings.openAppSettings(type: AppSettingsType.location);
  } catch (_) {
    await openAppSettings();
  }
}

/// Request location permission for scanning. Opens app settings when the user
/// has permanently denied it. Returns whether it is now granted.
Future<bool> requestScanLocationPermission() async {
  try {
    final res = await Permission.locationWhenInUse.request();
    if (res.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }
    return res.isGranted || res.isLimited;
  } catch (_) {
    return false;
  }
}

const _kSettingsChannel = MethodChannel('cc.seeed.voice/settings');

/// Open system Bluetooth settings (or system Settings root as fallback).
///
/// Never opens this app's settings page — users cannot Forget a BLE device there.
Future<void> openSystemBluetoothSettings() async {
  if (Platform.isAndroid) {
    await AppSettings.openAppSettings(type: AppSettingsType.bluetooth);
    return;
  }

  if (Platform.isIOS) {
    try {
      await _kSettingsChannel.invokeMethod<void>('openSystemBluetoothSettings');
      return;
    } catch (_) {
      // Fall through to Dart-side prefs URLs.
    }

    // Prefer Bluetooth page; otherwise Settings app root — not app settings.
    const candidates = <String>[
      'App-Prefs:root=Bluetooth',
      'App-Prefs:Bluetooth',
      'prefs:root=Bluetooth',
      'App-Prefs:',
      'prefs:root=',
    ];
    for (final raw in candidates) {
      try {
        final ok = await launchUrl(
          Uri.parse(raw),
          mode: LaunchMode.externalApplication,
        );
        if (ok) return;
      } catch (_) {}
    }
  }
}
