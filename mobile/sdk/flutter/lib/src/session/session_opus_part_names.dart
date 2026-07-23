import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// Sort by part index: 0001.opus < 0002.opus < 0010.opus < 10000.opus (numeric).
int compareSessionOpusPartFilename(String a, String b) {
  final na = partNumberFromSessionOpusFilename(a);
  final nb = partNumberFromSessionOpusFilename(b);
  if (na != null && nb != null) return na.compareTo(nb);
  if (na != null) return -1;
  if (nb != null) return 1;
  return a.compareTo(b);
}

int? partNumberFromSessionOpusFilename(String name) {
  final lower = name.toLowerCase();
  final stem = lower.endsWith('.opus.part')
      ? p.basenameWithoutExtension(p.basenameWithoutExtension(name))
      : p.basenameWithoutExtension(name);
  if (stem == 'part_last') return 999999;
  final m = RegExp(r'^(?:part_)?(\d+)$').firstMatch(stem);
  if (m != null) return int.tryParse(m.group(1)!);
  final m2 = RegExp(r'^_part_\d+_(\d+)$').firstMatch(stem);
  if (m2 != null) return int.tryParse(m2.group(1)!);
  return null;
}

bool isCanonicalCompleteSessionOpusSlice(String filename) {
  final name = filename.toLowerCase();
  return RegExp(r'^\d+\.opus$').hasMatch(name);
}

/// Inventory of numbered slice files ready for ordered merge.
class SessionOpusSliceInventory {
  const SessionOpusSliceInventory({
    required this.orderedCompleteSlices,
    required this.missingIndices,
    required this.maxIndex,
    required this.allArtifacts,
    required this.duplicateIndices,
  });

  /// Complete `0001.opus`…`NNNN.opus` in numeric order.
  ///
  /// `part_last.opus` is only mergeable when no complete numbered slice exists;
  /// once `0001.opus` appears, it is a stale pre-resume tail and must not be
  /// appended after the full recording.
  final List<File> orderedCompleteSlices;
  final List<int> missingIndices;
  final int maxIndex;

  /// Every non-empty session artifact (for cleanup after merge).
  final List<File> allArtifacts;
  final List<int> duplicateIndices;
}

SessionOpusSliceInventory inventorySessionOpusParts(List<File> nonEmptyParts) {
  final byIndex = <int, File>{};
  final duplicateIndices = <int>[];
  File? partLast;
  final artifacts = <File>[];

  for (final f in nonEmptyParts) {
    final name = p.basename(f.path).toLowerCase();
    artifacts.add(f);
    if (name == 'part_last.opus') {
      partLast = f;
      continue;
    }
    if (!isCanonicalCompleteSessionOpusSlice(name)) continue;
    final idx = partNumberFromSessionOpusFilename(name);
    if (idx == null || idx <= 0 || idx >= 999998) continue;
    if (byIndex.containsKey(idx)) {
      duplicateIndices.add(idx);
    }
    byIndex[idx] = f;
  }

  if (byIndex.isEmpty) {
    final tail = <File>[];
    if (partLast != null) tail.add(partLast);
    return SessionOpusSliceInventory(
      orderedCompleteSlices: tail,
      missingIndices: const [],
      maxIndex: 0,
      allArtifacts: artifacts,
      duplicateIndices: duplicateIndices,
    );
  }

  final maxIndex = byIndex.keys.reduce(math.max);
  final missing = <int>[];
  final ordered = <File>[];
  for (var i = 1; i <= maxIndex; i++) {
    final slice = byIndex[i];
    if (slice == null) {
      missing.add(i);
    } else {
      ordered.add(slice);
    }
  }

  return SessionOpusSliceInventory(
    orderedCompleteSlices: ordered,
    missingIndices: missing,
    maxIndex: maxIndex,
    allArtifacts: artifacts,
    duplicateIndices: duplicateIndices,
  );
}
