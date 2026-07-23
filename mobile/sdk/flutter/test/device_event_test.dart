import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('parseDeviceEvent', () {
    test('returns null when event field is missing', () {
      expect(parseDeviceEvent({'ok': true}), isNull);
    });

    test('parses state event', () {
      final ev = parseDeviceEvent({
        'event': 'state',
        'state': 'RECORDING',
        'session': '20260401/foo',
        'duration': 42,
        'mode': 'enhanced',
      });
      expect(ev, isA<DeviceRecordingStateEvent>());
      final s = ev as DeviceRecordingStateEvent;
      expect(s.state, DeviceRecordingState.recording);
      expect(s.sessionId, '20260401/foo');
      expect(s.durationSeconds, 42);
      expect(s.mode, RecordingMode.enhanced);
    });

    test('accepts legacy state_change and bookmark names', () {
      final stateEv = parseDeviceEvent({
        'event': 'state_change',
        'new': 'idle',
        'session': 'abc',
      });
      expect(stateEv, isA<DeviceRecordingStateEvent>());
      expect(
        (stateEv as DeviceRecordingStateEvent).state,
        DeviceRecordingState.idle,
      );

      final markEv = parseDeviceEvent({
        'event': 'bookmark',
        'session': 'abc',
        'mark_count': 2,
      });
      expect(markEv, isA<DeviceBookmarkEvent>());
      expect((markEv as DeviceBookmarkEvent).markCount, 2);
    });

    test('parses battery_low and error events', () {
      final bat = parseDeviceEvent({'event': 'battery_low', 'level': 9});
      expect(bat, isA<DeviceBatteryLowEvent>());
      expect((bat as DeviceBatteryLowEvent).level, 9);

      final err = parseDeviceEvent({
        'event': 'error',
        'code': 1001,
        'error': 'SD full',
      });
      expect(err, isA<DeviceErrorEvent>());
      final e = err as DeviceErrorEvent;
      expect(e.code, 1001);
      expect(e.message, 'SD full');
    });

    test('unknown events become DeviceUnknownEvent', () {
      final ev = parseDeviceEvent({'event': 'custom_ping', 'foo': 1});
      expect(ev, isA<DeviceUnknownEvent>());
      expect((ev as DeviceUnknownEvent).name, 'custom_ping');
    });
  });

  group('DeviceRecordingStateX', () {
    test('parse accepts common aliases', () {
      expect(DeviceRecordingStateX.parse('rec'), DeviceRecordingState.recording);
      expect(
        DeviceRecordingStateX.parse('wifi-sync'),
        DeviceRecordingState.wifiSync,
      );
      expect(DeviceRecordingStateX.parse('???').id, isNull);
    });
  });
}
