import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Runtime permissions required for BLE scanning / connecting on mobile.
///
/// - Android 12+ needs `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT`.
/// - Android < 12 scanning often requires location permission
///   (varies by OEM / OS version).
/// - iOS Bluetooth permission is declared in `Info.plist` and prompted by the
///   system the first time `CoreBluetooth` is used; this helper short-circuits.
///
/// The host app must still add the matching entries to its `AndroidManifest.xml`
/// and `Info.plist`. See the SDK README "Platform setup".
class SenseCraftVoiceBlePermissions {
  /// Request scan / connect permissions where applicable. Returns whether the
  /// minimum scan + connect permissions are granted.
  static Future<bool> ensureGranted() async {
    if (!Platform.isAndroid && !Platform.isIOS) return true;
    if (Platform.isIOS) {
      // iOS handles Bluetooth via Info.plist; `permission_handler` does not
      // prompt for it explicitly.
      return true;
    }

    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      // Some OEMs still require location for scanning.
      Permission.locationWhenInUse,
    ];

    final statuses = await permissions.request();
    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    return scanOk && connOk;
  }
}
