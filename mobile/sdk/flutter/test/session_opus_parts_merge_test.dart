import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('session opus merge helpers', () {
    test('inventory keeps complete slices ordered and deduped', () {
      final parts = [
        _fakeFile('part_last.opus'),
        _fakeFile('0002.opus'),
        _fakeFile('0001.opus'),
        _fakeFile('0002.opus.part'),
      ];

      final inv = inventorySessionOpusParts(parts);
      expect(
        inv.orderedCompleteSlices.map((f) => pName(f.path)).toList(),
        ['0001.opus', '0002.opus'],
      );
      expect(inv.maxIndex, 2);
      expect(inv.missingIndices, isEmpty);
    });

    test('mergeSessionOpusPartsInDirectory concatenates ordered parts',
        () async {
      final dir = await Directory.systemTemp.createTemp('sensecraft_merge_');
      try {
        await _writeBytes('${dir.path}/0002.opus', [3, 4]);
        await _writeBytes('${dir.path}/0001.opus', [1, 2]);
        await _writeBytes('${dir.path}/part_last.opus', [9]);

        final out = '${dir.path}/merged.opus';
        final merged = await mergeSessionOpusPartsInDirectory(
          dir.path,
          out,
        );

        expect(merged, isNotNull);
        expect(
            await File(out).readAsBytes(), Uint8List.fromList([1, 2, 3, 4, 9]));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('resume floor prefers on-disk completed slices over DB bytes',
        () async {
      final dir = await Directory.systemTemp.createTemp('sensecraft_resume_');
      try {
        await _writeBytes('${dir.path}/0001.opus', [1, 2, 3]);
        await _writeBytes('${dir.path}/0002.opus', [4, 5]);
        await _writeBytes('${dir.path}/0002.opus.part', [9]);

        final floor = await resolveResumeByteFloor(
          sessionDirPath: dir.path,
          dbReceivedBytes: 1,
        );
        expect(floor, 5);

        final markers = await resolveSessionResumeMarkers(
          sessionDirPath: dir.path,
          startFile: '0003.opus',
          dbReceivedBytes: 1,
        );
        expect(markers.resumeByteOffset, 5);
        expect(markers.resumeFileIndex, 2);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('resume start file uses first missing slice when possible', () async {
      final dir = await Directory.systemTemp.createTemp('sensecraft_start_');
      try {
        await _writeBytes('${dir.path}/0001.opus', [1]);
        await _writeBytes('${dir.path}/0002.opus', [2]);
        await _writeBytes('${dir.path}/0004.opus', [4]);

        final startFile = await resolveSessionResumeStartFile(
          sessionDirPath: dir.path,
        );
        expect(startFile, '0003.opus');
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

File _fakeFile(String name) => File('/tmp/$name');

String pName(String path) => path.split(Platform.pathSeparator).last;

Future<void> _writeBytes(String path, List<int> bytes) async {
  await File(path).writeAsBytes(bytes);
}
