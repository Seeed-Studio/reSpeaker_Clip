import 'dart:io';
import 'dart:typed_data';

import 'raw_opus_decoder.dart';

/// Raw Opus utilities: duration calculation etc.
/// Frame length band for ogg_opus_muxer / duration scan. Upper bound matches
/// the decoder (`_kMaxFrameLen = 2000`) so a valid large frame is not mistaken
/// for a boundary slip and used to prematurely abort the mux.
const int kRawOpusMinFrameLen = 10;
const int kRawOpusMaxFrameLen = 2000;

///
/// Firmware format: [2-byte LE length][Opus frame data]...
/// When frame parsing differs from device format errors are likely; use decoded WAV duration instead.

/// Above this size, do not full-decode merged raw Opus just to read duration (blocks UI for minutes).
const int kMergedOpusSkipDecodeForDurationBytes = 15 * 1024 * 1024;

/// Firmware uses 20 ms frames @ 16 kHz mono.
const double kRawOpusFrameDurationSeconds = 0.02;

/// ~32 kbps mono raw Opus heuristic (fallback when frame scan fails).
int estimateRawOpusDurationSecondsFromBytes(int bytes) {
  if (bytes <= 0) return 1;
  return (bytes / 4000).round().clamp(1, 86400);
}

/// Scan length-prefixed frames without decoding — accurate for large merged files.
Future<int?> scanRawOpusDurationSeconds(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final totalSize = await file.length();
    if (totalSize < 4) return null;

    final raf = await file.open(mode: FileMode.read);
    try {
      var offset = 0;
      var frameCount = 0;
      const chunkSize = 256 * 1024;
      final chunk = Uint8List(chunkSize);
      var carry = Uint8List(0);

      while (offset < totalSize) {
        final n = await raf.readInto(chunk);
        if (n <= 0) break;
        final buf = Uint8List(n + carry.length);
        if (carry.isNotEmpty) {
          buf.setRange(0, carry.length, carry);
        }
        buf.setRange(carry.length, carry.length + n, chunk);
        var pos = 0;
        while (pos + 2 <= buf.length) {
          final frameLen =
              (buf[pos] & 0xff) | ((buf[pos + 1] & 0xff) << 8);
          if (frameLen < kRawOpusMinFrameLen || frameLen > kRawOpusMaxFrameLen) {
            pos += 2;
            continue;
          }
          final frameEnd = pos + 2 + frameLen;
          if (frameEnd > buf.length) break;
          frameCount++;
          pos = frameEnd;
        }
        carry = buf.sublist(pos);
        offset += n;
      }

      if (frameCount <= 0) return null;
      return (frameCount * kRawOpusFrameDurationSeconds).round().clamp(1, 86400 * 7);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

/// Duration for a freshly merged session file. Large merges use frame scan, not full decode.
Future<int?> resolveMergedOpusDurationSeconds(
  String mergedPath,
  int mergedBytes,
) async {
  if (mergedBytes <= 0) return null;
  if (mergedBytes > kMergedOpusSkipDecodeForDurationBytes) {
    final scanned = await scanRawOpusDurationSeconds(mergedPath);
    if (scanned != null && scanned > 0) return scanned;
    return estimateRawOpusDurationSecondsFromBytes(mergedBytes);
  }
  try {
    final decoded = await getRawOpusDurationSeconds(mergedPath);
    if (decoded != null && decoded > 0) return decoded;
  } catch (_) {}
  final scanned = await scanRawOpusDurationSeconds(mergedPath);
  if (scanned != null && scanned > 0) return scanned;
  return estimateRawOpusDurationSecondsFromBytes(mergedBytes);
}

/// Decode raw Opus to WAV, read duration from WAV header (accurate).
/// **Avoid on large merged sessions** — use [resolveMergedOpusDurationSeconds] instead.
Future<int?> getRawOpusDurationSeconds(String path) async {
  try {
    final wav = await decodeRawOpusToWav(path, sampleRate: 16000, channels: 1);
    if (wav == null) return null;
    final f = File(wav);
    if (!await f.exists()) return null;
    final raf = await f.open(mode: FileMode.read);
    try {
      final bytes = await raf.read(44);
      if (bytes.length < 44) return null;
      final dataSize = (bytes[40] & 0xff) |
          ((bytes[41] & 0xff) << 8) |
          ((bytes[42] & 0xff) << 16) |
          ((bytes[43] & 0xff) << 24);
      return (dataSize / (16000 * 1 * 2)).round().clamp(1, 86400);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}
