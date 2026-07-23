import '../models/device.dart';

/// Recording state reported by the device in unsolicited `event:"state"`
/// notifications, GSTAT replies, and AT+START/AT+STOP responses.
///
/// Aligned with `py_test/docs/protocol.md` Section 7.1.1 (device states:
/// `IDLE`, `RECORDING`, `PAUSED`, `TRANSMITTING`, `WIFI_SYNC`, `ERROR`).
enum DeviceRecordingState {
  idle,
  recording,
  paused,
  transmitting,
  wifiSync,
  error,
  unknown,
}

extension DeviceRecordingStateX on DeviceRecordingState {
  /// Stable lowercase identifier matching the convention used elsewhere in
  /// the app (`firmwareRecState` strings). Returns `null` for [unknown].
  String? get id => switch (this) {
        DeviceRecordingState.idle => 'idle',
        DeviceRecordingState.recording => 'recording',
        DeviceRecordingState.paused => 'paused',
        DeviceRecordingState.transmitting => 'transmitting',
        DeviceRecordingState.wifiSync => 'wifi_sync',
        DeviceRecordingState.error => 'error',
        DeviceRecordingState.unknown => null,
      };

  static DeviceRecordingState parse(Object? raw) {
    if (raw == null) return DeviceRecordingState.unknown;
    final s = raw.toString().trim().toLowerCase();
    if (s.isEmpty) return DeviceRecordingState.unknown;
    return switch (s) {
      'idle' => DeviceRecordingState.idle,
      'rec' || 'recording' => DeviceRecordingState.recording,
      'paused' || 'pause' => DeviceRecordingState.paused,
      'transmitting' ||
      'transfer' ||
      'transferring' ||
      'transfering' =>
        DeviceRecordingState.transmitting,
      'wifi_sync' || 'wifi-sync' || 'wifisync' => DeviceRecordingState.wifiSync,
      'error' || 'err' || 'fault' => DeviceRecordingState.error,
      _ => DeviceRecordingState.unknown,
    };
  }
}

/// Base type for all unsolicited events sent by the device on the
/// Response characteristic (`6E400003-...`).
///
/// See `py_test/docs/protocol.md` Section 7 for the wire format. Apps should
/// listen via [RecordingSession.deviceEvents] / [parseDeviceEvent] rather
/// than re-implement the JSON shape detection.
sealed class DeviceEvent {
  /// The original JSON map from `at.jsonMessages`. Useful for vendor-specific
  /// fields not modelled by the typed subclasses.
  final Map<String, dynamic> raw;

  const DeviceEvent({required this.raw});
}

/// `{"event":"state", "state":"RECORDING|IDLE|PAUSED|...", "session":"<id>"}`
///
/// Triggered by both AT commands (`AT+START`, `AT+STOP`, `AT+PAUSE`,
/// `AT+RESUME`) and physical button events (long press start/stop, see
/// `protocol.md` Appendix E.5).
final class DeviceRecordingStateEvent extends DeviceEvent {
  /// Parsed recording state. Falls back to [DeviceRecordingState.unknown]
  /// when the firmware reports a value the SDK does not recognise.
  final DeviceRecordingState state;

  /// Session ID that the state change applies to. May be `null` when the
  /// firmware omits it (e.g. error transitions).
  final String? sessionId;

  /// Recording duration in seconds when present (firmware emits this on
  /// stop / IDLE transitions per `protocol.md` Section 7.1.1).
  final int? durationSeconds;

  /// Recording mode when present (e.g. on START events from some firmwares).
  final RecordingMode? mode;

  const DeviceRecordingStateEvent({
    required this.state,
    required this.sessionId,
    required this.durationSeconds,
    required this.mode,
    required super.raw,
  });

  @override
  String toString() =>
      'DeviceRecordingStateEvent(state=$state, session=$sessionId, '
      'duration=${durationSeconds}s, mode=$mode)';
}

/// `{"event":"mark", "session":"<id>", "mark_count":N}`
///
/// Sent when a bookmark is added during recording, either via `AT+MARK` or
/// the device's physical short-press button (see `protocol.md` Section 7.1.2
/// and Appendix E.2 / E.5).
final class DeviceBookmarkEvent extends DeviceEvent {
  /// Session ID the bookmark belongs to.
  final String? sessionId;

  /// Total number of bookmarks in the session **after** this mark, when
  /// reported by the firmware. May be `null` for legacy firmwares that only
  /// emit the trigger without a count.
  final int? markCount;

  /// Optional second-offset from session start (only some firmwares include
  /// this in the unsolicited event; the AT+MARK reply always does).
  final int? offsetSeconds;

  /// Optional note attached to the bookmark.
  final String? note;

  const DeviceBookmarkEvent({
    required this.sessionId,
    required this.markCount,
    required this.offsetSeconds,
    required this.note,
    required super.raw,
  });

  @override
  String toString() =>
      'DeviceBookmarkEvent(session=$sessionId, count=$markCount, '
      'offset=${offsetSeconds}s, note="${note ?? ''}")';
}

/// `{"event":"battery_low", "level":<percent>}`
///
/// Triggered when battery falls below the firmware threshold (typically 10%).
final class DeviceBatteryLowEvent extends DeviceEvent {
  /// Reported battery level (0..100). May be `null` for legacy firmwares.
  final int? level;

  const DeviceBatteryLowEvent({required this.level, required super.raw});

  @override
  String toString() => 'DeviceBatteryLowEvent(level=$level%)';
}

/// `{"event":"storage_low", "free_mb":<MB>}`
final class DeviceStorageLowEvent extends DeviceEvent {
  /// Free SD-card space in megabytes when reported.
  final int? freeMb;

  const DeviceStorageLowEvent({required this.freeMb, required super.raw});

  @override
  String toString() => 'DeviceStorageLowEvent(free=${freeMb}MB)';
}

/// `{"event":"error", "code":<code>, "error":"<message>"}`
final class DeviceErrorEvent extends DeviceEvent {
  /// Numeric error code (see `protocol.md` Section 8.3).
  final int? code;

  /// Human-readable error message.
  final String? message;

  const DeviceErrorEvent({
    required this.code,
    required this.message,
    required super.raw,
  });

  @override
  String toString() => 'DeviceErrorEvent(code=$code, message="$message")';
}

/// `{"event":"connected", "addr":"AA:BB:CC:DD:EE:FF"}`
final class DeviceConnectedEvent extends DeviceEvent {
  final String? address;

  const DeviceConnectedEvent({required this.address, required super.raw});
}

/// `{"event":"disconnected", "reason":"<reason>"}`
final class DeviceDisconnectedEvent extends DeviceEvent {
  final String? reason;

  const DeviceDisconnectedEvent({required this.reason, required super.raw});
}

/// Catch-all for events the SDK does not yet model. Apps can still inspect
/// [DeviceEvent.raw] for the original payload.
final class DeviceUnknownEvent extends DeviceEvent {
  /// The raw `event` string, lowercased. Empty when missing.
  final String name;

  const DeviceUnknownEvent({required this.name, required super.raw});

  @override
  String toString() => 'DeviceUnknownEvent(name="$name", raw=$raw)';
}

/// Inspect [msg] (typically a value yielded by `AtTransport.jsonMessages`)
/// and return a typed [DeviceEvent] if it matches the unsolicited event
/// shape defined in `py_test/docs/protocol.md` Section 7.
///
/// Returns `null` for plain AT command responses. Callers should also skip
/// `_isSyntheticFramerFailure` / progress payloads — those are still
/// dispatched as `null`.
///
/// Both protocol-compliant and historical event names are accepted:
/// - `state` (current spec) and `state_change` (legacy app convention).
/// - `mark` (current spec) and `bookmark` (legacy).
DeviceEvent? parseDeviceEvent(Map<String, dynamic> msg) {
  final dataObj = msg['data'];
  final dataMap = dataObj is Map
      ? Map<String, dynamic>.from(dataObj)
      : const <String, dynamic>{};

  final eventName = (msg['event'] ?? dataMap['event'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  if (eventName.isEmpty) return null;

  T? read<T>(String key) {
    final v = msg[key];
    if (v != null) return v as T?;
    return dataMap[key] as T?;
  }

  String? readStr(String key) {
    final v = read<Object?>(key);
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  int? readInt(String key) {
    final v = read<Object?>(key);
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  switch (eventName) {
    case 'state':
    case 'state_change':
      // `state` is the current protocol field; `new` is the legacy app
      // convention emitted by some firmwares (carried over from
      // `state_change`). Accept both for forward/backward compatibility.
      final stateRaw =
          msg['state'] ?? dataMap['state'] ?? msg['new'] ?? dataMap['new'];
      final modeRaw = msg['mode'] ?? dataMap['mode'];
      RecordingMode? mode;
      if (modeRaw != null) {
        final s = modeRaw.toString().trim().toLowerCase();
        if (s == 'enhanced' || s == '1') {
          mode = RecordingMode.enhanced;
        } else if (s == 'normal' || s == '0' || s.isNotEmpty) {
          mode = RecordingMode.normal;
        }
      }
      return DeviceRecordingStateEvent(
        state: DeviceRecordingStateX.parse(stateRaw),
        sessionId: readStr('session') ?? readStr('session_id'),
        durationSeconds: readInt('duration') ?? readInt('duration_s'),
        mode: mode,
        raw: msg,
      );

    case 'mark':
    case 'bookmark':
      return DeviceBookmarkEvent(
        sessionId: readStr('session') ?? readStr('session_id'),
        markCount: readInt('mark_count') ??
            readInt('count') ??
            readInt('marks') ??
            readInt('bookmarks'),
        offsetSeconds: readInt('offset') ?? readInt('offset_sec'),
        note: readStr('note'),
        raw: msg,
      );

    case 'battery_low':
    case 'low_battery':
      return DeviceBatteryLowEvent(
        level: readInt('level') ?? readInt('battery'),
        raw: msg,
      );

    case 'storage_low':
    case 'low_storage':
      return DeviceStorageLowEvent(
        freeMb: readInt('free_mb') ?? readInt('free'),
        raw: msg,
      );

    case 'error':
      return DeviceErrorEvent(
        code: readInt('code') ?? readInt('error_code'),
        message: readStr('error') ?? readStr('message') ?? readStr('msg'),
        raw: msg,
      );

    case 'connected':
      return DeviceConnectedEvent(
        address: readStr('addr') ?? readStr('address'),
        raw: msg,
      );

    case 'disconnected':
      return DeviceDisconnectedEvent(
        reason: readStr('reason'),
        raw: msg,
      );

    default:
      return DeviceUnknownEvent(name: eventName, raw: msg);
  }
}
