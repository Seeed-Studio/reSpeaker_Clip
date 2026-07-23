import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Parse SenseCraft Voice Clip firmware packages (ZIP or single BIN) into
/// the `List<mcumgr.Image>` accepted by `FirmwareUpdateManager.update`.
///
/// Protocol: SMP service `00001530-1212-EFDE-1523-785FEABCD123`,
/// characteristic `DA2E7828-FBCE-4E01-AE9E-261174997C48` (mcumgr / Zephyr).
class OtaFirmwareProcessor {
  /// Parse a multi-image ZIP update. The archive must contain a `manifest.json`
  /// of shape `{ "files": [{ "file": "...", "image_index": 0, "size": ... }, ...] }`
  /// alongside the referenced binaries. When `size` (or optional hash fields) are
  /// present, the referenced binaries are verified before OTA starts.
  static Future<List<mcumgr.Image>> processZip(Uint8List zipData) async {
    final prefix = 'firmware_${const Uuid().v4()}';
    final tempDir = await getTemporaryDirectory();
    final workDir = Directory('${tempDir.path}/$prefix');
    await workDir.create(recursive: true);

    try {
      final zipFile = File('${workDir.path}/firmware.zip');
      await zipFile.writeAsBytes(zipData);

      final destDir = Directory('${workDir.path}/firmware');
      await destDir.create(recursive: true);

      await ZipFile.extractToDirectory(
        zipFile: zipFile,
        destinationDir: destDir,
      );

      final manifestFile = File('${destDir.path}/manifest.json');
      if (!await manifestFile.exists()) {
        throw const OtaFirmwareException(
          'Firmware ZIP is missing manifest.json',
        );
      }

      final manifestJson = json.decode(await manifestFile.readAsString())
          as Map<String, dynamic>;
      final files = manifestJson['files'] as List<dynamic>?;
      if (files == null || files.isEmpty) {
        throw const OtaFirmwareException(
          'manifest.json contains no "files" entries',
        );
      }

      final List<mcumgr.Image> images = [];
      for (final f in files) {
        final map = f as Map<String, dynamic>;
        final fileName = map['file'] as String? ?? '';
        final imageIndexStr = map['image_index']?.toString() ?? '0';
        final imageIndex = int.tryParse(imageIndexStr) ?? 0;

        final binFile = File('${destDir.path}/$fileName');
        if (!await binFile.exists()) {
          throw OtaFirmwareException(
            'Manifest references a missing binary: $fileName',
          );
        }
        final data = await binFile.readAsBytes();
        validateManifestFileEntry(
          fileName: fileName,
          data: data,
          entry: map,
        );
        images.add(mcumgr.Image(image: imageIndex, data: data));
      }
      return images;
    } finally {
      try {
        await workDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Validates a manifest `files[]` entry against its binary payload.
  ///
  /// Supported fields (all optional except [fileName] must be non-empty):
  /// - `size` — exact byte length
  /// - `sha256` / `hash` — lowercase hex SHA-256 digest
  /// - `md5` — lowercase hex MD5 digest
  @visibleForTesting
  static void validateManifestFileEntry({
    required String fileName,
    required Uint8List data,
    required Map<String, dynamic> entry,
  }) {
    if (fileName.trim().isEmpty) {
      throw const OtaFirmwareException(
        'manifest.json entry is missing "file" name',
      );
    }

    final expectedSize = _parseManifestInt(entry['size']);
    if (expectedSize != null && data.length != expectedSize) {
      throw OtaFirmwareException(
        'Firmware binary size mismatch for $fileName: '
        'expected $expectedSize bytes, got ${data.length}',
      );
    }

    final expectedSha256 = _readManifestDigest(entry, const ['sha256', 'hash']);
    if (expectedSha256 != null) {
      final actual = sha256.convert(data).toString();
      if (actual != expectedSha256) {
        throw OtaFirmwareException(
          'Firmware binary SHA-256 mismatch for $fileName',
        );
      }
    }

    final expectedMd5 = _readManifestDigest(entry, const ['md5']);
    if (expectedMd5 != null) {
      final actual = md5.convert(data).toString();
      if (actual != expectedMd5) {
        throw OtaFirmwareException(
          'Firmware binary MD5 mismatch for $fileName',
        );
      }
    }
  }

  static int? _parseManifestInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value >= 0 ? value : null;
    return int.tryParse(value.toString());
  }

  static String? _readManifestDigest(
    Map<String, dynamic> entry,
    List<String> keys,
  ) {
    for (final key in keys) {
      final raw = entry[key];
      if (raw == null) continue;
      final normalized = raw.toString().trim().toLowerCase();
      if (normalized.isNotEmpty) return normalized;
    }
    return null;
  }

  /// Single `.bin` blob — wrapped as image index 0.
  static Future<List<mcumgr.Image>> processBin(Uint8List binData) async {
    if (binData.isEmpty) {
      throw const OtaFirmwareException('Firmware BIN is empty');
    }
    return [mcumgr.Image(image: 0, data: binData)];
  }

  /// Dispatch to [processZip] or [processBin] by file extension.
  static Future<List<mcumgr.Image>> processFile(File file) async {
    final bytes = await file.readAsBytes();
    final name = file.path.split(RegExp(r'[/\\]')).last.toLowerCase();
    if (name.endsWith('.zip')) {
      return processZip(bytes);
    }
    if (name.endsWith('.bin')) {
      return processBin(bytes);
    }
    throw const OtaFirmwareException(
      'Unsupported firmware format — expected .zip or .bin',
    );
  }
}

/// Thrown when firmware parsing fails (missing manifest, empty bin, etc.).
class OtaFirmwareException implements Exception {
  final String message;
  const OtaFirmwareException(this.message);

  @override
  String toString() => 'OtaFirmwareException: $message';
}
