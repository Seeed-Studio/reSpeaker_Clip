import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/api/asr_api.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/server/server_providers.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../ai_config/domain/stt_config.dart';
import '../../ai_config/domain/asr_vendor_config.dart';
import '../../ai_config/presentation/ai_config_providers.dart';
import '../../../core/audio/audio_waveform_peaks.dart'
    show decodeAudioToWavForPlayback, isLikelyRawOpusPath;
import '../../../core/audio/raw_opus_decoder.dart' show decodeRawOpusToWav;
import '../data/chunked_asr_transcription.dart'
    show
        ChunkedAsrException,
        TranscriptionAbortedException,
        resolveTranscriptionDurationSeconds,
        shouldChunkWavForAsr,
        shouldSegmentRawOpusForAsr,
        transcribeRawDeviceOpusInChunks,
        transcribeSingleUpload,
        transcribeWavInChunks;
import '../data/recordings_repository.dart';
import '../domain/recording.dart';
import 'recordings_controller.dart';
import 'transcribe_common.dart';

void _refreshRecordingUi(dynamic ref, String recordingId) {
  ref.invalidate(recordingByIdProvider(recordingId));
  bumpRecordingsLists(ref);
}

void _logTranscriptIfDebug(String? text) {
  if (text == null || !kDebugMode) return;
  final total = text.length;
  debugPrint('[ASR] transcript_len=$total');
  const chunk = 800;
  for (var i = 0; i < total; i += chunk) {
    final end = (i + chunk < total) ? i + chunk : total;
    debugPrint(
      '[ASR] transcript_chunk ${i + 1}-$end: ${text.substring(i, end)}',
    );
  }
}

bool _uiMounted(BuildContext? uiContext) =>
    uiContext != null && uiContext.mounted;

/// Full local-audio → transcript path used by detail page and batch transcribe.
/// Returns non-null transcript text on success (already persisted). Returns null
/// if aborted, failed, or user dismissed gateway retry.
///
/// Caller must ensure transfer is complete ([Recording.transferState] == `done`) and
/// [Recording.recordingState] is idle, then call [RecordingsRepository.ensureAsrResultId]
/// and set job state to `queued` before invoking this.
///
/// Does not abort when [uiContext] unmounts — use [shouldAbort] for explicit cancel.
Future<String?> runRecordingTranscriptionPipeline({
  required dynamic ref,
  required AppLocalizations l10n,
  required Locale locale,
  BuildContext? uiContext,
  required Recording recording,
  required int asrResultId,
  required TranscribeSheetSelection selection,
  ValueNotifier<String>? progressMessage,
  bool Function()? shouldAbort,
  bool allowGatewayTimeoutRetry = true,
  Future<void> Function()? onGatewayTimeoutRetry,
}) async {
  final repo = await ref.read(recordingsRepositoryProvider.future);

  Future<void> failJob(String state) async {
    await repo.updateJobState(recording.id, state);
    _refreshRecordingUi(ref, recording.id);
  }

  final p = recording.localPath;
  if (p == null || p.trim().isEmpty) {
    if (_uiMounted(uiContext)) {
      await AppDialogs.showErrorDialog(
        uiContext!,
        title: l10n.errorTitle,
        message: l10n.localAudioMissing,
        confirmText: l10n.confirm,
      );
    }
    await failJob('failed');
    return null;
  }
  final f = File(p);
  if (!await f.exists()) {
    if (_uiMounted(uiContext)) {
      await AppDialogs.showErrorDialog(
        uiContext!,
        title: l10n.errorTitle,
        message: l10n.localAudioMissing,
        confirmText: l10n.confirm,
      );
    }
    await failJob('failed');
    return null;
  }

  final langRes = resolvedTranscribeLanguage(selection.language, locale);
  final userApi = ref.read(userApiProvider);
  final asrApi = ref.read(asrApiProvider);
  List<SttConfig> availableSttConfigs;
  try {
    availableSttConfigs = await ref.read(sttConfigsProvider.future);
  } catch (_) {
    availableSttConfigs = const <SttConfig>[];
  }
  final resolvedStt =
      resolveSttExecution(selection, availableSttConfigs, l10n, locale);
  final activeStt = resolvedStt.config;
  final vendorId = activeStt?.asrRemoteVendorId;
  if (vendorId == null) {
    if (_uiMounted(uiContext)) {
      await AppDialogs.showErrorDialog(
        uiContext!,
        title: l10n.errorTitle,
        message: l10n.asrVendorIdNotConfigured,
        confirmText: l10n.confirm,
      );
    }
    await failJob('failed');
    return null;
  }

  String? transcript;
  try {
    if (_uiMounted(uiContext) && resolvedStt.notice != null) {
      ScaffoldMessenger.of(uiContext!).showSnackBar(
        SnackBar(content: Text(resolvedStt.notice!)),
      );
    }
    File fileToUpload = f;
    final lowerPath = p.toLowerCase();
    final isOpusPath = lowerPath.endsWith('.opus');
    var preferChunkProgressBanner = false;
    var chunkProgressCompleted = 0;
    var chunkProgressTotal = 0;

    void setChunkProgressBanner(int completed, int total) {
      chunkProgressCompleted = completed;
      chunkProgressTotal = total;
      if (progressMessage == null) return;
      progressMessage.value = l10n.transcribingChunkProgress(
        completed.clamp(0, total),
        total,
      );
    }

    Future<void> onAsrJobUpdate(AsrJobItem job) async {
      final nextState = switch (job.status) {
        'pending' => 'queued',
        'running' => 'transcribing',
        'failed' => 'failed',
        'succeeded' => 'transcribing',
        _ => 'transcribing',
      };
      if (progressMessage != null) {
        if (preferChunkProgressBanner && chunkProgressTotal > 0) {
          setChunkProgressBanner(
            chunkProgressCompleted,
            chunkProgressTotal,
          );
        } else {
          progressMessage.value = switch (job.status) {
            'pending' => l10n.statusQueued,
            'running' => l10n.transcribing,
            'failed' => l10n.statusFailed,
            'succeeded' => l10n.transcribing,
            _ => l10n.transcribing,
          };
        }
      }
      await repo.updateJobState(
        recording.id,
        nextState,
        sttJobId: job.id.toString(),
      );
      _refreshRecordingUi(ref, recording.id);
    }

    Future<void> onChunkPrefixTranscript(String text) async {
      await repo.updateTranscript(recording.id, text);
      _refreshRecordingUi(ref, recording.id);
    }

    if (isOpusPath && await isLikelyRawOpusPath(p)) {
      final durOpus = resolveTranscriptionDurationSeconds(recording, p);
      if (kDebugMode) {
        debugPrint(
          '[ASR] branch raw opus '
          'recordingId=${recording.id} path=$p '
          'durOpus=$durOpus chunkThreshold=$kAsrChunkThresholdSeconds '
          'shouldSegment=${shouldSegmentRawOpusForAsr(durOpus)}',
        );
      }
      if (shouldSegmentRawOpusForAsr(durOpus)) {
        preferChunkProgressBanner = true;
        chunkProgressTotal = ((durOpus + kAsrChunkThresholdSeconds - 1) ~/
                kAsrChunkThresholdSeconds)
            .clamp(1, 1 << 20);
        setChunkProgressBanner(0, chunkProgressTotal);
        try {
          transcript = await transcribeRawDeviceOpusInChunks(
            opusPath: p,
            totalDurationSeconds: durOpus,
            recording: recording,
            vendorId: vendorId,
            language: langRes.apiLanguage,
            transcriptDisplayHint: langRes.displayHint,
            autoSpeaker: resolvedStt.autoSpeaker,
            asrResultId: asrResultId,
            asrApi: asrApi,
            userApi: userApi,
            onJobUpdate: onAsrJobUpdate,
            onDecodeProgress: (progress) {
              if (progressMessage == null) return;
              final pct = (progress * 100).round().clamp(0, 100);
              progressMessage.value = l10n.preparingAudioForTranscription(
                progress >= 1.0 ? 100 : pct,
              );
            },
            onChunkProgress: (cur, tot) {
              setChunkProgressBanner(cur, tot);
            },
            onPrefixTranscript: onChunkPrefixTranscript,
            shouldAbort: shouldAbort,
          );
        } on TranscriptionAbortedException {
          rethrow;
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '[ASR] raw opus chunk path failed, fallback to wav '
              'recordingId=${recording.id} error=$e',
            );
          }
          final wavPath = await decodeAudioToWavForPlayback(
            p,
            sampleRate: 16000,
          );
          if (wavPath != null) {
            final wavFile = File(wavPath);
            if (await wavFile.exists()) fileToUpload = wavFile;
          }
          transcript = null;
        }
      } else {
        if (kDebugMode) {
          debugPrint(
            '[ASR] raw opus skipped chunking, decode to wav '
            'recordingId=${recording.id} path=$p durOpus=$durOpus',
          );
        }
        final wavPath = await decodeRawOpusToWav(
          p,
          sampleRate: 16000,
          channels: 1,
        );
        if (wavPath != null) {
          final wavFile = File(wavPath);
          if (await wavFile.exists()) fileToUpload = wavFile;
        }
      }
    } else if (isOpusPath) {
      if (kDebugMode) {
        debugPrint(
          '[ASR] branch non-raw opus decode to wav '
          'recordingId=${recording.id} path=$p',
        );
      }
      final wavPath = await decodeAudioToWavForPlayback(
        p,
        sampleRate: 16000,
      );
      if (wavPath != null) {
        final wavFile = File(wavPath);
        if (await wavFile.exists()) fileToUpload = wavFile;
      }
    }

    if (transcript == null) {
      final durSec =
          resolveTranscriptionDurationSeconds(recording, fileToUpload.path);
      final useChunks = shouldChunkWavForAsr(fileToUpload.path, durSec);
      if (kDebugMode) {
        debugPrint(
          '[ASR] final upload decision '
          'recordingId=${recording.id} uploadPath=${fileToUpload.path} '
          'durSec=$durSec '
          'isWav=${fileToUpload.path.toLowerCase().endsWith('.wav')} '
          'useChunks=$useChunks vendorId=$vendorId',
        );
      }

      if (useChunks) {
        preferChunkProgressBanner = true;
        chunkProgressTotal = ((durSec + kAsrChunkThresholdSeconds - 1) ~/
                kAsrChunkThresholdSeconds)
            .clamp(1, 1 << 20);
        setChunkProgressBanner(0, chunkProgressTotal);
        transcript = await transcribeWavInChunks(
          srcWav: fileToUpload,
          totalDurationSeconds: durSec,
          recording: recording,
          vendorId: vendorId,
          language: langRes.apiLanguage,
          transcriptDisplayHint: langRes.displayHint,
          autoSpeaker: resolvedStt.autoSpeaker,
          asrResultId: asrResultId,
          asrApi: asrApi,
          userApi: userApi,
          onJobUpdate: onAsrJobUpdate,
          onChunkProgress: (cur, tot) {
            setChunkProgressBanner(cur, tot);
          },
          onPrefixTranscript: onChunkPrefixTranscript,
          shouldAbort: shouldAbort,
        );
      } else {
        if (kDebugMode) {
          debugPrint(
            '[ASR] transcribe single upload '
            'recordingId=${recording.id} uploadPath=${fileToUpload.path} '
            'vendorId=$vendorId',
          );
        }
        transcript = await transcribeSingleUpload(
          fileToUpload: fileToUpload,
          recording: recording,
          vendorId: vendorId,
          language: langRes.apiLanguage,
          transcriptDisplayHint: langRes.displayHint,
          autoSpeaker: resolvedStt.autoSpeaker,
          asrResultId: asrResultId,
          asrApi: asrApi,
          userApi: userApi,
          onJobUpdate: onAsrJobUpdate,
          shouldAbort: shouldAbort,
        );
      }
    }
    _logTranscriptIfDebug(transcript);
  } on TranscriptionAbortedException {
    await failJob('none');
    return null;
  } catch (e) {
    if (_uiMounted(uiContext)) {
      final ctx = uiContext!;
      final isGatewayTimeout =
          e is ServerException && (e.statusCode == 504 || e.statusCode == 502);
      final msg = (e is ServerException && e.statusCode == 413)
          ? l10n.uploadFileTooLarge413
          : isGatewayTimeout
              ? l10n.transcriptionGatewayTimeout
              : e is ChunkedAsrException
                  ? l10n.transcriptionFailed(e.message)
                  : l10n.transcriptionFailed(
                      serverErrorDialogMessage(ctx, e),
                    );
      if (isGatewayTimeout && allowGatewayTimeoutRetry) {
        final retry = await AppDialogs.showConfirm(
          ctx,
          title: l10n.errorTitle,
          message: msg,
          cancelText: l10n.cancel,
          confirmText: l10n.transcriptionGatewayTimeoutRetry,
        );
        if (retry && ctx.mounted && onGatewayTimeoutRetry != null) {
          await onGatewayTimeoutRetry();
        }
      } else {
        await AppDialogs.showErrorDialog(
          ctx,
          title: l10n.errorTitle,
          message: msg,
          confirmText: l10n.confirm,
        );
      }
    }
    await failJob('failed');
    return null;
  }

  await repo.updateTranscript(recording.id, transcript);
  _refreshRecordingUi(ref, recording.id);
  return transcript;
}
