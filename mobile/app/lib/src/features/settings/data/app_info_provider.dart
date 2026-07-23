import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/cache/app_cache.dart';

/// App version string (versionName only; build number is not shown in UI).
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});

/// Regeneratable cache size (waveform decode, ASR temp, etc.) — excludes Documents recordings.
final cacheSizeBytesProvider = FutureProvider<int>((ref) async {
  try {
    return await computeAppCacheSizeBytes();
  } catch (_) {
    return 0;
  }
});

/// Human-readable size, e.g. "124 MB"
String formatCacheSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const k = 1024;
  final mb = bytes / (k * k);
  if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
  final kb = bytes / k;
  if (kb >= 1) return '${kb.toStringAsFixed(1)} KB';
  return '$bytes B';
}

