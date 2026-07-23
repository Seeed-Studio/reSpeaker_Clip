import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

int _findNextPlausibleFrameOffset(
  Uint8List bytes,
  int startOffset, {
  int maxLookaheadBytes = 400,
}) {
  final start = math.max(0, startOffset);
  final limit = math.min(bytes.length - 2, start + maxLookaheadBytes);
  for (var offset = start; offset <= limit; offset += 2) {
    final frameLen = (bytes[offset] & 0xff) | ((bytes[offset + 1] & 0xff) << 8);
    if (frameLen >= _kMinFrameLen && frameLen <= _kMaxFrameLen) {
      return offset;
    }
  }
  return -1;
}

/// Firmware raw Opus layout: each frame is [2-byte little-endian length][Opus frame data]
/// (matches py_test/tools/decode_opus.py).
///
/// Use when FFmpeg cannot decode (missing libopus/opus demuxer).
///
/// If [outPath] is set, write there (to align with FFmpeg cache paths), else a temp file.
///
/// Large files use streaming decode (not fully buffered); [onProgress] ≈ input bytes read / total size.
/// Decode raw Opus to WAV.
///
/// When [maxDurationSeconds] is set, only the first N seconds of audio are
/// decoded — useful for fast-start playback of large recordings.
Future<String?> decodeRawOpusToWav(
  String srcPath, {
  int sampleRate = 16000,
  int channels = 1,
  String? outPath,
  void Function(double progress)? onProgress,
  int? maxDurationSeconds,
}) async {
  try {
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return null;
    final st = await srcFile.stat();
    if (st.size < 100) return null;

    await _ensureOpusInit();

    String targetPath;
    if (outPath != null) {
      targetPath = outPath;
      await File(targetPath).parent.create(recursive: true);
    } else {
      final tmp = await getTemporaryDirectory();
      final outDir = Directory(p.join(tmp.path, 'waveform_cache'));
      if (!await outDir.exists()) await outDir.create(recursive: true);
      targetPath = p.join(
          outDir.path, 'raw_opus_${srcFile.path.hashCode}_${st.size}.wav');
    }

    final maxSamples =
        maxDurationSeconds != null ? maxDurationSeconds * sampleRate : null;

    // Use streaming path when limiting duration (avoid loading full file) or
    // for files exceeding the inline threshold.
    if (maxSamples != null || st.size > _kRawOpusInlineDecodeMaxBytes) {
      final ok = await _decodeRawOpusToWavStreamed(
        srcFile,
        targetPath,
        totalSize: st.size,
        sampleRate: sampleRate,
        channels: channels,
        onProgress: onProgress,
        maxSamples: maxSamples,
      );
      return ok ? targetPath : null;
    }

    final rawData = await srcFile.readAsBytes();
    final pcm = _decodeRawOpusFrames(rawData,
        sampleRate: sampleRate, channels: channels);
    if (pcm.isEmpty) return null;
    onProgress?.call(1.0);
    await _writeWav(targetPath, pcm,
        sampleRate: sampleRate, channels: channels);
    return targetPath;
  } catch (e, st) {
    if (kDebugMode) debugPrint('[RawOpus] decode error: $e\n$st');
    return null;
  }
}

/// **Single-pass** scan of device raw Opus (`[u16 len][opus packet]…`), emit multiple **16 kHz** PCM16 mono WAV segments for chunked ASR.
///
/// Avoids full-file Opus → full WAV → FFmpeg split. Opus is sequential: after [chunkCount] segments are written we **stop reading** early
/// (if [totalDurationSeconds] is short vs real tail, tail is dropped — same as metadata-based chunking).
///
/// Returns segment WAV paths in order; empty on failure (caller may fall back to full-file decode).
Future<List<String>> decodeRawOpusFileToAsrWavSegments(
  String srcPath, {
  required int sampleRate,
  required int segmentDurationSeconds,
  required int totalDurationSeconds,
  required String outDirectoryPath,
  required String fileNamePrefix,
  void Function(double progress)? onProgress,

  /// Return true to stop decoding and yield an empty list (caller distinguishes cancel vs failure).
  bool Function()? shouldAbort,
}) async {
  final paths = <String>[];
  try {
    await _ensureOpusInit();
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return paths;
    final st = await srcFile.stat();
    if (st.size < 100) return paths;

    final totalSec = totalDurationSeconds.clamp(1, 86400 * 7);
    final segSec = segmentDurationSeconds.clamp(1, 86400);
    final chunkCount = math.max(1, (totalSec + segSec - 1) ~/ segSec);

    int segmentTargetSamples(int i) {
      final startSec = i * segSec;
      final lenSec = i == chunkCount - 1
          ? (totalSec - startSec).clamp(1, segSec * 2)
          : segSec;
      return (lenSec * sampleRate).round().clamp(1, 86400 * sampleRate);
    }

    final outDir = Directory(outDirectoryPath);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final rafs = List<RandomAccessFile?>.filled(chunkCount, null);
    final pcmByteCount = List<int>.filled(chunkCount, 0);
    final outPaths = List<String?>.filled(chunkCount, null);

    Future<void> ensureOpen(int i) async {
      if (rafs[i] != null) return;
      final path = p.join(outDirectoryPath, '${fileNamePrefix}_$i.wav');
      outPaths[i] = path;
      final f = File(path);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
      rafs[i] = await f.open(mode: FileMode.write);
      await rafs[i]!.writeFrom(Uint8List(44));
    }

    Future<void> appendPcm(
        int segIndex, Int16List pcm, int offset, int n) async {
      if (n <= 0) return;
      await ensureOpen(segIndex);
      final raf = rafs[segIndex]!;
      final pcmBytes = Uint8List(n * 2);
      for (var k = 0; k < n; k++) {
        final v = pcm[offset + k];
        pcmBytes[k * 2] = v & 0xff;
        pcmBytes[k * 2 + 1] = (v >> 8) & 0xff;
      }
      await raf.writeFrom(pcmBytes);
      pcmByteCount[segIndex] += pcmBytes.length;
    }

    Future<void> finishSegment(int i) async {
      final r = rafs[i];
      if (r == null) return;
      if (pcmByteCount[i] < 100) {
        await r.close();
        rafs[i] = null;
        final op = outPaths[i];
        if (op != null) {
          try {
            await File(op).delete();
          } catch (_) {}
          outPaths[i] = null;
        }
        return;
      }
      await _patchWavHeader(r, pcmByteCount[i], sampleRate, 1);
      await r.close();
      rafs[i] = null;
    }

    RandomAccessFile? rafIn;
    var abortedAlignment = false;
    var userAbortedDecode = false;
    try {
      rafIn = await srcFile.open(mode: FileMode.read);
      final inFile = rafIn;
      final totalSize = st.size;
      final decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: 1);
      try {
        var slab = Uint8List(0);
        var filePos = 0;
        var alignedStart = false;
        var segIndex = 0;
        var samplesInSeg = 0;
        var targetSamples = segmentTargetSamples(0);

        Future<void> refill() async {
          if (filePos >= totalSize) return;
          await inFile.setPosition(filePos);
          final n = math.min(_kStreamReadChunkBytes, totalSize - filePos);
          final chunk = await inFile.read(n);
          if (chunk.isEmpty) return;
          filePos += chunk.length;
          if (slab.isEmpty) {
            slab = chunk;
          } else {
            final merged = Uint8List(slab.length + chunk.length);
            merged.setAll(0, slab);
            merged.setAll(slab.length, chunk);
            slab = merged;
          }
        }

        var framesSinceProgress = 0;

        while (true) {
          if (shouldAbort?.call() == true) {
            userAbortedDecode = true;
            break;
          }
          if (abortedAlignment) {
            break;
          }
          if (segIndex >= chunkCount) {
            break;
          }
          while (slab.length < 200 && filePos < totalSize) {
            await refill();
          }
          if (slab.length < 2) break;

          if (!alignedStart) {
            var skip = 0;
            while (skip < 200 && skip + 2 <= slab.length) {
              final frameLen =
                  (slab[skip] & 0xff) | ((slab[skip + 1] & 0xff) << 8);
              if (frameLen >= _kMinFrameLen && frameLen <= _kMaxFrameLen) {
                break;
              }
              skip += 2;
            }
            if (skip >= 200) {
              abortedAlignment = true;
              break;
            }
            if (skip > 0) {
              slab = Uint8List.sublistView(slab, skip);
            }
            alignedStart = true;
          }

          var o = 0;
          while (o + 2 <= slab.length &&
              segIndex < chunkCount &&
              !userAbortedDecode) {
            final frameLen = (slab[o] & 0xff) | ((slab[o + 1] & 0xff) << 8);
            final need = 2 + frameLen;
            if (frameLen < _kMinFrameLen || frameLen > _kMaxFrameLen) {
              var found = false;
              for (var s = 2; s < 400 && o + s + 2 <= slab.length; s += 2) {
                final nextLen =
                    (slab[o + s] & 0xff) | ((slab[o + s + 1] & 0xff) << 8);
                if (nextLen >= _kMinFrameLen && nextLen <= _kMaxFrameLen) {
                  o += s;
                  found = true;
                  break;
                }
              }
              if (!found) {
                if (o + 2 <= slab.length) {
                  o += 2;
                  continue;
                }
                break;
              }
              continue;
            }
            if (o + need > slab.length) {
              break;
            }

            final frameStart = o;
            final frameData = Uint8List.sublistView(slab, o + 2, o + need);
            o += need;

            try {
              final pcm = decoder.decode(input: frameData);
              if (pcm.isNotEmpty) {
                var pOff = 0;
                while (pOff < pcm.length && segIndex < chunkCount) {
                  final needS = targetSamples - samplesInSeg;
                  final take = math.min(needS, pcm.length - pOff);
                  await appendPcm(segIndex, pcm, pOff, take);
                  pOff += take;
                  samplesInSeg += take;
                  if (samplesInSeg >= targetSamples) {
                    await finishSegment(segIndex);
                    segIndex++;
                    samplesInSeg = 0;
                    if (segIndex < chunkCount) {
                      targetSamples = segmentTargetSamples(segIndex);
                    }
                  }
                }
              }
            } catch (_) {
              final nextOffset = _findNextPlausibleFrameOffset(
                slab,
                frameStart + 2,
              );
              if (nextOffset >= 0 && nextOffset != frameStart) {
                o = nextOffset;
              }
            }

            framesSinceProgress++;
            if (framesSinceProgress >= 64) {
              framesSinceProgress = 0;
              onProgress
                  ?.call((filePos / math.max(1, totalSize)).clamp(0.0, 0.99));
              await Future<void>.delayed(Duration.zero);
              if (shouldAbort?.call() == true) {
                userAbortedDecode = true;
                break;
              }
            }
          }

          if (userAbortedDecode) {
            break;
          }

          if (o > 0) {
            slab =
                o < slab.length ? Uint8List.sublistView(slab, o) : Uint8List(0);
          }

          if (o == 0 && slab.isNotEmpty && filePos >= totalSize) {
            break;
          }
          if (filePos < totalSize) {
            await refill();
          } else if (slab.length < 2) {
            break;
          }
        }

        for (var i = 0; i < chunkCount; i++) {
          await finishSegment(i);
        }
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('[RawOpus] segment decode error: $e\n$st');
        }
      } finally {
        decoder.destroy();
      }

      if (userAbortedDecode) {
        for (var i = 0; i < chunkCount; i++) {
          await finishSegment(i);
          final op = outPaths[i];
          if (op != null) {
            try {
              await File(op).delete();
            } catch (_) {}
          }
        }
        paths.clear();
        return paths;
      }

      if (abortedAlignment) {
        for (var i = 0; i < chunkCount; i++) {
          await finishSegment(i);
          final op = outPaths[i];
          if (op != null) {
            try {
              await File(op).delete();
            } catch (_) {}
          }
        }
        return paths;
      }

      for (var i = 0; i < chunkCount; i++) {
        final op = outPaths[i];
        if (op != null &&
            await File(op).exists() &&
            await File(op).length() > 200) {
          paths.add(op);
        }
      }
      if (paths.length != chunkCount) {
        for (final f in paths) {
          try {
            await File(f).delete();
          } catch (_) {}
        }
        paths.clear();
        return paths;
      }
      onProgress?.call(1.0);
      return paths;
    } finally {
      await rafIn?.close();
    }
  } catch (e, st) {
    if (kDebugMode) debugPrint('[RawOpus] segment wav error: $e\n$st');
    return paths;
  }
}

class RawOpusPeaksProgress {
  final List<double> peaks;
  final double parsedFraction;

  const RawOpusPeaksProgress({
    required this.peaks,
    required this.parsedFraction,
  });
}

/// Decode raw opus progressively and emit a bounded waveform summary.
///
/// The output list length is capped by [targetBars], so even multi-hour files
/// keep the UI payload stable.
Stream<RawOpusPeaksProgress> extractRawOpusPeaksStream(
  String srcPath, {
  int targetBars = 220,
  int sampleRate = 8000,
  int channels = 1,
  int? durationSeconds,
}) async* {
  RandomAccessFile? rafIn;
  try {
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return;
    final st = await srcFile.stat();
    if (st.size < 100) return;

    await _ensureOpusInit();

    rafIn = await srcFile.open(mode: FileMode.read);
    final inFile = rafIn;
    final decoder =
        SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
    try {
      final bars = targetBars.clamp(40, 800);
      final peakMax = List<double>.filled(bars, 0.0, growable: false);
      var slab = Uint8List(0);
      var filePos = 0;
      var alignedStart = false;
      var lastTouchedBucket = -1;
      var lastYieldBucket = -1;
      var lastYieldFraction = -1.0;
      const minYieldFractionStep = 0.05;
      var framesSinceYield = 0;
      var totalSamplesDecoded = 0;
      final totalSamplesHint = (durationSeconds != null && durationSeconds > 0)
          ? durationSeconds * sampleRate
          : 0;

      double decodeProgress({required int consumedBytes}) {
        if (totalSamplesHint > 0) {
          return (totalSamplesDecoded / totalSamplesHint).clamp(0.0, 1.0);
        }
        return (consumedBytes / math.max(1, st.size)).clamp(0.0, 1.0);
      }

      int bucketForProgress(double progress) {
        return math.min(
          bars - 1,
          math.max(0, (progress * bars).floor()),
        );
      }

      Future<void> refill() async {
        if (filePos >= st.size) return;
        await inFile.setPosition(filePos);
        final n = math.min(_kStreamReadChunkBytes, st.size - filePos);
        final chunk = await inFile.read(n);
        if (chunk.isEmpty) return;
        filePos += chunk.length;
        if (slab.isEmpty) {
          slab = chunk;
        } else {
          final merged = Uint8List(slab.length + chunk.length);
          merged.setAll(0, slab);
          merged.setAll(slab.length, chunk);
          slab = merged;
        }
      }

      RawOpusPeaksProgress? snapshot({
        required double parsedFraction,
        required bool forceFullLength,
      }) {
        if (lastTouchedBucket < 0) return null;
        final end = forceFullLength
            ? peakMax.length
            : math.min(peakMax.length, lastTouchedBucket + 1);
        if (end <= 0) return null;
        final out = List<double>.generate(end, (i) {
          return peakMax[i].clamp(0.0, 1.0);
        }, growable: false);
        return RawOpusPeaksProgress(
          peaks: out,
          parsedFraction: forceFullLength
              ? 1.0
              : parsedFraction.clamp(0.0, 1.0),
        );
      }

      while (true) {
        while (slab.length < 200 && filePos < st.size) {
          await refill();
        }
        if (slab.length < 2) break;

        if (!alignedStart) {
          var skip = 0;
          while (skip < 200 && skip + 2 <= slab.length) {
            final frameLen =
                (slab[skip] & 0xff) | ((slab[skip + 1] & 0xff) << 8);
            if (frameLen >= _kMinFrameLen && frameLen <= _kMaxFrameLen) {
              break;
            }
            skip += 2;
          }
          if (skip >= 200) return;
          if (skip > 0) {
            slab = Uint8List.sublistView(slab, skip);
          }
          alignedStart = true;
        }

        var o = 0;
        while (o + 2 <= slab.length) {
          final frameLen = (slab[o] & 0xff) | ((slab[o + 1] & 0xff) << 8);
          final need = 2 + frameLen;
          if (frameLen < _kMinFrameLen || frameLen > _kMaxFrameLen) {
            var found = false;
            for (var s = 2; s < 400 && o + s + 2 <= slab.length; s += 2) {
              final nextLen =
                  (slab[o + s] & 0xff) | ((slab[o + s + 1] & 0xff) << 8);
              if (nextLen >= _kMinFrameLen && nextLen <= _kMaxFrameLen) {
                o += s;
                found = true;
                break;
              }
            }
            if (!found) {
              if (o + 2 <= slab.length) {
                o += 2;
                continue;
              }
              break;
            }
            continue;
          }
          if (o + need > slab.length) {
            break;
          }

          final frameStart = o;
          final frameData = Uint8List.sublistView(slab, o + 2, o + need);
          o += need;

          try {
            final pcm = decoder.decode(input: frameData);
            if (pcm.isNotEmpty) {
              totalSamplesDecoded += pcm.length;
              final consumedBytes = filePos - slab.length + o;
              final progress = decodeProgress(consumedBytes: consumedBytes);
              final bucket = bucketForProgress(progress);
              final peak = _normalizedPeakFromPcm(pcm);
              if (peak > peakMax[bucket]) {
                peakMax[bucket] = peak;
              }
              if (bucket > lastTouchedBucket) {
                lastTouchedBucket = bucket;
              }
            }
          } catch (_) {
            final nextOffset = _findNextPlausibleFrameOffset(
              slab,
              frameStart + 2,
            );
            if (nextOffset >= 0 && nextOffset != frameStart) {
              o = nextOffset;
            }
          }

          framesSinceYield++;
          if (framesSinceYield >= 128 && lastTouchedBucket > lastYieldBucket) {
            framesSinceYield = 0;
            final consumedBytes = filePos - slab.length + o;
            final currentFrac = decodeProgress(consumedBytes: consumedBytes);
            final shouldYield = lastYieldFraction < 0 ||
                currentFrac - lastYieldFraction >= minYieldFractionStep;
            if (shouldYield) {
              final progress = snapshot(
                parsedFraction: currentFrac,
                forceFullLength: false,
              );
              if (progress != null) {
                lastYieldFraction = currentFrac;
                lastYieldBucket = lastTouchedBucket;
                yield progress;
                await Future<void>.delayed(Duration.zero);
              }
            }
          }
        }

        if (o > 0) {
          slab =
              o < slab.length ? Uint8List.sublistView(slab, o) : Uint8List(0);
        }

        if (o == 0 && slab.isNotEmpty && filePos >= st.size) {
          break;
        }
        if (filePos < st.size) {
          await refill();
        } else if (slab.length < 2) {
          break;
        }
      }

      final done = snapshot(parsedFraction: 1.0, forceFullLength: true);
      if (done != null) {
        yield done;
      }
    } finally {
      decoder.destroy();
    }
  } catch (e, st) {
    if (kDebugMode) debugPrint('[RawOpus] peaks decode error: $e\n$st');
  } finally {
    await rafIn?.close();
  }
}

/// Above this size, decode with streaming I/O (hours-long recordings fit in RAM for index only).
const int _kRawOpusInlineDecodeMaxBytes = 6 * 1024 * 1024;

const int _kStreamReadChunkBytes = 262144;

Future<bool> _decodeRawOpusToWavStreamed(
  File srcFile,
  String targetPath, {
  required int totalSize,
  required int sampleRate,
  required int channels,
  void Function(double progress)? onProgress,
  int? maxSamples,
}) async {
  RandomAccessFile? rafIn;
  RandomAccessFile? rafOut;
  try {
    rafIn = await srcFile.open(mode: FileMode.read);
    final outF = File(targetPath);
    if (await outF.exists()) {
      try {
        await outF.delete();
      } catch (_) {}
    }
    rafOut = await outF.open(mode: FileMode.write);
    await rafOut.writeFrom(Uint8List(44));

    final inFile = rafIn;
    final decoder =
        SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
    try {
      var slab = Uint8List(0);
      var filePos = 0;
      var pcmBytesWritten = 0;
      var totalSamplesDecoded = 0;
      var reachedSampleLimit = false;
      var framesSinceYield = 0;
      var alignedStart = false;

      Future<void> refill() async {
        if (filePos >= totalSize) return;
        await inFile.setPosition(filePos);
        final n = math.min(_kStreamReadChunkBytes, totalSize - filePos);
        final chunk = await inFile.read(n);
        if (chunk.isEmpty) return;
        filePos += chunk.length;
        if (slab.isEmpty) {
          slab = chunk;
        } else {
          final merged = Uint8List(slab.length + chunk.length);
          merged.setAll(0, slab);
          merged.setAll(slab.length, chunk);
          slab = merged;
        }
      }

      Future<void> flushPcmBatch(Int16List pcm) async {
        if (pcm.isEmpty) return;
        final pcmBytes = Uint8List(pcm.length * 2);
        for (var i = 0; i < pcm.length; i++) {
          final v = pcm[i];
          pcmBytes[i * 2] = v & 0xff;
          pcmBytes[i * 2 + 1] = (v >> 8) & 0xff;
        }
        await rafOut!.writeFrom(pcmBytes);
        pcmBytesWritten += pcmBytes.length;
      }

      while (true) {
        if (reachedSampleLimit) break;
        while (slab.length < 200 && filePos < totalSize) {
          await refill();
        }
        if (slab.length < 2) break;

        if (!alignedStart) {
          var skip = 0;
          while (skip < 200 && skip + 2 <= slab.length) {
            final frameLen =
                (slab[skip] & 0xff) | ((slab[skip + 1] & 0xff) << 8);
            if (frameLen >= _kMinFrameLen && frameLen <= _kMaxFrameLen) {
              break;
            }
            skip += 2;
          }
          if (skip >= 200) return false;
          if (skip > 0) {
            slab = Uint8List.sublistView(slab, skip);
          }
          alignedStart = true;
        }

        var o = 0;
        while (o + 2 <= slab.length) {
          final frameLen = (slab[o] & 0xff) | ((slab[o + 1] & 0xff) << 8);
          final need = 2 + frameLen;
          if (frameLen < _kMinFrameLen || frameLen > _kMaxFrameLen) {
            var found = false;
            for (var s = 2; s < 400 && o + s + 2 <= slab.length; s += 2) {
              final nextLen =
                  (slab[o + s] & 0xff) | ((slab[o + s + 1] & 0xff) << 8);
              if (nextLen >= _kMinFrameLen && nextLen <= _kMaxFrameLen) {
                o += s;
                found = true;
                break;
              }
            }
            if (!found) {
              if (o + 2 <= slab.length) {
                o += 2;
                continue;
              }
              break;
            }
            continue;
          }
          if (o + need > slab.length) {
            break;
          }

          final frameStart = o;
          final frameData = Uint8List.sublistView(slab, o + 2, o + need);
          o += need;
          try {
            final pcm = decoder.decode(input: frameData);
            if (maxSamples != null &&
                totalSamplesDecoded + pcm.length > maxSamples) {
              final remaining = maxSamples - totalSamplesDecoded;
              if (remaining > 0) {
                await flushPcmBatch(Int16List.sublistView(pcm, 0, remaining));
                totalSamplesDecoded += remaining;
              }
              reachedSampleLimit = true;
              break;
            }
            await flushPcmBatch(pcm);
            totalSamplesDecoded += pcm.length;
          } catch (_) {
            final nextOffset = _findNextPlausibleFrameOffset(
              slab,
              frameStart + 2,
            );
            if (nextOffset >= 0 && nextOffset != frameStart) {
              o = nextOffset;
            }
          }

          framesSinceYield++;
          if (framesSinceYield >= 64) {
            framesSinceYield = 0;
            onProgress
                ?.call((filePos / math.max(1, totalSize)).clamp(0.0, 0.99));
            await Future<void>.delayed(Duration.zero);
          }
        }

        if (o > 0) {
          slab =
              o < slab.length ? Uint8List.sublistView(slab, o) : Uint8List(0);
        }

        if (o == 0 && slab.isNotEmpty && filePos >= totalSize) {
          break;
        }
        if (filePos < totalSize) {
          await refill();
        } else if (slab.length < 2) {
          break;
        }
      }

      if (pcmBytesWritten < 100) return false;
      await _patchWavHeader(rafOut, pcmBytesWritten, sampleRate, channels);
      onProgress?.call(1.0);
      return true;
    } finally {
      decoder.destroy();
    }
  } finally {
    await rafIn?.close();
    await rafOut?.close();
  }
}

Future<void> _patchWavHeader(
  RandomAccessFile raf,
  int pcmDataSize,
  int sampleRate,
  int channels,
) async {
  final byteRate = sampleRate * channels * 2;
  final blockAlign = channels * 2;
  final header = ByteData(44);
  header.setUint8(0, 0x52);
  header.setUint8(1, 0x49);
  header.setUint8(2, 0x46);
  header.setUint8(3, 0x46);
  header.setUint32(4, 36 + pcmDataSize, Endian.little);
  header.setUint8(8, 0x57);
  header.setUint8(9, 0x41);
  header.setUint8(10, 0x56);
  header.setUint8(11, 0x45);
  header.setUint8(12, 0x66);
  header.setUint8(13, 0x6d);
  header.setUint8(14, 0x74);
  header.setUint8(15, 0x20);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, 16, Endian.little);
  header.setUint8(36, 0x64);
  header.setUint8(37, 0x61);
  header.setUint8(38, 0x74);
  header.setUint8(39, 0x61);
  header.setUint32(40, pcmDataSize, Endian.little);
  await raf.setPosition(0);
  await raf.writeFrom(header.buffer.asUint8List());
  await raf.setPosition(44 + pcmDataSize);
}

bool _opusInitialized = false;
Future<void> _ensureOpusInit() async {
  if (_opusInitialized) return;
  try {
    final lib = await opus_flutter.load();
    initOpus(lib);
    _opusInitialized = true;
  } catch (e) {
    if (kDebugMode) debugPrint('[RawOpus] init failed: $e');
    rethrow;
  }
}

/// Valid frame size band; Opus frames cap ~1275 B, we allow up to 2000 for edge cases.
const int _kMinFrameLen = 10;
const int _kMaxFrameLen = 2000;

double _normalizedPeakFromPcm(Int16List pcm) {
  if (pcm.isEmpty) return 0.0;
  if (pcm.length <= 8) {
    var maxAbs = 0;
    for (final sample in pcm) {
      final abs = sample.abs();
      if (abs > maxAbs) maxAbs = abs;
    }
    return (maxAbs / 32768.0).clamp(0.0, 1.0);
  }
  // p98 within frame: ignore single-sample pops at file boundaries.
  final absVals = List<int>.filled(pcm.length, 0);
  for (var i = 0; i < pcm.length; i++) {
    absVals[i] = pcm[i].abs();
  }
  absVals.sort();
  final idx = (absVals.length * 0.98).floor().clamp(0, absVals.length - 1);
  return (absVals[idx] / 32768.0).clamp(0.0, 1.0);
}

/// Parse [2-byte LE length][frame] and decode to PCM16.
/// After merging parts, bad lengths at boundaries can occur; try to resync in following bytes.
Uint8List _decodeRawOpusFrames(
  Uint8List rawData, {
  int sampleRate = 16000,
  int channels = 1,
}) {
  final decoder = SimpleOpusDecoder(sampleRate: sampleRate, channels: channels);
  try {
    final pcmFrames = <Int16List>[];
    var offset = 0;

    // Find a plausible frame start within the first 200 bytes
    while (offset < 200 && offset + 2 <= rawData.length) {
      final frameLen =
          (rawData[offset] & 0xff) | ((rawData[offset + 1] & 0xff) << 8);
      if (frameLen >= _kMinFrameLen && frameLen <= _kMaxFrameLen) break;
      offset += 2;
    }
    if (offset >= 200) return Uint8List(0);

    while (offset + 2 <= rawData.length) {
      final frameLen =
          (rawData[offset] & 0xff) | ((rawData[offset + 1] & 0xff) << 8);
      offset += 2;
      if (frameLen < _kMinFrameLen || frameLen > _kMaxFrameLen) {
        // Likely part boundary slip; rescan within the next 400 bytes
        var found = false;
        for (var skip = 2;
            skip < 400 && offset + skip + 2 <= rawData.length;
            skip += 2) {
          final nextLen = (rawData[offset + skip] & 0xff) |
              ((rawData[offset + skip + 1] & 0xff) << 8);
          if (nextLen >= _kMinFrameLen && nextLen <= _kMaxFrameLen) {
            offset += skip;
            found = true;
            break;
          }
        }
        if (!found) break;
        continue;
      }
      if (offset + frameLen > rawData.length) break;

      final frameStart = offset - 2;
      final frameData =
          Uint8List.fromList(rawData.sublist(offset, offset + frameLen));
      offset += frameLen;

      try {
        final pcm = decoder.decode(input: frameData);
        if (pcm.isNotEmpty) pcmFrames.add(pcm);
      } catch (_) {
        final nextOffset =
            _findNextPlausibleFrameOffset(rawData, frameStart + 2);
        if (nextOffset >= 0 && nextOffset != frameStart) {
          offset = nextOffset;
        }
        continue;
      }
    }

    if (pcmFrames.isEmpty) return Uint8List(0);
    final totalSamples = pcmFrames.fold<int>(0, (s, f) => s + f.length);
    final out = Uint8List(totalSamples * 2);
    var pos = 0;
    for (final f in pcmFrames) {
      for (var i = 0; i < f.length; i++) {
        final v = f[i];
        out[pos++] = v & 0xff;
        out[pos++] = (v >> 8) & 0xff;
      }
    }
    return out;
  } finally {
    decoder.destroy();
  }
}

Future<void> _writeWav(
  String path,
  Uint8List pcmData, {
  int sampleRate = 16000,
  int channels = 1,
}) async {
  final file = File(path);
  final dataSize = pcmData.length;
  final byteRate = sampleRate * channels * 2;
  final blockAlign = channels * 2;

  final header = ByteData(44);
  header.setUint8(0, 0x52); // 'R'
  header.setUint8(1, 0x49); // 'I'
  header.setUint8(2, 0x46); // 'F'
  header.setUint8(3, 0x46); // 'F'
  header.setUint32(4, 36 + dataSize, Endian.little);
  header.setUint8(8, 0x57); // 'W'
  header.setUint8(9, 0x41); // 'A'
  header.setUint8(10, 0x56); // 'V'
  header.setUint8(11, 0x45); // 'E'
  header.setUint8(12, 0x66); // 'f'
  header.setUint8(13, 0x6d); // 'm'
  header.setUint8(14, 0x74); // 't'
  header.setUint8(15, 0x20); // ' '
  header.setUint32(16, 16, Endian.little); // fmt chunk size
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, 16, Endian.little); // bits per sample
  header.setUint8(36, 0x64); // 'd'
  header.setUint8(37, 0x61); // 'a'
  header.setUint8(38, 0x74); // 't'
  header.setUint8(39, 0x61); // 'a'
  header.setUint32(40, dataSize, Endian.little);

  final sink = file.openWrite();
  sink.add(header.buffer.asUint8List());
  sink.add(pcmData);
  await sink.flush();
  await sink.close();
}
