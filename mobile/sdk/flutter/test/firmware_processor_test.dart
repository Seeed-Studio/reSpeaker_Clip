import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/src/ota/firmware_processor.dart';

void main() {
  group('validateManifestFileEntry', () {
    final data = Uint8List.fromList([1, 2, 3, 4, 5]);

    test('passes when size matches manifest', () {
      expect(
        () => OtaFirmwareProcessor.validateManifestFileEntry(
          fileName: 'clip.signed.bin',
          data: data,
          entry: {'file': 'clip.signed.bin', 'size': 5},
        ),
        returnsNormally,
      );
    });

    test('throws when size mismatches manifest', () {
      expect(
        () => OtaFirmwareProcessor.validateManifestFileEntry(
          fileName: 'clip.signed.bin',
          data: data,
          entry: {'file': 'clip.signed.bin', 'size': 6},
        ),
        throwsA(
          isA<OtaFirmwareException>().having(
            (e) => e.message,
            'message',
            contains('size mismatch'),
          ),
        ),
      );
    });

    test('throws when sha256 mismatches manifest', () {
      expect(
        () => OtaFirmwareProcessor.validateManifestFileEntry(
          fileName: 'ipc_radio.bin',
          data: data,
          entry: {
            'file': 'ipc_radio.bin',
            'sha256': '0' * 64,
          },
        ),
        throwsA(
          isA<OtaFirmwareException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256 mismatch'),
          ),
        ),
      );
    });

    test('passes when sha256 matches manifest', () {
      final digest = sha256.convert(data).toString();
      expect(
        () => OtaFirmwareProcessor.validateManifestFileEntry(
          fileName: 'ipc_radio.bin',
          data: data,
          entry: {
            'file': 'ipc_radio.bin',
            'sha256': digest,
          },
        ),
        returnsNormally,
      );
    });

    test('validates clip 0.0.5 debug manifest sizes', () {
      final manifest = json.decode(r'''
{
  "files": [
    {"file": "clip.signed.bin", "size": 934156},
    {"file": "ipc_radio.bin", "size": 165736}
  ]
}
''') as Map<String, dynamic>;
      final files = manifest['files'] as List<dynamic>;

      expect(
        () => OtaFirmwareProcessor.validateManifestFileEntry(
          fileName: 'clip.signed.bin',
          data: Uint8List(934156),
          entry: files[0] as Map<String, dynamic>,
        ),
        returnsNormally,
      );
      expect(
        () => OtaFirmwareProcessor.validateManifestFileEntry(
          fileName: 'clip.signed.bin',
          data: Uint8List(934155),
          entry: files[0] as Map<String, dynamic>,
        ),
        throwsA(isA<OtaFirmwareException>()),
      );
    });
  });
}
