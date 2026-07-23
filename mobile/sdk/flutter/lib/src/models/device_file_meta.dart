/// Metadata for a single recording file stored on the device.
class DeviceFileMeta {
  /// Device identifier (same as BLE remote-id / [Device.id]).
  final String deviceId;

  /// Unique path on the device, e.g. `"REC/20260121_080000.opus"`.
  final String path;

  /// Display name (often equal to the filename).
  final String name;

  final int sizeBytes;
  final int durationSeconds;
  final int bookmarkCount;
  final DateTime? createdAt;

  const DeviceFileMeta({
    required this.deviceId,
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.bookmarkCount,
    required this.createdAt,
  });

  /// Composite identifier (`deviceId_path`) — handy as a primary key in
  /// client-side caches.
  String get recordingId => '${deviceId}_$path';
}
