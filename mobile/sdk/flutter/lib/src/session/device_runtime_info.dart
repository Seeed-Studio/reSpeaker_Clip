import 'device_status.dart';

/// Best-effort runtime snapshot read from common Clip AT commands.
///
/// Built from:
/// - `AT+VERSION`
/// - `AT+TIME?`
/// - `AT+GSTAT`
/// - `AT+PAIR?`
class DeviceRuntimeInfo {
  /// Firmware version reported by `AT+VERSION` or, as a fallback, `AT+GSTAT`.
  final String? firmwareVersion;

  /// Raw value returned by `AT+TIME?`.
  final Object? rawDeviceTime;

  /// Parsed device time when the raw value is ISO-8601 or unix seconds.
  final DateTime? deviceTime;

  /// Status parsed from `AT+GSTAT`.
  final DeviceStatus? status;

  /// Pairing state returned by `AT+PAIR?`, usually a free-form firmware string.
  final String? pairStatus;

  /// Peer address returned by `AT+PAIR?`, when available.
  final String? pairAddress;

  /// Raw replies for clients that need firmware-specific fields.
  final Map<String, dynamic>? versionReply;
  final Map<String, dynamic>? timeReply;
  final Map<String, dynamic>? statusReply;
  final Map<String, dynamic>? pairReply;

  const DeviceRuntimeInfo({
    this.firmwareVersion,
    this.rawDeviceTime,
    this.deviceTime,
    this.status,
    this.pairStatus,
    this.pairAddress,
    this.versionReply,
    this.timeReply,
    this.statusReply,
    this.pairReply,
  });

  String? get state => status?.state;
  bool? get isRecording => status?.isRecording;
  String? get sessionId => status?.sessionId;
  int? get batteryPercent => status?.batteryPercent;

  /// Local-time display string useful for logs and sample apps.
  String? get formattedDeviceTime => formatDeviceAtTime(rawDeviceTime);

  bool get hasAnyData =>
      firmwareVersion != null ||
      rawDeviceTime != null ||
      status != null ||
      pairStatus != null ||
      pairAddress != null;
}

/// Format firmware `AT+TIME?` values for UI/log display.
///
/// Accepts ISO-8601 strings and unix timestamps in seconds or milliseconds.
/// Unknown formats are returned unchanged.
String? formatDeviceAtTime(Object? raw) {
  if (raw == null) return null;
  final parsed = parseDeviceAtTime(raw);
  if (parsed == null) {
    final s = raw.toString().trim();
    return s.isEmpty ? null : s;
  }
  final local = parsed.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm:$ss';
}

DateTime? parseDeviceAtTime(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is int) return _dateFromUnix(raw);
  if (raw is double) return _dateFromUnix(raw.toInt());
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso;
  final n = int.tryParse(s);
  if (n != null) return _dateFromUnix(n);
  return null;
}

DateTime _dateFromUnix(int value) {
  final ms = value > 4102444800 ? value : value * 1000;
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}
