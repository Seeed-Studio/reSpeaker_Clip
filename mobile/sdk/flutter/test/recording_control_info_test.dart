import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('RecordingControlInfo', () {
    test('parses session and duration from AT replies', () {
      final info = RecordingControlInfo.fromAtReply({
        'ok': true,
        'data': {
          'session': '20260716093000',
          'duration': 18,
        },
      });

      expect(info.sessionId, '20260716093000');
      expect(info.durationSeconds, 18);
      expect(info.raw['ok'], true);
    });

    test('falls back to root values when data is absent', () {
      final info = RecordingControlInfo.fromAtReply({
        'ok': true,
        'session_id': 'abc123',
        'duration_s': '42',
      });

      expect(info.sessionId, 'abc123');
      expect(info.durationSeconds, 42);
    });
  });
}
