import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// BLE UUIDs defined by the SenseCraft Voice Clip AT protocol.
class SenseCraftVoiceBleUuids {
  /// BLE (GATT) transport per the spec:
  /// - Command receive characteristic (Write): `6E400002-...`
  /// - Response/progress characteristic  (Notify): `6E400003-...`
  /// - File data characteristic          (Notify): `6E400004-...`
  ///
  /// This is a Nordic-UART-like service UUID with an extra data
  /// characteristic appended.
  static final Guid clipAtService =
      Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');

  /// App -> Device. Write / WriteWithoutResponse.
  static final Guid commandRxCharacteristic =
      Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');

  /// Device -> App. Notify. JSON response and progress.
  static final Guid responseTxCharacteristic =
      Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');

  /// Device -> App. Notify. Raw file data.
  static final Guid fileDataCharacteristic =
      Guid('6E400004-B5A3-F393-E0A9-E50E24DCCA9E');

  // Standard BLE services
  static final Guid batteryService =
      Guid('0000180F-0000-1000-8000-00805F9B34FB');
  static final Guid batteryLevelCharacteristic =
      Guid('00002A19-0000-1000-8000-00805F9B34FB');
  static final Guid deviceInfoService =
      Guid('0000180A-0000-1000-8000-00805F9B34FB');

  // OTA (SMP) service UUID (Zephyr/mcumgr style).
  static final Guid smpService =
      Guid('00001530-1212-EFDE-1523-785FEABCD123');

  /// SMP characteristic (Write / WriteWithoutResponse / Notify).
  static final Guid smpCharacteristic =
      Guid('DA2E7828-FBCE-4E01-AE9E-261174997C48');
}
