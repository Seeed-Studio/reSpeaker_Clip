import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../core/audio/audio_waveform_peaks.dart' show logWaveformPeaksDebug;
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_pill_button.dart';
import '../../../../core/widgets/playback_waveform.dart';

/// A timestamp marker shown on the waveform timeline.
class RecordingMarker {
  final Duration position;
  final String? label;

  const RecordingMarker({
    required this.position,
    this.label,
  });
}

/// A selected trim range on the waveform.
class RecordingTrimRange {
  final Duration start;
  final Duration end;

  RecordingTrimRange({
    required this.start,
    required this.end,
  }) : assert(!end.isNegative);

  RecordingTrimRange normalized() {
    if (end < start) return RecordingTrimRange(start: end, end: start);
    return this;
  }
}

/// A lightweight controller to drive the player UI.
///
/// For now, this controller only stores state. You can later bind it to a real
/// audio engine (e.g., just_audio) by calling [setPosition]/[setPlaying], etc.
abstract class RecordingPlayerAdapter {
  Future<void> setPlaying(bool isPlaying);
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
}

class RecordingPlayerController extends ChangeNotifier {
  RecordingPlayerController({
    required Duration duration,
    Duration position = Duration.zero,
    bool isPlaying = false,
    double speed = 1.0,
  })  : _duration = duration,
        _position = position,
        _isPlaying = isPlaying,
        _speed = speed;

  Duration _duration;
  Duration _position;
  bool _isPlaying;
  double _speed;

  RecordingPlayerAdapter? _adapter;
  bool _updatingFromAdapter = false;

  Duration get duration => _duration;
  Duration get position => _position;
  bool get isPlaying => _isPlaying;
  double get speed => _speed;
  bool get isPlaybackReady => _adapter != null;

  void attachAdapter(RecordingPlayerAdapter adapter) {
    _adapter = adapter;
    // Push current state to adapter (best-effort).
    unawaited(_adapter?.setSpeed(_speed));
    unawaited(_adapter?.seek(_position));
    unawaited(_adapter?.setPlaying(_isPlaying));
    notifyListeners();
  }

  void detachAdapter(RecordingPlayerAdapter adapter) {
    if (identical(_adapter, adapter)) {
      _adapter = null;
      if (_isPlaying) {
        _isPlaying = false;
      }
      notifyListeners();
    }
  }

  void setDuration(Duration v) => _setDurationInternal(v, fromAdapter: false);

  void setDurationFromAdapter(Duration v) => _setDurationInternal(v, fromAdapter: true);

  void _setDurationInternal(Duration v, {required bool fromAdapter}) {
    _duration = v < Duration.zero ? Duration.zero : v;
    if (_position > _duration) _position = _duration;
    notifyListeners();
    // No adapter call needed for duration.
    _ignore(fromAdapter);
  }

  void setPosition(Duration v) => _setPositionInternal(v, fromAdapter: false);

  void setPositionFromAdapter(Duration v) => _setPositionInternal(v, fromAdapter: true);

  void _setPositionInternal(Duration v, {required bool fromAdapter}) {
    // IMPORTANT:
    // When duration is unknown (0), do not clamp upper bound; otherwise the UI
    // will "freeze" at 00:00 during real playback.
    final clamped = (_duration == Duration.zero)
        ? (v < Duration.zero ? Duration.zero : v)
        : _clampDuration(v, Duration.zero, _duration);
    if (clamped == _position) return;
    _position = clamped;
    notifyListeners();
    if (!fromAdapter && !_updatingFromAdapter) {
      unawaited(_adapter?.seek(_position));
    }
  }

  void seekBy(Duration delta) => setPosition(_position + delta);

  void setPlaying(bool v) => _setPlayingInternal(v, fromAdapter: false);

  void setPlayingFromAdapter(bool v) => _setPlayingInternal(v, fromAdapter: true);

  void _setPlayingInternal(bool v, {required bool fromAdapter}) {
    if (v == _isPlaying) return;
    // Do not enter "playing" until engine is attached or UI shows playing with no just_audio (long files decode slowly).
    if (v && !fromAdapter && !_updatingFromAdapter && _adapter == null) {
      return;
    }
    _isPlaying = v;
    // After natural end, next play starts from the beginning
    if (v && !fromAdapter && !_updatingFromAdapter && _duration > Duration.zero && _position >= _duration) {
      _position = Duration.zero;
      notifyListeners();
      final a = _adapter;
      if (a != null) {
        unawaited(a.seek(Duration.zero).then((_) => a.setPlaying(true)));
      }
      return;
    }
    notifyListeners();
    if (!fromAdapter && !_updatingFromAdapter) {
      unawaited(_adapter?.setPlaying(v));
    }
  }

  void togglePlayPause() => setPlaying(!isPlaying);

  void setSpeed(double v) => _setSpeedInternal(v, fromAdapter: false);

  void setSpeedFromAdapter(double v) => _setSpeedInternal(v, fromAdapter: true);

  void _setSpeedInternal(double v, {required bool fromAdapter}) {
    final next = v.clamp(0.5, 3.0);
    if (next == _speed) return;
    _speed = next;
    notifyListeners();
    if (!fromAdapter && !_updatingFromAdapter) {
      unawaited(_adapter?.setSpeed(_speed));
    }
  }

  void beginAdapterUpdate() => _updatingFromAdapter = true;

  void endAdapterUpdate() => _updatingFromAdapter = false;

  static Duration _clampDuration(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  void _ignore(bool _) {}
}

/// Reusable recording player widget (waveform + timeline + markers + trim UI).
///
/// - **Waveform highlight color**: uses `Theme.of(context).colorScheme.primary`
/// - **Markers**: show as small ticks on waveform
/// - **Playback**: UI-driven; expected to be bound to a real audio adapter.
class RecordingPlayer extends StatefulWidget {
  final RecordingPlayerController controller;
  final List<double>? peaks; // normalized 0..1
  /// Parsed duration fraction (0..1); <1 shows placeholder tail. Default 1 = fully parsed.
  final double parsedFraction;
  final List<RecordingMarker> markers;

  /// If provided, the "Trim" button will open a dedicated trim editor page.
  /// Otherwise the player falls back to inline trim mode.
  final VoidCallback? onOpenTrimEditor;

  /// Called when user applies "Keep" / "Delete" while trimming.
  final ValueChanged<RecordingTrimRange>? onTrimKeep;
  final ValueChanged<RecordingTrimRange>? onTrimDelete;

  /// Optional: render a row of marker timestamps below waveform.
  final bool showMarkerTimestamps;

  /// When true the play / seek controls are visually disabled but the
  /// waveform and position display remain intact.
  final bool playbackDisabled;

  const RecordingPlayer({
    super.key,
    required this.controller,
    this.peaks,
    this.parsedFraction = 1.0,
    this.markers = const [],
    this.onOpenTrimEditor,
    this.onTrimKeep,
    this.onTrimDelete,
    this.showMarkerTimestamps = true,
    this.playbackDisabled = false,
  });

  @override
  State<RecordingPlayer> createState() => _RecordingPlayerState();
}

class _RecordingPlayerState extends State<RecordingPlayer> with SingleTickerProviderStateMixin {
  static const int _uiPeaksLen = 240; // keep bar density stable to avoid visual "blink"

  late List<double> _peaks;

  bool _trimMode = false;
  RecordingTrimRange? _trim;

  // Smoothly morph placeholder peaks -> real peaks to avoid a visible "blink".
  // When new peaks arrive, we blend old/new for a short duration.
  late final AnimationController _blendCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() {
      if (mounted) setState(() {});
    });
  List<double>? _blendFrom;
  List<double>? _blendTo;
  /// Running max during progressive parse — avoids p10/p95 remap jumps.
  double _progressiveRefMax = 0.0;

  @override
  void initState() {
    super.initState();
    _peaks = _effectivePeaks(widget.peaks);
    widget.controller.addListener(_onControllerChanged);
    _logPeaksForUi(widget.peaks);
  }

  @override
  void didUpdateWidget(covariant RecordingPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    final nextPeaks = widget.peaks;
    final oldPeaks = oldWidget.peaks;
    final peaksChanged = nextPeaks != oldPeaks;
    if (nextPeaks == null || nextPeaks.isEmpty) {
      _progressiveRefMax = 0.0;
    } else if (oldWidget.parsedFraction >= 1.0 && widget.parsedFraction < 1.0) {
      _progressiveRefMax = 0.0;
    }
    if (peaksChanged) {
      final next = _effectivePeaks(nextPeaks);
      if (widget.parsedFraction >= 1.0) {
        _startBlendTo(next);
      } else {
        _blendCtrl.stop();
        _blendFrom = null;
        _blendTo = null;
        _peaks = next;
      }
      _logPeaksForUi(nextPeaks);
    }
  }

  void _logPeaksForUi(List<double>? rawPeaks) {
    if (!kDebugMode || rawPeaks == null || rawPeaks.isEmpty) return;
    logWaveformPeaksDebug(
      'player-raw',
      peaks: rawPeaks,
      parsedFraction: widget.parsedFraction,
    );
    final displayPeaksRaw = _effectivePeaks(rawPeaks);
    final displayPeaks = _resamplePeaksToLength(displayPeaksRaw, _uiPeaksLen);
    final peaksForUi = _buildUiPeaks(displayPeaks);
    logWaveformPeaksDebug(
      'player-ui',
      peaks: peaksForUi,
      parsedFraction: widget.parsedFraction,
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _blendCtrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _toggleTrimMode() {
    setState(() {
      _trimMode = !_trimMode;
      if (_trimMode) {
        // Default selection: around current position, 10% window.
        final d = widget.controller.duration;
        final p = widget.controller.position;
        final half = Duration(milliseconds: (d.inMilliseconds * 0.05).round());
        _trim = RecordingTrimRange(
          start: p - half,
          end: p + half,
        ).normalized();
      } else {
        _trim = null;
      }
    });
  }

  void _seekToFraction(double frac) {
    final clamped = frac.clamp(0.0, 1.0);
    final ms = (widget.controller.duration.inMilliseconds * clamped).round();
    widget.controller.setPosition(Duration(milliseconds: ms));
  }

  void _updateTrimStart(double frac) {
    final d = widget.controller.duration;
    final ms = (d.inMilliseconds * frac.clamp(0.0, 1.0)).round();
    final start = Duration(milliseconds: ms);
    final end = _trim?.end ?? d;
    setState(() => _trim = RecordingTrimRange(start: start, end: end).normalized());
  }

  void _updateTrimEnd(double frac) {
    final d = widget.controller.duration;
    final ms = (d.inMilliseconds * frac.clamp(0.0, 1.0)).round();
    final end = Duration(milliseconds: ms);
    final start = _trim?.start ?? Duration.zero;
    setState(() => _trim = RecordingTrimRange(start: start, end: end).normalized());
  }

  Future<void> _pickSpeed() async {
    final speeds = const [0.75, 1.0, 1.25, 1.5, 2.0];
    final current = widget.controller.speed;
    final picked = await showAppBottomSheet<double>(
      context,
      builder: (ctx) {
        return ListView(
          shrinkWrap: true,
          children: [
            const SizedBox(height: 8),
            ...speeds.map((s) {
              final selected = (s - current).abs() < 0.001;
              return ListTile(
                title: Text(AppLocalizations.of(ctx)!.playbackSpeedTimes(s.truncateToDouble() == s ? '${s.toInt()}' : '$s')),
                trailing: selected ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(s),
              );
            }),
            const SizedBox(height: 8),
          ],
        );
      },
    );
    if (picked != null) widget.controller.setSpeed(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final c = widget.controller;

    final posText = _formatDuration(c.position);
    final durText = _formatDuration(c.duration);

    // Visual polish:
    // 1) Normalize to this clip's max peak (quiet speech can look flat otherwise)
    // 2) Light curve boost to match product-style bars
    final displayPeaksRaw = _blendCtrl.isAnimating ? _blendPeaks() : _peaks;
    final displayPeaks = _resamplePeaksToLength(displayPeaksRaw, _uiPeaksLen);
    final peaksForUi = _buildUiPeaks(displayPeaks);

    final trim = _trim?.normalized();
    final trimStartFrac = (c.duration.inMilliseconds == 0)
        ? 0.0
        : (trim == null ? 0.0 : trim.start.inMilliseconds / c.duration.inMilliseconds);
    final trimEndFrac = (c.duration.inMilliseconds == 0)
        ? 1.0
        : (trim == null ? 1.0 : trim.end.inMilliseconds / c.duration.inMilliseconds);

    final canTrim = widget.onOpenTrimEditor != null || widget.onTrimKeep != null || widget.onTrimDelete != null;
    final isPlaceholder = widget.peaks == null || (widget.peaks?.isEmpty ?? true);
    final playbackReady = c.isPlaybackReady && !widget.playbackDisabled;

    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Time row
          Row(
            children: [
              Text(
                posText,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
              Text(' / $durText', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600)),
            ],
          ),
          const SizedBox(height: 8),

          // Waveform
        PlaybackWaveform(
          height: 86,
          peaks: peaksForUi,
          parsedFraction: widget.parsedFraction,
          isPlaceholder: isPlaceholder,
          // Unplayed bars gray; played uses primary
          activeColor: cs.primary,
          inactiveColor: AppColors.border, // AppColors.grayD1
          // Rounded bar look: thicker + tighter spacing (with downsample when dense)
          barStrokeWidth: 2.0,
          activeBarStrokeWidth: 2.0,
          minBarGap: 1.5,
          // No rounded bottom cap under bars
          backgroundColor: Colors.transparent,
          border: null,
          borderRadius: BorderRadius.zero,
          duration: c.duration,
          position: c.position,
          isPlaying: c.isPlaying,
          showPlayhead: true,
          onSeekFraction: (!playbackReady ||
                  (isPlaceholder && c.duration <= Duration.zero))
              ? null
              : _seekToFraction,
          trimMode: _trimMode,
          trimStartFrac: trimStartFrac,
          trimEndFrac: trimEndFrac,
          onTrimStartDrag: _updateTrimStart,
          onTrimEndDrag: _updateTrimEnd,
          markers: widget.markers
              .map((m) => PlaybackWaveformMarker(position: m.position, label: m.label))
              .toList(growable: false),
        ),

          // Debug info removed (no demo playback).

          if (widget.showMarkerTimestamps && widget.markers.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: widget.markers.take(6).map((m) {
                return _MarkerChip(
                  label: m.label ?? _formatDuration(m.position),
                  onTap: () => c.setPosition(m.position),
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 12),

          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _PlayButton(
                isPlaying: c.isPlaying,
                onPressed: playbackReady ? c.togglePlayPause : null,
                activeColor: cs.primary,
              ),
              IconButton(
                tooltip: l10n.seekBack5s,
                onPressed: playbackReady
                    ? () => c.seekBy(const Duration(seconds: -5))
                    : null,
                icon: Icon(Icons.replay_5, size: 32, color: AppColors.textPrimary),
              ),
              IconButton(
                tooltip: l10n.seekForward5s,
                onPressed: playbackReady
                    ? () => c.seekBy(const Duration(seconds: 5))
                    : null,
                icon: Icon(Icons.forward_5, size: 32, color: AppColors.textPrimary),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SpeedChip(
                      speed: c.speed, onTap: playbackReady ? _pickSpeed : null),
                  if (canTrim) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: l10n.trim,
                      onPressed: widget.onOpenTrimEditor ?? _toggleTrimMode,
                      icon: Icon(_trimMode ? Icons.close : Icons.content_cut),
                    ),
                  ],
                ],
              ),
            ],
          ),

          if (_trimMode && trim != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: AppOutlinedPillButton(
                    label: l10n.deleteSegment,
                    onPressed: widget.onTrimDelete == null ? null : () => widget.onTrimDelete!(trim),
                    leading: const Icon(Icons.delete_outline),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: widget.onTrimKeep == null ? null : () => widget.onTrimKeep!(trim),
                    icon: const Icon(Icons.check),
                    label: Text(l10n.keepSegment),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _startBlendTo(List<double> next) {
    // If peaks are identical-ish, skip.
    if (identical(next, _peaks)) {
      _peaks = next;
      return;
    }
    _blendFrom = _peaks;
    _blendTo = next;
    _peaks = next;
    _blendCtrl
      ..stop()
      ..value = 0.0
      ..forward();
  }

  List<double> _buildUiPeaks(List<double> resampledPeaks) {
    final smoothed = _capEndPeakOutliers(resampledPeaks);
    final normalized = widget.parsedFraction >= 1.0
        ? _normalizePeaksForUi(smoothed)
        : _normalizePeaksProgressive(smoothed);
    return _applyUiContrast(_expandLowDynamicRange(normalized));
  }

  List<double> _normalizePeaksProgressive(List<double> peaks) {
    if (peaks.isEmpty) return peaks;
    final edgeN = _edgeBarCount(peaks.length);
    final coreSample = peaks.length > edgeN * 2 + 4
        ? peaks.sublist(edgeN, peaks.length - edgeN)
        : peaks;
    final mx = coreSample.reduce((a, b) => a > b ? a : b);
    if (mx > _progressiveRefMax) _progressiveRefMax = mx;
    final ref = math.max(_progressiveRefMax, 0.001);
    final scaled = peaks
        .map((v) => (v / ref).clamp(0.12, 1.0))
        .toList(growable: false);
    return _capNormalizedEdgeBars(scaled);
  }

  List<double> _blendPeaks() {
    final a0 = _blendFrom;
    final b0 = _blendTo;
    if (a0 == null || b0 == null) return _peaks;
    final t = _blendCtrl.value.clamp(0.0, 1.0);
    // Blend on a fixed UI length so there's no jump when animation ends.
    final a = _resamplePeaksToLength(a0, _uiPeaksLen);
    final b = _resamplePeaksToLength(b0, _uiPeaksLen);
    return List<double>.generate(_uiPeaksLen, (i) {
      final v = a[i] * (1 - t) + b[i] * t;
      return v.clamp(0.0, 1.0);
    }, growable: false);
  }
}

class _SpeedChip extends StatelessWidget {
  final double speed;
  final VoidCallback? onTap;

  const _SpeedChip({required this.speed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadii.r20),
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 14, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              '${speed.toStringAsFixed(speed == 1.0 ? 0 : 2)}x',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback? onPressed;
  final Color activeColor;

  const _PlayButton({
    required this.isPlaying,
    required this.onPressed,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Detail player: light gray circular play control per design
          color: onPressed == null ? AppColors.surfaceSubtle : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: onPressed == null ? AppColors.textTertiary : AppColors.textPrimary, size: 28),
        ),
      ),
    );
  }
}

class _MarkerChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _MarkerChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surfaceSubtle,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final total = d.inSeconds.clamp(0, 999999);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

const int _kUiPeaksLen = 240;

List<double> _effectivePeaks(List<double>? peaks) {
  if (peaks == null || peaks.isEmpty) return _generateEmptyStatePeaks(_kUiPeaksLen);
  final mx = peaks.reduce((a, b) => a > b ? a : b);
  if (mx <= 0.001) return _generateEmptyStatePeaks(_kUiPeaksLen);
  return peaks;
}

/// Placeholder waveform before parse: varied heights (design ref).
List<double> _generateEmptyStatePeaks(int count) {
  final peaks = <double>[];
  for (var i = 0; i < count; i++) {
    final t = i / count;
    final wave = 0.35 + 0.45 * math.sin(t * math.pi * 4) * (0.6 + 0.4 * math.sin(t * math.pi * 2));
    peaks.add(wave.clamp(0.2, 0.9));
  }
  return peaks;
}

List<double> _resamplePeaksToLength(List<double> peaks, int length) {
  if (peaks.isEmpty) return List<double>.filled(length, 0.0, growable: false);
  if (peaks.length == length) return peaks;
  final out = <double>[];
  final n = peaks.length;
  final m = length;
  for (var i = 0; i < m; i++) {
    final idx = (m <= 1 || n <= 1) ? 0 : ((i * (n - 1)) / (m - 1)).round();
    out.add(peaks[idx].clamp(0.0, 1.0));
  }
  return out;
}

double _contrastPeak(double v) {
  final x = v.clamp(0.0, 1.0);
  return math.pow(x, 0.80).toDouble();
}

/// Stretch narrow post-normalize range so quiet speech keeps visible bar variation.
List<double> _expandLowDynamicRange(List<double> peaks) {
  if (peaks.length < 4) return peaks;
  var min = peaks.first;
  var max = peaks.first;
  for (final v in peaks) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
  final range = max - min;
  if (range >= 0.25 || range <= 0.00001) return peaks;
  return peaks
      .map((v) => (0.20 + ((v - min) / range) * 0.72).clamp(0.12, 1.0))
      .toList(growable: false);
}

List<double> _applyUiContrast(List<double> peaks) {
  if (peaks.isEmpty) return peaks;
  var min = peaks.first;
  var max = peaks.first;
  for (final v in peaks) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
  final flat = (max - min) < 0.30;
  return peaks
      .map((v) {
        final x = v.clamp(0.0, 1.0);
        if (flat) {
          // log-like curve for very flat speech after span expansion
          final logV = math.log(x * 9 + 1) / math.log(10);
          return (0.14 + logV * 0.82).clamp(0.12, 1.0);
        }
        return _contrastPeak(x);
      })
      .map(_boostPeak)
      .toList(growable: false);
}

double _boostPeak(double v) {
  // Mild gain only; higher values caused long speech recordings to clip flat.
  return v.clamp(0.0, 1.0);
}

/// Tame edge spikes (Opus/FFmpeg pops at start/end).
/// Caps the first/last few bars to match core audio level, not decode transients.
List<double> _capEndPeakOutliers(List<double> peaks) {
  if (peaks.length < 8) return peaks;
  final edgeN = _edgeBarCount(peaks.length);
  if (peaks.length <= edgeN * 2 + 2) return peaks;

  final core = peaks.sublist(edgeN, peaks.length - edgeN);
  final ref = _typicalLevel(core);
  final out = List<double>.from(peaks);

  for (var i = 0; i < edgeN; i++) {
    final neighbor = out[edgeN];
    final cap = math.max(ref, neighbor) * 1.08;
    if (out[i] > cap) out[i] = cap.clamp(0.0, 1.0);
  }

  for (var i = out.length - edgeN; i < out.length; i++) {
    final neighbor = out[out.length - edgeN - 1];
    final cap = math.max(ref, neighbor) * 1.08;
    if (out[i] > cap) out[i] = cap.clamp(0.0, 1.0);
  }

  return out;
}

int _edgeBarCount(int length) =>
    math.max(2, (length * 0.02).round()).clamp(1, length ~/ 4);

List<double> _capNormalizedEdgeBars(List<double> normalized) {
  if (normalized.length < 8) return normalized;
  final edgeN = _edgeBarCount(normalized.length);
  if (normalized.length <= edgeN * 2 + 2) return normalized;

  final core = normalized.sublist(edgeN, normalized.length - edgeN);
  final sorted = List<double>.from(core)..sort();
  final p90Idx = (sorted.length * 0.90).floor().clamp(0, sorted.length - 1);
  final edgeCap = (sorted[p90Idx] * 1.05).clamp(0.0, 1.0);

  final out = List<double>.from(normalized);
  for (var i = 0; i < edgeN; i++) {
    if (out[i] > edgeCap) out[i] = edgeCap;
  }
  for (var i = out.length - edgeN; i < out.length; i++) {
    if (out[i] > edgeCap) out[i] = edgeCap;
  }
  return out;
}

double _typicalLevel(List<double> rest) {
  if (rest.isEmpty) return 0.0;
  final sorted = List<double>.from(rest)..sort();
  final p95 = sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
  return math.max(p95, sorted.last * 0.8);
}

List<double> _normalizePeaksForUi(List<double> peaks) {
  if (peaks.isEmpty) return peaks;
  // Map p10..p95 into 0..1 so narrow-band speech (common on long Opus files)
  // keeps visible bar variation instead of clipping to a flat top.
  // Exclude edge bars from the reference so decode pops don't become 1.0.
  final edgeN = _edgeBarCount(peaks.length);
  final useCore = peaks.length > edgeN * 2 + 4;
  final sample =
      useCore ? peaks.sublist(edgeN, peaks.length - edgeN) : peaks;

  final sorted = List<double>.from(sample)..sort();
  final n = sorted.length;
  final loIdx = (n * 0.10).floor().clamp(0, n - 1);
  final hiIdx = (n * 0.95).floor().clamp(0, n - 1);
  var lo = sorted[loIdx];
  var hi = sorted[hiIdx];
  final rawSpan = hi - lo;
  // Narrow raw band (common on long Opus speech): widen percentile window.
  if (rawSpan < 0.025 && n >= 12) {
    lo = sorted[(n * 0.05).floor().clamp(0, n - 1)];
    hi = sorted[(n * 0.98).floor().clamp(0, n - 1)];
  }
  final span = hi - lo;
  if (span <= 0.00001) {
    final mid = sorted[n ~/ 2];
    if (mid <= 0.000001) return peaks;
    final flat = peaks
        .map((v) => (v / mid * 0.55).clamp(0.12, 0.88))
        .toList(growable: false);
    return _capNormalizedEdgeBars(flat);
  }
  final normalized = peaks
      .map((v) => ((v - lo) / span).clamp(0.0, 1.0))
      .toList(growable: false);
  return _capNormalizedEdgeBars(normalized);
}

