import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:respeaker_app/src/core/audio/session_opus_part_names.dart';

void main() {
  test('does not append stale part_last after complete resumed slices',
      () async {
    final dir = await Directory.systemTemp.createTemp('opus_parts_');
    try {
      final first = File('${dir.path}/0001.opus')..writeAsBytesSync([1, 2]);
      final second = File('${dir.path}/0002.opus')..writeAsBytesSync([3, 4]);
      final staleTail = File('${dir.path}/part_last.opus')
        ..writeAsBytesSync([9]);

      final inventory = inventorySessionOpusParts([first, staleTail, second]);

      expect(
        inventory.orderedCompleteSlices.map((f) => f.uri.pathSegments.last),
        ['0001.opus', '0002.opus'],
      );
      expect(inventory.allArtifacts, contains(staleTail));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('keeps part_last mergeable when it is the only available audio',
      () async {
    final dir = await Directory.systemTemp.createTemp('opus_parts_');
    try {
      final tail = File('${dir.path}/part_last.opus')..writeAsBytesSync([9]);

      final inventory = inventorySessionOpusParts([tail]);

      expect(
        inventory.orderedCompleteSlices.map((f) => f.uri.pathSegments.last),
        ['part_last.opus'],
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
