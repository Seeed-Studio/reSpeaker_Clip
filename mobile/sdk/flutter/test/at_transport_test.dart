import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('AtTransport reply heuristics', () {
    test('isStopAckShape accepts STOP cmd and file metadata', () {
      expect(
        AtTransport.isStopAckShape({
          'ok': true,
          'data': {'cmd': 'STOP', 'session': 's1', 'frames': 3},
        }),
        isTrue,
      );
      expect(
        AtTransport.isStopAckShape({
          'ok': true,
          'data': {'session': 's1', 'file_count': 2},
        }),
        isTrue,
      );
      expect(
        AtTransport.isStopAckShape({
          'ok': true,
          'data': {'session': 's1', 'state': 'idle'},
        }),
        isFalse,
      );
      expect(AtTransport.isStopAckShape({'ok': false}), isTrue);
    });

    test('looksLikeGstatOkReply matches payloads PAUSE/RESUME must ignore', () {
      final gstatWhileRecording = {
        'ok': true,
        'data': {
          'state': 'recording',
          'battery': 88,
          'recording': true,
          'session': '20260203100000',
        },
      };
      expect(AtTransport.looksLikeGstatOkReply(gstatWhileRecording), isTrue);
      // Real AT+PAUSE ack is typically {"ok": true} without GSTAT fields.
      expect(
        AtTransport.looksLikeGstatOkReply({'ok': true}),
        isFalse,
      );
    });

    test('looksLikeGstatOkReply detects GSTAT-shaped payloads', () {
      expect(
        AtTransport.looksLikeGstatOkReply({
          'ok': true,
          'cmd': 'GSTAT',
          'data': {'state': 'idle'},
        }),
        isTrue,
      );
      expect(
        AtTransport.looksLikeGstatOkReply({
          'ok': true,
          'data': {
            'state': 'recording',
            'battery': 88,
            'recording': true,
            'session': 's1',
          },
        }),
        isTrue,
      );
      expect(
        AtTransport.looksLikeGstatOkReply({
          'event': 'state',
          'state': 'idle',
        }),
        isFalse,
      );
    });
  });
}
