/// Recording mode supported by SenseCraft Voice Clip firmware.
enum RecordingMode { normal, enhanced }

/// Device-side state of a SenseCraft Voice Clip device.
///
/// SDK note: persistence timestamps (`createdAt`, `updatedAt`, `lastSeen`)
/// are optional. They are convenient for apps that cache devices in a local
/// DB; pure-SDK clients can ignore them.
class Device {
  /// BLE remote-id string (or any other stable identifier you choose).
  final String id;

  /// User-customisable display name. Defaults to [model] when unknown.
  final String name;

  /// Serial number reported by the device, if any.
  final String? sn;

  /// Device model, e.g. `"SenseCraft Voice Lav"`.
  final String model;

  /// 0..100. `null` when unknown.
  final int? batteryPercent;

  /// Normal / Enhanced. Defaults to [RecordingMode.normal].
  final RecordingMode recordingMode;

  /// Firmware version string reported by AT+VERSION, e.g. `"v1.2.4"`.
  final String? firmwareVersion;

  /// Whether a newer firmware version is available to flash.
  final bool hasFirmwareUpdate;

  /// Whether the device currently has a live BLE link.
  final bool isOnline;

  /// Last time the SDK saw a successful link to this device.
  final DateTime? lastSeen;

  final DateTime createdAt;
  final DateTime updatedAt;

  Device({
    required this.id,
    required this.name,
    this.sn,
    required this.model,
    this.batteryPercent,
    this.recordingMode = RecordingMode.normal,
    this.firmwareVersion,
    this.hasFirmwareUpdate = false,
    required this.isOnline,
    this.lastSeen,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Device copyWith({
    String? id,
    String? name,
    String? sn,
    String? model,
    int? batteryPercent,
    RecordingMode? recordingMode,
    String? firmwareVersion,
    bool? hasFirmwareUpdate,
    bool? isOnline,
    DateTime? lastSeen,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      sn: sn ?? this.sn,
      model: model ?? this.model,
      batteryPercent: batteryPercent ?? this.batteryPercent,
      recordingMode: recordingMode ?? this.recordingMode,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      hasFirmwareUpdate: hasFirmwareUpdate ?? this.hasFirmwareUpdate,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
