import '../domain/recording.dart';

/// Parse firmware session id (UTC) into local [DateTime].
///
/// Supports `YYYYMMDD_HHMMSS` and `YYYYMMDDHHMMSS`.
DateTime? parseSessionTimestamp(String path) {
  final s = path.trim();
  final session = s.contains('/') ? s.split('/').first : s;
  RegExpMatch? m = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$')
      .firstMatch(session);
  if (m == null) {
    m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$')
        .firstMatch(session);
  }
  if (m == null) return null;
  final y = int.tryParse(m.group(1)!) ?? 0;
  final mo = int.tryParse(m.group(2)!) ?? 1;
  final d = int.tryParse(m.group(3)!) ?? 1;
  final hh = int.tryParse(m.group(4)!) ?? 0;
  final mm = int.tryParse(m.group(5)!) ?? 0;
  final ss = int.tryParse(m.group(6)!) ?? 0;
  if (y <= 0) return null;
  return DateTime.utc(y, mo, d, hh, mm, ss).toLocal();
}

String recordingSessionRoot(String devicePath) {
  final s = devicePath.trim();
  return s.contains('/') ? s.split('/').first : s;
}

/// App-side list title format: `{deviceName}_yyyy/mm/dd`.
String recordingDisplayNameForDevice(String deviceName, DateTime date) {
  final y = date.year;
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${deviceName}_$y/$m/$d';
}

/// Firmware-triggered rows often store `{deviceName}_YYYYMMDDHHMMSS`.
bool isFirmwareStyleRecordingName(String name) {
  return RegExp(r'_\d{14}$').hasMatch(name.trim());
}

String? deviceNameFromRecordingName(String? name) {
  final n = name?.trim();
  if (n == null || n.isEmpty) return null;
  final idx = n.lastIndexOf('_');
  if (idx <= 0) return null;
  final suffix = n.substring(idx + 1);
  if (RegExp(r'^\d{14}$').hasMatch(suffix) ||
      RegExp(r'^\d{4}/\d{2}/\d{2}$').hasMatch(suffix)) {
    return n.substring(0, idx);
  }
  return null;
}

/// Resolve a user-visible title, normalizing firmware session ids to App format.
String resolveRecordingDisplayTitle(
  Recording r, {
  String defaultDeviceName = 'SenseCraft Voice Clip',
}) {
  final sessionRoot = recordingSessionRoot(r.devicePath);
  final parsed = parseSessionTimestamp(sessionRoot);
  final stored = r.name?.trim();

  final shouldFormat = stored == null ||
      stored.isEmpty ||
      stored == r.devicePath ||
      stored == sessionRoot ||
      isFirmwareStyleRecordingName(stored);

  if (r.source == 'device' && parsed != null && shouldFormat) {
    final deviceName = deviceNameFromRecordingName(stored)?.trim();
    return recordingDisplayNameForDevice(
      (deviceName != null && deviceName.isNotEmpty)
          ? deviceName
          : defaultDeviceName,
      parsed,
    );
  }

  if (stored != null && stored.isNotEmpty) return stored;
  return r.devicePath;
}
