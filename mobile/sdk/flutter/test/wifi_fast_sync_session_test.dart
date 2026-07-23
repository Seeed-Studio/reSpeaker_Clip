import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('Wifi batch types', () {
    test('WifiBatchItem copyWith preserves defaults', () {
      const item = WifiBatchItem(
        recordingId: 'r1',
        sessionId: 's1',
        sessionDir: '/tmp/session',
        expectedBytes: 123,
        startFile: '0002.opus',
        resumeByteOffset: 44,
      );

      final copied = item.copyWith(sessionDir: '/tmp/other');

      expect(copied.recordingId, 'r1');
      expect(copied.sessionId, 's1');
      expect(copied.sessionDir, '/tmp/other');
      expect(copied.expectedBytes, 123);
      expect(copied.startFile, '0002.opus');
      expect(copied.resumeByteOffset, 44);
    });

    test('WifiFastSyncBatchResult getters reflect result state', () {
      const ok = WifiFastSyncBatchResult(succeeded: 2, failed: 0);
      expect(ok.isOverallSuccess, isTrue);
      expect(ok.shouldFallBackToBle, isFalse);

      const fallback = WifiFastSyncBatchResult(
        succeeded: 0,
        failed: 1,
        bleFallbackReason: WifiBleFallbackReason.phoneWifiDisconnected,
      );
      expect(fallback.isOverallSuccess, isFalse);
      expect(fallback.shouldFallBackToBle, isTrue);
    });

    test('WifiVerifyFailure string is stable enough for UI/logging', () {
      const failure = WifiVerifyFailure(
        WifiVerifyFailureKind.timedOut,
        hotspot: WifiHotspotInfo(
          enabled: true,
          ssid: 'Clip',
          password: '12345678',
          ip: '192.168.4.1',
          port: 8089,
        ),
      );
      expect(failure.toString(), contains('Wi-Fi setup'));
      expect(failure.hotspot.ssid, 'Clip');
    });
  });
}
