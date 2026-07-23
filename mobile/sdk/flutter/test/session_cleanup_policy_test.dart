import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('RecordingSession cleanup policy', () {
    test(
        'canonicalTransferExpectedBytes prefers device totals when DB is stale',
        () {
      expect(
        RecordingSession.canonicalTransferExpectedBytes(
          dbExpected: 2000,
          transferredTotal: 1000,
        ),
        1000,
      );
      expect(
        RecordingSession.canonicalTransferExpectedBytes(
          dbExpected: 900,
          transferredTotal: 1000,
        ),
        900,
      );
      expect(
        RecordingSession.canonicalTransferExpectedBytes(
          dbExpected: null,
          transferredTotal: 1200,
        ),
        1200,
      );
    });

    test('localMergedFileCompleteForDelete applies ratio threshold', () {
      expect(
        RecordingSession.localMergedFileCompleteForDelete(
          actualSize: 950,
          expectedBytes: 1000,
        ),
        isTrue,
      );
      expect(
        RecordingSession.localMergedFileCompleteForDelete(
          actualSize: 949,
          expectedBytes: 1000,
        ),
        isFalse,
      );
      expect(
        RecordingSession.localMergedFileCompleteForDelete(
          actualSize: 950,
          verifiedBytes: 1000,
        ),
        isTrue,
      );
    });

    test('localMergedFileCompleteForDelete validates ratio input', () {
      expect(
        () => RecordingSession.localMergedFileCompleteForDelete(
          actualSize: 100,
          expectedBytes: 100,
          minCompletionRatio: 1.2,
        ),
        throwsArgumentError,
      );
    });

    test('bookmarks sidecar path and json writer are stable', () async {
      final dir = await Directory.systemTemp.createTemp('svc_bookmarks_');
      addTearDown(() async {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      });

      final mergedPath = '${dir.path}/session.opus';
      final sidecar = RecordingSession.bookmarksSidecarPathForMergedFile(
        mergedPath,
      );

      expect(sidecar, '${dir.path}/session_bookmarks.json');

      final written = await RecordingSession.writeBookmarksJsonSidecar(
        path: sidecar,
        bookmarks: const [
          DeviceBookmark(
            offsetSeconds: 12,
            note: 'hello',
            raw: {'offset': 12, 'note': 'hello'},
          ),
        ],
      );

      expect(written, sidecar);
      final decoded =
          jsonDecode(await File(sidecar).readAsString()) as List<dynamic>;
      expect(decoded.single, {'offset': 12, 'note': 'hello'});
    });
  });
}
