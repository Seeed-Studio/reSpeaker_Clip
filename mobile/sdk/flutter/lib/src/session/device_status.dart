import '../models/device.dart';

/// Snapshot of device status, parsed from an `AT+GSTAT` reply.
class DeviceStatus {
  /// Free-form lowercase state string from firmware, e.g. `idle`, `recording`,
  /// `transmitting`, `wifi_sync`.
  final String state;

  /// `true` when the device is currently recording audio.
  final bool isRecording;

  /// Active recording session ID, if any.
  final String? sessionId;

  /// Battery percentage (`0..100`), `null` if not reported.
  final int? batteryPercent;

  /// `true` if the device reported `charging: true`.
  final bool? isCharging;

  /// Free storage on the device in bytes, if reported.
  final int? freeSpaceBytes;

  /// Configured recording bitrate, if reported (kbps).
  final int? bitrate;

  /// Recording mode currently configured on the device.
  final RecordingMode? recordingMode;

  /// Active recording duration, in seconds, if reported.
  final int? recordingSeconds;

  /// Reported firmware version (some firmwares include it here).
  final String? firmwareVersion;

  /// Original `data` map from the device for fields not modelled above.
  final Map<String, dynamic> raw;

  const DeviceStatus({
    required this.state,
    required this.isRecording,
    required this.sessionId,
    required this.batteryPercent,
    required this.isCharging,
    required this.freeSpaceBytes,
    required this.bitrate,
    required this.recordingMode,
    required this.recordingSeconds,
    required this.firmwareVersion,
    required this.raw,
  });

  factory DeviceStatus.fromAtReply(Map<String, dynamic> resp) {
    final data = resp['data'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(resp['data'] as Map<String, dynamic>)
        : <String, dynamic>{};
    final state = (data['state'] ?? '').toString().trim().toLowerCase();
    final isRecording = data['recording'] == true || state == 'recording';
    final sid = (data['session'] ?? '').toString().trim();
    final battery = _asInt(data['battery']);
    final charging = data['charging'] == true
        ? true
        : data['charging'] == false
            ? false
            : null;
    final free = _asInt(data['free_space']);
    final bitrate = _asInt(data['bitrate']);
    final mode = _parseMode(data['mode']);
    final dur = _asInt(data['duration']);
    final fwv = (data['version'] ?? data['firmware_version'] ?? '')
        .toString()
        .trim();
    return DeviceStatus(
      state: state,
      isRecording: isRecording,
      sessionId: sid.isEmpty ? null : sid,
      batteryPercent: battery,
      isCharging: charging,
      freeSpaceBytes: free,
      bitrate: bitrate,
      recordingMode: mode,
      recordingSeconds: dur,
      firmwareVersion: fwv.isEmpty ? null : fwv,
      raw: data,
    );
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static RecordingMode? _parseMode(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim().toLowerCase();
    if (s.isEmpty) return null;
    if (s == 'enhanced' || s == '1') return RecordingMode.enhanced;
    return RecordingMode.normal;
  }
}
