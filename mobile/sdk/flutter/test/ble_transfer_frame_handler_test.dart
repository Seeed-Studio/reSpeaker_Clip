import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

Uint8List _dataFrame(int seq, List<int> payload) {
  return Uint8List.fromList([
    kClipFrameData,
    seq & 0xff,
    (seq >> 8) & 0xff,
    payload.length & 0xff,
    (payload.length >> 8) & 0xff,
    ...payload,
  ]);
}

void main() {
  group('BleTransferFrameHandler', () {
    test('legacy raw bytes when framing is off', () {
      final state = BleTransferFrameState();
      // Avoid 0x01/0x10/0x11/0x12 — those are framed opcodes, not legacy raw.
      final raw = Uint8List.fromList([0x4f, 0x50, 0x55]);
      final r = BleTransferFrameHandler.handle(bytes: raw, state: state);
      expect(r, isA<BleTransferFrameRaw>());
      expect((r as BleTransferFrameRaw).bytes, raw);
      expect(state.useFraming, isFalse);
    });

    test('FILE_START resets per-file state', () {
      final state = BleTransferFrameState()
        ..useFraming = true
        ..fileCrc = 99
        ..nextSeq = 5;
      final name = utf8.encode('0002.opus');
      final frame = Uint8List.fromList([
        kClipFrameFileStart,
        name.length,
        ...name,
        0x00,
        0x10,
        0x00,
        0x00,
      ]);
      final r = BleTransferFrameHandler.handle(bytes: frame, state: state);
      expect(r, isA<BleTransferFrameFileStart>());
      expect(state.fileCrc, 0);
      expect(state.nextSeq, 0);
      expect(state.currentFilename, '0002.opus');
      expect(state.currentFileDeclaredSize, 4096);
    });

    test('DATA orphan adopts filename from effectiveStartFile', () {
      final state = BleTransferFrameState()..fileCompleteCount = 2;
      final payload = utf8.encode('abc');
      final r = BleTransferFrameHandler.handle(
        bytes: _dataFrame(7, payload),
        state: state,
        effectiveStartFile: '0003.opus',
      );
      expect(r, isA<BleTransferFrameData>());
      expect(state.currentFilename, '0003.opus');
      expect(state.nextSeq, 8);
    });

    test('FILE_END ok increments fileCompleteCount', () {
      final state = BleTransferFrameState()
        ..useFraming = true
        ..currentFilename = '0001.opus'
        ..currentFileDeclaredSize = 3
        ..bytesThisFile = 3
        ..fileCompleteCount = 0;
      final payload = utf8.encode('abc');
      BleTransferFrameHandler.handle(bytes: _dataFrame(0, payload), state: state);
      final crc = state.fileCrc;
      final end = Uint8List.fromList([
        kClipFrameFileEnd,
        crc & 0xff,
        (crc >> 8) & 0xff,
        (crc >> 16) & 0xff,
        (crc >> 24) & 0xff,
      ]);
      final r = BleTransferFrameHandler.handle(bytes: end, state: state);
      expect(r, isA<BleTransferFrameFileEndOk>());
      expect(state.fileCompleteCount, 1);
      expect((r as BleTransferFrameFileEndOk).filename, '0001.opus');
    });

    test('duplicate DATA seq is flagged', () {
      final state = BleTransferFrameState()
        ..useFraming = true
        ..currentFilename = '0001.opus'
        ..nextSeq = 2;
      final r = BleTransferFrameHandler.handle(
        bytes: _dataFrame(1, [1]),
        state: state,
      );
      expect(r, isA<BleTransferFrameData>());
      expect((r as BleTransferFrameData).duplicateSeq, isTrue);
    });
  });
}
