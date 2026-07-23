import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('parseClipFileDataNotify', () {
    test('returns invalid for empty payload', () {
      final r = parseClipFileDataNotify([]);
      expect(r, isA<ClipParsedInvalid>());
      expect((r as ClipParsedInvalid).reason, 'empty');
    });

    test('parses DATA frame', () {
      final payload = utf8.encode('hello');
      final frame = Uint8List.fromList([
        kClipFrameData,
        0x05,
        0x00, // seq = 5
        payload.length,
        0x00,
        ...payload,
      ]);
      final r = parseClipFileDataNotify(frame);
      expect(r, isA<ClipParsedData>());
      final d = r as ClipParsedData;
      expect(d.seq, 5);
      expect(utf8.decode(d.payload), 'hello');
    });

    test('parses FILE_START frame', () {
      final name = utf8.encode('0001.opus');
      final frame = Uint8List.fromList([
        kClipFrameFileStart,
        name.length,
        ...name,
        0x10,
        0x27,
        0x00,
        0x00, // fileSize = 10000 LE
      ]);
      final r = parseClipFileDataNotify(frame);
      expect(r, isA<ClipParsedFileStart>());
      final fs = r as ClipParsedFileStart;
      expect(fs.filename, '0001.opus');
      expect(fs.fileSize, 10000);
    });

    test('parses FILE_END frame', () {
      final frame = Uint8List.fromList([
        kClipFrameFileEnd,
        0x78,
        0x56,
        0x34,
        0x12,
      ]);
      final r = parseClipFileDataNotify(frame);
      expect(r, isA<ClipParsedFileEnd>());
      expect((r as ClipParsedFileEnd).crc32, 0x12345678);
    });

    test('parses TRANSFER_DONE frame', () {
      final sid = utf8.encode('20260401/foo');
      final frame = Uint8List.fromList([
        kClipFrameTransferDone,
        sid.length,
        ...sid,
        0x03,
        0x00,
        0x00,
        0x00, // fileCount = 3 LE
      ]);
      final r = parseClipFileDataNotify(frame);
      expect(r, isA<ClipParsedTransferDone>());
      final td = r as ClipParsedTransferDone;
      expect(td.sessionId, '20260401/foo');
      expect(td.fileCount, 3);
    });

    test('unknown type falls back to raw bytes', () {
      final frame = Uint8List.fromList([0x99, 1, 2, 3]);
      final r = parseClipFileDataNotify(frame);
      expect(r, isA<ClipParsedRaw>());
      expect((r as ClipParsedRaw).bytes, frame);
    });
  });
}
