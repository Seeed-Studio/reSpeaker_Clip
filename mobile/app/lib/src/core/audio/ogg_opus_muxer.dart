import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'raw_opus_utils.dart';

/// Mux device raw Opus (2-byte length-prefixed frames) into Ogg Opus without decode/re-encode.
/// ExoPlayer/just_audio can play Ogg Opus directly.
///
/// See RFC 7845 (Ogg Opus), RFC 3533 (Ogg framing).
///
/// **Streaming mux**: read frames from disk and page writes out to avoid `readAsBytes` + isolate copies that
/// spike memory (~2× file size) and jank the detail view on long takes.
/// Remux raw Opus to Ogg Opus.
///
/// When [maxDurationMs] is set, only the first N milliseconds of audio are
/// included — useful for fast-start playback of large recordings.
Future<String?> rawOpusToOggOpus(
  String srcPath, {
  String? outPath,
  int? maxDurationMs,
}) async {
  try {
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return null;
    final st = await srcFile.stat();
    if (st.size < 100) return null;

    String targetPath;
    if (outPath != null) {
      targetPath = outPath;
      await File(targetPath).parent.create(recursive: true);
    } else {
      final keyStr = maxDurationMs != null
          ? 'v8|$srcPath|${st.size}|${st.modified.millisecondsSinceEpoch}|head$maxDurationMs'
          : 'v8|$srcPath|${st.size}|${st.modified.millisecondsSinceEpoch}';
      final key = sha1.convert(utf8.encode(keyStr)).toString();
      final tmp = await getTemporaryDirectory();
      final outDir = Directory(p.join(tmp.path, 'ogg_opus_cache'));
      if (!await outDir.exists()) await outDir.create(recursive: true);
      targetPath = p.join(outDir.path, '$key.opus');
      if (await File(targetPath).exists()) return targetPath;
    }

    final maxGranules = maxDurationMs != null ? (maxDurationMs * 48) : null;
    final ok = await _streamMuxRawOpusToOgg(
      srcPath,
      targetPath,
      maxGranules: maxGranules,
    );
    if (!ok) {
      try {
        await File(targetPath).delete();
      } catch (_) {}
      return null;
    }
    return targetPath;
  } catch (e, st) {
    if (kDebugMode) debugPrint('[OggOpus] mux error: $e\n$st');
    return null;
  }
}

/// Scan file head for first plausible [2-byte LE len][frame] sync (same rules as legacy parser).
Future<int?> _findRawOpusSyncOffset(RandomAccessFile raf) async {
  await raf.setPosition(0);
  final header = await raf.read(200);
  if (header.length < 4) return null;
  var offset = 0;
  while (offset < 200 && offset + 2 <= header.length) {
    final frameLen =
        (header[offset] & 0xff) | ((header[offset + 1] & 0xff) << 8);
    if (frameLen >= kRawOpusMinFrameLen && frameLen <= kRawOpusMaxFrameLen) {
      return offset;
    }
    offset += 2;
  }
  return null;
}

/// Stream raw Opus frames to Ogg file; bounded memory (~tens of KB per page batch).
///
/// When [maxGranules] is set, stop after the cumulative granule position
/// reaches the limit (48 kHz granule rate: 1 ms = 48 granules).
Future<bool> _streamMuxRawOpusToOgg(
  String srcPath,
  String targetPath, {
  int? maxGranules,
}) async {
  RandomAccessFile? raf;
  IOSink? sink;
  try {
    raf = await File(srcPath).open(mode: FileMode.read);
    final syncOff = await _findRawOpusSyncOffset(raf);
    if (syncOff == null) return false;
    await raf.setPosition(syncOff);

    sink = File(targetPath).openWrite();

    // Opus ID + comment headers (identical to in-memory muxer)
    final idHeader = ByteData(19);
    idHeader.setUint8(0, 0x4F);
    idHeader.setUint8(1, 0x70);
    idHeader.setUint8(2, 0x75);
    idHeader.setUint8(3, 0x73);
    idHeader.setUint8(4, 0x48);
    idHeader.setUint8(5, 0x65);
    idHeader.setUint8(6, 0x61);
    idHeader.setUint8(7, 0x64);
    idHeader.setUint8(8, 1);
    idHeader.setUint8(9, 1);
    idHeader.setUint16(10, 312, Endian.little);
    idHeader.setUint32(12, 48000, Endian.little);
    idHeader.setUint16(16, 0, Endian.little);
    idHeader.setUint8(18, 0);

    final commentHeader = ByteData(16);
    commentHeader.setUint8(0, 0x4F);
    commentHeader.setUint8(1, 0x70);
    commentHeader.setUint8(2, 0x75);
    commentHeader.setUint8(3, 0x73);
    commentHeader.setUint8(4, 0x54);
    commentHeader.setUint8(5, 0x61);
    commentHeader.setUint8(6, 0x67);
    commentHeader.setUint8(7, 0x73);
    commentHeader.setUint32(8, 0, Endian.little);
    commentHeader.setUint32(12, 0, Endian.little);

    const serial = 0x12345678;
    var pageSeq = 0;

    void writePage(BytesBuilder bb) {
      sink!.add(bb.takeBytes());
    }

    var bb = BytesBuilder(copy: false);
    _appendOggPage(
      bb,
      data: idHeader.buffer.asUint8List(),
      flags: 0x02,
      granule: 0,
      serial: serial,
      pageSeq: pageSeq++,
    );
    writePage(bb);
    bb = BytesBuilder(copy: false);
    _appendOggPage(
      bb,
      data: commentHeader.buffer.asUint8List(),
      flags: 0,
      granule: 0,
      serial: serial,
      pageSeq: pageSeq++,
    );
    writePage(bb);

    const maxPageData = 65025; // 255 lacing values * 255 bytes
    final pageFrames = <Uint8List>[];
    var pageLacingCount = 0;
    var pageDataLen = 0;
    var cumulativeGranule = 0;
    var audioPageCount = 0;

    void flushAudioPage({required bool endStream}) {
      if (pageFrames.isEmpty) return;
      audioPageCount++;
      final data = _concatFrames(pageFrames);
      final segmentTable = _buildSegmentTable(pageFrames);
      pageFrames.clear();
      pageLacingCount = 0;
      pageDataLen = 0;
      final pageBb = BytesBuilder(copy: false);
      _appendOggPageWithSegments(
        pageBb,
        data: data,
        segmentTable: segmentTable,
        flags: endStream ? 0x04 : 0,
        granule: cumulativeGranule,
        serial: serial,
        pageSeq: pageSeq++,
      );
      sink!.add(pageBb.takeBytes());
    }

    // Buffered reading — read 256 KB at a time instead of per-frame, reducing
    // async I/O calls from millions to a few hundred for multi-hour files.
    const readChunkSize = 262144;
    final inFile = raf;
    final fileLen = await inFile.length();
    var filePos = syncOff;
    var slab = Uint8List(0);

    Future<void> refill() async {
      if (filePos >= fileLen) return;
      await inFile.setPosition(filePos);
      final n =
          fileLen - filePos < readChunkSize ? fileLen - filePos : readChunkSize;
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

    await refill();

    while (true) {
      // Ensure we have enough data in the buffer.
      while (slab.length < 2004 && filePos < fileLen) {
        await refill();
      }
      if (slab.length < 2) break;

      var o = 0;
      while (o + 2 <= slab.length) {
        final frameLen = (slab[o] & 0xff) | ((slab[o + 1] & 0xff) << 8);
        if (frameLen < kRawOpusMinFrameLen || frameLen > kRawOpusMaxFrameLen) {
          // Frame-boundary slip (e.g. between two concatenated part files):
          // resync to the next plausible length instead of aborting. Aborting
          // here silently drops every frame after the slip, which truncated
          // long recordings to a fraction of their real duration.
          var found = false;
          for (var s = 2; s < 400 && o + s + 2 <= slab.length; s += 2) {
            final nextLen =
                (slab[o + s] & 0xff) | ((slab[o + s + 1] & 0xff) << 8);
            if (nextLen >= kRawOpusMinFrameLen &&
                nextLen <= kRawOpusMaxFrameLen) {
              o += s;
              found = true;
              break;
            }
          }
          if (found) continue;
          if (o + 2 <= slab.length) {
            o += 2;
            continue;
          }
          break;
        }
        final need = 2 + frameLen;
        if (o + need > slab.length) break;

        final frame = Uint8List.sublistView(slab, o + 2, o + need);
        o += need;

        final frameLacingCount = _lacingValueCount(frame.length);
        final exceedsCurrentPage = pageFrames.isNotEmpty &&
            (pageLacingCount + frameLacingCount > 255 ||
                pageDataLen + frame.length > maxPageData);
        if (exceedsCurrentPage) {
          flushAudioPage(endStream: false);
        }

        pageFrames.add(Uint8List.fromList(frame));
        pageLacingCount += frameLacingCount;
        pageDataLen += frame.length;
        cumulativeGranule += _samplesFromToc(frame);

        if (pageLacingCount >= 255 || pageDataLen >= maxPageData) {
          flushAudioPage(endStream: false);
        }

        if (maxGranules != null && cumulativeGranule >= maxGranules) {
          break;
        }
      }

      final reachedLimit =
          maxGranules != null && cumulativeGranule >= maxGranules;

      if (o > 0) {
        slab = o < slab.length ? Uint8List.sublistView(slab, o) : Uint8List(0);
      }

      if (reachedLimit) break;

      // Invalid frame length or not enough data in slab — try refill.
      if (o == 0 && slab.isNotEmpty && filePos >= fileLen) break;
      if (filePos < fileLen) {
        await refill();
      } else if (slab.length < 2) {
        break;
      }
    }

    flushAudioPage(endStream: true);

    if (audioPageCount == 0) return false;

    await sink.flush();
    await sink.close();
    sink = null;
    await raf.close();
    raf = null;
    return true;
  } catch (e, st) {
    if (kDebugMode) debugPrint('[OggOpus] stream mux error: $e\n$st');
    return false;
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      await raf?.close();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// ASR segment mux: single pass raw Opus → multiple Ogg/Opus files, no decode/encode
// ---------------------------------------------------------------------------

/// Split a device raw Opus file into multiple Ogg/Opus segment files in **one read pass**.
///
/// No decode/encode: assign raw Opus frames to Ogg pages by time boundary only,
/// ~20× faster than decode→WAV→FFmpeg→Ogg.
///
/// Returns output paths (may be fewer than expected, e.g. very short source).
/// [segmentDurationSeconds] target segment length in seconds.
/// [totalDurationSeconds] total recording length for segment count estimate.
Future<List<String>> rawOpusToOggOpusSegments(
  String srcPath, {
  required int segmentDurationSeconds,
  required int totalDurationSeconds,
  required String outDirectoryPath,
  required String fileNamePrefix,
  void Function(double progress)? onProgress,
  bool Function()? shouldAbort,
}) async {
  final results = <String>[];
  RandomAccessFile? raf;
  try {
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return results;
    final st = await srcFile.stat();
    if (st.size < 100) return results;

    raf = await srcFile.open(mode: FileMode.read);
    final syncOff = await _findRawOpusSyncOffset(raf);
    if (syncOff == null) return results;
    await raf.setPosition(syncOff);

    final outDir = Directory(outDirectoryPath);
    if (!await outDir.exists()) await outDir.create(recursive: true);

    final fileLen = st.size;
    final segGranules = segmentDurationSeconds * 48000;
    final totalSec = totalDurationSeconds.clamp(1, 86400 * 7);
    final segSec = segmentDurationSeconds.clamp(1, 86400);
    final expectedChunks = (totalSec + segSec - 1) ~/ segSec;

    // Capture non-null ref for use in closures
    final inFile = raf;

    // Buffered read from source
    const readChunkSize = 262144;
    var filePos = syncOff;
    var slab = Uint8List(0);

    Future<void> refill() async {
      if (filePos >= fileLen) return;
      await inFile.setPosition(filePos);
      final n =
          fileLen - filePos < readChunkSize ? fileLen - filePos : readChunkSize;
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

    await refill();

    var segIndex = 0;
    var segGranulePos = 0;
    IOSink? sink;
    var pageSeq = 0;
    var audioPageCount = 0;
    final pageFrames = <Uint8List>[];
    var pageLacingCount = 0;
    var pageDataLen = 0;
    var aborted = false;
    var progressCounter = 0;
    var lastReportedProgress = -1.0;

    void reportProgress({
      required int processedBytes,
      bool force = false,
    }) {
      final progress = (processedBytes / fileLen).clamp(0.0, 0.99);
      if (!force && lastReportedProgress >= 0) {
        // Avoid chatty UI updates while still making large-file progress feel
        // continuous; ~0.4% step keeps the banner smooth on mobile.
        if ((progress - lastReportedProgress).abs() < 0.004) return;
      }
      lastReportedProgress = progress;
      onProgress?.call(progress);
    }

    void openNewSegment() {
      final outPath = p.join(
        outDirectoryPath,
        '${fileNamePrefix}_$segIndex.ogg',
      );
      sink = File(outPath).openWrite();
      results.add(outPath);
      pageSeq = 0;
      audioPageCount = 0;
      segGranulePos = 0;
      pageFrames.clear();

      // Write Ogg Opus headers
      final bb = BytesBuilder(copy: false);
      _appendOggPage(
        bb,
        data: _opusIdHeader(),
        flags: 0x02, // beginning of stream
        granule: 0,
        serial: 0x12345678 + segIndex,
        pageSeq: pageSeq++,
      );
      sink!.add(bb.takeBytes());

      final bb2 = BytesBuilder(copy: false);
      _appendOggPage(
        bb2,
        data: _opusCommentHeader(),
        flags: 0,
        granule: 0,
        serial: 0x12345678 + segIndex,
        pageSeq: pageSeq++,
      );
      sink!.add(bb2.takeBytes());
    }

    void flushAudioPage({required bool endStream}) {
      if (pageFrames.isEmpty || sink == null) return;
      audioPageCount++;
      final data = _concatFrames(pageFrames);
      final segmentTable = _buildSegmentTable(pageFrames);
      pageFrames.clear();
      pageLacingCount = 0;
      pageDataLen = 0;
      final pageBb = BytesBuilder(copy: false);
      _appendOggPageWithSegments(
        pageBb,
        data: data,
        segmentTable: segmentTable,
        flags: endStream ? 0x04 : 0,
        granule: segGranulePos,
        serial: 0x12345678 + segIndex,
        pageSeq: pageSeq++,
      );
      sink!.add(pageBb.takeBytes());
    }

    Future<void> closeSegment() async {
      flushAudioPage(endStream: true);
      if (sink != null) {
        await sink!.flush();
        await sink!.close();
        sink = null;
      }
      if (audioPageCount == 0 && results.isNotEmpty) {
        // Empty segment, remove it
        try {
          await File(results.removeLast()).delete();
        } catch (_) {}
      }
    }

    openNewSegment();

    while (true) {
      if (shouldAbort?.call() == true) {
        aborted = true;
        break;
      }

      while (slab.length < 2004 && filePos < fileLen) {
        await refill();
      }
      if (slab.length < 2) break;

      var o = 0;
      while (o + 2 <= slab.length && !aborted) {
        final frameLen = (slab[o] & 0xff) | ((slab[o + 1] & 0xff) << 8);
        if (frameLen < kRawOpusMinFrameLen || frameLen > kRawOpusMaxFrameLen) {
          // Resync past a frame-boundary slip rather than aborting (see
          // _streamMuxRawOpusToOgg): a single bad length otherwise drops all
          // remaining audio, shortening every ASR segment after the slip.
          var found = false;
          for (var s = 2; s < 400 && o + s + 2 <= slab.length; s += 2) {
            final nextLen =
                (slab[o + s] & 0xff) | ((slab[o + s + 1] & 0xff) << 8);
            if (nextLen >= kRawOpusMinFrameLen &&
                nextLen <= kRawOpusMaxFrameLen) {
              o += s;
              found = true;
              break;
            }
          }
          if (found) continue;
          if (o + 2 <= slab.length) {
            o += 2;
            continue;
          }
          break;
        }
        final need = 2 + frameLen;
        if (o + need > slab.length) break;

        final frame = Uint8List.sublistView(slab, o + 2, o + need);
        o += need;

        final samples = _samplesFromToc(frame);
        final frameLacingCount = _lacingValueCount(frame.length);
        final exceedsCurrentPage = pageFrames.isNotEmpty &&
            (pageLacingCount + frameLacingCount > 255 ||
                pageDataLen + frame.length > 65025);
        if (exceedsCurrentPage) {
          flushAudioPage(endStream: false);
        }

        pageFrames.add(Uint8List.fromList(frame));
        pageLacingCount += frameLacingCount;
        pageDataLen += frame.length;
        segGranulePos += samples;

        if (pageLacingCount >= 255 || pageDataLen >= 65025) {
          flushAudioPage(endStream: false);
        }

        // Check segment boundary
        if (segGranulePos >= segGranules && segIndex < expectedChunks - 1) {
          await closeSegment();
          segIndex++;
          openNewSegment();
        }

        progressCounter++;
        if (progressCounter >= 120) {
          progressCounter = 0;
          final processedBytes = (filePos - slab.length + o).clamp(0, fileLen);
          reportProgress(processedBytes: processedBytes);
          await Future<void>.delayed(Duration.zero);
          if (shouldAbort?.call() == true) {
            aborted = true;
            break;
          }
        }
      }

      if (aborted) break;

      if (o > 0) {
        slab = o < slab.length ? Uint8List.sublistView(slab, o) : Uint8List(0);
      }

      if (o == 0 && slab.isNotEmpty && filePos >= fileLen) break;
      if (filePos < fileLen) {
        await refill();
      } else if (slab.length < 2) {
        break;
      }
    }

    await closeSegment();

    if (aborted) {
      for (final path in results) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      results.clear();
      return results;
    }

    reportProgress(processedBytes: fileLen, force: true);
    onProgress?.call(1.0);
    return results;
  } catch (e, stackTrace) {
    if (kDebugMode) {
      debugPrint('[OggOpus] segmented mux error: $e\n$stackTrace');
    }
    return results;
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

Uint8List _opusIdHeader() {
  final h = ByteData(19);
  h.setUint8(0, 0x4F); // 'OpusHead'
  h.setUint8(1, 0x70);
  h.setUint8(2, 0x75);
  h.setUint8(3, 0x73);
  h.setUint8(4, 0x48);
  h.setUint8(5, 0x65);
  h.setUint8(6, 0x61);
  h.setUint8(7, 0x64);
  h.setUint8(8, 1); // version
  h.setUint8(9, 1); // channel count
  h.setUint16(10, 312, Endian.little); // pre-skip
  h.setUint32(12, 48000, Endian.little); // input sample rate
  h.setUint16(16, 0, Endian.little); // output gain
  h.setUint8(18, 0); // channel mapping family
  return h.buffer.asUint8List();
}

Uint8List _opusCommentHeader() {
  final h = ByteData(16);
  h.setUint8(0, 0x4F); // 'OpusTags'
  h.setUint8(1, 0x70);
  h.setUint8(2, 0x75);
  h.setUint8(3, 0x73);
  h.setUint8(4, 0x54);
  h.setUint8(5, 0x61);
  h.setUint8(6, 0x67);
  h.setUint8(7, 0x73);
  h.setUint32(8, 0, Endian.little); // vendor string length
  h.setUint32(12, 0, Endian.little); // user comment count
  return h.buffer.asUint8List();
}

/// Parse Opus TOC first byte to packet duration in samples @ 48 kHz.
/// Firmware uses 20 ms / 16 kHz frames; we fix 20 ms = 960 samples @ 48 kHz, matching sync.py.
int _samplesFromToc(Uint8List frame) {
  return 960;
}

Uint8List _concatFrames(List<Uint8List> frames) {
  final total = frames.fold<int>(0, (s, f) => s + f.length);
  final out = Uint8List(total);
  var pos = 0;
  for (final f in frames) {
    out.setRange(pos, pos + f.length, f);
    pos += f.length;
  }
  return out;
}

List<int> _buildSegmentTable(List<Uint8List> frames) {
  final table = <int>[];
  for (final f in frames) {
    var remaining = f.length;
    while (remaining > 255) {
      table.add(255);
      remaining -= 255;
    }
    table.add(remaining);
  }
  return table;
}

int _lacingValueCount(int packetLength) => (packetLength + 254) ~/ 255;

void _appendOggPage(
  BytesBuilder buf, {
  required Uint8List data,
  required int flags,
  required int granule,
  required int serial,
  required int pageSeq,
}) {
  final segmentTable = _buildSegmentTable([data]);
  _appendOggPageWithSegments(
    buf,
    data: data,
    segmentTable: segmentTable,
    flags: flags,
    granule: granule,
    serial: serial,
    pageSeq: pageSeq,
  );
}

void _appendOggPageWithSegments(
  BytesBuilder buf, {
  required Uint8List data,
  required List<int> segmentTable,
  required int flags,
  required int granule,
  required int serial,
  required int pageSeq,
}) {
  final headerLen = 27 + segmentTable.length;
  final header = ByteData(headerLen);
  header.setUint8(0, 0x4F); // 'O'
  header.setUint8(1, 0x67); // 'g'
  header.setUint8(2, 0x67); // 'g'
  header.setUint8(3, 0x53); // 'S'
  header.setUint8(4, 0);
  header.setUint8(5, flags);
  header.setUint32(6, granule & 0xffffffff, Endian.little);
  header.setUint32(10, (granule >> 32) & 0xffffffff, Endian.little);
  header.setUint32(14, serial, Endian.little);
  header.setUint32(18, pageSeq, Endian.little);
  header.setUint32(22, 0); // CRC placeholder
  header.setUint8(26, segmentTable.length);
  for (var i = 0; i < segmentTable.length; i++) {
    header.setUint8(27 + i, segmentTable[i]);
  }

  final headerBytes = header.buffer.asUint8List(0, headerLen);
  final pageForCrc = Uint8List(headerLen + data.length);
  pageForCrc.setRange(0, headerLen, headerBytes);
  pageForCrc.setRange(headerLen, headerLen + data.length, data);
  final crc = _oggCrc32(pageForCrc);
  header.setUint32(22, crc, Endian.little);

  buf.add(header.buffer.asUint8List(0, headerLen));
  buf.add(data);
}

/// Ogg CRC32: poly 0x04c11db7, init 0, final XOR 0 (not the same as zlib).
///
/// Dart ints are 64-bit; every shift/XOR must be masked to 32 bits,
/// otherwise upper bits corrupt the 0x80000000 check and the table entries.
final _oggCrc32Table = List<int>.generate(256, (i) {
  const poly = 0x04c11db7;
  var v = i << 24;
  for (var j = 0; j < 8; j++) {
    final top = v & 0x80000000;
    v = (v << 1) & 0xffffffff;
    if (top != 0) v ^= poly;
  }
  return v;
});

int _oggCrc32(Uint8List data) {
  var crc = 0;
  for (var i = 0; i < data.length; i++) {
    crc = ((crc << 8) ^ _oggCrc32Table[((crc >> 24) ^ data[i]) & 0xff]) &
        0xffffffff;
  }
  return crc;
}
