import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_overlay_tap_dismiss.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../../core/log/app_log.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_providers.dart';
import '../../../core/server/server_exception.dart';
import '../../ai_config/presentation/ai_config_providers.dart';
import '../../ai_config/domain/llm_config.dart';
import '../../ai_config/domain/llm_vendor_config.dart';
import '../../ai_config/domain/prompt_template.dart';
import '../../ai_config/domain/stt_config.dart';
import '../../llm_sessions/domain/llm_session.dart';
import '../../llm_sessions/domain/llm_session_message.dart';
import '../../llm_sessions/data/llm_session_remote_repository.dart';
import '../../device/presentation/device_controller.dart';
import '../data/recordings_repository.dart';
import '../domain/folder.dart';
import '../domain/recording.dart';
import '../domain/recording_summary.dart';
import '../utils/content_utils.dart'
    show
        isErrorLikeContent,
        summaryFirstSentenceFromText,
        summaryHistoryDisplayTitle;
import '../utils/recording_export_text.dart';
import 'recordings_controller.dart';
import 'folders_providers.dart';
import 'transfer_sync_ui.dart';
import 'widgets/recording_player.dart';
import 'widgets/recording_share_sheet.dart';
import '../../../core/audio/audio_waveform_peaks.dart'
    show
        PreparedPlaybackAudio,
        decodeAudioToWavForPlayback,
        invalidateDecodedWavCache,
        isLikelyRawOpusPath,
        logWaveformPeaksDebug,
        prepareAudioForPlayback,
        prepareHeadAudioForPlayback,
        WaveformPeaksRequest,
        WaveformPeaksResult;
import '../../../core/audio/playback_opus_hints.dart';
import 'ai_data_sharing_consent.dart';
import 'transcribe_common.dart';
import 'transcription_task_controller.dart';

class RecordingDetailPage extends ConsumerStatefulWidget {
  final String recordingId;
  const RecordingDetailPage({super.key, required this.recordingId});

  @override
  ConsumerState<RecordingDetailPage> createState() =>
      _RecordingDetailPageState();
}

class _RecordingDetailPageState extends ConsumerState<RecordingDetailPage> {
  // Persists across page instances: once Ogg playback fails on a device,
  // all subsequent detail pages skip Ogg and go straight to WAV.
  // iOS always true because AVPlayer has no Ogg Opus support.
  static bool _sOggOpusFailed = Platform.isIOS;

  int _tab = 0; // 0 source, 1 note
  int _noteSyncToken = 0;
  RecordingPlayerController? _playerCtrl;
  String? _markersPath;
  List<RecordingMarker> _markers = const [];
  bool _busyAi = false;
  int _aiBusyRef = 0;

  void _retainAiBusy() {
    _aiBusyRef++;
    _busyAi = true;
    if (mounted) setState(() {});
  }

  void _releaseAiBusy() {
    if (_aiBusyRef <= 0) return;
    _aiBusyRef--;
    _busyAi = _aiBusyRef > 0;
    if (mounted) setState(() {});
  }

  static bool _isActiveAiJobState(String jobState) {
    switch (jobState.trim()) {
      case 'queued':
      case 'transcribing':
      case 'summarizing':
        return true;
      default:
        return false;
    }
  }

  /// True while transcribe/summarize runs on this page or in the background controller.
  bool _isAiWorkInProgress(Recording recording) {
    if (_busyAi || _streamingSummaryActive) return true;
    if (ref.read(transcriptionTaskControllerProvider).isActive(recording.id)) {
      return true;
    }
    return _isActiveAiJobState(recording.jobState);
  }

  /// Non-blocking top progress label for summarize-only (transcribe uses [transcriptionTaskControllerProvider]).
  ValueNotifier<String>? _transcribeProgressBanner;

  /// Bridges global transcription progress into detail-page ValueListenable widgets.
  ValueNotifier<String>? _backgroundTranscribeProgress;

  void _tearDownTranscribeBanner() {
    final n = _transcribeProgressBanner;
    if (n == null) return;
    _transcribeProgressBanner = null;
    n.dispose();
  }

  void _syncBackgroundTranscribeBanner(String message) {
    if (message.trim().isEmpty) return;
    _backgroundTranscribeProgress ??= ValueNotifier<String>(message);
    if (_backgroundTranscribeProgress!.value != message) {
      _backgroundTranscribeProgress!.value = message;
    }
  }

  void _clearBackgroundTranscribeBanner() {
    final n = _backgroundTranscribeProgress;
    if (n == null) return;
    _backgroundTranscribeProgress = null;
    n.dispose();
  }

  String? _streamingSummary;
  String? _streamingSummaryRecordingId;
  bool _streamingSummaryActive = false;
  String? _latestServerSessionId;
  String? _lastSummaryText;
  int? _lastGeneratedAssistantMessageId;
  String _lastLanguage = 'Auto';

  // Real audio playback (Plaud-like behavior).
  AudioPlayer? _audio;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerException>? _errSub;
  RecordingPlayerAdapter? _audioAdapter;
  String? _boundAudioPath;
  bool _preferRealAudio =
      false; // if we have a localPath, prefer real sound (disable demo).
  bool _bindingAudio = false;

  /// File exists on disk but decode/player bind failed (distinct from "path missing" copy).
  bool _localFileInvalid = false;
  bool _preferWavForDeviceOpus = _sOggOpusFailed;

  /// Recovery attempts for ExoPlayer source errors (incl. UnrecognizedInputFormat) on the same recording, to avoid infinite loops.
  String? _opusRecoveryPathTracked;
  int _opusPlaybackRecoveryAttempts = 0;

  /// After bind failure or player dispose, throttle decode retries per frame; after expiry [ _ensureAudioBound ] may retry.
  DateTime? _audioBindDebounceUntil;

  /// Set after decode/setFilePath error to drop the "preparing playback" placeholder instead of spinning forever.
  bool _lastPlaybackBindFailed = false;
  // Async file-existence cache to avoid synchronous I/O in build().
  String? _localExistsPath;
  bool _localExistsResult = false;
  bool _localExistsChecking = false; // true while the async check is in-flight

  // ---------------------------------------------------------------------------
  // Fast-start playback for large raw Opus files.
  //
  // General concept: the player always has a "current file boundary" — the
  // duration of the currently loaded (possibly truncated) file.  When the
  // boundary is non-null, position monitoring triggers a rebind to the next
  // available longer file, giving a seamless progressive-playback experience.
  //
  //  head (10 min)  ──▶  medium (1 h)  ──▶  full file
  //       ↑ play immediately    ↑ ready in seconds     ↑ ready in tens of sec
  // ---------------------------------------------------------------------------
  static const _kFastStartThresholdBytes = 3 * 1024 * 1024; // ~15 min Opus
  static const _kHeadDurationSeconds = 20 * 60;
  static const _kMediumDurationSeconds = 60 * 60; // 1 hour
  String? _fullPrepOriginalPath;
  String? _pendingFullAudioPath;

  /// Non-null when the current player file is truncated. Position monitoring
  /// will trigger a rebind when approaching this boundary.
  Duration? _currentFileBoundary;

  /// Boundary of [_pendingFullAudioPath] — null means it covers the full file.
  Duration? _pendingFileBoundary;
  bool _rebindingToFull = false;
  bool _waitingForFullFile = false;
  bool _wasPlayingAtHeadEnd = false;
  Duration? _pendingSeekAfterRebind;

  /// True while the background audio prep (fast-start) is still running.
  /// Kept for playback UX / status text only; waveform subscription no longer
  /// waits on it because long recordings could otherwise never start building
  /// peaks until playback prep fully settles.
  bool _fastStartPrepInProgress = false;
  bool _fullPrepPreferWav = false;

  /// Defer subscribing to [waveformPeaksProvider] so just_audio can bind first
  /// (less jank on WAV fallback / large files).
  Timer? _waveformDeferTimer;
  String? _waveformDeferScheduledFor;
  String? _waveformGatePath;
  String? _stableWaveformPath;
  WaveformPeaksResult? _stableWaveformResult;
  double _lastPublishedWaveformFraction = -1.0;
  String? _waveformUiLogKey;

  WaveformPeaksResult? _resolveStableWaveformResult(
    String? path,
    WaveformPeaksResult? liveResult,
  ) {
    final normalizedPath = path?.trim();
    if (normalizedPath == null || normalizedPath.isEmpty) {
      return liveResult;
    }
    WaveformPeaksResult? resolved;
    var fromStable = false;
    if (liveResult != null && liveResult.peaks.isNotEmpty) {
      final frac = liveResult.parsedFraction;
      final shouldPublish = frac >= 1.0 ||
          _stableWaveformPath != normalizedPath ||
          _stableWaveformResult == null ||
          frac - _lastPublishedWaveformFraction >= 0.08;
      if (shouldPublish) {
        _stableWaveformPath = normalizedPath;
        _stableWaveformResult = liveResult;
        _lastPublishedWaveformFraction = frac;
      }
      resolved = _stableWaveformPath == normalizedPath
          ? _stableWaveformResult
          : liveResult;
    } else if (_stableWaveformPath == normalizedPath) {
      resolved = _stableWaveformResult;
      fromStable = true;
    } else {
      resolved = null;
    }
    _maybeLogWaveformUi(
      path: normalizedPath,
      result: resolved,
      fromStable: fromStable,
      liveEmpty: liveResult == null || liveResult.peaks.isEmpty,
    );
    return resolved;
  }

  void _maybeLogWaveformUi({
    required String path,
    required WaveformPeaksResult? result,
    required bool fromStable,
    required bool liveEmpty,
  }) {
    if (!kDebugMode) return;
    final peaksLen = result?.peaks.length ?? 0;
    final frac = result?.parsedFraction;
    final key =
        '$path|$peaksLen|${frac?.toStringAsFixed(3) ?? '-'}|$fromStable|$liveEmpty';
    if (key == _waveformUiLogKey) return;
    _waveformUiLogKey = key;
    debugPrint(
      '[Waveform] detail ui path=$path peaks=$peaksLen '
      'frac=${frac?.toStringAsFixed(3) ?? '-'} '
      'fromStable=$fromStable liveEmpty=$liveEmpty',
    );
    if (result != null && result.peaks.isNotEmpty) {
      logWaveformPeaksDebug(
        'detail-ui',
        peaks: result.peaks,
        parsedFraction: frac,
      );
    }
  }

  @override
  void dispose() {
    _tearDownTranscribeBanner();
    _clearBackgroundTranscribeBanner();
    _waveformDeferTimer?.cancel();
    final ctrl = _playerCtrl;
    _playerCtrl = null;
    _disposeAudio(clearBoundPath: true);
    ctrl?.dispose();
    super.dispose();
  }

  void _disposeAudio({required bool clearBoundPath}) {
    _posSub?.cancel();
    _posSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _durSub?.cancel();
    _durSub = null;
    _errSub?.cancel();
    _errSub = null;

    final adapter = _audioAdapter;
    if (adapter != null) {
      _playerCtrl?.detachAdapter(adapter);
    }
    _audioAdapter = null;

    _audio?.dispose();
    _audio = null;
    if (clearBoundPath) _boundAudioPath = null;

    _currentFileBoundary = null;
    _pendingFileBoundary = null;
    _fullPrepOriginalPath = null;
    _pendingFullAudioPath = null;
    _rebindingToFull = false;
    _waitingForFullFile = false;
    _wasPlayingAtHeadEnd = false;
    _pendingSeekAfterRebind = null;
    _fastStartPrepInProgress = false;
  }

  // ---------------------------------------------------------------------------
  // Fast-start: two-phase playback helpers
  // ---------------------------------------------------------------------------

  /// Try to bind a short head audio and kick off background full-file prep.
  /// Returns true on success; false means caller should fall through.
  Future<bool> _tryBindHeadPhase(
    String originalPath, {
    required bool preferWav,
    required bool isOpusOrCaf,
  }) async {
    // Kick off medium prep in parallel with head prep so it's ready sooner.
    // For a 9.5 h recording, even a 20 min head is only 3.5% of the progress
    // bar — users will seek past it quickly.
    final mediumFuture = prepareHeadAudioForPlayback(
      originalPath,
      headSeconds: _kMediumDurationSeconds,
      preferWav: preferWav,
    );

    final prepared = await prepareHeadAudioForPlayback(
      originalPath,
      headSeconds: _kHeadDurationSeconds,
      preferWav: preferWav,
    );
    if (prepared == null) return false;

    final player = AudioPlayer();
    _audio = player;

    try {
      await player.setFilePath(prepared.path);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[RecordingDetail] head setFilePath failed: $e');
      }
      await player.dispose();
      _audio = null;
      // Ogg head failed — retry with WAV head.
      if (prepared.isRemuxedOgg && !preferWav) {
        // Ogg failed; restart medium prep with WAV too.
        final wavMediumFuture = prepareHeadAudioForPlayback(
          originalPath,
          headSeconds: _kMediumDurationSeconds,
          preferWav: true,
        );
        final wavHead = await prepareHeadAudioForPlayback(
          originalPath,
          headSeconds: _kHeadDurationSeconds,
          preferWav: true,
        );
        if (wavHead != null) {
          final player2 = AudioPlayer();
          _audio = player2;
          try {
            await player2.setFilePath(wavHead.path);
          } catch (_) {
            await player2.dispose();
            _audio = null;
            return false;
          }
          PlaybackOpusHints.forcePreferWavOverOgg();
          _sOggOpusFailed = true;
          _preferWavForDeviceOpus = true;
          return _finishHeadBind(
            player2,
            originalPath,
            wavHead.path,
            preferWav: true,
            isOpusOrCaf: isOpusOrCaf,
            earlyMediumFuture: wavMediumFuture,
          );
        }
      }
      return false;
    }

    return _finishHeadBind(
      player,
      originalPath,
      prepared.path,
      preferWav: preferWav,
      isOpusOrCaf: isOpusOrCaf,
      earlyMediumFuture: mediumFuture,
    );
  }

  Future<bool> _finishHeadBind(
    AudioPlayer player,
    String originalPath,
    String headPath, {
    required bool preferWav,
    required bool isOpusOrCaf,
    Future<PreparedPlaybackAudio?>? earlyMediumFuture,
  }) async {
    _fullPrepOriginalPath = originalPath;
    _pendingFullAudioPath = null;
    _pendingFileBoundary = null;
    _waitingForFullFile = false;
    _rebindingToFull = false;
    _wasPlayingAtHeadEnd = false;
    _pendingSeekAfterRebind = null;
    _fastStartPrepInProgress = true;

    final headBound =
        player.duration ?? Duration(seconds: _kHeadDurationSeconds);
    _currentFileBoundary = headBound;
    if (kDebugMode) {
      debugPrint('[RecordingDetail] headBound=${headBound.inSeconds}s '
          'playerDur=${player.duration?.inSeconds}s '
          'kHead=${_kHeadDurationSeconds}s');
    }

    final innerAdapter = _JustAudioAdapter(player);
    final adapter = _HeadPhaseAdapter(
      innerAdapter,
      headDuration: headBound,
      onSeekBeyondHead: (target) => _onSeekBeyondBoundary(target, player),
    );
    _audioAdapter = adapter;

    // Ignore the head file's duration — the controller keeps the metadata
    // duration so the UI shows the full recording length.
    _durSub = player.durationStream.listen((_) {});

    _posSub = player.positionStream.listen((pos) {
      if (!mounted || _waitingForFullFile) return;
      final c = _playerCtrl;
      if (c == null) return;
      c.beginAdapterUpdate();
      c.setPositionFromAdapter(pos);
      c.endAdapterUpdate();
      _checkBoundaryProactive(player, pos);
    });

    _stateSub = player.playerStateStream.listen((st) {
      if (!mounted) return;
      final c = _playerCtrl;
      if (c == null) return;
      _handleBoundaryCompletion(st, player, c);
    });

    // On playback error (e.g. Ogg on Huawei) fall back to single-phase WAV.
    if (isOpusOrCaf) {
      _errSub = player.errorStream.listen((_) {
        _errSub?.cancel();
        _errSub = null;
        _disposeAudio(clearBoundPath: false);
        PlaybackOpusHints.forcePreferWavOverOgg();
        _sOggOpusFailed = true;
        if (mounted) {
          setState(() => _preferWavForDeviceOpus = true);
        }
        _boundAudioPath = null;
        _bindingAudio = false;
        if (mounted) _bindJustAudio(originalPath);
      });
    }

    if (!mounted || _playerCtrl == null) {
      await player.dispose();
      if (identical(_audio, player)) _audio = null;
      _audioAdapter = null;
      _currentFileBoundary = null;
      _bindingAudio = false;
      return false;
    }

    _playerCtrl!.attachAdapter(adapter);
    _audioBindDebounceUntil = null;
    _bindingAudio = false;

    _startFullFilePreparation(
      originalPath,
      preferWav: preferWav,
      earlyMediumFuture: earlyMediumFuture,
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Unified boundary monitoring helpers (used by both head bind & rebinds)
  // ---------------------------------------------------------------------------

  /// Called when the user tries to seek past the current file boundary.
  void _onSeekBeyondBoundary(Duration target, AudioPlayer player) {
    _pendingSeekAfterRebind = target;
    _wasPlayingAtHeadEnd = _playerCtrl?.isPlaying ?? false;

    player.pause();
    final c = _playerCtrl;
    if (c != null) {
      c.beginAdapterUpdate();
      c.setPlayingFromAdapter(false);
      c.setPositionFromAdapter(target);
      c.endAdapterUpdate();
    }

    // Only rebind if the pending file actually covers the target position.
    // E.g. seeking to 1:23 with only a 1-hour medium file → wait for full.
    final pendingBoundary = _pendingFileBoundary;
    final pendingCovers = _pendingFullAudioPath != null &&
        (pendingBoundary == null || target <= pendingBoundary);

    if (pendingCovers) {
      _rebindToFullAudio();
    } else {
      final adapter = _audioAdapter;
      if (adapter is _HeadPhaseAdapter) adapter.blocked = true;
      _waitingForFullFile = true;
      if (mounted) setState(() {});
      if (kDebugMode) {
        debugPrint(
            '[RecordingDetail] seek ${target.inSeconds}s beyond coverage '
            '(pending boundary=${pendingBoundary?.inSeconds}s) — waiting');
      }
      _startTargetedPrep(target);
    }
  }

  /// Prepare a segment that covers [target] + buffer so the user doesn't
  /// wait for the entire file to be decoded (critical for WAV-only devices).
  void _startTargetedPrep(Duration target) {
    final originalPath = _fullPrepOriginalPath;
    if (originalPath == null) return;
    if (_pendingFileBoundary == null) return; // full file already pending
    final neededSeconds = target.inSeconds + 20 * 60; // + 20 min buffer
    if (kDebugMode) {
      debugPrint(
          '[RecordingDetail] starting targeted prep for ${neededSeconds}s');
    }
    () async {
      try {
        final ext = await prepareHeadAudioForPlayback(
          originalPath,
          headSeconds: neededSeconds,
          preferWav: _fullPrepPreferWav,
        );
        if (!mounted || _fullPrepOriginalPath != originalPath) return;
        if (ext == null) return;
        // Only update if this provides better coverage than current pending.
        final curBoundary = _pendingFileBoundary;
        if (curBoundary == null) return; // full file already ready
        if (neededSeconds <= curBoundary.inSeconds) return;
        _pendingFullAudioPath = ext.path;
        _pendingFileBoundary = Duration(seconds: neededSeconds);
        if (kDebugMode) {
          debugPrint('[RecordingDetail] targeted prep ${neededSeconds}s ready');
        }
        _triggerRebindIfNeeded('targeted ${neededSeconds}s');
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[RecordingDetail] targeted prep failed: $e');
        }
      }
    }();
  }

  /// Proactively rebind when position approaches the current boundary.
  void _checkBoundaryProactive(AudioPlayer player, Duration pos) {
    final boundary = _currentFileBoundary;
    if (boundary == null || _rebindingToFull) return;
    if (_pendingFullAudioPath == null) return;
    if (pos >= boundary - const Duration(seconds: 5)) {
      _wasPlayingAtHeadEnd = player.playing;
      _rebindToFullAudio();
    }
  }

  /// Handle player completion — if we're in a bounded phase, try to rebind
  /// to the next available file instead of stopping.
  void _handleBoundaryCompletion(
    PlayerState st,
    AudioPlayer player,
    RecordingPlayerController c,
  ) {
    if (st.processingState == ProcessingState.completed &&
        _currentFileBoundary != null) {
      _wasPlayingAtHeadEnd = true;
      if (_pendingFullAudioPath != null) {
        _rebindToFullAudio();
      } else {
        c.beginAdapterUpdate();
        c.setPlayingFromAdapter(false);
        c.endAdapterUpdate();
        final adapter = _audioAdapter;
        if (adapter is _HeadPhaseAdapter) adapter.blocked = true;
        _waitingForFullFile = true;
        if (mounted) setState(() {});
      }
      return;
    }

    c.beginAdapterUpdate();
    if (st.processingState == ProcessingState.completed) {
      c.setPlayingFromAdapter(false);
      final dur = player.duration ?? c.duration;
      if (dur > Duration.zero) c.setPositionFromAdapter(dur);
    } else {
      c.setPlayingFromAdapter(st.playing);
    }
    c.endAdapterUpdate();
  }

  /// Progressive background preparation:
  ///   1. Await the medium version (1 hour) — started in parallel with head
  ///   2. Prepare the full file — may take longer for WAV decode
  ///
  /// Each step updates [_pendingFullAudioPath] and triggers a rebind if the
  /// player is already waiting.  When the medium version is bound, boundary
  /// monitoring continues so the full file seamlessly takes over later.
  void _startFullFilePreparation(
    String originalPath, {
    required bool preferWav,
    Future<PreparedPlaybackAudio?>? earlyMediumFuture,
  }) {
    _fullPrepPreferWav = preferWav;
    () async {
      try {
        final sw = Stopwatch()..start();
        if (kDebugMode) {
          debugPrint(
              '[RecordingDetail] progressive prep started (preferWav=$preferWav)');
        }

        // --- Step 1: medium version (1 hour) — reuse the early future
        // started in _tryBindHeadPhase so it runs in parallel with head prep.
        final medium = await (earlyMediumFuture ??
            prepareHeadAudioForPlayback(
              originalPath,
              headSeconds: _kMediumDurationSeconds,
              preferWav: preferWav,
            ));
        if (kDebugMode) {
          debugPrint(
              '[RecordingDetail] medium prep (${_kMediumDurationSeconds}s) '
              'done in ${sw.elapsedMilliseconds}ms');
        }
        if (!mounted || _fullPrepOriginalPath != originalPath) return;
        if (medium != null) {
          _pendingFullAudioPath = medium.path;
          _pendingFileBoundary = Duration(seconds: _kMediumDurationSeconds);
          _triggerRebindIfNeeded('medium');
        }

        // Ungate waveform extraction after medium prep — the heavy decode
        // is done, so the event loop has more room for peak extraction.
        if (_fastStartPrepInProgress) {
          _fastStartPrepInProgress = false;
          if (mounted) setState(() {});
        }

        // --- Step 2: full file --------------------------------------------
        final full = await prepareAudioForPlayback(
          originalPath,
          preferWav: preferWav,
        );
        if (kDebugMode) {
          debugPrint(
              '[RecordingDetail] full file prep done in ${sw.elapsedMilliseconds}ms');
        }
        if (!mounted || _fullPrepOriginalPath != originalPath) return;
        if (full == null) return;

        _pendingFullAudioPath = full.path;
        _pendingFileBoundary = null; // full — no boundary
        _triggerRebindIfNeeded('full');
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[RecordingDetail] progressive prep failed: $e');
        }
        if (_fastStartPrepInProgress) {
          _fastStartPrepInProgress = false;
          if (mounted) setState(() {});
        }
      }
    }();
  }

  /// Trigger a rebind if the player is waiting at its boundary, or if the
  /// currently loaded file still has a boundary (upgrade proactively).
  void _triggerRebindIfNeeded(String tag) {
    if (_waitingForFullFile) {
      // Only rebind if this file can actually cover the pending seek target.
      final seekTarget = _pendingSeekAfterRebind;
      final boundary = _pendingFileBoundary;
      if (seekTarget != null && boundary != null && seekTarget > boundary) {
        if (kDebugMode) {
          debugPrint(
              '[RecordingDetail] $tag ready but seek ${seekTarget.inSeconds}s '
              'exceeds boundary ${boundary.inSeconds}s — still waiting');
        }
        return;
      }

      _waitingForFullFile = false;
      // Unblock the adapter so controls resume.
      final adapter = _audioAdapter;
      if (adapter is _HeadPhaseAdapter) adapter.blocked = false;

      if (mounted) setState(() {});
      if (kDebugMode) {
        debugPrint('[RecordingDetail] was waiting — rebinding to $tag');
      }
      _rebindToFullAudio();
    } else if (_currentFileBoundary != null && !_rebindingToFull) {
      if (kDebugMode) {
        debugPrint('[RecordingDetail] $tag ready, will rebind at boundary');
      }
    }
  }

  Future<void> _rebindToFullAudio() async {
    if (_rebindingToFull || !mounted) return;
    final nextPath = _pendingFullAudioPath;
    if (nextPath == null) return;

    _rebindingToFull = true;

    final nextBoundary = _pendingFileBoundary; // null ⇒ full file
    final seekTarget =
        _pendingSeekAfterRebind ?? _playerCtrl?.position ?? Duration.zero;
    _pendingSeekAfterRebind = null;
    final wasPlaying =
        _wasPlayingAtHeadEnd || (_playerCtrl?.isPlaying ?? false);
    _wasPlayingAtHeadEnd = false;

    if (kDebugMode) {
      debugPrint('[RecordingDetail] rebinding → '
          '${nextBoundary != null ? "${nextBoundary.inSeconds}s partial" : "full"} '
          'seek=$seekTarget wasPlaying=$wasPlaying');
    }

    // Tear down current player.
    _posSub?.cancel();
    _posSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _durSub?.cancel();
    _durSub = null;
    _errSub?.cancel();
    _errSub = null;
    final oldAdapter = _audioAdapter;
    if (oldAdapter != null) _playerCtrl?.detachAdapter(oldAdapter);
    _audioAdapter = null;
    final oldPlayer = _audio;
    _audio = null;

    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      final player = AudioPlayer();
      _audio = player;

      await player.setFilePath(nextPath);

      // Seek BEFORE subscribing to position/state streams.
      // This prevents the position stream from emitting 0:00 (the new
      // player's initial position) and overwriting the target position,
      // which would cause the waveform active/inactive split to flash.
      await player.seek(seekTarget);

      _currentFileBoundary = nextBoundary;

      if (nextBoundary != null) {
        // --- Partial file: suppress reported duration, monitor boundary ----
        _durSub = player.durationStream.listen((_) {});

        final innerAdapter = _JustAudioAdapter(player);
        final adapter = _HeadPhaseAdapter(
          innerAdapter,
          headDuration: nextBoundary,
          onSeekBeyondHead: (target) => _onSeekBeyondBoundary(target, player),
        );
        _audioAdapter = adapter;

        _posSub = player.positionStream.listen((pos) {
          if (!mounted || _waitingForFullFile) return;
          final c = _playerCtrl;
          if (c == null) return;
          c.beginAdapterUpdate();
          c.setPositionFromAdapter(pos);
          c.endAdapterUpdate();
          _checkBoundaryProactive(player, pos);
        });

        _stateSub = player.playerStateStream.listen((st) {
          if (!mounted) return;
          final c = _playerCtrl;
          if (c == null) return;
          _handleBoundaryCompletion(st, player, c);
        });

        if (!mounted || _playerCtrl == null) {
          await player.dispose();
          if (identical(_audio, player)) _audio = null;
          _audioAdapter = null;
          _currentFileBoundary = null;
          _rebindingToFull = false;
          return;
        }
        _playerCtrl!.attachAdapter(adapter);
      } else {
        // --- Full file: normal setup, no boundary -------------------------
        void onDuration(Duration? d) {
          if (d == null || !mounted) return;
          _playerCtrl?.setDurationFromAdapter(d);
          _syncDurationToDbIfNeeded(d.inSeconds);
        }

        final d0 = player.duration;
        if (d0 != null) onDuration(d0);
        _durSub = player.durationStream.listen(onDuration);

        _posSub = player.positionStream.listen((pos) {
          if (!mounted) return;
          final c = _playerCtrl;
          if (c == null) return;
          c.beginAdapterUpdate();
          c.setPositionFromAdapter(pos);
          c.endAdapterUpdate();
        });

        _stateSub = player.playerStateStream.listen((st) {
          if (!mounted) return;
          final c = _playerCtrl;
          if (c == null) return;
          c.beginAdapterUpdate();
          if (st.processingState == ProcessingState.completed) {
            c.setPlayingFromAdapter(false);
            final dur = player.duration ?? c.duration;
            if (dur > Duration.zero) c.setPositionFromAdapter(dur);
          } else {
            c.setPlayingFromAdapter(st.playing);
          }
          c.endAdapterUpdate();
        });

        final adapter = _JustAudioAdapter(player);
        _audioAdapter = adapter;

        if (!mounted || _playerCtrl == null) {
          await player.dispose();
          if (identical(_audio, player)) _audio = null;
          _audioAdapter = null;
          _rebindingToFull = false;
          return;
        }
        _playerCtrl!.attachAdapter(adapter);
      }

      if (wasPlaying) {
        await player.play();
      }

      await oldPlayer?.dispose();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[RecordingDetail] rebind failed: $e');
      }
      if (_audio == null && oldPlayer != null) {
        _audio = oldPlayer;
      } else {
        await oldPlayer?.dispose();
      }
    } finally {
      _rebindingToFull = false;
    }
  }

  /// Keep [RecordingPlayerController] aligned with DB metadata. The controller
  /// is created once (`??=`), so without this, opening detail right after STOP
  /// can stick at 0:00 until audio bind resolves duration.
  void _syncPlayerDurationFromRecording(int? durationSeconds) {
    final sec = durationSeconds ?? 0;
    final meta = Duration(seconds: sec.clamp(0, 999999));
    _playerCtrl ??= RecordingPlayerController(duration: meta);
    if (sec <= 0) return;
    final current = _playerCtrl!.duration;
    // Head/partial playback intentionally ignores clip duration — prefer the
    // full recording length from metadata when the player is still unknown.
    if (current <= Duration.zero || meta > current) {
      _playerCtrl!.setDuration(meta);
    }
  }

  Future<void> _syncDurationToDbIfNeeded(int actualSeconds) async {
    if (actualSeconds <= 0) return;
    try {
      final repo = await ref.read(recordingsRepositoryProvider.future);
      final rec = await repo.getById(widget.recordingId);
      if (rec == null) return;
      final dbSec = rec.durationSeconds ?? 0;
      if (dbSec == actualSeconds) return;
      if (dbSec > 0 && actualSeconds < dbSec) return;
      await repo.updateDeviceRecordingMeta(
          id: widget.recordingId, durationSeconds: actualSeconds);
      if (!mounted) return;
      ref.invalidate(recordingByIdProvider(widget.recordingId));
      bumpRecordingsLists(ref);
    } catch (_) {}
  }

  Future<List<RecordingMarker>> _loadBookmarksForPath(String localPath) async {
    final dir = p.dirname(localPath);
    final base = p.basenameWithoutExtension(localPath);
    final path = p.join(dir, '${base}_bookmarks.json');
    final file = File(path);
    if (!await file.exists()) return const [];
    final content = await file.readAsString();
    final decoded = jsonDecode(content);
    if (decoded is! List) return const [];
    final markers = <RecordingMarker>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final offsetRaw = m['offset'];
      final offsetSec = offsetRaw is int
          ? offsetRaw
          : (offsetRaw is num
              ? offsetRaw.toInt()
              : int.tryParse(offsetRaw?.toString() ?? '') ?? 0);
      if (offsetSec < 0) continue;
      final note = (m['note'] ?? '').toString().trim();
      markers.add(RecordingMarker(
        position: Duration(seconds: offsetSec),
        label: note.isEmpty ? null : note,
      ));
    }
    markers.sort((a, b) => a.position.compareTo(b.position));
    return markers;
  }

  void _ensureAudioBound(String? localPath) {
    final p = localPath?.trim();
    if (p == null || p.isEmpty) {
      _localFileInvalid = false;
      if (_preferRealAudio) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_preferRealAudio) setState(() => _preferRealAudio = false);
        });
      }
      if (_audio != null) _disposeAudio(clearBoundPath: true);
      _bindingAudio = false;
      return;
    }

    // Prefer real audio if we have a path (even before load finishes).
    if (!_preferRealAudio) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_preferRealAudio) setState(() => _preferRealAudio = true);
      });
    }

    if (_bindingAudio) return;
    // Skip only when just_audio was created and attached. If we only "reserve" path but _audio is null (bind error /
    // errorStream recovery exhausted), allow retry or waveform decodes while audio never plays.
    if (p == _boundAudioPath && _audio != null) return;
    if (p == _boundAudioPath &&
        _audio == null &&
        _audioBindDebounceUntil != null &&
        DateTime.now().isBefore(_audioBindDebounceUntil!)) {
      return;
    }
    if (p != _boundAudioPath) {
      _audioBindDebounceUntil = null;
      _lastPlaybackBindFailed = false;
      _localFileInvalid = false;
    }

    _bindingAudio = true;
    _boundAudioPath = p;

    // Defer heavy work until after build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bindJustAudio(p);
    });
  }

  Future<void> _bindJustAudio(String path) async {
    _lastPlaybackBindFailed = false;
    _localFileInvalid = false;
    try {
      final f = File(path);
      if (!await f.exists()) {
        if (mounted) {
          setState(() => _preferRealAudio = false);
        }
        _bindingAudio = false;
        return;
      }

      if (_opusRecoveryPathTracked != path) {
        _opusRecoveryPathTracked = path;
        _opusPlaybackRecoveryAttempts = 0;
      }

      // Recreate player when switching audio sources.
      _disposeAudio(clearBoundPath: false);

      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      final isOpusOrCaf = path.toLowerCase().endsWith('.opus') ||
          path.toLowerCase().endsWith('.caf');
      final looksRawOpus = path.toLowerCase().endsWith('.opus') &&
          await isLikelyRawOpusPath(path);

      await PlaybackOpusHints.ensureInitialized();
      final preferWav =
          _preferWavForDeviceOpus || PlaybackOpusHints.skipOggRemux;

      // --- Fast-start for large raw Opus files ---
      if (looksRawOpus && isOpusOrCaf) {
        final srcSize = await File(path).length();
        if (srcSize > _kFastStartThresholdBytes) {
          final headOk = await _tryBindHeadPhase(
            path,
            preferWav: preferWav,
            isOpusOrCaf: isOpusOrCaf,
          );
          if (headOk) return;
          // Head preparation failed — fall through to regular single-phase binding.
        }
      }

      final player = AudioPlayer();
      _audio = player;

      final adapter = _JustAudioAdapter(player);
      _audioAdapter = adapter;
      var boundPlayableIsOgg = false;

      if (preferWav && isOpusOrCaf) {
        // Ogg already failed on this device — skip straight to WAV decode.
        final wav = await decodeAudioToWavForPlayback(path, sampleRate: 8000);
        if (wav != null) {
          await player.setFilePath(wav);
        } else {
          throw Exception('WAV decode failed for $path');
        }
      } else if (looksRawOpus) {
        final prepared =
            await prepareAudioForPlayback(path, preferWav: preferWav);
        if (prepared == null) {
          throw Exception('No playable audio generated for $path');
        }
        boundPlayableIsOgg = prepared.isRemuxedOgg;
        try {
          await player.setFilePath(prepared.path);
        } catch (_) {
          if (!prepared.isRemuxedOgg) rethrow;
          _sOggOpusFailed = true;
          _preferWavForDeviceOpus = true;
          final wav = await decodeAudioToWavForPlayback(path, sampleRate: 8000);
          if (wav == null) rethrow;
          await player.setFilePath(wav);
          boundPlayableIsOgg = false;
        }
      } else {
        try {
          await player.setFilePath(path);
        } catch (_) {
          if (!isOpusOrCaf) rethrow;
          final playable = await prepareAudioForPlayback(
            path,
            preferWav: preferWav,
          );
          if (playable == null) rethrow;
          boundPlayableIsOgg = playable.isRemuxedOgg;
          try {
            await player.setFilePath(playable.path);
          } catch (_) {
            if (!boundPlayableIsOgg) rethrow;
            _sOggOpusFailed = true;
            _preferWavForDeviceOpus = true;
            final wav =
                await decodeAudioToWavForPlayback(path, sampleRate: 8000);
            if (wav == null) rethrow;
            await player.setFilePath(wav);
            boundPlayableIsOgg = false;
          }
        }
      }

      // Sync duration immediately if available.
      // When boundPlayableIsOgg is true the Ogg decoder may crash shortly
      // (e.g. on Huawei), so skip DB sync to avoid a spurious rebuild/flicker.
      final skipDbSync = boundPlayableIsOgg;
      void onDuration(Duration? d) {
        if (d == null || !mounted) return;
        _playerCtrl?.setDurationFromAdapter(d);
        if (!skipDbSync) {
          _syncDurationToDbIfNeeded(d.inSeconds);
        }
      }

      final d0 = player.duration;
      if (d0 != null) {
        onDuration(d0);
      } else {
        try {
          final d = await player.durationStream
              .where((d) => d != null)
              .cast<Duration>()
              .first
              .timeout(
                const Duration(seconds: 2),
              );
          onDuration(d);
        } catch (_) {}
      }

      _durSub = player.durationStream.listen(onDuration);

      _posSub = player.positionStream.listen((pos) {
        if (!mounted) return;
        final c = _playerCtrl;
        if (c == null) return;
        c.beginAdapterUpdate();
        c.setPositionFromAdapter(pos);
        c.endAdapterUpdate();
      });

      _stateSub = player.playerStateStream.listen((st) {
        if (!mounted) return;
        final c = _playerCtrl;
        if (c == null) return;
        c.beginAdapterUpdate();
        if (st.processingState == ProcessingState.completed) {
          c.setPlayingFromAdapter(false);
          final dur = player.duration ?? c.duration;
          if (dur > Duration.zero) c.setPositionFromAdapter(dur);
        } else {
          c.setPlayingFromAdapter(st.playing);
        }
        c.endAdapterUpdate();
      });

      // ExoPlayer on Huawei etc. may report Source error / UnrecognizedInputFormat for Ogg or bad WAV cache;
      // not Ogg-only — listen and rebind (clear WAV cache + force WAV).
      if (isOpusOrCaf) {
        _errSub = player.errorStream.listen((_) {
          _errSub?.cancel();
          _errSub = null;
          _stateSub?.cancel();
          _posSub?.cancel();
          _durSub?.cancel();
          _playerCtrl?.detachAdapter(adapter);
          _audioAdapter = null;
          player.dispose();
          if (identical(_audio, player)) _audio = null;
          _boundAudioPath = null;
          _bindingAudio = false;

          _opusPlaybackRecoveryAttempts++;
          if (_opusPlaybackRecoveryAttempts > 2) {
            // Do not keep path reserved forever or _ensureAudioBound always bails and the player never rebuilds.
            _opusPlaybackRecoveryAttempts = 0;
            _boundAudioPath = null;
            _audioBindDebounceUntil =
                DateTime.now().add(const Duration(seconds: 2));
            Timer(const Duration(milliseconds: 2100), () {
              if (!mounted) return;
              setState(() {});
            });
            return;
          }
          PlaybackOpusHints.forcePreferWavOverOgg();
          _sOggOpusFailed = true;
          if (mounted) {
            setState(() => _preferWavForDeviceOpus = true);
          }
          Future.wait([
            invalidateDecodedWavCache(path, sampleRate: 8000),
            invalidateDecodedWavCache(path, sampleRate: 16000),
          ]).then((_) {
            if (mounted) _bindJustAudio(path);
          });
        });
      }

      if (!mounted || _playerCtrl == null) {
        await player.dispose();
        if (identical(_audio, player)) _audio = null;
        _audioAdapter = null;
        return;
      }
      _playerCtrl!.attachAdapter(adapter);
      _audioBindDebounceUntil = null;
    } catch (e, st) {
      // Keep _boundAudioPath so we do not re-trigger decode every frame in build while the file still exists.
      if (kDebugMode) {
        debugPrint('[RecordingDetail] bind audio failed: $e\n$st');
      }
      unawaited(invalidateDecodedWavCache(path, sampleRate: 8000));
      unawaited(invalidateDecodedWavCache(path, sampleRate: 16000));
      _disposeAudio(clearBoundPath: false);
      _audioBindDebounceUntil = DateTime.now().add(const Duration(seconds: 2));
      _lastPlaybackBindFailed = true;
      if (mounted) {
        setState(() => _localFileInvalid = true);
      } else {
        _localFileInvalid = true;
      }
    } finally {
      _bindingAudio = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final asyncRec = ref.watch(recordingByIdProvider(widget.recordingId));
    final primary = Theme.of(context).colorScheme.primary;
    final l10n = AppLocalizations.of(context)!;

    return asyncRec.when(
      skipLoadingOnReload: true,
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(
          title: Text(l10n.source,
              style: const TextStyle(
                  fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
        ),
        body: Center(child: Text(e.toString())),
      ),
      data: (rec) {
        if (rec == null) {
          return Scaffold(
            appBar: AppBar(
              title: Text(l10n.source,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s16)),
            ),
            body: Center(child: Text(l10n.errorRecordNotFound)),
          );
        }
        final recording = rec;
        _syncPlayerDurationFromRecording(recording.durationSeconds);

        // Device recording whose bytes are still being pulled / merged: the local
        // file on disk is partial (or absent), so playback / waveform / transcribe
        // would operate on incomplete audio (wrong duration, broken seek, partial
        // peaks). Render a dedicated "syncing" placeholder instead and let the
        // page auto-refresh into the playable UI once `recordingByIdProvider`
        // reports `transfer_state == 'done'`.
        final deviceUi = ref.watch(deviceControllerProvider);
        final activeTransferForRow =
            (deviceUi.activeTransferRecordingId ?? '').trim() ==
                recording.id.trim();
        final syncInProgress = recording.source == 'device' &&
            (recording.transferState == 'transferring' ||
                recording.transferState == 'merging');
        // Reuse the exact list/banner presentation so the placeholder label and
        // bar (syncing / merging / NN%) stay consistent across the app.
        final syncUi = syncInProgress
            ? resolveTransferSyncStatusPresentation(
                recording: recording,
                liveRecordWhileBleTransfer: false,
                transferActiveForRecording: activeTransferForRow,
              )
            : null;

        // If this recording has a local audio file, bind real playback + extract waveform peaks.
        final p = recording.localPath;
        final hasLocalPath = p != null && p.trim().isNotEmpty;
        // Use cached async result; schedule check if path changed.
        if (hasLocalPath && p != _localExistsPath) {
          _localExistsPath = p;
          _localExistsResult = false;
          _localExistsChecking = true;
          File(p).exists().then((exists) {
            if (!mounted || p != _localExistsPath) return;
            setState(() {
              _localExistsResult = exists;
              _localExistsChecking = false;
            });
          });
        } else if (!hasLocalPath) {
          _localExistsPath = null;
          _localExistsResult = false;
          _localExistsChecking = false;
        }
        final localExists = hasLocalPath && _localExistsResult;
        // Never bind playback / build peaks against a file that is still syncing.
        final canPlay = localExists && !_localFileInvalid && !syncInProgress;
        final hasMetadataDuration = (recording.durationSeconds ?? 0) > 0;
        // After STOP the list may already show duration while local file check
        // or transfer is still in flight — keep the player chrome (incl. total
        // time) visible instead of an empty loading box.
        final showPlayerArea = canPlay ||
            hasMetadataDuration ||
            _localExistsChecking ||
            _bindingAudio;

        // Bind player whenever a local file exists; decode/play errors do not hide the source audio area.
        _ensureAudioBound(canPlay ? p : null);

        final lower = p?.toLowerCase() ?? '';
        final canPeaks = canPlay &&
            (lower.endsWith('.wav') ||
                lower.endsWith('.opus') ||
                lower.endsWith('.caf'));
        if (!canPeaks) {
          _waveformDeferTimer?.cancel();
          _waveformDeferScheduledFor = null;
          _waveformGatePath = null;
        } else if (_waveformDeferScheduledFor != p) {
          _waveformDeferScheduledFor = p;
          _waveformGatePath = null;
          _waveformDeferTimer?.cancel();
          final key = p;
          _waveformDeferTimer = Timer(const Duration(milliseconds: 450), () {
            if (!mounted || _waveformDeferScheduledFor != key) return;
            if (kDebugMode) {
              debugPrint('[Waveform] detail subscribe path=$key');
            }
            setState(() => _waveformGatePath = key);
          });
        }
        final waveDisplayPath = canPeaks ? p : null;
        final waveWatchPath = canPeaks && _waveformGatePath == p ? p : null;
        final wavePeaksAsync = waveWatchPath != null
            ? ref.watch(waveformPeaksProvider(WaveformPeaksRequest(
                path: waveWatchPath,
                durationSeconds: recording.durationSeconds,
              )))
            : const AsyncValue<WaveformPeaksResult?>.data(null);
        final waveResult = _resolveStableWaveformResult(
          waveDisplayPath,
          wavePeaksAsync.valueOrNull,
        );
        final waveformBuilding = waveWatchPath != null &&
            wavePeaksAsync.isLoading &&
            waveResult == null;
        if (hasLocalPath && p != _markersPath) {
          final pathForLoad = p;
          _markersPath = pathForLoad;
          _loadBookmarksForPath(pathForLoad).then((markers) {
            if (!mounted) return;

            if (_markersPath == pathForLoad) {
              setState(() => _markers = markers);
            }
          }).catchError((_) {
            if (!mounted) return;
            if (_markersPath == pathForLoad) {
              setState(() => _markers = const []);
            }
          });
        }

        final hasTranscriptContent =
            (recording.transcript ?? '').trim().isNotEmpty;

        ref.listen<TranscriptionTaskState>(
          transcriptionTaskControllerProvider,
          (prev, next) {
            if (!mounted) return;
            final msg = next.progressFor(recording.id);
            final active = next.isActive(recording.id);
            if (active && msg != null) {
              _syncBackgroundTranscribeBanner(msg);
              setState(() {});
            } else if (_transcribeProgressBanner == null) {
              if (_backgroundTranscribeProgress != null) {
                _clearBackgroundTranscribeBanner();
                setState(() {});
              }
            }
          },
        );

        final taskState = ref.watch(transcriptionTaskControllerProvider);
        final taskMsg = taskState.progressFor(recording.id);
        if (taskState.isActive(recording.id) && taskMsg != null) {
          _syncBackgroundTranscribeBanner(taskMsg);
        }
        var transcribeBanner =
            _transcribeProgressBanner ?? _backgroundTranscribeProgress;
        final transcribeActive =
            transcribeBanner != null || taskState.isActive(recording.id);
        if (transcribeBanner == null && taskState.isActive(recording.id)) {
          _syncBackgroundTranscribeBanner(l10n.transcriptionWorkInProgress);
          transcribeBanner = _backgroundTranscribeProgress;
        }
        final inlineTranscribeUnderTitle =
            transcribeActive && _tab == 0 && hasTranscriptContent;
        final showTranscribeBottomBar =
            transcribeActive && !inlineTranscribeUnderTitle;
        final aiWorkInProgress = _isAiWorkInProgress(recording);

        return Scaffold(
          backgroundColor: AppColors.appBackground,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                final r = GoRouter.of(context);
                if (r.canPop()) {
                  r.pop();
                } else {
                  r.go('/recordings');
                }
              },
            ),
            title: _TopTabs(
              tab: _tab,
              onChanged: (v) {
                if (v == 1 && _tab != 1) {
                  _playerCtrl?.setPlaying(false);
                  setState(() {
                    _tab = v;
                    _noteSyncToken++;
                  });
                  return;
                }
                setState(() => _tab = v);
              },
            ),
            centerTitle: true,
            actions: [
              IconButton(
                onPressed: () => _openShareSheet(context, recording),
                icon: const Icon(Icons.share_outlined),
              ),
              Builder(
                builder: (ctx) {
                  return IconButton(
                    onPressed: () => _showMoreMenu(ctx, recording),
                    icon: const Icon(Icons.more_horiz),
                  );
                },
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      Offstage(
                        offstage: _tab != 0,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                          child: syncInProgress
                              ? _SyncStatusCard(presentation: syncUi!)
                              : !showPlayerArea
                                  ? Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 14),
                                      decoration: BoxDecoration(
                                        color: AppColors.surface,
                                        borderRadius:
                                            BorderRadius.circular(AppRadii.r18),
                                        border: Border.all(
                                            color: AppColors.borderLight),
                                      ),
                                      child: Text(
                                        (hasLocalPath &&
                                                _localExistsResult &&
                                                _localFileInvalid)
                                            ? l10n.localAudioUnplayable
                                            : l10n.localAudioMissing,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: AppColors.textSecondary,
                                              height: 1.35,
                                            ),
                                      ),
                                    )
                                  : ListenableBuilder(
                                      listenable: _playerCtrl!,
                                      builder: (context, _) {
                                        final playbackPreparing = !canPlay &&
                                                (_localExistsChecking ||
                                                    _bindingAudio) ||
                                            _waitingForFullFile ||
                                            (canPlay &&
                                                !_playerCtrl!.isPlaybackReady &&
                                                !_lastPlaybackBindFailed);
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (waveformBuilding)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    bottom: 6),
                                                child: Row(
                                                  children: [
                                                    const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        l10n.waveformBuilding,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: AppColors
                                                                  .textSecondary,
                                                            ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            if (playbackPreparing)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    bottom: 6),
                                                child: Row(
                                                  children: [
                                                    const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Text(
                                                        l10n.playbackPreparing,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: AppColors
                                                                  .textSecondary,
                                                            ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            RecordingPlayer(
                                              controller: _playerCtrl!,
                                              peaks: canPlay
                                                  ? waveResult?.peaks
                                                  : null,
                                              parsedFraction:
                                                  waveResult?.parsedFraction ??
                                                      1.0,
                                              playbackDisabled: !canPlay ||
                                                  _waitingForFullFile,
                                              markers: (hasLocalPath &&
                                                      p == _markersPath)
                                                  ? _markers
                                                  : const [],
                                              showMarkerTimestamps: false,
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                        ),
                      ),
                      if (_tab == 0) const SizedBox(height: 8),
                      Expanded(
                        child: _tab == 0
                            ? _SourceTab(
                                recording: recording,
                                primary: primary,
                                onTranscribeAndSummarize: () => _openAiSheet(
                                    context,
                                    recording,
                                    _AiAction.transcribeAndSummarize),
                                onGenerateSummary: () => _openAiSheet(
                                    context, recording, _AiAction.summarize),
                                transcribeProgress: transcribeBanner,
                                inlineTranscribeProgress:
                                    inlineTranscribeUnderTitle,
                                hidePrimaryAction: aiWorkInProgress,
                                syncInProgress: syncInProgress,
                              )
                            : _NoteTab(
                                recording: recording,
                                primary: primary,
                                hidePrimaryAction: aiWorkInProgress,
                                streamingSummary:
                                    (_streamingSummaryRecordingId ==
                                            recording.id)
                                        ? _streamingSummary
                                        : null,
                                isStreaming: _streamingSummaryActive,
                                lastSummaryText: _lastSummaryText,
                                generatedSessionId: _latestServerSessionId,
                                lastGeneratedAssistantMessageId:
                                    _lastGeneratedAssistantMessageId,
                                onDeletedSessionMessage: () {
                                  setState(() {
                                    _latestServerSessionId = null;
                                    _lastGeneratedAssistantMessageId = null;
                                    _lastSummaryText = null;
                                  });
                                },
                                syncToken: _noteSyncToken,
                                onGenerateAgain: () => _openAiSheet(context,
                                    recording, _AiAction.summarizeAgain),
                                onSummarize: () => _openAiSheet(
                                    context, recording, _AiAction.summarize),
                                onTranscribeAndSummarize: () => _openAiSheet(
                                    context,
                                    recording,
                                    _AiAction.transcribeAndSummarize),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar:
              showTranscribeBottomBar && transcribeBanner != null
                  ? _TranscribeProgressBottomBar(message: transcribeBanner)
                  : null,
        );
      },
    );
  }

  Future<void> _openShareSheet(
      BuildContext context, Recording recording) async {
    var summaryText = _lastSummaryText ?? recording.summary;
    if ((summaryText ?? '').trim().isEmpty) {
      final repo = await ref.read(recordingsRepositoryProvider.future);
      final versions = await repo.listSummaryVersions(recording.id);
      final currentId = recording.currentSummaryId?.trim();
      if (currentId != null && currentId.isNotEmpty) {
        summaryText =
            versions.where((v) => v.id == currentId).firstOrNull?.content;
      }
      summaryText ??= versions.isNotEmpty ? versions.last.content : summaryText;
    }
    if (!context.mounted) return;
    await RecordingShareSheet.show(
      context,
      recording,
      summaryExportText: summaryText,
    );
  }

  Future<void> _openAiSheet(
      BuildContext context, Recording recording, _AiAction action) async {
    if (_isAiWorkInProgress(recording)) return;
    _retainAiBusy();
    try {
      final l10n = AppLocalizations.of(context)!;
      var nextAction = action;
      if (action == _AiAction.summarize &&
          ((recording.transcript ?? '').trim().isEmpty)) {
        nextAction = _AiAction.transcribeAndSummarize;
      }
      final cfg = _AiSheetConfig.forAction(nextAction, l10n);
      final initLanguage = (recording.lastLanguage ?? '').trim().isNotEmpty
          ? recording.lastLanguage!
          : _lastLanguage;

      final consentOk = await ensureAiDataSharingConsent(
        context: context,
        l10n: l10n,
        sendsAudio: nextAction.needsTranscribe,
        sendsTranscript: nextAction.needsSummarize,
      );
      if (!consentOk || !context.mounted) return;

      final result = await showAppBottomSheet<_GenerateSelection>(
        context,
        builder: (_) => _GenerateSheet(
          recording: recording,
          config: cfg,
          initial: _GenerateSelection(
            template: null,
            llm: null,
            stt: null,
            language: initLanguage,
            autoSpeaker: recording.lastAutoSpeaker,
          ),
        ),
      );
      if (result == null) return;
      if (!context.mounted) return;

      _lastLanguage = result.language;

      // Persist the mapping (Template <-> LLM config) for traceability.
      final repo = await ref.read(recordingsRepositoryProvider.future);
      await repo.updateAiSelection(
        id: recording.id,
        sttConfigId: result.stt?.id,
        llmConfigId: result.llm?.id,
        templateId: result.template?.id,
        language: result.language,
        autoSpeaker: cfg.showStt ? result.autoSpeaker : null,
      );

      if (!context.mounted) return;
      await _showLoadingAndRunAiAction(recording, nextAction, result);
    } finally {
      _releaseAiBusy();
    }
  }

  Future<void> _showLoadingAndRunAiAction(
    Recording recording,
    _AiAction action,
    _GenerateSelection selection,
  ) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    ValueNotifier<String>? progressMessage;
    final skipLoading =
        action == _AiAction.summarize || action == _AiAction.summarizeAgain;
    // Transcribe progress is owned by [transcriptionTaskControllerProvider].
    if (!skipLoading && !action.needsTranscribe) {
      _tearDownTranscribeBanner();
      progressMessage = ValueNotifier<String>(l10n.summarizing);
      _transcribeProgressBanner = progressMessage;
      if (mounted) setState(() {});
    }
    try {
      await _runAiAction(
        recording: recording,
        action: action,
        selection: selection,
        progressMessage: progressMessage,
      );
    } finally {
      _tearDownTranscribeBanner();
      if (mounted) setState(() {});
    }
  }

  /// Provider updates for AI job progress. Uses [ProviderContainer] so list/detail
  /// providers refresh even when the user leaves this page mid-transcribe/summary
  /// (WidgetRef must not be used after dispose — SENSECRAFT-VOICE-5).
  void _publishRecordingJobChange(
    ProviderContainer container,
    String recordingId, {
    bool summaries = false,
  }) {
    container.invalidate(recordingByIdProvider(recordingId));
    if (summaries) {
      container.invalidate(recordingSummaryVersionsProvider(recordingId));
    }
    bumpRecordingsLists(container);
  }

  Future<void> _runAiAction({
    required Recording recording,
    required _AiAction action,
    required _GenerateSelection selection,
    ValueNotifier<String>? progressMessage,
  }) async {
    if (!mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final repo = await container.read(recordingsRepositoryProvider.future);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final transferIncomplete = recording.transferState != 'done';
    final lifecycleBusy = switch (recording.recordingState) {
      'recording' || 'stopping' || 'transferring' => true,
      _ => false,
    };

    // Rescue path: when the DB row still says "transferring" but the merged
    // local file is already on disk at (or close to) the expected size, the
    // transfer actually completed and we just hit a late / missed
    // `transfer_state='done'` write. This regressed with multi-device
    // (phase 1/2): switching the active device while a transfer was in
    // flight, GATT flapping between two background links, or a merge path
    // throwing right before the final repo update all leave a row stuck in
    // `transferring` even though the file is fully synced. Blocking ASR in
    // that state means the user can't transcribe at all until they manually
    // re-sync — refusing to transcribe a file that's already on disk is
    // worse than letting it through, so accept the local file as ground
    // truth and let ASR proceed.
    var transferRescuedByLocalFile = false;
    if (action.needsTranscribe && transferIncomplete && !lifecycleBusy) {
      final localPath = recording.localPath?.trim() ?? '';
      if (localPath.isNotEmpty) {
        try {
          final f = File(localPath);
          if (await f.exists()) {
            final size = await f.length();
            final exp = recording.expectedBytes ?? 0;
            if (size > 0 && (exp <= 0 || size >= (exp * 0.9).round())) {
              transferRescuedByLocalFile = true;
              AppLog.i(
                '[ASR] transfer-state rescue: row=${recording.id} '
                'transferState=${recording.transferState} but localFile '
                'exists size=$size expected=$exp — allowing ASR',
              );
              // Best-effort fix the stuck DB state so the rest of the UI
              // (sync banner, list badges, etc.) matches reality.
              try {
                await repo.updateTransfer(
                  id: recording.id,
                  state: 'done',
                  progress: 1.0,
                  receivedBytes: size,
                  expectedBytes: exp > 0 ? exp : size,
                );
                bumpRecordingsLists(container);
              } catch (e, st) {
                AppLog.w('[ASR] failed to repair stuck transfer_state', e, st);
              }
            }
          }
        } catch (e, st) {
          AppLog.w('[ASR] rescue path stat() failed', e, st);
        }
      }
    }

    final blockedByTransfer = action.needsTranscribe &&
        ((transferIncomplete && !transferRescuedByLocalFile) || lifecycleBusy);
    if (blockedByTransfer) {
      AppLog.w(
        '[ASR] blocked while transfer active '
        'recordingId=${recording.id} '
        'transferState=${recording.transferState} '
        'recordingState=${recording.recordingState} '
        'expectedBytes=${recording.expectedBytes} '
        'receivedBytes=${recording.receivedBytes} '
        'localPath=${recording.localPath}',
      );
      if (mounted) {
        await AppDialogs.showErrorDialog(
          context,
          title: l10n.errorTitle,
          message: l10n.waitCurrentTransferToRetry,
          confirmText: l10n.confirm,
        );
      }
      await repo.updateJobState(recording.id, 'failed');
      _publishRecordingJobChange(container, recording.id);
      return;
    }

    final asrResultId = await repo.ensureAsrResultId(recording.id);
    if (asrResultId == null) {
      return;
    }
    // Transcribe: update only after the API returns new data; do not clear early; on failure keep prior transcript.
    switch (action) {
      case _AiAction.transcribe:
      case _AiAction.transcribeAndSummarize:
        // Do not clearTranscript here; updateTranscript after recognizeUrl returns.
        break;
      case _AiAction.summarize:
      case _AiAction.summarizeAgain:
        break;
    }

    await repo.updateJobState(
      recording.id,
      action.needsTranscribe ? 'queued' : 'summarizing',
    );
    _publishRecordingJobChange(container, recording.id);

    String? transcript;

    if (action.needsTranscribe) {
      transcript =
          await ref.read(transcriptionTaskControllerProvider.notifier).run(
                recording: recording,
                asrResultId: asrResultId,
                selection: TranscribeSheetSelection(
                  stt: selection.stt,
                  language: selection.language,
                  autoSpeaker: selection.autoSpeaker,
                ),
                uiContext: mounted ? context : null,
                allowGatewayTimeoutRetry: true,
                onGatewayTimeoutRetry: () => _showLoadingAndRunAiAction(
                  recording,
                  action,
                  selection,
                ),
              );
      if (transcript == null) {
        return;
      }
    }

    if (action.needsSummarize) {
      if (mounted && progressMessage == null) {
        _tearDownTranscribeBanner();
        progressMessage = ValueNotifier<String>(l10n.summarizing);
        _transcribeProgressBanner = progressMessage;
        if (mounted) setState(() {});
      } else if (mounted && progressMessage != null) {
        progressMessage.value = l10n.summarizing;
      }
      await repo.updateJobState(recording.id, 'summarizing');
      _publishRecordingJobChange(container, recording.id);
      if (mounted && action != _AiAction.transcribeAndSummarize) {
        setState(() => _tab = 1);
      }
      final baseTranscript = (transcript ?? recording.transcript)?.trim() ?? '';
      if (baseTranscript.isEmpty) {
        if (mounted) {
          await AppDialogs.showErrorDialog(
            context,
            title: l10n.errorTitle,
            message: l10n.needTranscriptFirst,
            confirmText: l10n.confirm,
          );
        }
        await repo.updateJobState(recording.id, 'failed');
        _publishRecordingJobChange(container, recording.id);
        return;
      }
      final llm = selection.llm;
      final tpl = selection.template;
      if (llm == null || tpl == null) {
        if (mounted) {
          await AppDialogs.showErrorDialog(
            context,
            title: l10n.errorTitle,
            message: l10n.llmTemplateNotSelected,
            confirmText: l10n.confirm,
          );
        }
        await repo.updateJobState(recording.id, 'failed');
        _publishRecordingJobChange(container, recording.id);
        return;
      }

      final llmApi = container.read(llmApiProvider);
      String summary;
      final sessionId = '';
      try {
        final configId = llm.llmRemoteConfigId ?? 0;
        final systemPrompt = tpl.prompt;
        debugPrint(
          '[LLM] chat_request'
          ' recordingId=${recording.id}'
          ' config_id=$configId'
          ' template(localId=${tpl.id}, remoteId=${tpl.remoteId}, isDefault=${tpl.isDefault}, name="${tpl.name}")'
          ' mac_address="${(recording.deviceId ?? '').trim()}"'
          ' inputLen=${baseTranscript.length}'
          ' session_id="$sessionId"'
          ' asr_result_id=$asrResultId',
        );
        _streamingSummaryRecordingId = recording.id;
        _streamingSummary = '';
        _streamingSummaryActive = true;
        _lastSummaryText = null;
        _lastGeneratedAssistantMessageId = null;
        final buffer = StringBuffer();
        await for (final delta in llmApi.streamSummary(
          configId: configId,
          input: baseTranscript,
          macAddress: recording.deviceId ?? '',
          systemPrompt: systemPrompt,
          sessionId: sessionId,
          asrResultId: asrResultId,
          onSessionId: (sid) {
            if (sid.trim().isEmpty) return;
            if (_latestServerSessionId == sid) return;
            // Log key params after session creation for backend cross-check.
            debugPrint(
              '[LLM] session_created'
              ' recordingId=${recording.id}'
              ' config_id=$configId'
              ' mac_address="${(recording.deviceId ?? '').trim()}"'
              ' inputLen=${baseTranscript.length}'
              ' session_id=$sid'
              ' asr_result_id=$asrResultId',
            );
            if (mounted) {
              setState(() => _latestServerSessionId = sid);
            } else {
              _latestServerSessionId = sid;
            }
          },
        )) {
          buffer.write(delta);
          if (mounted) {
            setState(() => _streamingSummary = buffer.toString());
          }
        }
        summary = buffer.toString();
        if (mounted) {
          setState(() {
            _streamingSummaryActive = false;
          });
        } else {
          _streamingSummaryActive = false;
        }
      } catch (e) {
        _streamingSummaryActive = false;
        _streamingSummary = null;
        if (mounted) {
          final message = e is ServerException
              ? serverErrorDialogMessage(context, e)
              : l10n.summaryFailed(e.toString());
          await AppDialogs.showErrorDialog(
            context,
            title: l10n.errorTitle,
            message: message,
            confirmText: l10n.confirm,
          );
        }
        await repo.updateJobState(recording.id, 'failed');
        _publishRecordingJobChange(container, recording.id);
        return;
      }

      // Append version (does not delete previous summaries).
      String? remoteSid = _latestServerSessionId?.trim();
      int? remoteAssistantMsgId;
      if (remoteSid != null && remoteSid.isNotEmpty) {
        try {
          final sessRepo =
              await container.read(llmSessionRemoteRepositoryProvider.future);
          final msgs = await sessRepo.getSessionMessagesRemote(remoteSid);
          final target = msgs.where((m) => m.role == 'assistant').toList();
          if (target.isNotEmpty) {
            // Prefer assistant with identical content; else last assistant message.
            final matched = target
                .where((m) => m.content.trim() == summary.trim())
                .toList();
            remoteAssistantMsgId =
                (matched.isNotEmpty ? matched.last : target.last).id;
          }
        } catch (_) {
          // best effort only
        }
      }
      await repo.addSummaryVersion(
        recordingId: recording.id,
        content: summary,
        title: summaryFirstSentenceFromText(summary),
        titlePrefix: l10n.summaryVersionPrefix,
        defaultTitlePrefix: l10n.summaryVersionPrefix,
        remoteSessionId: remoteSid,
        remoteMessageId: remoteAssistantMsgId,
      );
      _publishRecordingJobChange(container, recording.id, summaries: true);
      if (mounted) {
        setState(() {
          _streamingSummary = null;
          _lastSummaryText = summary;
          _lastGeneratedAssistantMessageId = remoteAssistantMsgId;
          _noteSyncToken++;
        });
      } else {
        _streamingSummary = null;
        _lastSummaryText = summary;
        _lastGeneratedAssistantMessageId = remoteAssistantMsgId;
        _noteSyncToken++;
      }
    }

    await repo.updateJobState(recording.id, 'done');
    _publishRecordingJobChange(container, recording.id);
    if (!mounted) return;
    if (action.needsSummarize && action != _AiAction.transcribeAndSummarize) {
      setState(() => _tab = 1);
    }
  }

  Future<void> _showMoreMenu(
      BuildContext anchorContext, Recording recording) async {
    final overlay = Overlay.of(anchorContext);

    late OverlayEntry entry;
    void dismiss() {
      if (entry.mounted) entry.remove();
    }

    final box = anchorContext.findRenderObject() as RenderBox?;
    final ovBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || ovBox == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: ovBox);
    final size = box.size;

    const menuW = 260.0;
    const menuH = 180.0;
    const gap = 8.0;
    final screenW = ovBox.size.width;
    final screenH = ovBox.size.height;
    var left =
        (topLeft.dx + size.width - menuW).clamp(12.0, screenW - menuW - 12.0);
    var top =
        (topLeft.dy + size.height + gap).clamp(12.0, screenH - menuH - 12.0);

    entry = OverlayEntry(
      builder: (ctx) => _DetailMorePopup(
        position: Offset(left, top),
        isNoteTab: _tab == 1,
        isInRecycleBin: recording.isDeleted,
        aiActionsDisabled: _isAiWorkInProgress(recording),
        onDismiss: dismiss,
        onSelect: (a) async {
          dismiss();
          switch (a) {
            case _DetailMoreAction.moveToFolder:
              await _moveToFolder(recording);
              break;
            case _DetailMoreAction.transcribeOrSummarizeAgain:
              if (_isAiWorkInProgress(recording)) return;
              if (_tab == 0) {
                await _openAiSheet(context, recording, _AiAction.transcribe);
              } else {
                await _openAiSheet(
                    context, recording, _AiAction.summarizeAgain);
              }
              break;
            case _DetailMoreAction.recycle:
              await _moveToRecycle(recording);
              break;
            case _DetailMoreAction.restore:
              await _restoreFromRecycleBin(recording);
              break;
          }
        },
      ),
    );
    overlay.insert(entry);
  }

  Future<void> _moveToFolder(Recording recording) async {
    final folders = await ref.read(foldersListProvider.future);
    if (!mounted) return;
    final picked = await showAppBottomSheet<String?>(
      context,
      builder: (_) => _MoveToFolderSheet(
        currentFolderId: recording.folderId,
        folders: folders,
      ),
    );
    if (picked == null) return;
    final repo = await ref.read(recordingsRepositoryProvider.future);
    await repo.moveToFolder(
        id: recording.id, folderId: picked.isEmpty ? null : picked);
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(recording.id));
  }

  Future<void> _moveToRecycle(Recording recording) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await AppDialogs.showConfirm(
      context,
      title: l10n.moveToRecycleBin,
      message:
          l10n.moveToRecycleBinConfirmName(recording.name ?? l10n.recording),
      confirmText: l10n.move,
      cancelText: l10n.cancel,
    );
    if (!ok) return;
    final repo = await ref.read(recordingsRepositoryProvider.future);
    await ref
        .read(deviceControllerProvider.notifier)
        .cancelTransfer(recording.id, errorCode: 'user_cancelled');
    await repo.moveToRecycleBin(id: recording.id);
    bumpRecordingsLists(ref, removedIds: {recording.id});
    if (!mounted) return;
    Navigator.of(context).pop(); // back to list
  }

  Future<void> _restoreFromRecycleBin(Recording recording) async {
    final repo = await ref.read(recordingsRepositoryProvider.future);
    await repo.restoreFromRecycleBin(id: recording.id);
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(recording.id));
    if (!mounted) return;
    Navigator.of(context).pop(); // back to list
  }
}

class _JustAudioAdapter implements RecordingPlayerAdapter {
  final AudioPlayer _player;
  _JustAudioAdapter(this._player);

  @override
  Future<void> setPlaying(bool isPlaying) async {
    if (isPlaying) {
      await _player.play();
    } else {
      await _player.pause();
    }
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
}

/// Wraps [_JustAudioAdapter] during the head-phase to intercept seeks that
/// go beyond the loaded head audio. Instead of letting just_audio clamp the
/// position, it triggers the full-file rebind with the intended target.
class _HeadPhaseAdapter implements RecordingPlayerAdapter {
  final _JustAudioAdapter _inner;
  final Duration headDuration;
  final void Function(Duration target) onSeekBeyondHead;

  /// When true, all play / seek commands are silently ignored so the UI
  /// stays stable while waiting for a longer audio file.
  bool blocked = false;

  _HeadPhaseAdapter(
    this._inner, {
    required this.headDuration,
    required this.onSeekBeyondHead,
  });

  @override
  Future<void> setPlaying(bool isPlaying) {
    if (blocked) return Future<void>.value();
    return _inner.setPlaying(isPlaying);
  }

  @override
  Future<void> seek(Duration position) {
    if (blocked) return Future<void>.value();
    if (position >= headDuration) {
      onSeekBeyondHead(position);
      return Future<void>.value();
    }
    return _inner.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) => _inner.setSpeed(speed);
}

enum _AiAction {
  transcribeAndSummarize,
  summarize,
  transcribe,
  summarizeAgain,
}

extension on _AiAction {
  bool get needsTranscribe =>
      this == _AiAction.transcribeAndSummarize || this == _AiAction.transcribe;
  bool get needsSummarize =>
      this == _AiAction.transcribeAndSummarize ||
      this == _AiAction.summarize ||
      this == _AiAction.summarizeAgain;
}

class _AiSheetConfig {
  final String title;
  final bool showLlm;
  final bool showStt;
  final bool showLanguage;

  const _AiSheetConfig({
    required this.title,
    required this.showLlm,
    required this.showStt,
    required this.showLanguage,
  });

  factory _AiSheetConfig.forAction(_AiAction action, AppLocalizations l10n) {
    switch (action) {
      case _AiAction.transcribeAndSummarize:
        return _AiSheetConfig(
            title: l10n.transcribeAndSummarize,
            showLlm: true,
            showStt: true,
            showLanguage: true);
      case _AiAction.summarize:
        return _AiSheetConfig(
            title: l10n.summarize,
            showLlm: true,
            showStt: false,
            showLanguage: false);
      case _AiAction.transcribe:
        return _AiSheetConfig(
            title: l10n.transcribeAgain,
            showLlm: false,
            showStt: true,
            showLanguage: true);
      case _AiAction.summarizeAgain:
        return _AiSheetConfig(
            title: l10n.summarizeAgain,
            showLlm: true,
            showStt: false,
            showLanguage: false);
    }
  }
}

enum _DetailMoreAction {
  moveToFolder,
  transcribeOrSummarizeAgain,
  recycle,
  restore
}

class _DetailMorePopup extends StatelessWidget {
  final Offset position;
  final bool isNoteTab;
  final bool isInRecycleBin;
  final bool aiActionsDisabled;
  final void Function(_DetailMoreAction) onSelect;
  final VoidCallback onDismiss;

  const _DetailMorePopup({
    required this.position,
    required this.isNoteTab,
    required this.onSelect,
    required this.onDismiss,
    this.isInRecycleBin = false,
    this.aiActionsDisabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final midLabel = isNoteTab ? l10n.summarizeAgain : l10n.transcribeAgain;
    final midIcon =
        isNoteTab ? Icons.auto_awesome_outlined : Icons.auto_fix_high_outlined;

    return AppOverlayTapDismiss(
      onDismiss: onDismiss,
      child: Positioned(
        left: position.dx,
        top: position.dy,
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(AppRadii.r18),
          color: Colors.transparent,
          child: Container(
            width: 260,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.r18),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: isInRecycleBin
                  ? [
                      _MoreRow(
                        icon: Icons.restore_outlined,
                        label: l10n.restoreFromRecycleBin,
                        color: AppColors.brandPrimary,
                        onTap: () => onSelect(_DetailMoreAction.restore),
                      ),
                    ]
                  : [
                      _MoreRow(
                        icon: Icons.create_new_folder_outlined,
                        label: l10n.moveToFolder,
                        color: AppColors.textPrimary,
                        onTap: () => onSelect(_DetailMoreAction.moveToFolder),
                      ),
                      _MoreRow(
                        icon: midIcon,
                        label: midLabel,
                        color: aiActionsDisabled
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                        onTap: aiActionsDisabled
                            ? null
                            : () => onSelect(
                                _DetailMoreAction.transcribeOrSummarizeAgain),
                      ),
                      const Divider(
                          height: 1, thickness: 1, color: AppColors.border),
                      _MoreRow(
                        icon: Icons.delete_outline,
                        label: l10n.moveToRecycleBin,
                        color: AppColors.dangerStrong,
                        onTap: () => onSelect(_DetailMoreAction.recycle),
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _MoreRow(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                    fontSize: AppTypography.s14,
                    color: color,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SelectRow(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfacePrimarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadii.r18),
          border: Border.all(
              color: selected
                  ? AppColors.brandPrimary.withValues(alpha: 0.25)
                  : AppColors.borderLight),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppTypography.s14,
                  fontWeight: FontWeight.w500,
                  color:
                      selected ? AppColors.brandPrimary : AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected)
              const Icon(Icons.check, color: AppColors.brandPrimary),
          ],
        ),
      ),
    );
  }
}

class _MoveToFolderSheet extends ConsumerWidget {
  final String? currentFolderId;
  final List<Folder> folders;
  const _MoveToFolderSheet(
      {required this.currentFolderId, required this.folders});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetHeader(
                title: l10n.moveToFolder,
                onClose: () => Navigator.of(context).pop(null)),
            const SizedBox(height: 10),
            _SelectRow(
              label: l10n.allFiles,
              selected: currentFolderId == null,
              onTap: () => Navigator.of(context).pop(''),
            ),
            const SizedBox(height: 8),
            for (final f in folders) ...[
              _SelectRow(
                label: f.name,
                selected: currentFolderId == f.id,
                onTap: () => Navigator.of(context).pop(f.id),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _TopTabs extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onChanged;
  const _TopTabs({required this.tab, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    TextStyle style(bool selected) =>
        Theme.of(context).textTheme.titleMedium!.copyWith(
              fontWeight: FontWeight.w500,
              fontSize: AppTypography.s16,
              color:
                  selected ? AppColors.textPrimary : AppColors.textPlaceholder,
            );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => onChanged(0),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              children: [
                Text(l10n.source, style: style(tab == 0)),
                const SizedBox(height: 6),
                Container(
                  height: 3,
                  width: 44,
                  decoration: BoxDecoration(
                    color: tab == 0 ? Colors.black : Colors.transparent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          onTap: () => onChanged(1),
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              children: [
                Text(l10n.note, style: style(tab == 1)),
                const SizedBox(height: 6),
                Container(
                  height: 3,
                  width: 44,
                  decoration: BoxDecoration(
                    color: tab == 1 ? Colors.black : Colors.transparent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceTab extends ConsumerWidget {
  final Recording recording;
  final Color primary;
  final VoidCallback onTranscribeAndSummarize;
  final VoidCallback onGenerateSummary;
  final ValueNotifier<String>? transcribeProgress;
  final bool inlineTranscribeProgress;
  final bool hidePrimaryAction;

  /// True while the source file is still syncing — the transcribe entry is
  /// disabled (transcription needs the complete audio) and a hint is shown.
  final bool syncInProgress;

  const _SourceTab({
    required this.recording,
    required this.primary,
    required this.onTranscribeAndSummarize,
    required this.onGenerateSummary,
    this.transcribeProgress,
    this.inlineTranscribeProgress = false,
    this.hidePrimaryAction = false,
    this.syncInProgress = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final transcript = recording.transcript;
    if (transcript == null || transcript.trim().isEmpty) {
      return _DetailEmptyState(
        title: l10n.noTranscriptYet,
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
        bottomSpaceAfterButton: 32,
        onTranscribeAndSummarize: onTranscribeAndSummarize,
        hidePrimaryAction: hidePrimaryAction,
        syncInProgress: syncInProgress,
      );
    }

    final progress = transcribeProgress;
    final showInline = inlineTranscribeProgress && progress != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.transcription,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          if (showInline) ...[
            const SizedBox(height: 12),
            _TranscribeProgressInlineCard(message: progress),
          ],
          SizedBox(height: showInline ? 12 : 10),
          Expanded(
            child: ListView(
              key: ValueKey(transcript),
              children: parseTranscriptBlocks(transcript)
                  .map((b) => _TranscriptBlockView(block: b))
                  .toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _NoteTab extends ConsumerStatefulWidget {
  final Recording recording;
  final Color primary;
  final VoidCallback onGenerateAgain;
  final VoidCallback onSummarize;
  final VoidCallback onTranscribeAndSummarize;
  final String? streamingSummary;
  final bool isStreaming;
  final String? lastSummaryText;
  final String? generatedSessionId;
  final int? lastGeneratedAssistantMessageId;
  final VoidCallback? onDeletedSessionMessage;
  final int syncToken;

  /// While transcribe/summarize runs, hide empty-state primary button ("Summarize" / "Transcribe and summarize"); parent sets false on failure/done.
  final bool hidePrimaryAction;

  const _NoteTab({
    required this.recording,
    required this.primary,
    required this.onGenerateAgain,
    required this.onSummarize,
    required this.onTranscribeAndSummarize,
    required this.streamingSummary,
    required this.isStreaming,
    required this.lastSummaryText,
    required this.generatedSessionId,
    required this.lastGeneratedAssistantMessageId,
    this.onDeletedSessionMessage,
    required this.syncToken,
    required this.hidePrimaryAction,
  });

  @override
  ConsumerState<_NoteTab> createState() => _NoteTabState();
}

class _NoteTabState extends ConsumerState<_NoteTab>
    with SingleTickerProviderStateMixin {
  String? _currentSessionId;
  String? _currentSessionTitle;
  String? _selectedLocalSummaryId;
  int? _selectedMessageId;
  bool _usingLocalFallback = false;
  late final AnimationController _pulseCtrl;
  late final ScrollController _summaryScrollCtrl;
  List<LlmSessionMessage>? _messages;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _summaryScrollCtrl = ScrollController();
    _adoptGeneratedSessionIfNeeded(force: true);
  }

  @override
  void didUpdateWidget(covariant _NoteTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final recordingChanged = oldWidget.recording.id != widget.recording.id;
    if (recordingChanged) {
      _currentSessionId = null;
      _currentSessionTitle = null;
      _selectedLocalSummaryId = null;
      _selectedMessageId = null;
      _usingLocalFallback = false;
      _messages = null;
    }
    final shouldAdoptGenerated =
        recordingChanged || widget.syncToken != oldWidget.syncToken;
    if (shouldAdoptGenerated) {
      _adoptGeneratedSessionIfNeeded();
    }
    // After a new summary, if this is the "just generated" session and messages not fetched yet, load so delete works.
    if (!widget.isStreaming &&
        _currentSessionId != null &&
        _currentSessionId == widget.generatedSessionId?.trim() &&
        _messages == null) {
      _loadMessagesForCurrentSession();
    }
    if (widget.streamingSummary != oldWidget.streamingSummary &&
        widget.streamingSummary != null &&
        widget.streamingSummary!.trim().isNotEmpty) {
      _scrollSummaryToBottom();
    }
  }

  void _adoptGeneratedSessionIfNeeded({bool force = false}) {
    if (!force && widget.isStreaming) return;
    final sid = widget.generatedSessionId?.trim();
    if (sid == null || sid.isEmpty || sid == _currentSessionId) return;
    _currentSessionId = sid;
    _currentSessionTitle = null;
    _selectedLocalSummaryId = null;
    _selectedMessageId = null;
    _usingLocalFallback = false;
    _messages = null;
  }

  void _scrollSummaryToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_summaryScrollCtrl.hasClients) return;
      final pos = _summaryScrollCtrl.position;
      _summaryScrollCtrl.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _loadMessagesForCurrentSession() async {
    final sid = _currentSessionId?.trim();
    if (sid == null || sid.isEmpty) return;
    try {
      final repo = await ref.read(llmSessionRemoteRepositoryProvider.future);
      final msgs = await repo.getSessionMessagesRemote(sid);
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        final assistant = _pickAssistantMessageForPreview(msgs);
        _selectedMessageId = assistant?.id ?? _pickDefaultMessage(msgs)?.id;
      });
    } catch (_) {
      // On failure, ignore; delete stays disabled.
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _summaryScrollCtrl.dispose();
    super.dispose();
  }

  Future<List<RecordingSummaryVersion>> _loadLocalSummaries() async {
    final repo = await ref.read(recordingsRepositoryProvider.future);
    return repo.listSummaryVersions(widget.recording.id);
  }

  int _compareSessionsNewestFirst(LlmSession a, LlmSession b) {
    final ta =
        a.updatedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final tb =
        b.updatedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final c = tb.compareTo(ta);
    if (c != 0) return c;
    return b.sessionId.compareTo(a.sessionId);
  }

  Future<void> _deleteCurrentMessage(String sessionId, int messageId) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await AppDialogs.showDeleteConfirm(
      context,
      title: l10n.deleteSession,
      message: l10n.deleteSessionMessage,
      deleteText: l10n.delete,
    );
    if (!ok) return;
    // After delete, clear parent-cached id so a second tap does not 404 with a stale id.
    void clearParentGeneratedId() => widget.onDeletedSessionMessage?.call();
    final repo = await ref.read(llmSessionRemoteRepositoryProvider.future);
    try {
      await repo.deleteMessage(sessionId, messageId);
    } on ServerException catch (e) {
      if (e.statusCode != 404) rethrow;
      // 404: message gone on server (maybe already deleted) — treat as deleted, sync local, update UI.
    }
    clearParentGeneratedId();
    // Remove matching local Summary version if mapping exists.
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final localBeforeDelete =
        await recRepo.listSummaryVersions(widget.recording.id);
    final mappedLocalSummary =
        _pickLocalSummaryForRemote(localBeforeDelete, sessionId, messageId);
    if (mappedLocalSummary != null) {
      await recRepo.deleteSummaryVersion(
        recordingId: widget.recording.id,
        summaryId: mappedLocalSummary.id,
      );
    } else {
      await recRepo.deleteSummaryVersionByRemote(
        recordingId: widget.recording.id,
        remoteSessionId: sessionId,
        remoteMessageId: messageId,
      );
    }
    ref.invalidate(recordingSummaryVersionsProvider(widget.recording.id));
    ref.invalidate(recordingByIdProvider(widget.recording.id));
    bumpRecordingsLists(ref);
    if (!mounted) return;
    final remaining = (_messages ?? const <LlmSessionMessage>[])
        .where((m) => m.id != messageId)
        .toList(growable: false);
    final hasAssistant = _pickAssistantMessageForPreview(remaining) != null;
    if (!hasAssistant) {
      // No valid summary left in this session — switch to latest valid remote/local summary.
      List<LlmSession> sessions;
      var usedLocalSessions = false;
      try {
        final asrId = await recRepo.ensureAsrResultId(widget.recording.id);
        sessions = await repo.listSessionsRemote(
          asrResultId: asrId,
          includeMessages: true,
          messageLimit: 100,
        );
      } catch (_) {
        sessions = await repo.listSessionsLocal(includeMessages: true);
        usedLocalSessions = true;
      }
      if (!mounted) return;
      final validSessions = sessions
          .where((s) => s.sessionId != sessionId && _isSessionValid(s))
          .toList()
        ..sort(_compareSessionsNewestFirst);
      if (validSessions.isNotEmpty) {
        final latestSession = validSessions.first;
        final latestMessages =
            latestSession.messages ?? const <LlmSessionMessage>[];
        final latestMessageId =
            _pickAssistantMessageForPreview(latestMessages)?.id ??
                _pickDefaultMessage(latestMessages)?.id;
        setState(() {
          _currentSessionId = latestSession.sessionId;
          _currentSessionTitle = latestSession.title.trim().isEmpty
              ? null
              : latestSession.title.trim();
          _selectedLocalSummaryId = null;
          _selectedMessageId = latestMessageId;
          _messages = latestMessages;
          _usingLocalFallback = usedLocalSessions;
        });
        return;
      }

      // If remote has no valid summary, use latest local summary list entry (or empty).
      final localList = await _loadLocalSummaries();
      if (!mounted) return;
      final latestId = localList.isNotEmpty ? localList.last.id : null;
      if (localList.isEmpty) {
        await ref
            .read(recordingSummaryVersionsProvider(widget.recording.id).future);
        if (!mounted) return;
      }
      setState(() {
        _currentSessionId = null;
        _currentSessionTitle = null;
        _selectedLocalSummaryId = latestId;
        _selectedMessageId = null;
        _messages = null;
        _usingLocalFallback = true;
      });
      return;
    }
    setState(() {
      _messages = remaining;
      if (_selectedMessageId == messageId) {
        _selectedMessageId = _pickAssistantMessageForPreview(remaining)?.id ??
            _pickDefaultMessage(remaining)?.id;
      }
    });
  }

  Future<void> _deleteCurrentLocalSummary() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await AppDialogs.showDeleteConfirm(
      context,
      title: l10n.deleteCurrentSummary,
      message: l10n.deleteSessionMessage,
      deleteText: l10n.delete,
    );
    if (!ok) return;
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final localList = await _loadLocalSummaries();
    final persistedId = widget.recording.currentSummaryId?.trim();
    final currentId = _selectedLocalSummaryId ??
        ((persistedId != null && persistedId.isNotEmpty)
            ? persistedId
            : null) ??
        (localList.isNotEmpty ? localList.last.id : null);
    if (currentId == null) return;
    await recRepo.deleteSummaryVersion(
        recordingId: widget.recording.id, summaryId: currentId);
    ref.invalidate(recordingSummaryVersionsProvider(widget.recording.id));
    ref.invalidate(recordingByIdProvider(widget.recording.id));
    bumpRecordingsLists(ref);
    // Wait for version list refresh before setState; after delete pick latest or empty state.
    final refreshedVersions = await ref
        .read(recordingSummaryVersionsProvider(widget.recording.id).future);
    if (!mounted) return;
    setState(() {
      _currentSessionId = null;
      _currentSessionTitle = null;
      _messages = null;
      _selectedMessageId = null;
      _selectedLocalSummaryId =
          refreshedVersions.isNotEmpty ? refreshedVersions.last.id : null;
      _usingLocalFallback = true;
    });
  }

  LlmSessionMessage? _pickMessageById(
      List<LlmSessionMessage> messages, int? id) {
    if (id == null) return null;
    return messages.where((m) => m.id == id).firstOrNull;
  }

  LlmSessionMessage? _pickDefaultMessage(List<LlmSessionMessage> messages) {
    if (messages.isEmpty) return null;
    final list = [...messages];
    list.sort((a, b) {
      final ta = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final c = tb.compareTo(ta);
      if (c != 0) return c;
      return b.id.compareTo(a.id);
    });
    return list.first;
  }

  /// For preview, prefer assistant (summary) over user (transcript).
  LlmSessionMessage? _pickAssistantMessageForPreview(
      List<LlmSessionMessage> messages) {
    final assistants = messages.where((m) => m.role == 'assistant').toList();
    if (assistants.isEmpty) return null;
    final list = [...assistants];
    list.sort((a, b) {
      final ta = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final c = tb.compareTo(ta);
      if (c != 0) return c;
      return b.id.compareTo(a.id);
    });
    final picked = list.first;
    if (isErrorLikeContent(picked.content)) return null;
    return picked;
  }

  /// List only sessions with a valid summary (drop empty or error-only).
  bool _isSessionValid(LlmSession s) {
    final msgs = s.messages ?? const <LlmSessionMessage>[];
    return _pickAssistantMessageForPreview(msgs) != null;
  }

  RecordingSummaryVersion? _pickLocalSummary(
    List<RecordingSummaryVersion> versions,
    String? pickedId,
  ) {
    if (versions.isEmpty) return null;
    if (pickedId != null) {
      final matched = versions.where((v) => v.id == pickedId).firstOrNull;
      if (matched != null) return matched;
    }
    final persistedId = widget.recording.currentSummaryId?.trim();
    if (persistedId != null && persistedId.isNotEmpty) {
      final matched = versions.where((v) => v.id == persistedId).firstOrNull;
      if (matched != null) return matched;
    }
    return versions.last;
  }

  RecordingSummaryVersion? _pickLocalSummaryForRemote(
    List<RecordingSummaryVersion> versions,
    String? sessionId,
    int? messageId,
  ) {
    final sid = sessionId?.trim();
    if (sid == null || sid.isEmpty) return null;
    final byMessage = messageId != null && messageId > 0
        ? versions
            .where((v) =>
                v.remoteSessionId == sid && v.remoteMessageId == messageId)
            .firstOrNull
        : null;
    if (byMessage != null) return byMessage;
    final matched = versions.where((v) => v.remoteSessionId == sid).toList();
    return matched.isEmpty ? null : matched.last;
  }

  String _displayTitleForLocalSummary(
    RecordingSummaryVersion version,
    AppLocalizations l10n, {
    int maxRunes = 48,
  }) {
    return summaryHistoryDisplayTitle(
      localizedGenericPrefix: l10n.summaryVersionPrefix,
      storedTitle: version.title,
      summaryContent: version.content,
      maxRunes: maxRunes,
    );
  }

  String _displayTitleForSession({
    required String? sessionTitle,
    required LlmSessionMessage? displayMessage,
    required RecordingSummaryVersion? localVersion,
    required AppLocalizations l10n,
    int maxRunes = 48,
  }) {
    if (localVersion != null) {
      return _displayTitleForLocalSummary(localVersion, l10n,
          maxRunes: maxRunes);
    }
    return summaryHistoryDisplayTitle(
      localizedGenericPrefix: l10n.summaryVersionPrefix,
      storedTitle: sessionTitle,
      summaryContent: displayMessage?.content,
      emptyFallback: l10n.sessionHistory,
      maxRunes: maxRunes,
    );
  }

  Future<void> _selectLocalSummary(String summaryId) async {
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    await recRepo.setCurrentSummary(
      recordingId: widget.recording.id,
      summaryId: summaryId,
    );
    ref.invalidate(recordingSummaryVersionsProvider(widget.recording.id));
    ref.invalidate(recordingByIdProvider(widget.recording.id));
    bumpRecordingsLists(ref);
    if (!mounted) return;
    setState(() {
      _currentSessionId = null;
      _currentSessionTitle = null;
      _selectedLocalSummaryId = summaryId;
      _selectedMessageId = null;
      _usingLocalFallback = true;
      _messages = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final streamingText = widget.streamingSummary;
    final hasStreamingText =
        streamingText != null && streamingText.trim().isNotEmpty;
    final lastSummaryText = widget.lastSummaryText;
    final hasLastSummaryText =
        lastSummaryText != null && lastSummaryText.trim().isNotEmpty;
    final showLastSummary = hasLastSummaryText;
    final showStreaming =
        hasStreamingText && (widget.isStreaming || !showLastSummary);
    // Show "AI is generating..." as soon as summarize is called (same as loading), do not wait for first chunk.
    final isGenerating = widget.isStreaming || showStreaming;
    final jobState = widget.recording.jobState.trim();
    final localSummariesAsync =
        ref.watch(recordingSummaryVersionsProvider(widget.recording.id));
    final hasLoadedLocalSummaries = localSummariesAsync.hasValue;

    final localVersions =
        localSummariesAsync.valueOrNull ?? const <RecordingSummaryVersion>[];
    final localPicked =
        _pickLocalSummary(localVersions, _selectedLocalSummaryId);
    final currentId = _currentSessionId;
    final messageValue = _messages ?? const <LlmSessionMessage>[];
    final rawDisplayMessage =
        _pickMessageById(messageValue, _selectedMessageId) ??
            _pickAssistantMessageForPreview(messageValue) ??
            _pickDefaultMessage(messageValue);
    // Note tab: summary (assistant) only, not transcript (user).
    final displayMessage =
        (rawDisplayMessage?.role == 'assistant') ? rawDisplayMessage : null;
    final localVersionForCurrentSession = currentId == null
        ? null
        : _pickLocalSummaryForRemote(
            localVersions,
            currentId,
            displayMessage?.id,
          );
    final title = currentId == null
        ? (localPicked == null
            ? l10n.sessionHistory
            : _displayTitleForLocalSummary(localPicked, l10n, maxRunes: 24))
        : _displayTitleForSession(
            sessionTitle: _currentSessionTitle,
            displayMessage: displayMessage,
            localVersion: localVersionForCurrentSession,
            l10n: l10n,
            maxRunes: 24,
          );
    final assistantForDelete =
        displayMessage ?? _pickAssistantMessageForPreview(messageValue);
    // Right after summary, GET messages may not include assistant yet; parent lastGeneratedAssistantMessageId still allows delete.
    final messageIdToDelete = assistantForDelete?.id ??
        (currentId == widget.generatedSessionId?.trim()
            ? widget.lastGeneratedAssistantMessageId
            : null);
    final canDeleteSummary = currentId != null
        ? messageIdToDelete != null
        : (localVersions.isNotEmpty || localPicked != null);
    final generatedSid = widget.generatedSessionId?.trim();
    final isViewingGeneratedSession = currentId != null &&
        generatedSid != null &&
        generatedSid.isNotEmpty &&
        currentId == generatedSid;
    final hasSummaryContent = showStreaming ||
        (showLastSummary &&
            (currentId == null ||
                (isViewingGeneratedSession && displayMessage == null))) ||
        (displayMessage != null && displayMessage.content.trim().isNotEmpty) ||
        (localVersions.isNotEmpty &&
            ((localPicked ?? localVersions.lastOrNull)?.content ?? '')
                .trim()
                .isNotEmpty);
    // If this is the "just generated" session and messages not loaded, fetch once so delete works.
    if (!showStreaming &&
        currentId != null &&
        currentId == widget.generatedSessionId?.trim() &&
        _messages == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_currentSessionId == currentId && _messages == null) {
          _loadMessagesForCurrentSession();
        }
      });
    }
    IconData? statusIcon;
    Color? statusColor;
    String? statusText;
    if (isGenerating) {
      statusIcon = Icons.auto_awesome_rounded;
      statusColor = widget.primary;
      statusText = l10n.summarizing;
    } else {
      switch (jobState) {
        case 'failed':
          statusIcon = Icons.error_outline_rounded;
          statusColor = AppColors.dangerStrong;
          statusText = l10n.statusFailed;
          break;
        case 'done':
          if (hasSummaryContent) {
            statusIcon = Icons.check_circle_rounded;
            statusColor = AppColors.success;
            statusText = l10n.summaryComplete;
          }
          break;
      }
    }
    final showStatusLine = statusText != null && statusText.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top controls: history dropdown (capped width) + actions (fixed right)
          Row(
            children: [
              SizedBox(
                width: MediaQuery.sizeOf(context).width - 180,
                child: InkWell(
                  onTap: () async {
                    final repo = await ref
                        .read(llmSessionRemoteRepositoryProvider.future);
                    final recRepo =
                        await ref.read(recordingsRepositoryProvider.future);
                    final asrId =
                        await recRepo.ensureAsrResultId(widget.recording.id);
                    List<LlmSession> sessions;
                    var usedLocal = false;
                    try {
                      sessions = await repo.listSessionsRemote(
                        asrResultId: asrId,
                        includeMessages: true,
                        messageLimit: 100,
                      );
                    } catch (e) {
                      if (!mounted) return;
                      sessions =
                          await repo.listSessionsLocal(includeMessages: true);
                      usedLocal = true;
                    }
                    if (!context.mounted) return;
                    if (sessions.isEmpty) {
                      final localList = await _loadLocalSummaries();
                      if (!context.mounted) return;
                      if (localList.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.noSummaryYet)));
                        return;
                      }
                      final pickedLocal = await _pickFromList<String>(
                        context,
                        title: l10n.summary,
                        items:
                            localList.map((v) => v.id).toList(growable: false),
                        labelOf: (id) => _displayTitleForLocalSummary(
                            localList.firstWhere((v) => v.id == id), l10n),
                        selected: _selectedLocalSummaryId ??
                            widget.recording.currentSummaryId,
                      );
                      if (pickedLocal == null) return;
                      await _selectLocalSummary(pickedLocal);
                      return;
                    }
                    final validSessions =
                        sessions.where(_isSessionValid).toList();
                    if (validSessions.isEmpty) {
                      final localList = await _loadLocalSummaries();
                      if (!context.mounted) return;
                      if (localList.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.noSummaryYet)));
                        return;
                      }
                      final pickedLocal = await _pickFromList<String>(
                        context,
                        title: l10n.summary,
                        items:
                            localList.map((v) => v.id).toList(growable: false),
                        labelOf: (id) => _displayTitleForLocalSummary(
                            localList.firstWhere((v) => v.id == id), l10n),
                        selected: _selectedLocalSummaryId ??
                            widget.recording.currentSummaryId,
                      );
                      if (pickedLocal == null) return;
                      await _selectLocalSummary(pickedLocal);
                      return;
                    }
                    final sessionsToShow = validSessions;
                    final pickedSid = await _pickFromList<String>(
                      context,
                      title: l10n.sessionHistory,
                      items: sessionsToShow
                          .map((s) => s.sessionId)
                          .toList(growable: false),
                      labelOf: (sid) {
                        final s =
                            sessions.firstWhere((x) => x.sessionId == sid);
                        final msgs = s.messages ?? const <LlmSessionMessage>[];
                        final assistant = _pickAssistantMessageForPreview(msgs);
                        final localSummary = _pickLocalSummaryForRemote(
                          localVersions,
                          sid,
                          assistant?.id,
                        );
                        if (localSummary != null) {
                          return _displayTitleForLocalSummary(
                              localSummary, l10n);
                        }
                        return summaryHistoryDisplayTitle(
                          localizedGenericPrefix: l10n.summaryVersionPrefix,
                          storedTitle: s.title,
                          summaryContent: assistant?.content,
                          sessionIdFallback: sid,
                          emptyFallback: l10n.sessionHistory,
                        );
                      },
                      selected: _currentSessionId,
                    );
                    if (pickedSid == null || !context.mounted) return;
                    final pickedSession =
                        sessions.firstWhere((x) => x.sessionId == pickedSid);
                    final msgs =
                        pickedSession.messages ?? const <LlmSessionMessage>[];
                    final pickedMsgId =
                        _pickAssistantMessageForPreview(msgs)?.id ??
                            _pickDefaultMessage(msgs)?.id;
                    final mappedLocal = _pickLocalSummaryForRemote(
                        localVersions, pickedSid, pickedMsgId);
                    if (mappedLocal != null) {
                      await recRepo.setCurrentSummary(
                        recordingId: widget.recording.id,
                        summaryId: mappedLocal.id,
                      );
                      ref.invalidate(
                          recordingByIdProvider(widget.recording.id));
                      bumpRecordingsLists(ref);
                    }
                    if (!context.mounted) return;
                    setState(() {
                      _currentSessionId = pickedSid;
                      _currentSessionTitle = pickedSession.title.trim().isEmpty
                          ? null
                          : pickedSession.title.trim();
                      _messages = msgs;
                      _selectedMessageId = pickedMsgId;
                      _selectedLocalSummaryId = null;
                      _usingLocalFallback = usedLocal;
                    });
                  },
                  borderRadius: BorderRadius.circular(AppRadii.r14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMuted,
                      borderRadius: BorderRadius.circular(AppRadii.r14),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w500,
                              fontSize: AppTypography.s14,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.keyboard_arrow_down_rounded,
                            color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed:
                    widget.hidePrimaryAction ? null : widget.onGenerateAgain,
                icon: const Icon(Icons.add),
                tooltip: l10n.summarizeAgain,
              ),
              IconButton(
                tooltip: l10n.deleteSession,
                onPressed: canDeleteSummary &&
                        (currentId == null || messageIdToDelete != null)
                    ? (currentId != null
                        ? () =>
                            _deleteCurrentMessage(currentId, messageIdToDelete!)
                        : _deleteCurrentLocalSummary)
                    : null,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),

          const SizedBox(height: 10),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            child: showStatusLine
                ? SizedBox(
                    height: 22,
                    child: Row(
                      children: [
                        if (isGenerating)
                          FadeTransition(
                            opacity: CurvedAnimation(
                                parent: _pulseCtrl, curve: Curves.easeInOut),
                            child:
                                Icon(statusIcon, size: 16, color: statusColor),
                          )
                        else
                          Icon(statusIcon, size: 16, color: statusColor),
                        const SizedBox(width: 6),
                        Text(
                          statusText,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w500,
                            fontSize: AppTypography.s14,
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          const SizedBox(height: 12),
          Text(l10n.aiDisclaimer,
              style: const TextStyle(color: AppColors.textPlaceholder)),
          const SizedBox(height: 16),

          Expanded(
            child: Builder(
              builder: (context) {
                Widget contentBody;
                final generatedSid = widget.generatedSessionId?.trim();
                final isViewingGeneratedSession = currentId != null &&
                    generatedSid != null &&
                    generatedSid.isNotEmpty &&
                    currentId == generatedSid;
                if (showStreaming) {
                  contentBody = _CanvasSummaryView(
                    text: streamingText,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(height: 1.4),
                    color: AppColors.textPrimary,
                  );
                } else if (widget.isStreaming) {
                  // Re-summarize: clear old text first, wait for new stream.
                  contentBody = const SizedBox.shrink();
                } else if (currentId == null &&
                    hasLoadedLocalSummaries &&
                    localVersions.isEmpty &&
                    !showLastSummary) {
                  // Empty state only when no local history and no in-memory fresh text (avoids Provider lag hiding _lastSummaryText).
                  final hasTranscript =
                      (widget.recording.transcript ?? '').trim().isNotEmpty;
                  contentBody = _DetailEmptyState(
                    title: l10n.noSummaryYet,
                    padding: const EdgeInsets.fromLTRB(0, 28, 0, 0),
                    bottomSpaceAfterButton: 8,
                    onTranscribeAndSummarize: widget.onTranscribeAndSummarize,
                    hasTranscript: hasTranscript,
                    onSummarize: widget.onSummarize,
                    hidePrimaryAction: widget.hidePrimaryAction,
                  );
                } else if (showLastSummary &&
                    (currentId == null ||
                        (isViewingGeneratedSession &&
                            displayMessage == null))) {
                  contentBody = _CanvasSummaryView(
                    text: lastSummaryText,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(height: 1.4),
                    color: AppColors.textPrimary,
                  );
                } else if (currentId == null) {
                  contentBody = localSummariesAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Text(e.toString()),
                    data: (versions) {
                      if (versions.isEmpty) {
                        final hasTranscript =
                            (widget.recording.transcript ?? '')
                                .trim()
                                .isNotEmpty;
                        return _DetailEmptyState(
                          title: l10n.noSummaryYet,
                          padding: const EdgeInsets.fromLTRB(0, 28, 0, 0),
                          bottomSpaceAfterButton: 8,
                          onTranscribeAndSummarize:
                              widget.onTranscribeAndSummarize,
                          hasTranscript: hasTranscript,
                          onSummarize: widget.onSummarize,
                          hidePrimaryAction: widget.hidePrimaryAction,
                        );
                      }
                      final fallback = widget.recording.summary?.trim();
                      final picked =
                          _pickLocalSummary(versions, _selectedLocalSummaryId);
                      final text = picked?.content ??
                          (versions.isNotEmpty
                              ? versions.last.content
                              : (fallback ?? ''));
                      if (text.trim().isEmpty) {
                        final hasTranscript =
                            (widget.recording.transcript ?? '')
                                .trim()
                                .isNotEmpty;
                        return _DetailEmptyState(
                          title: l10n.noSummaryYet,
                          padding: const EdgeInsets.fromLTRB(0, 28, 0, 0),
                          bottomSpaceAfterButton: 8,
                          onTranscribeAndSummarize:
                              widget.onTranscribeAndSummarize,
                          hasTranscript: hasTranscript,
                          onSummarize: widget.onSummarize,
                          hidePrimaryAction: widget.hidePrimaryAction,
                        );
                      }
                      return _CanvasSummaryView(
                        text: text,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(height: 1.4),
                        color: AppColors.textPrimary,
                      );
                    },
                  );
                } else if (displayMessage == null) {
                  if (_usingLocalFallback) {
                    contentBody = localSummariesAsync.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Text(e.toString()),
                      data: (versions) {
                        if (versions.isEmpty) {
                          final hasTranscript =
                              (widget.recording.transcript ?? '')
                                  .trim()
                                  .isNotEmpty;
                          return _DetailEmptyState(
                            title: l10n.noSummaryYet,
                            padding: const EdgeInsets.fromLTRB(0, 28, 0, 0),
                            bottomSpaceAfterButton: 8,
                            onTranscribeAndSummarize:
                                widget.onTranscribeAndSummarize,
                            hasTranscript: hasTranscript,
                            onSummarize: widget.onSummarize,
                            hidePrimaryAction: widget.hidePrimaryAction,
                          );
                        }
                        final fallback = widget.recording.summary?.trim();
                        final picked = _pickLocalSummary(
                            versions, _selectedLocalSummaryId);
                        final text = picked?.content ??
                            (versions.isNotEmpty
                                ? versions.last.content
                                : (fallback ?? ''));
                        if (text.trim().isEmpty) {
                          final hasTranscript =
                              (widget.recording.transcript ?? '')
                                  .trim()
                                  .isNotEmpty;
                          return _DetailEmptyState(
                            title: l10n.noSummaryYet,
                            padding: const EdgeInsets.fromLTRB(0, 28, 0, 0),
                            bottomSpaceAfterButton: 8,
                            onTranscribeAndSummarize:
                                widget.onTranscribeAndSummarize,
                            hasTranscript: hasTranscript,
                            onSummarize: widget.onSummarize,
                            hidePrimaryAction: widget.hidePrimaryAction,
                          );
                        }
                        return _CanvasSummaryView(
                          text: text,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(height: 1.4),
                          color: AppColors.textPrimary,
                        );
                      },
                    );
                  } else {
                    final hasTranscript =
                        (widget.recording.transcript ?? '').trim().isNotEmpty;
                    contentBody = _DetailEmptyState(
                      title: l10n.noSummaryYet,
                      padding: const EdgeInsets.fromLTRB(0, 28, 0, 0),
                      bottomSpaceAfterButton: 8,
                      onTranscribeAndSummarize: widget.onTranscribeAndSummarize,
                      hasTranscript: hasTranscript,
                      onSummarize: widget.onSummarize,
                      hidePrimaryAction: widget.hidePrimaryAction,
                    );
                  }
                } else {
                  contentBody = _CanvasSummaryView(
                    text: displayMessage.content,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(height: 1.4),
                    color: AppColors.textPrimary,
                  );
                }
                if (contentBody is _DetailEmptyState) {
                  return contentBody;
                }
                return SingleChildScrollView(
                  controller: _summaryScrollCtrl,
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: contentBody,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GenerateSheet extends ConsumerStatefulWidget {
  final Recording recording;
  final _AiSheetConfig config;
  final _GenerateSelection? initial;
  const _GenerateSheet(
      {required this.recording, required this.config, this.initial});

  @override
  ConsumerState<_GenerateSheet> createState() => _GenerateSheetState();
}

class _GenerateSheetState extends ConsumerState<_GenerateSheet> {
  bool _autoSpeaker = true;
  String _language = 'Auto';
  PromptTemplate? _template;
  LlmConfig? _llm;
  SttConfig? _stt;
  bool _didAutoPickDefaults = false;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      _autoSpeaker = init.autoSpeaker;
      _language = init.language;
      _template = init.template;
      _llm = init.llm;
      _stt = init.stt;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_preloadConfigs());
    });
  }

  Future<void> _preloadConfigs() async {
    await Future.wait([
      ensureSttConfigsLoaded(ref),
      ensureLlmConfigsLoaded(ref),
      ensurePromptTemplatesLoaded(ref),
    ]);
  }

  static bool _asyncLoading(AsyncValue<dynamic> async) =>
      async.isLoading && !async.hasValue;

  static Widget _sheetTrailingLoadingOr(Widget child, {required bool loading}) {
    if (loading) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.25),
      );
    }
    return child;
  }

  void _maybeAutoPickDefaults({
    required AsyncValue<List<PromptTemplate>> tplAsync,
    required AsyncValue<List<LlmConfig>> llmAsync,
    required AsyncValue<List<SttConfig>> sttAsync,
    required List<PromptTemplate> tplList,
    required List<LlmConfig> llmList,
    required List<SttConfig> sttList,
  }) {
    if (!_didAutoPickDefaults &&
        (tplAsync.hasValue || tplAsync.hasError) &&
        (llmAsync.hasValue || llmAsync.hasError) &&
        (sttAsync.hasValue || sttAsync.hasError)) {
      _didAutoPickDefaults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final rec = widget.recording;
        setState(() {
          if (_template == null && tplList.isNotEmpty) {
            final tid = rec.lastTemplateId?.trim();
            if (tid != null && tid.isNotEmpty) {
              _template = PromptTemplate.resolveStoredId(tplList, tid);
            }
            _template ??= tplList.first;
          }
          if (widget.config.showLlm && _llm == null && llmList.isNotEmpty) {
            _llm = llmList.resolveStoredLlmId(rec.lastLlmConfigId) ??
                llmList.first;
          }
          if (widget.config.showStt && _stt == null && sttList.isNotEmpty) {
            final sid = rec.lastSttConfigId?.trim();
            if (sid != null && sid.isNotEmpty) {
              try {
                _stt = sttList.firstWhere((c) => c.id == sid);
              } on StateError {
                _stt = null;
              }
            }
            _stt ??= sttList.first;
          }
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tplAsync = ref.watch(promptTemplatesProvider);
    final llmAsync = ref.watch(llmConfigsProvider);
    final sttAsync = ref.watch(sttConfigsProvider);

    final tplLoading = widget.config.showLlm && _asyncLoading(tplAsync);
    final llmLoading = widget.config.showLlm && _asyncLoading(llmAsync);
    final sttLoading = widget.config.showStt && _asyncLoading(sttAsync);

    final tplList = tplAsync.valueOrNull ?? const <PromptTemplate>[];
    final llmList = llmAsync.valueOrNull ?? const <LlmConfig>[];
    final sttList = sttAsync.valueOrNull ?? const <SttConfig>[];
    _maybeAutoPickDefaults(
      tplAsync: tplAsync,
      llmAsync: llmAsync,
      sttAsync: sttAsync,
      tplList: tplList,
      llmList: llmList,
      sttList: sttList,
    );
    final displayTemplate =
        _template ?? (tplList.isNotEmpty ? tplList.first : null);
    final displayLlm = _llm ??
        (widget.config.showLlm && llmList.isNotEmpty ? llmList.first : null);
    final displayStt = _stt ??
        (widget.config.showStt && sttList.isNotEmpty ? sttList.first : null);
    final locale = Localizations.localeOf(context);
    final autoSpeakerEnabled = widget.config.showStt &&
        !sttLoading &&
        displayStt != null &&
        configSupportsSpeakerDiarization(
          displayStt,
          language: _language,
          locale: locale,
        );
    final effectiveAutoSpeaker = autoSpeakerEnabled && _autoSpeaker;

    final configsReady = (!widget.config.showLlm || !tplLoading) &&
        (!widget.config.showLlm || !llmLoading) &&
        (!widget.config.showStt || !sttLoading);
    final canGenerate = configsReady &&
        (widget.config.showStt ? displayStt != null : true) &&
        (widget.config.showLlm
            ? (displayLlm != null && displayTemplate != null)
            : true);
    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AiSheetHeader(
              title: widget.config.title,
              icon: Icons.extension_outlined,
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 10),
            if (widget.config.showLlm)
              _SheetRow(
                label: l10n.template,
                trailing: _sheetTrailingLoadingOr(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayTemplate?.name ?? l10n.viewAll,
                        style: const TextStyle(
                            color: AppColors.textPlaceholder,
                            fontWeight: FontWeight.w500,
                            fontSize: AppTypography.s14),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right,
                          color: AppColors.textPlaceholder, size: 28),
                    ],
                  ),
                  loading: tplLoading,
                ),
                onTap: tplLoading
                    ? null
                    : () async {
                        final list =
                            (tplAsync.valueOrNull ?? const <PromptTemplate>[]);
                        final picked = await _pickFromList<PromptTemplate>(
                          context,
                          title: l10n.template,
                          items: list,
                          labelOf: (t) => t.name,
                          selected: displayTemplate,
                        );
                        if (picked != null) setState(() => _template = picked);
                      },
              ),
            if (widget.config.showStt)
              _SheetRow(
                label: l10n.autoSpeakerLabeling,
                trailing: Switch(
                  value: effectiveAutoSpeaker,
                  onChanged: autoSpeakerEnabled
                      ? (v) => setState(() => _autoSpeaker = v)
                      : null,
                ),
              ),
            if (widget.config.showLanguage)
              _SheetRow(
                label: l10n.audioLanguage,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _language == 'Auto'
                          ? l10n.auto
                          : (_language == 'zh'
                              ? l10n.languageChinese
                              : l10n.languageEnglish),
                      style: const TextStyle(
                          color: AppColors.textPlaceholder,
                          fontWeight: FontWeight.w500,
                          fontSize: AppTypography.s14),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right,
                        color: AppColors.textPlaceholder, size: 4),
                  ],
                ),
                onTap: () async {
                  final picked = await _pickFromList<String>(
                    context,
                    title: l10n.audioLanguage,
                    items: const ['Auto', 'zh', 'en'],
                    labelOf: (s) => s == 'Auto'
                        ? l10n.auto
                        : (s == 'zh'
                            ? l10n.languageChinese
                            : l10n.languageEnglish),
                  );
                  if (picked != null) setState(() => _language = picked);
                },
              ),
            if (widget.config.showStt)
              _SheetRow(
                label: l10n.sttModel,
                trailing: _sheetTrailingLoadingOr(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayStt?.name ?? l10n.select,
                        style: const TextStyle(
                            color: AppColors.textPlaceholder,
                            fontWeight: FontWeight.w500,
                            fontSize: AppTypography.s14),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right,
                          color: AppColors.textPlaceholder, size: 28),
                    ],
                  ),
                  loading: sttLoading,
                ),
                onTap: sttLoading
                    ? null
                    : () async {
                        final list =
                            sttAsync.valueOrNull ?? const <SttConfig>[];
                        final picked = await _pickFromList<SttConfig>(
                          context,
                          title: l10n.sttConfiguration,
                          items: list,
                          labelOf: (c) => c.name,
                          selected: displayStt,
                        );
                        if (picked != null) {
                          setState(() {
                            _stt = picked;
                            if (!configSupportsSpeakerDiarization(
                              picked,
                              language: _language,
                              locale: locale,
                            )) {
                              _autoSpeaker = false;
                            }
                          });
                        }
                      },
              ),
            if (widget.config.showLlm)
              _SheetRow(
                label: l10n.llmModel,
                trailing: _sheetTrailingLoadingOr(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayLlm?.name ?? l10n.select,
                        style: const TextStyle(
                            color: AppColors.textPlaceholder,
                            fontWeight: FontWeight.w500,
                            fontSize: AppTypography.s14),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right,
                          color: AppColors.textPlaceholder, size: 28),
                    ],
                  ),
                  loading: llmLoading,
                ),
                onTap: llmLoading
                    ? null
                    : () async {
                        final list =
                            llmAsync.valueOrNull ?? const <LlmConfig>[];
                        final picked = await _pickFromList<LlmConfig>(
                          context,
                          title: l10n.llmConfiguration,
                          items: list,
                          labelOf: (c) => c.modelName?.isNotEmpty == true
                              ? '${c.name} (${c.modelName})'
                              : c.name,
                          selected: displayLlm,
                        );
                        if (picked != null) setState(() => _llm = picked);
                      },
              ),
            const SizedBox(height: 24),
            AppBlackPillButton(
              label: l10n.generateNow,
              onPressed: canGenerate && !_submitted
                  ? () {
                      setState(() => _submitted = true);
                      Navigator.of(context).pop(_GenerateSelection(
                        template:
                            widget.config.showLlm ? displayTemplate : null,
                        llm: widget.config.showLlm ? displayLlm : null,
                        stt: widget.config.showStt ? displayStt : null,
                        language: _language,
                        autoSpeaker: widget.config.showStt
                            ? effectiveAutoSpeaker
                            : _autoSpeaker,
                      ));
                    }
                  : null,
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final String label;
  final Widget trailing;
  final VoidCallback? onTap;
  const _SheetRow({required this.label, required this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    fontSize: AppTypography.s16,
                    color: AppColors.textPrimary,
                  ),
            ),
          ),
          trailing,
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

class _SheetHeader extends StatelessWidget {
  final String title;
  final VoidCallback onClose;
  const _SheetHeader({required this.title, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: AppTypography.s18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onClose,
              child: const Icon(Icons.close,
                  size: 22, color: AppColors.textSecondary),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 4),
          child: Divider(height: 1, color: AppColors.borderLight),
        ),
      ],
    );
  }
}

class _AiSheetHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onClose;
  const _AiSheetHeader(
      {required this.title, required this.icon, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(icon, size: 22, color: AppColors.textPrimary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: AppTypography.s18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onClose,
              child: const Icon(Icons.close,
                  size: 22, color: AppColors.textSecondary),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 4),
          child: Divider(height: 1, color: AppColors.borderLight),
        ),
      ],
    );
  }
}

/// Shared empty state for Transcript / Note tabs: icon, title, body, button.
/// [padding] is top/left/right only: Source (16,28,16,0), Note (0,28,0,0).
/// [bottomSpaceAfterButton] gap from button to Expanded bottom; with parent padding keeps tab footers aligned: Source 32, Note 8 (outer +24).
/// [hasTranscript] true → "Summarize" button; false → "Transcribe and summarize"; use with [onSummarize].
/// [hidePrimaryAction] true hides the bottom primary during transcribe/summarize work.
/// Placeholder shown in place of the player while a device recording's audio
/// is still being pulled / merged. Mirrors the list/banner label & bar so the
/// state reads consistently; the page auto-swaps to the real player once the
/// transfer flips to `done` (provider invalidation triggers a rebuild).
class _SyncStatusCard extends StatelessWidget {
  final TransferSyncStatusPresentation presentation;

  const _SyncStatusCard({required this.presentation});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    final barValue = presentation.progressBarTarget;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.r18),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.25,
                  color: primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  presentation.statusLabel(l10n),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: barValue,
              backgroundColor: AppColors.borderLight,
              color: primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.waitCurrentTransferToRetry,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textPlaceholder,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailEmptyState extends StatelessWidget {
  final String title;
  final EdgeInsets padding;
  final double bottomSpaceAfterButton;
  final VoidCallback onTranscribeAndSummarize;
  final bool hasTranscript;
  final VoidCallback? onSummarize;
  final bool hidePrimaryAction;

  /// True while the source file is still syncing — transcription needs the
  /// complete audio, so the primary action is disabled with a hint.
  final bool syncInProgress;

  const _DetailEmptyState({
    required this.title,
    required this.padding,
    required this.bottomSpaceAfterButton,
    required this.onTranscribeAndSummarize,
    this.hasTranscript = false,
    this.onSummarize,
    this.hidePrimaryAction = false,
    this.syncInProgress = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showSummarize = hasTranscript && onSummarize != null;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.auto_awesome,
                            size: 52, color: AppColors.grayE0),
                        const SizedBox(height: 14),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          showSummarize
                              ? l10n.configureApiAndClickPlus
                              : l10n.configureApiAndTranscribe,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textPlaceholder,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (hidePrimaryAction)
            const SizedBox.shrink()
          else ...[
            AppBlackPillButton(
              label:
                  showSummarize ? l10n.summarize : l10n.transcribeAndSummarize,
              // Transcription needs the complete audio: keep the entry visible
              // but disabled while the source file is still syncing.
              onPressed: syncInProgress
                  ? null
                  : (showSummarize ? onSummarize! : onTranscribeAndSummarize),
            ),
            if (syncInProgress)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.waitCurrentTransferToRetry,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textPlaceholder,
                    height: 1.3,
                  ),
                ),
              ),
          ],
          SizedBox(height: bottomSpaceAfterButton),
        ],
      ),
    );
  }
}

/// Source tab with transcript body: progress card directly under the "Transcript" header.
class _TranscribeProgressInlineCard extends StatelessWidget {
  final ValueListenable<String> message;

  const _TranscribeProgressInlineCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: message,
      builder: (context, msg, _) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surfacePrimarySoft,
            borderRadius: BorderRadius.circular(AppRadii.r18),
            border: Border.all(color: AppColors.borderLight),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.25,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    msg,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// No transcript or on Note tab: fixed bottom progress strip (non-fullscreen).
///
/// On [HomeShellPage] the record FAB `Positioned(top: -28)` overlaps the inner Scaffold
/// `bottomNavigationBar`; reserve [kTranscribeBarShellRecordFabReserve] for text.
class _TranscribeProgressBottomBar extends StatelessWidget {
  /// Bottom inset matching the central record FAB overlap on [HomeShellPage] (logical pixels).
  static const double kTranscribeBarShellRecordFabReserve = 32;

  final ValueListenable<String> message;

  const _TranscribeProgressBottomBar({required this.message});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Material(
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      color: AppColors.surface,
      child: ValueListenableBuilder<String>(
        valueListenable: message,
        builder: (context, msg, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRect(
                child: LinearProgressIndicator(
                  minHeight: 3,
                  backgroundColor: AppColors.borderLight,
                  color: primary,
                ),
              ),
              SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    4 + kTranscribeBarShellRecordFabReserve,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.25,
                            color: primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          msg,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                  ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TranscriptBlockView extends StatelessWidget {
  final TranscriptBlock block;
  const _TranscriptBlockView({required this.block});

  String _speakerSuffix(String speaker) {
    return speaker.trim().toLowerCase().startsWith('speaker') ? ': ' : '：';
  }

  @override
  Widget build(BuildContext context) {
    final bodyStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          height: 1.32,
          fontSize: AppTypography.s16,
          color: AppColors.textPrimary,
          letterSpacing: 0,
        );
    if (!transcriptBlockShowsSpeakerLabel(block.speaker)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Text(block.text, style: bodyStyle),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '${block.speaker}${_speakerSuffix(block.speaker)}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppColors.brandPrimaryTap,
                        fontWeight: FontWeight.w600,
                        fontSize: AppTypography.s16,
                        height: 1.32,
                        letterSpacing: 0,
                      ),
                ),
                TextSpan(
                  text: block.text,
                  style: bodyStyle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> _pickFromList<T>(
  BuildContext context, {
  required String title,
  required List<T> items,
  required String Function(T) labelOf,
  T? selected,
}) async {
  return showAppBottomSheet<T>(
    context,
    builder: (sheetContext) => ListView(
      shrinkWrap: true,
      children: [
        ListTile(
            title: Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: AppTypography.s14,
                    color: AppColors.textPrimary))),
        for (final it in items)
          ListTile(
            title: Text(labelOf(it)),
            trailing: selected != null && it == selected
                ? const Icon(Icons.check, size: 18)
                : null,
            onTap: () => Navigator.of(sheetContext).pop(it),
          ),
      ],
    ),
  );
}

class _GenerateSelection {
  final PromptTemplate? template;
  final LlmConfig? llm;
  final SttConfig? stt;
  final String language;
  final bool autoSpeaker;
  _GenerateSelection({
    required this.template,
    required this.llm,
    required this.stt,
    required this.language,
    required this.autoSpeaker,
  });
}

class _CanvasSummaryView extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Color color;

  const _CanvasSummaryView({
    required this.text,
    required this.style,
    required this.color,
  });

  static const _accent = AppColors.brandPrimary;
  static const _bodyText = Color(0xFF374151); // gray-700
  static const _bodyTextSoft = Color(0xFF4B5563); // gray-600
  static String _stripCodeFences(String input) {
    if (input.trim().isEmpty) return input;
    final lines = input.split('\n');
    final out = <String>[];
    for (final raw in lines) {
      final t = raw.trim();
      if (t.startsWith('```')) continue;
      out.add(raw);
    }
    return out.join('\n');
  }

  static String _stripLeadingHashes(String s) {
    final t = s.trimLeft();
    var i = 0;
    while (i < t.length && t[i] == '#') {
      i++;
    }
    while (i < t.length && t[i] == ' ') {
      i++;
    }
    return i >= t.length ? t : t.substring(i);
  }

  List<InlineSpan> _parseInlineMarkdown(String text, TextStyle base,
      {Color? color, FontWeight? fontWeight}) {
    if (text.isEmpty) return [TextSpan(text: '', style: base)];
    final style = base.copyWith(
        color: color ?? base.color, fontWeight: fontWeight ?? base.fontWeight);
    final spans = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      if (i + 2 <= text.length && text.substring(i, i + 2) == '**') {
        final end = text.indexOf('**', i + 2);
        if (end == -1) {
          spans.add(TextSpan(text: '**', style: style));
          i += 2;
          continue;
        }
        spans.add(TextSpan(
            text: text.substring(i + 2, end),
            style: style.copyWith(fontWeight: FontWeight.w500)));
        i = end + 2;
      } else if (i < text.length &&
          text[i] == '*' &&
          (i + 1 >= text.length || text[i + 1] != '*')) {
        final end = text.indexOf('*', i + 1);
        if (end == -1 || (end + 1 < text.length && text[end + 1] == '*')) {
          spans.add(TextSpan(text: text[i], style: style));
          i++;
          continue;
        }
        spans.add(TextSpan(
            text: text.substring(i + 1, end),
            style: style.copyWith(fontStyle: FontStyle.italic)));
        i = end + 1;
      } else {
        final nextDouble = text.indexOf('**', i);
        final nextSingle = text.indexOf('*', i);
        int next = -1;
        int which = 0;
        if (nextDouble != -1 &&
            (nextSingle == -1 || nextDouble <= nextSingle)) {
          next = nextDouble;
          which = 1;
        } else if (nextSingle != -1) {
          next = nextSingle;
          which = 2;
        }
        if (next == -1) {
          spans.add(TextSpan(text: text.substring(i), style: style));
          break;
        }
        spans.add(TextSpan(text: text.substring(i, next), style: style));
        i = next;
        if (which == 1) {
          final end = text.indexOf('**', i + 2);
          if (end == -1) {
            spans.add(TextSpan(text: '**', style: style));
            i += 2;
            continue;
          }
          spans.add(TextSpan(
              text: text.substring(i + 2, end),
              style: style.copyWith(fontWeight: FontWeight.w500)));
          i = end + 2;
        } else {
          final end = text.indexOf('*', i + 1);
          if (end == -1 || (end + 1 < text.length && text[end + 1] == '*')) {
            spans.add(TextSpan(text: text[i], style: style));
            i++;
            continue;
          }
          spans.add(TextSpan(
              text: text.substring(i + 1, end),
              style: style.copyWith(fontStyle: FontStyle.italic)));
          i = end + 1;
        }
      }
    }
    return spans;
  }

  Widget _sectionHeader(String title, TextStyle base) {
    final stripped = _stripLeadingHashes(title);
    final headerStyle = base.copyWith(
      fontSize: (base.fontSize ?? 16) + 2,
      fontWeight: FontWeight.w500,
      height: 1.25,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: _accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: headerStyle,
                children: _parseInlineMarkdown(stripped, headerStyle),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bulletDot() => Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(color: _accent, shape: BoxShape.circle),
      );

  Widget _bulletLine(String line, TextStyle base) {
    // Two forms: normal bullet "- some text" / "- Key: Value..."
    // ** and * in content render as bold/italic, not literal.
    final content =
        line.startsWith('- ') ? line.substring(2).trimLeft() : line.trimLeft();
    final idx = content.indexOf(':');
    final isKv = idx > 0 &&
        idx < 32; // avoid treating colons in long sentences as key:value
    final bodyStyle = base.copyWith(
        color: _bodyText, height: 1.45, fontWeight: FontWeight.w500);
    final valueStyle = base.copyWith(
        color: _bodyTextSoft, height: 1.45, fontWeight: FontWeight.w500);
    if (isKv) {
      final key = content.substring(0, idx + 1).trimRight();
      final value = content.substring(idx + 1).trimLeft();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
                padding: const EdgeInsets.only(top: 7), child: _bulletDot()),
            const SizedBox(width: 10),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: bodyStyle,
                  children: [
                    ..._parseInlineMarkdown(
                        '$key ', base.copyWith(height: 1.45),
                        fontWeight: FontWeight.w500),
                    ..._parseInlineMarkdown(value, valueStyle),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 7), child: _bulletDot()),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                  style: bodyStyle,
                  children: _parseInlineMarkdown(content, bodyStyle)),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBlocks(String t, TextStyle base) {
    final lines = t.split('\n');
    final out = <Widget>[];

    // Title（H1）
    String? title;
    var i = 0;
    while (i < lines.length) {
      final s = lines[i].trim();
      if (s.isNotEmpty) {
        if (s.startsWith('# ')) {
          title = s.substring(2).trimLeft();
          i++;
        } else {}
        break;
      }
      i++;
    }

    if (title != null && title.isNotEmpty) {
      final h1Style = base.copyWith(
        fontSize: (base.fontSize ?? 16) + 8,
        fontWeight: FontWeight.w600,
        height: 1.15,
      );
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 10),
          child: RichText(
            text: TextSpan(
              style: h1Style,
              children:
                  _parseInlineMarkdown(_stripLeadingHashes(title), h1Style),
            ),
          ),
        ),
      );
    }

    for (; i < lines.length; i++) {
      final raw = lines[i];
      final s = raw.trimRight();
      final trimmed = s.trim();
      if (trimmed.isEmpty) {
        out.add(const SizedBox(height: 8));
        continue;
      }

      if (trimmed.startsWith('#')) {
        final stripped = _stripLeadingHashes(trimmed);
        if (stripped.isEmpty) {
          i++;
          continue;
        }
        if (trimmed.startsWith('# ')) {
          final hStyle = base.copyWith(
              fontSize: (base.fontSize ?? 16) + 6,
              fontWeight: FontWeight.w600,
              height: 1.15);
          out.add(
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 8),
              child: RichText(
                text: TextSpan(
                    style: hStyle,
                    children: _parseInlineMarkdown(stripped, hStyle)),
              ),
            ),
          );
        } else {
          out.add(_sectionHeader(trimmed, base));
        }
        continue;
      }
      if (trimmed.startsWith('- ')) {
        out.add(_bulletLine(trimmed, base));
        continue;
      }
      if (trimmed.startsWith('|') && trimmed.contains('|')) {
        final monoStyle = base.copyWith(
            fontFamily: 'monospace', height: 1.35, color: _bodyTextSoft);
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: RichText(
              text: TextSpan(
                  style: monoStyle,
                  children: _parseInlineMarkdown(trimmed, monoStyle)),
            ),
          ),
        );
        continue;
      }

      final paraStyle = base.copyWith(
          height: 1.45, color: _bodyText, fontWeight: FontWeight.w500);
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RichText(
            text: TextSpan(
                style: paraStyle,
                children: _parseInlineMarkdown(trimmed, paraStyle)),
          ),
        ),
      );
    }
    while (out.isNotEmpty && out.last is SizedBox) {
      out.removeLast();
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = _stripCodeFences(text).trim();
    if (t.isEmpty) return const SizedBox.shrink();
    final baseStyle = style ?? Theme.of(context).textTheme.titleMedium;
    final base =
        (baseStyle ?? const TextStyle(fontSize: 16)).copyWith(color: color);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _buildBlocks(t, base),
      ),
    );
  }
}

// Demo transcript/summary helpers removed: detail page now calls server APIs.
