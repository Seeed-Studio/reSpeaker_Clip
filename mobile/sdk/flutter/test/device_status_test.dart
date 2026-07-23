import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('crc32Ieee', () {
    test('matches known CRC-32 value', () {
      final bytes = Uint8List.fromList(utf8.encode('123456789'));
      expect(crc32Ieee(bytes), 0xCBF43926);
    });
  });

  group('DeviceStatus.fromAtReply', () {
    test('parses typical GSTAT payload', () {
      final st = DeviceStatus.fromAtReply({
        'ok': true,
        'data': {
          'state': 'recording',
          'recording': true,
          'session': '20260401/foo',
          'battery': 76,
          'charging': false,
          'free_space': 123456,
          'bitrate': 32,
          'mode': 'enhanced',
          'duration': 15,
          'version': '1.2.3',
        },
      });
      expect(st.state, 'recording');
      expect(st.isRecording, isTrue);
      expect(st.sessionId, '20260401/foo');
      expect(st.batteryPercent, 76);
      expect(st.isCharging, isFalse);
      expect(st.freeSpaceBytes, 123456);
      expect(st.bitrate, 32);
      expect(st.recordingMode, RecordingMode.enhanced);
      expect(st.recordingSeconds, 15);
      expect(st.firmwareVersion, '1.2.3');
    });
  });

  group('RecordingSession.isValidUserDeviceName', () {
    test('accepts printable names within byte limit', () {
      expect(RecordingSession.isValidUserDeviceName('My Clip'), isTrue);
      // Multi-byte UTF-8 names within the byte limit are accepted.
      expect(RecordingSession.isValidUserDeviceName('naïve café'), isTrue);
    });

    test('rejects empty, control chars, and too-long names', () {
      expect(RecordingSession.isValidUserDeviceName(''), isFalse);
      expect(RecordingSession.isValidUserDeviceName('bad\nname'), isFalse);
      expect(
        RecordingSession.isValidUserDeviceName('x' * 33),
        isFalse,
      );
    });
  });
}
