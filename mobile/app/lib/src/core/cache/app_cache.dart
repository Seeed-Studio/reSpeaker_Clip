import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Regeneratable app cache under the system temp directory.
///
/// **Never** includes synced recordings: those live under
/// [getApplicationDocumentsDirectory] (`recordings/`, `trimmed/`, etc.).
const List<String> kAppCacheDirectoryNames = [
  'waveform_cache',
  'waveform_summary_cache',
  'ogg_opus_cache',
];

/// Ephemeral files written directly under temp (not user recordings).
bool isEphemeralTempRootName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('asr_src_')) return true;
  if (lower.startsWith('export_pcm48_')) return true;
  if (lower.startsWith('firmware_')) return true;
  // Share-sheet remux exports: `{base}_{tag}_{isoTs}.opus` at temp root.
  if (lower.endsWith('.opus') && !lower.startsWith('.')) return true;
  return false;
}

bool isEphemeralTempRootDir(String name) {
  return name.startsWith('asr_raw_opus_');
}

Future<Directory?> _tempRoot() async {
  try {
    return await getTemporaryDirectory();
  } catch (_) {
    return null;
  }
}

Future<int> computeAppCacheSizeBytes() async {
  final tmp = await _tempRoot();
  if (tmp == null) return 0;
  var total = 0;
  for (final dirName in kAppCacheDirectoryNames) {
    total += await _dirSize(p.join(tmp.path, dirName));
  }
  if (await tmp.exists()) {
    await for (final entity in tmp.list(followLinks: false)) {
      final base = p.basename(entity.path);
      if (entity is Directory && isEphemeralTempRootDir(base)) {
        total += await _dirSize(entity.path);
      } else if (entity is File && isEphemeralTempRootName(base)) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
  }
  return total;
}

/// Clears decode / ASR / export temp artifacts only — not Documents recordings.
Future<int> clearAppCache() async {
  const timeout = Duration(seconds: 30);
  try {
    final tmp = await _tempRoot();
    if (tmp != null && await tmp.exists()) {
      for (final dirName in kAppCacheDirectoryNames) {
        final dir = Directory(p.join(tmp.path, dirName));
        await _deleteDirContents(dir).timeout(timeout);
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      }
      await for (final entity in tmp.list(followLinks: false)) {
        final base = p.basename(entity.path);
        if (entity is Directory && isEphemeralTempRootDir(base)) {
          await _deleteDirContents(entity).timeout(timeout);
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        } else if (entity is File && isEphemeralTempRootName(base)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
  } catch (_) {}

  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();

  try {
    return await computeAppCacheSizeBytes().timeout(timeout);
  } catch (_) {
    return 0;
  }
}

Future<int> _dirSize(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += await entity.length();
      } catch (_) {}
    }
  }
  return total;
}

Future<void> _deleteDirContents(Directory dir) async {
  if (!await dir.exists()) return;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is File) {
      try {
        await entity.delete();
      } catch (_) {}
    } else if (entity is Directory) {
      try {
        await _deleteDirContents(entity);
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  }
}
