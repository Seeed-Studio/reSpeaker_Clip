import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

class WavPcm16Info {
  final int channels;
  final int sampleRate;
  final int dataOffset;
  final int dataSize;

  const WavPcm16Info({
    required this.channels,
    required this.sampleRate,
    required this.dataOffset,
    required this.dataSize,
  });

  int get bytesPerSample => 2;
  int get blockAlign => channels * bytesPerSample;
  int get totalFrames => dataSize ~/ blockAlign;
}

/// fmt + data layout; supports standard PCM(1), IEEE float(3), WAVE_FORMAT_EXTENSIBLE(0xFFFE), etc., for duration/truncate checks.
class WavFileLayout {
  final int audioFormat;
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final int blockAlign;
  final int dataOffset;
  final int dataSize;

  const WavFileLayout({
    required this.audioFormat,
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.blockAlign,
    required this.dataOffset,
    required this.dataSize,
  });

  int get totalFrames =>
      blockAlign > 0 ? dataSize ~/ blockAlign : 0;
}

/// Read WAV fmt/data (not limited to PCM16). Parses extensible/float layouts the player can use.
WavFileLayout? readWavFileLayoutSync(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final raf = file.openSync(mode: FileMode.read);
  try {
    return _readWavFileLayout(raf);
  } finally {
    raf.closeSync();
  }
}

/// Read WAV header only (fast, no full file scan).
WavPcm16Info? readWavPcm16InfoSync(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final raf = file.openSync(mode: FileMode.read);
  try {
    return _readWavPcm16Info(raf);
  } finally {
    raf.closeSync();
  }
}

/// Per-bar frame peak sampler; flush uses p98 (aligned with raw Opus extraction).
class _BarPeakSampler {
  _BarPeakSampler(this._framesPerBar);

  final int _framesPerBar;
  final List<int> _samples = [];
  var _frameIdx = 0;
  static const _cap = 128;
  static const _maxAbs = 32768;

  void addFramePeak(int absSample) {
    _frameIdx++;
    final stride = math.max(1, _framesPerBar ~/ _cap);
    if (_frameIdx % stride != 0 && _samples.length >= 8) return;
    if (_samples.length < _cap) {
      _samples.add(absSample);
    } else {
      _samples[(_frameIdx ~/ stride) % _cap] = absSample;
    }
  }

  double flushNormalized() {
    if (_samples.isEmpty) return 0.0;
    final sorted = List<int>.from(_samples)..sort();
    final idx = (sorted.length * 0.98).floor().clamp(0, sorted.length - 1);
    return (sorted[idx] / _maxAbs).clamp(0.0, 1.0);
  }

  void reset() {
    _samples.clear();
    _frameIdx = 0;
  }
}

/// Extract peaks for a byte range within the WAV data section.
/// [startByte] and [endByte] are offsets within the data chunk (0-based).
/// Returns normalized peaks 0..1 for that segment.
Future<List<double>> extractWavPeaksForByteRange(
  String path, {
  required int startByte,
  required int endByte,
  required int targetBars,
  required WavPcm16Info info,
}) async {
  return compute(_extractWavPeaksForByteRangeIsolate, {
    'path': path,
    'startByte': startByte,
    'endByte': endByte,
    'targetBars': targetBars,
    'dataOffset': info.dataOffset,
    'blockAlign': info.blockAlign,
    'channels': info.channels,
  });
}

Future<List<double>> _extractWavPeaksForByteRangeIsolate(Map<String, Object?> args) async {
  final path = args['path'] as String;
  var startByte = args['startByte'] as int;
  var endByte = args['endByte'] as int;
  final targetBars = (args['targetBars'] as int?) ?? 40;
  final dataOffset = args['dataOffset'] as int;
  final blockAlign = args['blockAlign'] as int;
  final channels = args['channels'] as int;

  final file = File(path);
  if (!file.existsSync()) return const <double>[];
  startByte = (startByte ~/ blockAlign) * blockAlign;
  endByte = ((endByte + blockAlign - 1) ~/ blockAlign) * blockAlign;
  if (endByte <= startByte) return const <double>[];

  final dataSize = endByte - startByte;
  final totalFrames = dataSize ~/ blockAlign;
  final bars = math.max(1, math.min(targetBars, totalFrames));
  final framesPerBar = math.max(1, (totalFrames / bars).floor());

  final raf = file.openSync(mode: FileMode.read);
  try {
    raf.setPositionSync(dataOffset + startByte);
    final peaks = <double>[];
    var framesInBar = 0;
    final barSampler = _BarPeakSampler(framesPerBar);
    final chunkBytes = math.min(dataSize, 64 * 1024);
    int remaining = dataSize;
    Uint8List carry = Uint8List(0);

    void flushCarry(Uint8List next) {
      if (carry.isEmpty) {
        carry = next;
      } else {
        final merged = Uint8List(carry.length + next.length);
        merged.setAll(0, carry);
        merged.setAll(carry.length, next);
        carry = merged;
      }
    }

    while (remaining > 0) {
      final readN = math.min(chunkBytes, remaining);
      final buf = raf.readSync(readN);
      if (buf.isEmpty) break;
      remaining -= buf.length;
      flushCarry(buf);
      final fullFrames = carry.length ~/ blockAlign;
      final usableBytes = fullFrames * blockAlign;
      if (usableBytes == 0) continue;

      for (var f = 0; f < fullFrames; f++) {
        final base = f * blockAlign;
        var framePeak = 0;
        for (var ch = 0; ch < channels; ch++) {
          final i = base + ch * 2;
          final v = _i16le(carry, i).abs();
          if (v > framePeak) framePeak = v;
        }
        barSampler.addFramePeak(framePeak);
        framesInBar++;
        if (framesInBar >= framesPerBar) {
          peaks.add(barSampler.flushNormalized());
          barSampler.reset();
          framesInBar = 0;
        }
      }
      final rest = carry.length - usableBytes;
      if (rest > 0) {
        final nextCarry = Uint8List(rest);
        nextCarry.setAll(0, carry.sublist(usableBytes));
        carry = nextCarry;
      } else {
        carry = Uint8List(0);
      }
    }
    if (framesInBar > 0) {
      peaks.add(barSampler.flushNormalized());
    }
    return peaks.isEmpty ? const <double>[] : peaks;
  } finally {
    raf.closeSync();
  }
}

/// Parse while playing: stream waveform peaks, emit after each time chunk so UI can show parsed part immediately.
///
/// Default 60s per chunk; large files show waveform sooner without waiting for full parse.
/// Returns (peaks, parsedFraction); unparsed part shown as placeholder in UI to avoid stretch artifacts.
Stream<({List<double> peaks, double parsedFraction})> extractWavPeaksStreamWithFraction(
  String path, {
  int targetBars = 220,
  int chunkSeconds = 60,
}) async* {
  final info = readWavPcm16InfoSync(path);
  if (info == null) return;
  final totalFrames = info.totalFrames;
  final dataSize = info.dataSize;
  final blockAlign = info.blockAlign;
  if (totalFrames <= 0 || dataSize <= 0) return;

  final framesPerChunk = (chunkSeconds * info.sampleRate).clamp(1, totalFrames);
  final numChunks = math.max(1, (totalFrames / framesPerChunk).ceil());
  final barsPerChunk = math.max(1, (targetBars / numChunks).floor());
  final chunkBytes = framesPerChunk * blockAlign;

  final accumulated = <double>[];
  for (var i = 0; i < numChunks; i++) {
    final startByte = i * chunkBytes;
    var endByte = startByte + chunkBytes;
    if (endByte > dataSize) endByte = dataSize;
    if (startByte >= dataSize) break;

    final segment = await extractWavPeaksForByteRange(
      path,
      startByte: startByte,
      endByte: endByte,
      targetBars: barsPerChunk,
      info: info,
    );
    if (segment.isNotEmpty) {
      accumulated.addAll(segment);
      final frac = (i + 1) / numChunks;
      yield (peaks: List<double>.from(accumulated), parsedFraction: frac.clamp(0.0, 1.0));
    }
  }
  if (accumulated.isEmpty) return;
  final bars = targetBars.clamp(40, 800);
  if (accumulated.length != bars) {
    final out = <double>[];
    final n = accumulated.length;
    final m = bars;
    for (var i = 0; i < m; i++) {
      final idx = (m <= 1 || n <= 1) ? 0 : ((i * (n - 1)) / (m - 1)).round();
      out.add(accumulated[idx].clamp(0.0, 1.0));
    }
    yield (peaks: out, parsedFraction: 1.0);
  }
}

/// Extract waveform peaks from a WAV (PCM 16-bit LE) file.
///
/// Returns a list of normalized peaks in range 0..1, suitable for
/// `PlaybackWaveform(peaks: ...)`.
///
/// Notes:
/// - Only supports WAV with PCM (format=1), 16-bit little-endian.
/// - Runs heavy work in an isolate via `compute()` to avoid jank.
Future<List<double>> extractWavPeaks(
  String path, {
  int targetBars = 200,
}) async {
  return compute(_extractWavPeaksIsolate, {
    'path': path,
    'targetBars': targetBars,
  });
}

Future<List<double>> _extractWavPeaksIsolate(Map<String, Object?> args) async {
  final path = args['path'] as String;
  final targetBars = (args['targetBars'] as int?) ?? 200;

  final file = File(path);
  if (!file.existsSync()) return const <double>[];

  final raf = file.openSync(mode: FileMode.read);
  try {
    final info = _readWavPcm16Info(raf);
    if (info == null) return const <double>[];
    final channels = info.channels;
    final dataOffset = info.dataOffset;
    final dataSize = info.dataSize;
    final blockAlign = info.blockAlign;
    final totalFrames = info.totalFrames;

    final bars = targetBars.clamp(40, 800);
    final framesPerBar = math.max(1, (totalFrames / bars).floor());

    raf.setPositionSync(dataOffset);

    final peaks = <double>[];
    var framesInBar = 0;
    final barSampler = _BarPeakSampler(framesPerBar);

    // Read in chunks to control memory.
    final chunkBytes = math.min(dataSize, 64 * 1024);
    int remaining = dataSize;
    Uint8List carry = Uint8List(0);

    void flushCarry(Uint8List next) {
      if (carry.isEmpty) {
        carry = next;
      } else {
        final merged = Uint8List(carry.length + next.length);
        merged.setAll(0, carry);
        merged.setAll(carry.length, next);
        carry = merged;
      }
    }

    while (remaining > 0) {
      final readN = math.min(chunkBytes, remaining);
      final buf = raf.readSync(readN);
      if (buf.isEmpty) break;
      remaining -= buf.length;

      flushCarry(buf);

      // Parse full frames from carry buffer.
      final fullFrames = carry.length ~/ blockAlign;
      final usableBytes = fullFrames * blockAlign;
      if (usableBytes == 0) continue;

      for (var f = 0; f < fullFrames; f++) {
        final base = f * blockAlign;
        var framePeak = 0;
        for (var ch = 0; ch < channels; ch++) {
          final i = base + ch * 2;
          final v = _i16le(carry, i).abs();
          if (v > framePeak) framePeak = v;
        }
        barSampler.addFramePeak(framePeak);
        framesInBar++;
        if (framesInBar >= framesPerBar) {
          peaks.add(barSampler.flushNormalized());
          barSampler.reset();
          framesInBar = 0;
        }
      }

      // keep remainder bytes
      final rest = carry.length - usableBytes;
      if (rest > 0) {
        final nextCarry = Uint8List(rest);
        nextCarry.setAll(0, carry.sublist(usableBytes));
        carry = nextCarry;
      } else {
        carry = Uint8List(0);
      }
    }

    if (framesInBar > 0) {
      peaks.add(barSampler.flushNormalized());
    }

    // Normalize length roughly to bars (for consistent UI density).
    if (peaks.isEmpty) return const <double>[];
    if (peaks.length == bars) return peaks;

    final out = <double>[];
    final n = peaks.length;
    final m = bars;
    for (var i = 0; i < m; i++) {
      final idx = (m <= 1 || n <= 1) ? 0 : ((i * (n - 1)) / (m - 1)).round();
      out.add(peaks[idx].clamp(0.0, 1.0));
    }
    return out;
  } finally {
    raf.closeSync();
  }
}

/// Trim a WAV (PCM 16-bit LE) file to a new WAV file.
///
/// Only supports PCM16 WAV. For other formats, throws [UnsupportedError].
Future<void> trimWavPcm16ToNewFile({
  required String sourcePath,
  required String destPath,
  required Duration start,
  required Duration end,
}) async {
  final src = File(sourcePath);
  if (!src.existsSync()) throw FileSystemException('Source not found', sourcePath);

  final raf = src.openSync(mode: FileMode.read);
  try {
    final info = _readWavPcm16Info(raf);
    if (info == null) throw UnsupportedError('Not a PCM16 WAV file');

    final s = start < Duration.zero ? Duration.zero : start;
    final e = end < s ? s : end;

    final totalFrames = info.totalFrames;
    final startFrame = ((s.inMilliseconds * info.sampleRate) / 1000.0).floor().clamp(0, totalFrames);
    final endFrame = ((e.inMilliseconds * info.sampleRate) / 1000.0).floor().clamp(0, totalFrames);
    final frames = math.max(0, endFrame - startFrame);
    final newDataSize = frames * info.blockAlign;

    // Prepare output.
    final outFile = File(destPath);
    outFile.parent.createSync(recursive: true);
    final out = outFile.openSync(mode: FileMode.write);
    try {
      // Write a minimal PCM WAV header (44 bytes).
      final header = Uint8List(44);
      _writeAscii4(header, 0, 'RIFF');
      _writeU32le(header, 4, 36 + newDataSize);
      _writeAscii4(header, 8, 'WAVE');
      _writeAscii4(header, 12, 'fmt ');
      _writeU32le(header, 16, 16);
      _writeU16le(header, 20, 1); // PCM
      _writeU16le(header, 22, info.channels);
      _writeU32le(header, 24, info.sampleRate);
      final byteRate = info.sampleRate * info.blockAlign;
      _writeU32le(header, 28, byteRate);
      _writeU16le(header, 32, info.blockAlign);
      _writeU16le(header, 34, 16);
      _writeAscii4(header, 36, 'data');
      _writeU32le(header, 40, newDataSize);
      out.writeFromSync(header);

      // Copy audio frames.
      final startByte = info.dataOffset + startFrame * info.blockAlign;
      raf.setPositionSync(startByte);
      var remaining = newDataSize;
      final bufSize = 64 * 1024;
      final buf = Uint8List(bufSize);
      while (remaining > 0) {
        final n = math.min(bufSize, remaining);
        final read = raf.readIntoSync(buf, 0, n);
        if (read <= 0) break;
        out.writeFromSync(buf, 0, read);
        remaining -= read;
      }
      if (remaining != 0) {
        throw FileSystemException('Unexpected EOF while trimming', sourcePath);
      }
    } finally {
      out.closeSync();
    }
  } finally {
    raf.closeSync();
  }
}

/// Write a PCM16 WAV silence file.
///
/// Useful for demo/testing the "transfer -> local file -> playable" pipeline.
Future<void> writeSilenceWavPcm16({
  required String destPath,
  required Duration duration,
  int sampleRate = 16000,
  int channels = 1,
}) async {
  final d = duration < Duration.zero ? Duration.zero : duration;
  final frames = ((d.inMilliseconds * sampleRate) / 1000.0).floor();
  final blockAlign = channels * 2;
  final dataSize = frames * blockAlign;

  final outFile = File(destPath);
  outFile.parent.createSync(recursive: true);
  final out = outFile.openSync(mode: FileMode.write);
  try {
    final header = Uint8List(44);
    _writeAscii4(header, 0, 'RIFF');
    _writeU32le(header, 4, 36 + dataSize);
    _writeAscii4(header, 8, 'WAVE');
    _writeAscii4(header, 12, 'fmt ');
    _writeU32le(header, 16, 16);
    _writeU16le(header, 20, 1);
    _writeU16le(header, 22, channels);
    _writeU32le(header, 24, sampleRate);
    _writeU32le(header, 28, sampleRate * blockAlign);
    _writeU16le(header, 32, blockAlign);
    _writeU16le(header, 34, 16);
    _writeAscii4(header, 36, 'data');
    _writeU32le(header, 40, dataSize);
    out.writeFromSync(header);

    // write zeros
    final buf = Uint8List(64 * 1024);
    var remaining = dataSize;
    while (remaining > 0) {
      final n = math.min(buf.length, remaining);
      out.writeFromSync(buf, 0, n);
      remaining -= n;
    }
  } finally {
    out.closeSync();
  }
}

WavFileLayout? _readWavFileLayout(RandomAccessFile raf) {
  raf.setPositionSync(0);
  final riff = raf.readSync(12);
  if (riff.length < 12) return null;
  if (_ascii4(riff, 0) != 'RIFF' || _ascii4(riff, 8) != 'WAVE') return null;

  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  int? audioFormat;
  int? blockAlign;
  int? dataOffset;
  int? dataSize;

  while (raf.positionSync() + 8 <= raf.lengthSync()) {
    final hdr = raf.readSync(8);
    if (hdr.length < 8) break;
    final id = _ascii4(hdr, 0);
    final sz = _u32le(hdr, 4);
    final chunkStart = raf.positionSync();

    if (id == 'fmt ') {
      final fmt = raf.readSync(sz);
      if (fmt.length >= 16) {
        audioFormat = _u16le(fmt, 0);
        channels = _u16le(fmt, 2);
        sampleRate = _u32le(fmt, 4);
        blockAlign = _u16le(fmt, 12);
        bitsPerSample = _u16le(fmt, 14);
      }
    } else if (id == 'data') {
      dataOffset = raf.positionSync();
      dataSize = sz;
      raf.setPositionSync(chunkStart + sz);
    } else {
      raf.setPositionSync(chunkStart + sz);
    }

    if (sz.isOdd && raf.positionSync() < raf.lengthSync()) {
      raf.setPositionSync(raf.positionSync() + 1);
    }

    if (dataOffset != null &&
        dataSize != null &&
        channels != null &&
        sampleRate != null &&
        bitsPerSample != null &&
        audioFormat != null) {
      break;
    }
  }

  if (channels == null || channels <= 0) return null;
  if (sampleRate == null || sampleRate <= 0) return null;
  if (bitsPerSample == null || bitsPerSample <= 0) return null;
  if (audioFormat == null) return null;
  if (dataOffset == null || dataSize == null || dataSize <= 0) return null;

  var ba = blockAlign ?? 0;
  if (ba <= 0) {
    ba = channels * (bitsPerSample ~/ 8);
  }
  if (ba <= 0) return null;

  return WavFileLayout(
    audioFormat: audioFormat,
    channels: channels,
    sampleRate: sampleRate,
    bitsPerSample: bitsPerSample,
    blockAlign: ba,
    dataOffset: dataOffset,
    dataSize: dataSize,
  );
}

WavPcm16Info? _readWavPcm16Info(RandomAccessFile raf) {
  final layout = _readWavFileLayout(raf);
  if (layout == null) return null;
  if (layout.audioFormat != 1) return null;
  if (layout.bitsPerSample != 16) return null;
  return WavPcm16Info(
    channels: layout.channels,
    sampleRate: layout.sampleRate,
    dataOffset: layout.dataOffset,
    dataSize: layout.dataSize,
  );
}

String _ascii4(Uint8List b, int off) {
  return String.fromCharCodes([b[off], b[off + 1], b[off + 2], b[off + 3]]);
}

int _u16le(Uint8List b, int off) {
  return b[off] | (b[off + 1] << 8);
}

int _u32le(Uint8List b, int off) {
  return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
}

int _i16le(Uint8List b, int off) {
  final v = _u16le(b, off);
  return (v & 0x8000) != 0 ? v - 0x10000 : v;
}

void _writeAscii4(Uint8List b, int off, String s) {
  final codes = s.codeUnits;
  b[off] = codes[0];
  b[off + 1] = codes[1];
  b[off + 2] = codes[2];
  b[off + 3] = codes[3];
}

void _writeU16le(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
}

void _writeU32le(Uint8List b, int off, int v) {
  b[off] = v & 0xFF;
  b[off + 1] = (v >> 8) & 0xFF;
  b[off + 2] = (v >> 16) & 0xFF;
  b[off + 3] = (v >> 24) & 0xFF;
}

