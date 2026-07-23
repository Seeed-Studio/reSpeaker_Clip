import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('device runtime info', () {
    test('formats ISO and unix time values', () {
      expect(
        formatDeviceAtTime('2026-07-16T01:02:03Z'),
        isNotNull,
      );
      expect(
        formatDeviceAtTime(1760000000),
        isNotNull,
      );
      expect(parseDeviceAtTime('2026-07-16T01:02:03Z'), isA<DateTime>());
      expect(parseDeviceAtTime('not-a-time'), isNull);
    });

    test('DeviceRuntimeInfo exposes derived getters', () {
      const info = DeviceRuntimeInfo(
        firmwareVersion: 'v1.2.3',
        rawDeviceTime: '2026-07-16T01:02:03Z',
        status: DeviceStatus(
          state: 'idle',
          isRecording: false,
          sessionId: null,
          batteryPercent: 83,
          isCharging: true,
          freeSpaceBytes: 123,
          bitrate: 32,
          recordingMode: RecordingMode.normal,
          recordingSeconds: 0,
          firmwareVersion: 'v1.2.3',
          raw: {},
        ),
        pairStatus: 'paired',
        pairAddress: 'AA:BB:CC:DD:EE:FF',
      );

      expect(info.hasAnyData, isTrue);
      expect(info.state, 'idle');
      expect(info.isRecording, isFalse);
      expect(info.batteryPercent, 83);
      expect(info.formattedDeviceTime, isNotNull);
      expect(info.pairStatus, 'paired');
      expect(info.pairAddress, 'AA:BB:CC:DD:EE:FF');
    });
  });

  group('download session result', () {
    test('tracks completion state and file artifacts', () {
      const result = DownloadSessionResult(
        sessionId: 's1',
        directory: '/tmp/out',
        totalFiles: 2,
        totalBytes: 100,
        completedFiles: 2,
        completedBytes: 100,
        transferDone: DownloadTransferDone(sessionId: 's1', fileCount: 2),
        files: [
          DownloadedFileArtifact(
            filename: '0001.opus',
            path: '/tmp/out/0001.opus',
            sizeBytes: 50,
            crc32: 1,
          ),
        ],
      );

      expect(result.isComplete, isTrue);
      expect(result.files.single.filename, '0001.opus');
      expect(result.transferDone?.fileCount, 2);
    });
  });
}
