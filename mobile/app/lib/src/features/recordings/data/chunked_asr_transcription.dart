import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/audio/ogg_opus_muxer.dart' show rawOpusToOggOpusSegments;
import '../../../core/server/server_exception.dart';
import '../../../core/audio/wav_waveform_extractor.dart'
    show readWavFileLayoutSync;
import '../../../core/server/api/asr_api.dart';
import '../../../core/server/api/user_api.dart';
import '../domain/recording.dart';

/// WAV longer than this (seconds) is transcribed in segments; segment length matches (30 minutes).
const int kAsrChunkDurationSeconds = 30 * 60;

/// Max attempts per segment (upload + ASR), including the first try.
const int kAsrChunkMaxAttempts = 3;

/// Base backoff delay in seconds for ordinary errors.
const int _kRetryBaseDelaySec = 5;

/// Some models/vendors prefix each segment with **Transcript:** etc.; strip one leading layer when merging chunks, not body text.
String _stripRedundantChunkTranscriptLabel(String text) {
  var s = text.trim();
  if (s.isEmpty) return s;

  final inlinePrefixes = <RegExp>[
    RegExp(r'^\*\*transcript\*\*\s*:\s*', caseSensitive: false),
    RegExp(r'^\*\*transcription\*\*\s*:\s*', caseSensitive: false),
    RegExp(r'^transcript\s*:\s*', caseSensitive: false),
    RegExp(r'^transcription\s*:\s*', caseSensitive: false),
    RegExp(r'^转写\s*[:：]\s*'),
  ];
  for (final re in inlinePrefixes) {
    final n = s.replaceFirst(re, '');
    if (n != s) {
      s = n.trim();
      break;
    }
  }

  final lines = s.split('\n');
  if (lines.length >= 2) {
    final first = lines.first.trim();
    if (RegExp(r'^transcript\s*:?\s*$', caseSensitive: false).hasMatch(first) ||
        RegExp(r'^transcription\s*:?\s*$', caseSensitive: false)
            .hasMatch(first) ||
        first == '转写' ||
        first == '转写:' ||
        first == '转写：') {
      s = lines.sublist(1).join('\n').trim();
    }
  }
  return s;
}

/// Merge chunked ASR: with speaker on and all chunks having speaker segments, align IDs across chunks; else join each chunk [displayText].
String _mergeChunkTranscriptOutputs({
  required bool autoSpeaker,
  required List<AsrRecognizeResult?> chunkResults,
  required List<String?> pieces,
  required String? textHint,
}) {
  if (autoSpeaker &&
      AsrRecognizeResult.canAlignChunkedSpeakerResults(chunkResults)) {
    return _stripRedundantChunkTranscriptLabel(
      AsrRecognizeResult.displayTextForAlignedChunks(
        chunkResults: chunkResults.map((e) => e!).toList(),
        chunkDurationMs: kAsrChunkDurationSeconds * 1000,
        languageHint: textHint,
      ),
    );
  }
  final merged = <String>[];
  for (final e in pieces) {
    if (e != null && e.trim().isNotEmpty) merged.add(e.trim());
  }
  return merged.join('\n\n');
}

/// Count of consecutive successful chunks from the start (`chunkResults[i]` all non-null).
int _contiguousCompletePrefixLength(List<AsrRecognizeResult?> chunkResults) {
  for (var i = 0; i < chunkResults.length; i++) {
    if (chunkResults[i] == null) return i;
  }
  return chunkResults.length;
}

String _mergeTranscriptForPrefixLength({
  required int prefixLen,
  required bool autoSpeaker,
  required List<AsrRecognizeResult?> chunkResults,
  required List<String?> pieces,
  required String? textHint,
}) {
  if (prefixLen <= 0) return '';
  return _mergeChunkTranscriptOutputs(
    autoSpeaker: autoSpeaker,
    chunkResults: chunkResults.sublist(0, prefixLen),
    pieces: pieces.sublist(0, prefixLen),
    textHint: textHint,
  );
}

String _describeChunkError(Object? error) {
  if (error == null) return '';
  if (error is ChunkedAsrException) {
    return error.message.trim();
  }
  if (error is ServerException) {
    final details = error.details?.trim() ?? '';
    if (details.isNotEmpty) return details;
    return error.message.trim();
  }
  return error.toString().trim();
}

bool _isRetryableChunkError(Object error) {
  if (error is ServerException) {
    final statusCode = error.statusCode ?? 0;
    if (statusCode >= 400 &&
        statusCode < 500 &&
        statusCode != 408 &&
        statusCode != 409 &&
        statusCode != 429) {
      return false;
    }
  }

  final msg = _describeChunkError(error).toLowerCase();
  const nonRetryableNeedles = <String>[
    'baidu asr err_no 3307',
    'insufficient_quota',
    'you exceeded your current quota',
    'quota has been exceeded',
    'invalid api key',
    'incorrect api key',
    'unauthorized',
    'forbidden',
    'vendor not configured',
    'not configured',
    'invalid app info',
    'speaker diarization requires',
  ];
  for (final needle in nonRetryableNeedles) {
    if (msg.contains(needle)) return false;
  }
  return true;
}

String _buildChunkFailureMessage({
  required List<int> failed,
  required int chunkCount,
  required List<Object?> chunkErrors,
}) {
  final reason = failed
      .map((i) => _describeChunkError(chunkErrors[i]))
      .firstWhere((msg) => msg.isNotEmpty, orElse: () => '');
  if (chunkCount <= 1 && failed.length == 1) {
    return reason.isEmpty ? '转写失败。' : '转写失败：$reason';
  }
  final detail = failed.map((i) => '${i + 1}/$chunkCount').join('、');
  if (reason.isEmpty) {
    return '分段转写未完成：$detail。已保存自开头连续成功的内容，请检查网络后重试。';
  }
  return '分段转写未完成：$detail。失败原因：$reason。已保存自开头连续成功的内容，请检查网络后重试。';
}

/// Total duration for chunking: prefer WAV header, else [Recording.durationSeconds].
int resolveTranscriptionDurationSeconds(Recording recording, String filePath) {
  final lower = filePath.toLowerCase();
  if (lower.endsWith('.wav')) {
    final layout = readWavFileLayoutSync(filePath);
    if (layout != null && layout.sampleRate > 0 && layout.totalFrames > 0) {
      final sec = (layout.totalFrames / layout.sampleRate).ceil();
      if (sec > 0) return sec;
    }
  }
  final d = recording.durationSeconds;
  if (d != null && d > 0) return d;
  return 0;
}

/// Whether to use multi-segment transcription (WAV only; enabled when duration > [kAsrChunkDurationSeconds]).
bool shouldChunkWavForAsr(String filePath, int durationSeconds) {
  if (durationSeconds <= kAsrChunkDurationSeconds) return false;
  return filePath.toLowerCase().endsWith('.wav');
}

/// Device **raw Opus** (not Ogg) longer than [kAsrChunkDurationSeconds] can use single-pass Opus → multi-segment WAV.
bool shouldSegmentRawOpusForAsr(int durationSeconds) {
  if (durationSeconds <= 0) return false;
  return durationSeconds > kAsrChunkDurationSeconds;
}

/// Waveform decode cache is shared with UI; copy the file to avoid FFmpeg read conflicts.
Future<File> _stableAsrSourceWav(File src) async {
  final path = src.path;
  final lower = path.toLowerCase();
  final inSharedCache = lower.contains('waveform_cache');
  if (!inSharedCache) return src;

  final tmpRoot = await getTemporaryDirectory();
  final dest = File(
    p.join(
        tmpRoot.path, 'asr_src_${DateTime.now().millisecondsSinceEpoch}.wav'),
  );
  await src.copy(dest.path);
  final len = await dest.length();
  if (len < 100) {
    try {
      await dest.delete();
    } catch (_) {}
    throw ChunkedAsrException('复制音频失败：文件过小。');
  }
  return dest;
}

void _assertWavReadableForAsr(String path) {
  final layout = readWavFileLayoutSync(path);
  if (layout == null) {
    throw ChunkedAsrException(
      '无法解析 WAV 文件头。若文件可播放，请反馈该录音来源格式。',
    );
  }
  final expectedMin = layout.dataOffset + layout.dataSize;
  final actual = File(path).lengthSync();
  if (actual + 8 < expectedMin) {
    throw ChunkedAsrException(
      '音频文件可能尚未解码完成或缓存不完整，请稍候再试转写。',
    );
  }
}

/// Encode WAV segment to Ogg/Opus to shrink upload size (~75%). On failure returns the original file.
Future<File> _compressSegmentToOpus(File wavFile) async {
  final opusPath = '${wavFile.path}.ogg';
  try {
    final cmd = '-nostdin -loglevel error -y -i "${wavFile.path}" '
        '-ac 1 -ar 16000 -c:a libopus -b:a 64k "$opusPath"';
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (rc != null && ReturnCode.isSuccess(rc)) {
      final out = File(opusPath);
      if (await out.exists() && await out.length() > 100) {
        return out;
      }
    }
  } catch (_) {}
  return wavFile;
}

// ---------------------------------------------------------------------------
// Sequential: each segment upload → create job → wait → fetch result → next.
// Avoids concurrent ASR load and processing conflicts; much more reliable than parallel.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Raw Opus → direct Ogg mux → upload + ASR (device recording path)
// ---------------------------------------------------------------------------

/// Device raw Opus: **single scan** mux into multiple Ogg/Opus files, then upload + ASR in parallel.
///
/// Unlike decode→WAV→FFmpeg→Ogg, this skips PCM decode/re-encode and only remuxes to Ogg (~20× faster).
Future<String> transcribeRawDeviceOpusInChunks({
  required String opusPath,
  required int totalDurationSeconds,
  required Recording recording,
  required int vendorId,
  required String? language,
  String? transcriptDisplayHint,
  required bool autoSpeaker,
  required int? asrResultId,
  required AsrApi asrApi,
  required UserApi userApi,
  required Future<void> Function(AsrJobItem job) onJobUpdate,
  required void Function(int completed, int total) onChunkProgress,
  void Function(int chunkIndex, int chunkCount, int sent, int total)?
      onUploadProgress,
  bool Function()? shouldAbort,
  void Function(double progress)? onDecodeProgress,
  Future<void> Function(String partialTranscript)? onPrefixTranscript,
}) async {
  final tmpRoot = await getTemporaryDirectory();
  final segDir = Directory(p.join(tmpRoot.path,
      'asr_raw_opus_${recording.id}_${DateTime.now().millisecondsSinceEpoch}'));
  await segDir.create(recursive: true);
  try {
    if (shouldAbort?.call() == true) {
      throw const TranscriptionAbortedException();
    }

    // Direct Ogg mux: skip decode→WAV→FFmpeg→Ogg round trip.
    final oggPaths = await rawOpusToOggOpusSegments(
      opusPath,
      segmentDurationSeconds: kAsrChunkDurationSeconds,
      totalDurationSeconds: totalDurationSeconds,
      outDirectoryPath: segDir.path,
      fileNamePrefix: '${recording.id}_rawopus',
      onProgress: onDecodeProgress,
      shouldAbort: shouldAbort,
    );

    if (oggPaths.isEmpty) {
      if (shouldAbort?.call() == true) {
        throw const TranscriptionAbortedException();
      }
      throw ChunkedAsrException('Raw Opus Ogg 封装未生成有效分段文件。');
    }

    final files = oggPaths.map((e) => File(e)).toList(growable: false);
    return await _transcribePrebuiltOggChunkFiles(
      segmentFiles: files,
      recording: recording,
      vendorId: vendorId,
      language: language,
      transcriptDisplayHint: transcriptDisplayHint,
      autoSpeaker: autoSpeaker,
      asrResultId: asrResultId,
      asrApi: asrApi,
      userApi: userApi,
      onJobUpdate: onJobUpdate,
      onChunkProgress: onChunkProgress,
      onUploadProgress: onUploadProgress,
      shouldAbort: shouldAbort,
      onPrefixTranscript: onPrefixTranscript,
    );
  } finally {
    try {
      if (await segDir.exists()) {
        await segDir.delete(recursive: true);
      }
    } catch (_) {}
  }
}

/// **Sequential** processing of existing Ogg/Opus segment files:
///   per segment: upload → create ASR job → wait → fetch result → next.
Future<String> _transcribePrebuiltOggChunkFiles({
  required List<File> segmentFiles,
  required Recording recording,
  required int vendorId,
  required String? language,
  String? transcriptDisplayHint,
  required bool autoSpeaker,
  required int? asrResultId,
  required AsrApi asrApi,
  required UserApi userApi,
  required Future<void> Function(AsrJobItem job) onJobUpdate,
  required void Function(int completed, int total) onChunkProgress,
  void Function(int chunkIndex, int chunkCount, int sent, int total)?
      onUploadProgress,
  bool Function()? shouldAbort,
  Future<void> Function(String partialTranscript)? onPrefixTranscript,
}) async {
  final chunkCount = segmentFiles.length;
  if (shouldAbort?.call() == true) {
    throw const TranscriptionAbortedException();
  }
  if (chunkCount <= 1 && segmentFiles.isNotEmpty) {
    return transcribeSingleUpload(
      fileToUpload: segmentFiles.first,
      recording: recording,
      vendorId: vendorId,
      language: language,
      transcriptDisplayHint: transcriptDisplayHint,
      autoSpeaker: autoSpeaker,
      asrResultId: asrResultId,
      asrApi: asrApi,
      userApi: userApi,
      onJobUpdate: onJobUpdate,
      onUploadProgress: onUploadProgress != null
          ? (sent, total) => onUploadProgress(0, 1, sent, total)
          : null,
      shouldAbort: shouldAbort,
    );
  }

  final pieces = List<String?>.filled(chunkCount, null);
  final chunkResults = List<AsrRecognizeResult?>.filled(chunkCount, null);
  final chunkErrors = List<Object?>.filled(chunkCount, null);
  final textHint = transcriptDisplayHint ?? language;
  var lastEmittedPrefixLen = 0;

  for (var i = 0; i < chunkCount; i++) {
    if (shouldAbort?.call() == true) {
      throw const TranscriptionAbortedException();
    }

    final segFile = segmentFiles[i];
    try {
      if (!await segFile.exists() || await segFile.length() < 100) {
        chunkErrors[i] = ChunkedAsrException('分段 Ogg 缺失或过小（索引 $i）。');
        onChunkProgress(i + 1, chunkCount);
        continue;
      }

      OssUploadResult? upload;
      Object? lastErr;

      for (var attempt = 1; attempt <= kAsrChunkMaxAttempts; attempt++) {
        if (shouldAbort?.call() == true) {
          throw const TranscriptionAbortedException();
        }
        try {
          upload ??= await userApi.uploadToOss(
            file: segFile,
            type: 'audio',
            onProgress: onUploadProgress != null
                ? (sent, total) => onUploadProgress(i, chunkCount, sent, total)
                : null,
          );
          if (shouldAbort?.call() == true) {
            throw const TranscriptionAbortedException();
          }

          final job = await asrApi.createJob(
            fileId: '${recording.id}:stt:$i',
            id: vendorId,
            url: upload.publicUrl,
            language: language,
            autoSpeaker: autoSpeaker,
            macAddress: recording.deviceId,
          );
          await onJobUpdate(job);

          final finished = await asrApi.waitJobUntilDone(
            job.id,
            onJobUpdate: onJobUpdate,
            initialStatus: job.status,
          );

          if (finished.isFailed) {
            lastErr = ChunkedAsrException(
              finished.errorMessage.trim().isEmpty
                  ? 'ASR job $i failed'
                  : finished.errorMessage,
            );
            if (!_isRetryableChunkError(lastErr) ||
                attempt >= kAsrChunkMaxAttempts) {
              break;
            }
            if (attempt < kAsrChunkMaxAttempts) {
              await Future<void>.delayed(
                Duration(seconds: _kRetryBaseDelaySec * attempt),
              );
            }
            continue;
          }

          final resultId = finished.asrResultId;
          if (resultId == null || resultId <= 0) {
            lastErr = ChunkedAsrException('ASR job $i finished without result');
            continue;
          }

          final result = await asrApi.getResultByIdWithRetry(resultId);
          chunkResults[i] = result;
          final piece = _stripRedundantChunkTranscriptLabel(
              result.displayText(languageHint: textHint));
          if (piece.isNotEmpty) pieces[i] = piece;
          break; // success
        } on TranscriptionAbortedException {
          rethrow;
        } catch (e) {
          lastErr = e;
          if (!_isRetryableChunkError(e) || attempt >= kAsrChunkMaxAttempts) {
            break;
          }
          if (attempt < kAsrChunkMaxAttempts) {
            await Future<void>.delayed(
              Duration(seconds: _kRetryBaseDelaySec * attempt),
            );
          }
        }
      }

      if (chunkResults[i] == null && lastErr != null) {
        chunkErrors[i] = lastErr;
      }
    } finally {
      try {
        if (await segFile.exists()) await segFile.delete();
      } catch (_) {}
    }

    onChunkProgress(i + 1, chunkCount);

    if (chunkResults[i] != null && onPrefixTranscript != null) {
      final prefixLen = _contiguousCompletePrefixLength(chunkResults);
      if (prefixLen > lastEmittedPrefixLen) {
        final text = _mergeTranscriptForPrefixLength(
          prefixLen: prefixLen,
          autoSpeaker: autoSpeaker,
          chunkResults: chunkResults,
          pieces: pieces,
          textHint: textHint,
        );
        lastEmittedPrefixLen = prefixLen;
        if (text.trim().isNotEmpty) {
          await onPrefixTranscript(text);
        }
      }
    }
  }

  final failed = <int>[];
  for (var i = 0; i < chunkCount; i++) {
    if (chunkResults[i] == null) failed.add(i);
  }
  if (failed.isNotEmpty) {
    throw ChunkedAsrException(
      _buildChunkFailureMessage(
        failed: failed,
        chunkCount: chunkCount,
        chunkErrors: chunkErrors,
      ),
      failedChunkIndices: failed,
    );
  }

  return _mergeChunkTranscriptOutputs(
    autoSpeaker: autoSpeaker,
    chunkResults: chunkResults,
    pieces: pieces,
    textHint: textHint,
  );
}

// ---------------------------------------------------------------------------
// WAV split + upload + ASR (source WAV path)
// ---------------------------------------------------------------------------

/// Split [srcWav] into fixed-duration segments; for each in order:
///   FFmpeg split + Opus encode → upload → create ASR job → wait → result → next.
Future<String> transcribeWavInChunks({
  required File srcWav,
  required int totalDurationSeconds,
  required Recording recording,
  required int vendorId,
  required String? language,
  String? transcriptDisplayHint,
  required bool autoSpeaker,
  required int? asrResultId,
  required AsrApi asrApi,
  required UserApi userApi,
  required Future<void> Function(AsrJobItem job) onJobUpdate,
  required void Function(int completed, int total) onChunkProgress,
  void Function(int chunkIndex, int chunkCount, int sent, int total)?
      onUploadProgress,
  bool Function()? shouldAbort,
  Future<void> Function(String partialTranscript)? onPrefixTranscript,
}) async {
  final stable = await _stableAsrSourceWav(srcWav);
  final File? copiedStable = stable.path != srcWav.path ? stable : null;

  try {
    _assertWavReadableForAsr(stable.path);
    if (shouldAbort?.call() == true) {
      throw const TranscriptionAbortedException();
    }

    var total = totalDurationSeconds;
    final layout = readWavFileLayoutSync(stable.path);
    if (layout != null && layout.sampleRate > 0 && layout.totalFrames > 0) {
      final fromFile = (layout.totalFrames / layout.sampleRate).ceil();
      if (fromFile > 0 && fromFile < total) {
        total = fromFile;
      }
    }

    final chunkCount = math.max(
        1, (total + kAsrChunkDurationSeconds - 1) ~/ kAsrChunkDurationSeconds);
    if (chunkCount <= 1) {
      return transcribeSingleUpload(
        fileToUpload: stable,
        recording: recording,
        vendorId: vendorId,
        language: language,
        transcriptDisplayHint: transcriptDisplayHint,
        autoSpeaker: autoSpeaker,
        asrResultId: asrResultId,
        asrApi: asrApi,
        userApi: userApi,
        onJobUpdate: onJobUpdate,
        shouldAbort: shouldAbort,
      );
    }
    final srcPath = stable.path;
    final tmpRoot = await getTemporaryDirectory();
    final segDir = Directory(p.join(tmpRoot.path, 'asr_wav_chunks'));
    if (!await segDir.exists()) {
      await segDir.create(recursive: true);
    }

    final pieces = List<String?>.filled(chunkCount, null);
    final chunkResults = List<AsrRecognizeResult?>.filled(chunkCount, null);
    final chunkErrors = List<Object?>.filled(chunkCount, null);
    final textHint = transcriptDisplayHint ?? language;
    var lastEmittedPrefixLen = 0;

    try {
      for (var i = 0; i < chunkCount; i++) {
        if (shouldAbort?.call() == true) {
          throw const TranscriptionAbortedException();
        }

        final startSec = i * kAsrChunkDurationSeconds;
        var lenSec = kAsrChunkDurationSeconds;
        if (startSec + lenSec > total) lenSec = total - startSec;

        if (lenSec <= 0) {
          chunkErrors[i] = ChunkedAsrException('分段时长无效（索引 $i）。');
          onChunkProgress(i + 1, chunkCount);
          continue;
        }

        final outPath = p.join(
          segDir.path,
          '${recording.id}_asr_${i}_${DateTime.now().millisecondsSinceEpoch}.ogg',
        );
        File? segFile;

        try {
          final String cmd;
          if (startSec <= 0) {
            cmd = '-nostdin -loglevel error -y -i "$srcPath" -t $lenSec '
                '-ac 1 -ar 16000 -c:a libopus -b:a 64k "$outPath"';
          } else {
            cmd =
                '-nostdin -loglevel error -y -ss $startSec -t $lenSec -i "$srcPath" '
                '-ac 1 -ar 16000 -c:a libopus -b:a 64k "$outPath"';
          }
          final session = await FFmpegKit.execute(cmd);
          final rc = await session.getReturnCode();
          if (rc == null || !ReturnCode.isSuccess(rc)) {
            final logs = await session.getAllLogsAsString() ?? '';
            chunkErrors[i] = ChunkedAsrException(
              'FFmpeg 分段 $i 失败${logs.isEmpty ? '' : ': $logs'}',
            );
            onChunkProgress(i + 1, chunkCount);
            continue;
          }

          segFile = File(outPath);
          if (!await segFile.exists() || await segFile.length() < 100) {
            chunkErrors[i] = ChunkedAsrException('分段文件缺失或过小（索引 $i）。');
            onChunkProgress(i + 1, chunkCount);
            continue;
          }

          OssUploadResult? upload;
          Object? lastErr;

          for (var attempt = 1; attempt <= kAsrChunkMaxAttempts; attempt++) {
            if (shouldAbort?.call() == true) {
              throw const TranscriptionAbortedException();
            }
            try {
              upload ??= await userApi.uploadToOss(
                file: segFile,
                type: 'audio',
                onProgress: onUploadProgress != null
                    ? (sent, total) =>
                        onUploadProgress(i, chunkCount, sent, total)
                    : null,
              );
              if (shouldAbort?.call() == true) {
                throw const TranscriptionAbortedException();
              }

              final job = await asrApi.createJob(
                fileId: '${recording.id}:stt:$i',
                id: vendorId,
                url: upload.publicUrl,
                language: language,
                autoSpeaker: autoSpeaker,
                macAddress: recording.deviceId,
              );
              await onJobUpdate(job);

              final finished = await asrApi.waitJobUntilDone(
                job.id,
                onJobUpdate: onJobUpdate,
                initialStatus: job.status,
              );

              if (finished.isFailed) {
                lastErr = ChunkedAsrException(
                  finished.errorMessage.trim().isEmpty
                      ? 'ASR job $i failed'
                      : finished.errorMessage,
                );
                if (!_isRetryableChunkError(lastErr) ||
                    attempt >= kAsrChunkMaxAttempts) {
                  break;
                }
                if (attempt < kAsrChunkMaxAttempts) {
                  await Future<void>.delayed(
                    Duration(seconds: _kRetryBaseDelaySec * attempt),
                  );
                }
                continue;
              }

              final resultId = finished.asrResultId;
              if (resultId == null || resultId <= 0) {
                lastErr =
                    ChunkedAsrException('ASR job $i finished without result');
                continue;
              }

              final result = await asrApi.getResultByIdWithRetry(resultId);
              chunkResults[i] = result;
              final piece = _stripRedundantChunkTranscriptLabel(
                  result.displayText(languageHint: textHint));
              if (piece.isNotEmpty) pieces[i] = piece;
              break; // success
            } on TranscriptionAbortedException {
              rethrow;
            } catch (e) {
              lastErr = e;
              if (!_isRetryableChunkError(e) ||
                  attempt >= kAsrChunkMaxAttempts) {
                break;
              }
              if (attempt < kAsrChunkMaxAttempts) {
                await Future<void>.delayed(
                  Duration(seconds: _kRetryBaseDelaySec * attempt),
                );
              }
            }
          }

          if (chunkResults[i] == null && lastErr != null) {
            chunkErrors[i] = lastErr;
          }
        } finally {
          if (segFile != null) {
            try {
              if (await segFile.exists()) await segFile.delete();
            } catch (_) {}
          }
        }

        onChunkProgress(i + 1, chunkCount);

        if (chunkResults[i] != null && onPrefixTranscript != null) {
          final prefixLen = _contiguousCompletePrefixLength(chunkResults);
          if (prefixLen > lastEmittedPrefixLen) {
            final text = _mergeTranscriptForPrefixLength(
              prefixLen: prefixLen,
              autoSpeaker: autoSpeaker,
              chunkResults: chunkResults,
              pieces: pieces,
              textHint: textHint,
            );
            lastEmittedPrefixLen = prefixLen;
            if (text.trim().isNotEmpty) {
              await onPrefixTranscript(text);
            }
          }
        }
      }
    } finally {
      try {
        if (await segDir.exists()) {
          await for (final e in segDir.list()) {
            try {
              if (e is File) await e.delete();
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    final failed = <int>[];
    for (var i = 0; i < chunkCount; i++) {
      if (chunkResults[i] == null) failed.add(i);
    }
    if (failed.isNotEmpty) {
      throw ChunkedAsrException(
        _buildChunkFailureMessage(
          failed: failed,
          chunkCount: chunkCount,
          chunkErrors: chunkErrors,
        ),
        failedChunkIndices: failed,
      );
    }

    return _mergeChunkTranscriptOutputs(
      autoSpeaker: autoSpeaker,
      chunkResults: chunkResults,
      pieces: pieces,
      textHint: textHint,
    );
  } finally {
    try {
      if (copiedStable != null && await copiedStable.exists()) {
        await copiedStable.delete();
      }
    } catch (_) {}
  }
}

/// Single upload + one ASR pass. Compress WAV → Opus before upload when possible.
Future<String> transcribeSingleUpload({
  required File fileToUpload,
  required Recording recording,
  required int vendorId,
  required String? language,
  String? transcriptDisplayHint,
  required bool autoSpeaker,
  required int? asrResultId,
  required AsrApi asrApi,
  required UserApi userApi,
  required Future<void> Function(AsrJobItem job) onJobUpdate,
  void Function(int sent, int total)? onUploadProgress,
  bool Function()? shouldAbort,
}) async {
  if (shouldAbort?.call() == true) {
    throw const TranscriptionAbortedException();
  }
  File actualFile = fileToUpload;
  final isWav = fileToUpload.path.toLowerCase().endsWith('.wav');
  if (isWav) {
    final compressed = await _compressSegmentToOpus(fileToUpload);
    if (compressed.path != fileToUpload.path) {
      actualFile = compressed;
    }
  }
  try {
    final upload = await userApi.uploadToOss(
      file: actualFile,
      type: 'audio',
      onProgress: onUploadProgress,
    );
    if (shouldAbort?.call() == true) {
      throw const TranscriptionAbortedException();
    }
    final r = await asrApi.recognizeUrl(
      fileId: recording.id,
      url: upload.publicUrl,
      id: vendorId,
      language: language,
      autoSpeaker: autoSpeaker,
      macAddress: recording.deviceId,
      asrResultId: asrResultId,
      onJobUpdate: onJobUpdate,
    );
    return r.displayText(languageHint: transcriptDisplayHint ?? language);
  } finally {
    if (actualFile.path != fileToUpload.path) {
      try {
        if (await actualFile.exists()) await actualFile.delete();
      } catch (_) {}
    }
  }
}

class ChunkedAsrException implements Exception {
  ChunkedAsrException(this.message, {this.failedChunkIndices});

  final String message;
  final List<int>? failedChunkIndices;

  @override
  String toString() => message;
}

/// User left detail page etc. and aborted transcription (not a business failure).
class TranscriptionAbortedException implements Exception {
  const TranscriptionAbortedException();
}
