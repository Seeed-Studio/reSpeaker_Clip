import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ogg_opus_muxer.dart';
import 'raw_opus_decoder.dart';
import 'wav_waveform_extractor.dart';

/// Container formats that still rely on FFmpeg/WAV extraction keep a size guard.
const int _kMaxContainerAudioSizeForWaveform = 128 * 1024 * 1024;

/// Local `.wav` larger than this use chunked peak extraction so the UI gets
/// the first segment without waiting for a full-file isolate pass.
const int _kLargeWavBytesForStreamingPeaks = 12 * 1024 * 1024;

const int _kWaveformCacheVersion = 7;

/// Provider key: local audio path + known duration (from DB / player).
class WaveformPeaksRequest {
  final String path;
  final int? durationSeconds;

  const WaveformPeaksRequest({
    required this.path,
    this.durationSeconds,
  });

  @override
  bool operator ==(Object other) {
    return other is WaveformPeaksRequest &&
        other.path == path &&
        other.durationSeconds == durationSeconds;
  }

  @override
  int get hashCode => Object.hash(path, durationSeconds);
}

/// Scale bar count with duration so each bar covers ~2.5 s (capped for payload).
int resolveWaveformTargetBars({int? durationSeconds, int fallback = 220}) {
  if (durationSeconds == null || durationSeconds <= 0) return fallback;
  final scaled = (durationSeconds / 2.5).round();
  return scaled.clamp(220, 600);
}

/// Debug helper: log peak distribution (min/max/p95/std) to spot flat waveforms.
void logWaveformPeaksDebug(
  String tag, {
  required List<double> peaks,
  double? parsedFraction,
}) {
  if (!kDebugMode) return;
  if (peaks.isEmpty) {
    debugPrint(
      '[Waveform] $tag count=0 '
      'frac=${parsedFraction?.toStringAsFixed(3) ?? '-'}',
    );
    return;
  }
  var min = peaks.first;
  var max = peaks.first;
  var sum = 0.0;
  var sumSq = 0.0;
  for (final v in peaks) {
    if (v < min) min = v;
    if (v > max) max = v;
    sum += v;
    sumSq += v * v;
  }
  final mean = sum / peaks.length;
  final variance = (sumSq / peaks.length) - mean * mean;
  final stdDev = variance > 0 ? math.sqrt(variance) : 0.0;
  final sorted = List<double>.from(peaks)..sort();
  final p95Idx =
      (sorted.length * 0.95).floor().clamp(0, sorted.length - 1);
  final p95 = sorted[p95Idx];
  debugPrint(
    '[Waveform] $tag count=${peaks.length} '
    'frac=${parsedFraction?.toStringAsFixed(3) ?? '-'} '
    'min=${min.toStringAsFixed(3)} max=${max.toStringAsFixed(3)} '
    'p95=${p95.toStringAsFixed(3)} std=${stdDev.toStringAsFixed(3)}',
  );
}

class PreparedPlaybackAudio {
  final String path;
  final bool isRemuxedOgg;
  final bool isDecodedWav;

  const PreparedPlaybackAudio({
    required this.path,
    this.isRemuxedOgg = false,
    this.isDecodedWav = false,
  });
}

/// Waveform parse result: [peaks] are parsed maxima; [parsedFraction] is parsed duration share (0..1).
/// When [parsedFraction] < 1, the tail shows a placeholder in the UI to avoid stretch artifacts.
class WaveformPeaksResult {
  final List<double> peaks;
  final double parsedFraction;

  const WaveformPeaksResult(
      {required this.peaks, required this.parsedFraction});
}

Future<void> _yieldToUi() => Future<void>.delayed(Duration.zero);

/// Check if a decoded WAV already exists in the waveform cache for [srcPath].
///
/// This reuses the same cache key as [_ensureDecodedWavCached] so playback
/// preparation and waveform extraction share a single WAV file.
Future<String?> _findCachedWavForSrc(
  String srcPath, {
  int sampleRate = 8000,
}) async {
  try {
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return null;
    final st = await srcFile.stat();
    if (st.size < 100) return null;
    final keyBytes = utf8.encode(
        '${srcFile.path}|${st.size}|${st.modified.millisecondsSinceEpoch}|$sampleRate');
    final key = sha1.convert(keyBytes).toString();
    final tmp = await getTemporaryDirectory();
    final wavPath = p.join(tmp.path, 'waveform_cache', '$key.wav');
    final wavFile = File(wavPath);
    if (await wavFile.exists()) {
      final len = await wavFile.length();
      // Match [_ensureDecodedWavCached]: reject in-progress decodes whose header
      // is not yet patched (would otherwise race with playback prep).
      if (len > 44 && await _isLikelyPcmWavFile(wavPath)) {
        return wavPath;
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Stream of waveform peaks.
///
/// - `.wav`: small files in one pass; large files in time blocks with first segment first.
/// - `.opus` / `.caf`: decode to 8 kHz WAV, then per-block peaks; on timeout end stream (placeholder).
Stream<WaveformPeaksResult> extractAudioPeaksStream(
  String path, {
  int targetBars = 220,
  int? durationSeconds,
}) async* {
  final src = path.trim();
  if (src.isEmpty) return;
  final bars = durationSeconds != null && durationSeconds > 0
      ? resolveWaveformTargetBars(durationSeconds: durationSeconds)
      : targetBars;
  if (kDebugMode) {
    debugPrint(
      '[Waveform] extractAudioPeaksStream start path=$src bars=$bars '
      'durSec=${durationSeconds ?? '-'}',
    );
  }
  final cached = await _readWaveformPeaksCache(src, targetBars: bars);
  if (cached != null) {
    if (kDebugMode) {
      debugPrint('[Waveform] cache hit path=$src peaks=${cached.peaks.length}');
      logWaveformPeaksDebug(
        'cache-hit',
        peaks: cached.peaks,
        parsedFraction: cached.parsedFraction,
      );
    }
    yield cached;
    return;
  }
  final lower = src.toLowerCase();
  if (lower.endsWith('.wav')) {
    WaveformPeaksResult? last;
    try {
      final stat = await File(src).stat();
      if (stat.size > _kLargeWavBytesForStreamingPeaks) {
        if (kDebugMode) {
          debugPrint(
            '[Waveform] large wav streaming path=$src size=${stat.size}',
          );
        }
        await for (final chunk in extractWavPeaksStreamWithFraction(
          src,
          targetBars: bars,
        )) {
          if (chunk.peaks.isNotEmpty) {
            last = WaveformPeaksResult(
              peaks: chunk.peaks,
              parsedFraction: chunk.parsedFraction,
            );
            yield last;
            if (chunk.parsedFraction >= 1.0) {
              await _writeWaveformPeaksCache(src,
                  targetBars: bars, result: last);
            }
            if (kDebugMode) {
              debugPrint(
                '[Waveform] wav stream chunk path=$src '
                'peaks=${chunk.peaks.length} frac=${chunk.parsedFraction.toStringAsFixed(3)}',
              );
            }
            await _yieldToUi();
          }
        }
        return;
      }
    } catch (_) {}
    final peaks = await extractWavPeaks(src, targetBars: bars);
    if (peaks.isNotEmpty) {
      final result = WaveformPeaksResult(peaks: peaks, parsedFraction: 1.0);
      await _writeWaveformPeaksCache(src,
          targetBars: bars, result: result);
      yield result;
    }
    return;
  }
  if (lower.endsWith('.opus') || lower.endsWith('.caf')) {
    // For raw opus files, fast-path via cached WAV from playback prep.
    // If no cached WAV, stream peaks directly from raw Opus so large device
    // recordings can show waveform progressively without waiting for a full
    // WAV decode to finish.
    var isRawOpus = false;
    if (lower.endsWith('.opus')) {
      try {
        if (await isLikelyRawOpusPath(src)) {
          isRawOpus = true;
          final cachedWav = await _findCachedWavForSrc(src, sampleRate: 8000);
          if (cachedWav != null) {
            if (kDebugMode) {
              debugPrint('[Waveform] using cached WAV for raw opus peaks');
            }
            WaveformPeaksResult? last;
            await for (final chunk in extractWavPeaksStreamWithFraction(
              cachedWav,
              targetBars: bars,
            )) {
              if (chunk.peaks.isNotEmpty) {
                last = WaveformPeaksResult(
                  peaks: chunk.peaks,
                  parsedFraction: chunk.parsedFraction,
                );
                yield last;
                if (chunk.parsedFraction >= 1.0) {
                  await _writeWaveformPeaksCache(src,
                      targetBars: bars, result: last);
                }
                if (kDebugMode) {
                  debugPrint(
                    '[Waveform] cached wav chunk src=$src wav=$cachedWav '
                    'peaks=${chunk.peaks.length} frac=${chunk.parsedFraction.toStringAsFixed(3)}',
                  );
                }
                await _yieldToUi();
              }
            }
            if (last != null) {
              return;
            }
            if (kDebugMode) {
              debugPrint(
                '[Waveform] cached WAV yielded no peaks, falling back to raw opus '
                'stream (cache left intact) src=$src wav=$cachedWav',
              );
            }
          }
          if (kDebugMode) {
            debugPrint(
                '[Waveform] no cached WAV for raw opus — streaming peaks directly');
          }
          WaveformPeaksResult? last;
          await for (final chunk in extractRawOpusPeaksStream(
            src,
            targetBars: bars,
            sampleRate: 8000,
            durationSeconds: durationSeconds,
          )) {
            if (chunk.peaks.isEmpty) continue;
            last = WaveformPeaksResult(
              peaks: chunk.peaks,
              parsedFraction: chunk.parsedFraction,
            );
            yield last;
            if (chunk.parsedFraction >= 1.0) {
              await _writeWaveformPeaksCache(src,
                  targetBars: bars, result: last);
            }
            await _yieldToUi();
          }
          if (last != null) {
            if (kDebugMode) {
              debugPrint('[Waveform] raw opus stream completed path=$src');
            }
            return;
          }
          if (kDebugMode) {
            debugPrint(
                '[Waveform] raw opus stream produced no peaks path=$src');
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[Waveform] raw opus check error: $e');
      }
    }
    // Skip the size guard for raw opus: _ensureDecodedWavCached handles them
    // via opus_dart (not FFmpeg) and large files are expected.
    if (!isRawOpus) {
      try {
        final stat = await File(src).stat();
        if (stat.size > _kMaxContainerAudioSizeForWaveform) {
          if (kDebugMode) {
            debugPrint(
              '[Waveform] container audio too large (${stat.size} bytes), skipping decode',
            );
          }
          return;
        }
      } catch (_) {}
    }
    String? wav;
    try {
      if (kDebugMode) {
        debugPrint('[Waveform] decode-to-wav fallback start path=$src');
      }
      wav = await _ensureDecodedWavForWaveform(src).timeout(
        const Duration(minutes: 30),
        onTimeout: () {
          if (kDebugMode) {
            debugPrint('[Waveform] decode timeout (30min), using placeholder');
          }
          return null;
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[Waveform] decode error: $e');
    }
    if (wav == null) return;
    if (kDebugMode) {
      debugPrint('[Waveform] decode-to-wav fallback ready path=$src wav=$wav');
    }
    WaveformPeaksResult? last;
    await for (final chunk in extractWavPeaksStreamWithFraction(
      wav,
      targetBars: bars,
    )) {
      if (chunk.peaks.isNotEmpty) {
        last = WaveformPeaksResult(
          peaks: chunk.peaks,
          parsedFraction: chunk.parsedFraction,
        );
        yield last;
        if (chunk.parsedFraction >= 1.0) {
          await _writeWaveformPeaksCache(src,
              targetBars: bars, result: last);
        }
        if (kDebugMode) {
          debugPrint(
            '[Waveform] decoded wav chunk src=$src wav=$wav '
            'peaks=${chunk.peaks.length} frac=${chunk.parsedFraction.toStringAsFixed(3)}',
          );
        }
        await _yieldToUi();
      }
    }
  }
}

/// Extract waveform peaks for common audio files.
///
/// - `.wav` (PCM16): directly parsed in Dart (fast).
/// - `.opus` / `.caf`: decoded to a cached temporary `.wav` (PCM16) via FFmpeg,
///   then peaks extracted via [extractWavPeaks].
///
/// If extraction fails, returns an empty list.
Future<List<double>> extractAudioPeaks(
  String path, {
  int targetBars = 200,
}) async {
  final src = path.trim();
  if (src.isEmpty) return const <double>[];
  final cached = await _readWaveformPeaksCache(src, targetBars: targetBars);
  if (cached != null) return cached.peaks;
  final lower = src.toLowerCase();
  if (lower.endsWith('.wav')) {
    final peaks = await extractWavPeaks(src, targetBars: targetBars);
    if (peaks.isNotEmpty) {
      await _writeWaveformPeaksCache(
        src,
        targetBars: targetBars,
        result: WaveformPeaksResult(peaks: peaks, parsedFraction: 1.0),
      );
    }
    return peaks;
  }
  if (lower.endsWith('.opus') || lower.endsWith('.caf')) {
    if (lower.endsWith('.opus')) {
      try {
        if (await isLikelyRawOpusPath(src)) {
          WaveformPeaksResult? last;
          await for (final chunk in extractRawOpusPeaksStream(
            src,
            targetBars: targetBars,
            sampleRate: 8000,
          )) {
            if (chunk.peaks.isEmpty) continue;
            last = WaveformPeaksResult(
              peaks: chunk.peaks,
              parsedFraction: chunk.parsedFraction,
            );
          }
          if (last != null) {
            await _writeWaveformPeaksCache(src,
                targetBars: targetBars, result: last);
            return last.peaks;
          }
          return const <double>[];
        }
      } catch (_) {}
    }
    final wav = await _ensureDecodedWavForWaveform(src);
    if (wav == null) return const <double>[];
    final peaks = await extractWavPeaks(wav, targetBars: targetBars);
    if (peaks.isNotEmpty) {
      await _writeWaveformPeaksCache(
        src,
        targetBars: targetBars,
        result: WaveformPeaksResult(peaks: peaks, parsedFraction: 1.0),
      );
    }
    return peaks;
  }
  return const <double>[];
}

/// Waveform path: 8 kHz decode (~half the samples of 16 kHz) for faster large-file parsing.
Future<String?> _ensureDecodedWavForWaveform(String srcPath) async {
  return _ensureDecodedWavCached(srcPath, sampleRate: 8000);
}

/// ExoPlayer [WavExtractor] needs a valid RIFF WAVE header; corrupt/partial cache yields UnrecognizedInputFormat.
Future<bool> _isLikelyPcmWavFile(String wavPath) async {
  try {
    final f = File(wavPath);
    if (!await f.exists()) return false;
    if (await f.length() < 48) return false;
    final raf = await f.open(mode: FileMode.read);
    try {
      final h = await raf.read(12);
      if (h.length < 12) return false;
      if (h[0] != 0x52 || h[1] != 0x49 || h[2] != 0x46 || h[3] != 0x46) {
        return false;
      }
      if (h[8] != 0x57 || h[9] != 0x41 || h[10] != 0x56 || h[11] != 0x45) {
        return false;
      }
      return true;
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}

Future<String?> _ensureDecodedWavCached(
  String srcPath, {
  int sampleRate = 16000,
  void Function(double progress)? onDecodeProgress,
}) async {
  try {
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return null;
    final st = await srcFile.stat();
    if (st.size < 100) return null;
    final keyBytes = utf8.encode(
        '${srcFile.path}|${st.size}|${st.modified.millisecondsSinceEpoch}|$sampleRate');
    final key = sha1.convert(keyBytes).toString();

    final tmp = await getTemporaryDirectory();
    final outDir = Directory(p.join(tmp.path, 'waveform_cache'));
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final outPath = p.join(outDir.path, '$key.wav');
    final outFile = File(outPath);
    if (await outFile.exists()) {
      final len = await outFile.length();
      if (len > 44 && await _isLikelyPcmWavFile(outPath)) {
        return outPath;
      }
      try {
        await outFile.delete();
      } catch (_) {}
    }

    // Device .opus files are raw Opus (length-prefixed frames), NOT Ogg.
    // FFmpeg can never decode these, so skip directly to opus_dart.
    if (srcPath.toLowerCase().endsWith('.opus') &&
        await isRawOpusFile(srcFile)) {
      final rawWav = await decodeRawOpusToWav(
        srcPath,
        outPath: outPath,
        sampleRate: sampleRate,
        onProgress: onDecodeProgress,
      );
      if (rawWav != null &&
          await File(rawWav).exists() &&
          await _isLikelyPcmWavFile(rawWav)) {
        if (kDebugMode) debugPrint('[Waveform] Raw Opus decode ok: $rawWav');
        return rawWav;
      }
      try {
        if (rawWav != null && await File(rawWav).exists()) {
          await File(rawWav).delete();
        }
      } catch (_) {}
      if (kDebugMode) {
        debugPrint(
            '[Waveform] Raw Opus decode failed or invalid WAV at ${sampleRate}Hz: $srcPath');
      }
      // Some files fail almost all 8k frames (PCM<100B) but a few good frames still paint; retry at 16k.
      if (sampleRate == 8000) {
        return _ensureDecodedWavCached(srcPath,
            sampleRate: 16000, onDecodeProgress: onDecodeProgress);
      }
      return null;
    }

    // Standard containers (Ogg, CAF, etc.) — use FFmpeg.
    final cmd =
        '-nostdin -loglevel error -y -threads 0 -vn -i "${srcFile.path}" -ac 1 -ar $sampleRate -c:a pcm_s16le "$outPath"';
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (rc != null && ReturnCode.isSuccess(rc)) {
      if (await _isLikelyPcmWavFile(outPath)) return outPath;
      if (kDebugMode) {
        debugPrint(
            '[Waveform] FFmpeg output not a valid PCM WAV, deleting: $outPath');
      }
      try {
        if (await outFile.exists()) await outFile.delete();
      } catch (_) {}
      return null;
    }

    if (kDebugMode) {
      final logs = await session.getAllLogsAsString() ?? '';
      debugPrint(
          '[Waveform] FFmpeg decode failed rc=$rc src="$srcPath" logs=${logs.isEmpty ? '(empty)' : logs}');
    }
    try {
      if (await outFile.exists()) await outFile.delete();
    } catch (_) {}
    return null;
  } catch (e) {
    if (kDebugMode) debugPrint('[Waveform] ensureDecodedWavCached error: $e');
    return null;
  }
}

/// Delete decoded WAV cache for [srcPath] at [sampleRate] (same key as [_ensureDecodedWavCached]).
/// Use when ExoPlayer still fails with UnrecognizedInputFormat to force a fresh decode.
Future<void> invalidateDecodedWavCache(
  String srcPath, {
  int sampleRate = 8000,
}) async {
  try {
    final srcFile = File(srcPath.trim());
    if (!await srcFile.exists()) return;
    final st = await srcFile.stat();
    if (st.size < 100) return;
    final keyBytes = utf8.encode(
        '${srcFile.path}|${st.size}|${st.modified.millisecondsSinceEpoch}|$sampleRate');
    final key = sha1.convert(keyBytes).toString();
    final tmp = await getTemporaryDirectory();
    final outPath = p.join(tmp.path, 'waveform_cache', '$key.wav');
    final f = File(outPath);
    if (await f.exists()) {
      await f.delete();
      if (kDebugMode) {
        debugPrint('[Waveform] invalidated decoded wav cache: $outPath');
      }
    }
  } catch (_) {}
}

/// Returns true if the file does NOT start with 'OggS' magic —
/// i.e. it is a raw Opus file (device firmware format) rather than an Ogg container.
///
/// ExoPlayer cannot play raw length-prefixed Opus; callers must remux or decode first.
Future<bool> isRawOpusFile(File f) async {
  try {
    final raf = await f.open(mode: FileMode.read);
    try {
      final magic = await raf.read(4);
      if (magic.length < 4) return true;
      return magic[0] != 0x4F ||
          magic[1] != 0x67 ||
          magic[2] != 0x67 ||
          magic[3] != 0x53; // != 'OggS'
    } finally {
      await raf.close();
    }
  } catch (_) {
    return true;
  }
}

Future<bool> isLikelyRawOpusPath(String srcPath) async {
  final lower = srcPath.toLowerCase();
  if (!lower.endsWith('.opus')) return false;
  return isRawOpusFile(File(srcPath));
}

Future<PreparedPlaybackAudio?> prepareAudioForPlayback(
  String srcPath, {
  bool preferWav = false,
}) async {
  final lower = srcPath.toLowerCase();
  if (!lower.endsWith('.opus') && !lower.endsWith('.caf')) return null;

  if (!preferWav &&
      lower.endsWith('.opus') &&
      await isLikelyRawOpusPath(srcPath)) {
    final ogg = await rawOpusToOggOpus(srcPath);
    if (ogg != null) {
      return PreparedPlaybackAudio(path: ogg, isRemuxedOgg: true);
    }
  }

  final wav = await _ensureDecodedWavCached(srcPath, sampleRate: 8000);
  if (wav == null) return null;
  return PreparedPlaybackAudio(path: wav, isDecodedWav: true);
}

/// Prepare only the first [headSeconds] of audio for fast-start playback.
///
/// Returns a [PreparedPlaybackAudio] for the head portion. The result is
/// NOT stored in the long-term cache to avoid conflicting with full-file
/// entries. For raw Opus, the Ogg remux of 60 s is near-instant; for WAV
/// fallback the 8 kHz decode of 60 s finishes in < 1 s.
Future<PreparedPlaybackAudio?> prepareHeadAudioForPlayback(
  String srcPath, {
  int headSeconds = 60,
  bool preferWav = false,
}) async {
  final lower = srcPath.toLowerCase();
  if (!lower.endsWith('.opus') && !lower.endsWith('.caf')) return null;

  if (!preferWav &&
      lower.endsWith('.opus') &&
      await isLikelyRawOpusPath(srcPath)) {
    final ogg = await rawOpusToOggOpus(
      srcPath,
      maxDurationMs: headSeconds * 1000,
    );
    if (ogg != null) {
      return PreparedPlaybackAudio(path: ogg, isRemuxedOgg: true);
    }
  }

  final wav = await decodeRawOpusToWav(
    srcPath,
    sampleRate: 8000,
    channels: 1,
    maxDurationSeconds: headSeconds,
  );
  if (wav == null) return null;
  return PreparedPlaybackAudio(path: wav, isDecodedWav: true);
}

/// Get a path suitable for playback.
///
/// Device recordings use raw Opus (length-prefixed frames) which ExoPlayer
/// cannot read directly.
///
/// **Prefer Ogg Opus remux** (recontainer only, no re-encode; multi-hour files in seconds),
/// output size close to source opus (~50MB vs ~800MB WAV).
/// Fall back to full WAV decode when [preferWav] is true (e.g. Huawei Ogg play failure) or remux fails.
Future<String?> decodeAudioForPlayback(String srcPath,
    {bool preferWav = false}) async {
  final prepared = await prepareAudioForPlayback(srcPath, preferWav: preferWav);
  return prepared?.path;
}

/// Decode Opus/CAF to WAV.
///
/// [sampleRate] defaults to 16000 for ASR / quality-sensitive use.
/// Use 8000 for local preview playback to cut decode size roughly in half.
Future<String?> decodeAudioToWavForPlayback(
  String srcPath, {
  int sampleRate = 16000,
  void Function(double progress)? onProgress,
}) async {
  final lower = srcPath.toLowerCase();
  if (!lower.endsWith('.opus') && !lower.endsWith('.caf')) return null;
  return _ensureDecodedWavCached(srcPath,
      sampleRate: sampleRate, onDecodeProgress: onProgress);
}

Future<String?> _waveformPeaksCachePath(
  String srcPath, {
  required int targetBars,
}) async {
  final srcFile = File(srcPath);
  if (!await srcFile.exists()) return null;
  final st = await srcFile.stat();
  final keyBytes = utf8.encode(
    'waveform_summary_v$_kWaveformCacheVersion|${srcFile.path}|${st.size}|${st.modified.millisecondsSinceEpoch}|$targetBars',
  );
  final key = sha1.convert(keyBytes).toString();
  final tmp = await getTemporaryDirectory();
  final outDir = Directory(p.join(tmp.path, 'waveform_summary_cache'));
  if (!await outDir.exists()) {
    await outDir.create(recursive: true);
  }
  return p.join(outDir.path, '$key.json');
}

Future<WaveformPeaksResult?> _readWaveformPeaksCache(
  String srcPath, {
  required int targetBars,
}) async {
  try {
    final cachePath =
        await _waveformPeaksCachePath(srcPath, targetBars: targetBars);
    if (cachePath == null) return null;
    final file = File(cachePath);
    if (!await file.exists()) return null;
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map) return null;
    final version = raw['version'];
    if (version != _kWaveformCacheVersion) return null;
    final peaksRaw = raw['peaks'];
    if (peaksRaw is! List) return null;
    final peaks = peaksRaw
        .map((v) => (v is num) ? v.toDouble().clamp(0.0, 1.0) : null)
        .whereType<double>()
        .toList(growable: false);
    if (peaks.isEmpty) return null;
    return WaveformPeaksResult(peaks: peaks, parsedFraction: 1.0);
  } catch (_) {
    return null;
  }
}

Future<void> _writeWaveformPeaksCache(
  String srcPath, {
  required int targetBars,
  required WaveformPeaksResult result,
}) async {
  try {
    if (result.parsedFraction < 1.0 || result.peaks.isEmpty) return;
    final cachePath =
        await _waveformPeaksCachePath(srcPath, targetBars: targetBars);
    if (cachePath == null) return;
    final file = File(cachePath);
    final normalized = result.peaks
        .map((v) => double.parse(v.clamp(0.0, 1.0).toStringAsFixed(5)))
        .toList(growable: false);
    await file.writeAsString(jsonEncode({
      'version': _kWaveformCacheVersion,
      'target_bars': targetBars,
      'peaks': normalized,
    }));
    if (kDebugMode) {
      debugPrint('[Waveform] wrote summary cache path=$cachePath');
      logWaveformPeaksDebug(
        'cache-write',
        peaks: normalized,
        parsedFraction: result.parsedFraction,
      );
    }
  } catch (_) {}
}
