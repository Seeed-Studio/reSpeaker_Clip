import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A timestamp marker shown on the waveform timeline.
class PlaybackWaveformMarker {
  final Duration position;
  final String? label;

  const PlaybackWaveformMarker({
    required this.position,
    this.label,
  });
}

/// A selected trim range on the waveform.
class PlaybackTrimRange {
  final Duration start;
  final Duration end;

  PlaybackTrimRange({
    required this.start,
    required this.end,
  }) : assert(!end.isNegative);

  PlaybackTrimRange normalized() {
    if (end < start) return PlaybackTrimRange(start: end, end: start);
    return this;
  }
}

/// A reusable audio waveform widget:
/// - Bars are **grey** for unplayed, **green/primary** for played
/// - Optional: while playing, bars can gently "pulse" ([pulseWhilePlaying])
/// - If [peaks] is null, a deterministic placeholder waveform is generated
///
/// This widget is UI-only and does not depend on any audio engine.
class PlaybackWaveform extends StatefulWidget {
  /// Total duration of the audio.
  final Duration duration;

  /// Current playback position.
  final Duration position;

  /// Whether audio is playing (used with [pulseWhilePlaying] for bar pulse).
  final bool isPlaying;

  /// When true and [isPlaying], bar heights gently pulse. Default is false (static bars).
  final bool pulseWhilePlaying;

  /// Wave peaks, normalized 0..1. If null, placeholder peaks are generated.
  final List<double>? peaks;

  /// Parsed duration fraction (0..1). <1 uses placeholder tail to avoid stretch. Default 1.
  final double parsedFraction;

  /// Placeholder when waveform not parsed: left-to-right shimmer.
  final bool isPlaceholder;

  /// Markers rendered as small dots near the bottom.
  final List<PlaybackWaveformMarker> markers;

  /// Height of waveform.
  final double height;

  /// Active color (played section).
  final Color activeColor;

  /// Inactive color (unplayed section).
  final Color inactiveColor;

  /// Bar stroke width (in px) for unplayed section.
  final double barStrokeWidth;

  /// Bar stroke width (in px) for played section.
  final double activeBarStrokeWidth;

  /// Minimum empty gap (in px) between bars.
  ///
  /// If there are too many peaks for the available width, the waveform will
  /// automatically downsample so bars don't look overly dense.
  final double minBarGap;

  /// Optional container background. Use transparent for "flat" style.
  final Color backgroundColor;

  /// Optional border for container.
  final BorderSide? border;

  /// Border radius for container.
  final BorderRadius borderRadius;

  /// Show a vertical playhead line at current position.
  final bool showPlayhead;

  /// Enable seek by tapping/dragging. If null, seeking is disabled.
  final ValueChanged<double>? onSeekFraction;

  /// Optional trim overlay.
  final bool trimMode;
  final double trimStartFrac;
  final double trimEndFrac;
  final ValueChanged<double>? onTrimStartDrag;
  final ValueChanged<double>? onTrimEndDrag;

  const PlaybackWaveform({
    super.key,
    required this.duration,
    required this.position,
    required this.isPlaying,
    this.pulseWhilePlaying = false,
    this.peaks,
    this.parsedFraction = 1.0,
    this.isPlaceholder = false,
    this.markers = const [],
    this.height = 86,
    required this.activeColor,
    this.inactiveColor = const Color(0xFFCBD5E1),
    this.barStrokeWidth = 2.0,
    this.activeBarStrokeWidth = 2.6,
    this.minBarGap = 4.0,
    this.backgroundColor = Colors.transparent,
    this.border,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.showPlayhead = true,
    this.onSeekFraction,
    this.trimMode = false,
    this.trimStartFrac = 0.0,
    this.trimEndFrac = 1.0,
    this.onTrimStartDrag,
    this.onTrimEndDrag,
  });

  @override
  State<PlaybackWaveform> createState() => _PlaybackWaveformState();
}

class _PlaybackWaveformState extends State<PlaybackWaveform>
    with TickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final AnimationController _maskCtrl;
  late List<double> _peaks;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _maskCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _peaks = (widget.peaks != null && widget.peaks!.isNotEmpty)
        ? widget.peaks!
        : _generatePeaks(seed: widget.duration.inMilliseconds);
    _syncPulse();
    _syncMask();
  }

  @override
  void didUpdateWidget(covariant PlaybackWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextPeaks = widget.peaks;
    final oldPeaks = oldWidget.peaks;
    final peaksChanged = nextPeaks != oldPeaks;

    if (peaksChanged) {
      _peaks = (nextPeaks != null && nextPeaks.isNotEmpty)
          ? nextPeaks
          : _generatePeaks(seed: widget.duration.inMilliseconds);
    } else if ((nextPeaks == null || nextPeaks.isEmpty) &&
        widget.duration != oldWidget.duration) {
      _peaks = _generatePeaks(seed: widget.duration.inMilliseconds);
    }
    _syncPulse();
    _syncMask();
  }

  void _syncPulse() {
    if (widget.pulseWhilePlaying && widget.isPlaying) {
      if (!_pulseCtrl.isAnimating) _pulseCtrl.repeat();
    } else {
      if (_pulseCtrl.isAnimating) _pulseCtrl.stop();
    }
  }

  void _syncMask() {
    if (widget.isPlaceholder) {
      if (!_maskCtrl.isAnimating) _maskCtrl.repeat();
    } else {
      if (_maskCtrl.isAnimating) _maskCtrl.stop();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _maskCtrl.dispose();
    super.dispose();
  }

  void _seekTo(Offset local, double width) {
    final cb = widget.onSeekFraction;
    if (cb == null) return;
    cb((local.dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds;
    final frac =
        durationMs == 0 ? 0.0 : widget.position.inMilliseconds / durationMs;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final canSeek = widget.onSeekFraction != null;

        final child = Stack(
          children: [
            Container(
              height: widget.height,
              decoration: BoxDecoration(
                color: widget.backgroundColor,
                borderRadius: widget.borderRadius,
                border: widget.border == null
                    ? null
                    : Border.fromBorderSide(widget.border!),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _PlaybackWaveformPainter(
                      peaks: _peaks,
                      parsedFraction: widget.parsedFraction,
                      activeColor: widget.activeColor,
                      inactiveColor: widget.inactiveColor,
                      barStrokeWidth: widget.barStrokeWidth,
                      activeBarStrokeWidth: widget.activeBarStrokeWidth,
                      markers: widget.markers,
                      positionFraction: frac.clamp(0.0, 1.0),
                      duration: widget.duration,
                      trimMode: widget.trimMode,
                      trimStartFrac: widget.trimStartFrac,
                      trimEndFrac: widget.trimEndFrac,
                      showPlayhead: widget.showPlayhead,
                      minBarGap: widget.minBarGap,
                      pulse: (widget.pulseWhilePlaying && widget.isPlaying)
                          ? _pulseCtrl
                          : null,
                    ),
                  ),
                  if (widget.isPlaceholder)
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _maskCtrl,
                        builder: (context, _) {
                          final v = _maskCtrl.value;
                          return DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [
                                  Colors.transparent,
                                  Colors.transparent,
                                  Colors.white.withValues(alpha: 0.55),
                                  Colors.white.withValues(alpha: 0.55),
                                ],
                                stops: [0.0, v, v, 1.0],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            if (widget.trimMode) ...[
              Positioned(
                left: (w * widget.trimStartFrac).clamp(0.0, w - 12),
                top: 0,
                bottom: 0,
                child: _TrimHandle(
                  onDrag: (dx) {
                    widget.onTrimStartDrag
                        ?.call(((w * widget.trimStartFrac) + dx) / w);
                  },
                ),
              ),
              Positioned(
                left: (w * widget.trimEndFrac).clamp(12.0, w) - 12,
                top: 0,
                bottom: 0,
                child: _TrimHandle(
                  onDrag: (dx) {
                    widget.onTrimEndDrag
                        ?.call(((w * widget.trimEndFrac) + dx) / w);
                  },
                ),
              ),
            ],
          ],
        );

        if (!canSeek) return child;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _seekTo(d.localPosition, w),
          onPanUpdate: (d) => _seekTo(d.localPosition, w),
          child: child,
        );
      },
    );
  }
}

class _TrimHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;

  const _TrimHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => onDrag(d.delta.dx),
      child: Container(
        width: 12,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFCBD5E1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 2,
            height: 22,
            decoration: BoxDecoration(
              color: const Color(0xFFCBD5E1),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaybackWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final double parsedFraction;
  final Color activeColor;
  final Color inactiveColor;
  final double barStrokeWidth;
  final double activeBarStrokeWidth;
  final List<PlaybackWaveformMarker> markers;
  final double positionFraction;
  final Duration duration;
  final bool trimMode;
  final double trimStartFrac;
  final double trimEndFrac;
  final bool showPlayhead;
  final double minBarGap;
  final Animation<double>? pulse;

  _PlaybackWaveformPainter({
    required this.peaks,
    this.parsedFraction = 1.0,
    required this.activeColor,
    required this.inactiveColor,
    required this.barStrokeWidth,
    required this.activeBarStrokeWidth,
    required this.markers,
    required this.positionFraction,
    required this.duration,
    required this.trimMode,
    required this.trimStartFrac,
    required this.trimEndFrac,
    required this.showPlayhead,
    required this.minBarGap,
    required this.pulse,
  }) : super(repaint: pulse);

  @override
  void paint(Canvas canvas, Size size) {
    final safePeaks = peaks.isEmpty ? const <double>[0.6] : peaks;
    final paintInactive = Paint()
      ..color = inactiveColor
      ..strokeWidth = barStrokeWidth
      ..strokeCap = StrokeCap.round;

    final paintActive = Paint()
      ..color = activeColor
      ..strokeWidth = activeBarStrokeWidth
      ..strokeCap = StrokeCap.round;

    final h = size.height;
    final mid = h / 2;

    if (trimMode) {
      final left = size.width * trimStartFrac.clamp(0.0, 1.0);
      final right = size.width * trimEndFrac.clamp(0.0, 1.0);
      final overlay = Paint()..color = activeColor.withValues(alpha: 0.12);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
              left, 0, (right - left).clamp(0.0, size.width), size.height),
          const Radius.circular(12),
        ),
        overlay,
      );
    }

    // Keep bars from being too dense by downsampling peaks based on available width.
    final maxStroke = math.max(barStrokeWidth, activeBarStrokeWidth);
    final maxBars =
        math.max(1, (size.width / (minBarGap + maxStroke)).floor() - 1);
    final n = maxBars;
    final gap = size.width / (n + 1);
    final playedX = size.width * positionFraction.clamp(0.0, 1.0);

    // Partial parse: real peaks for first parsedFraction, placeholder for the rest
    final frac = parsedFraction.clamp(0.0, 1.0);
    final parsedBars = frac >= 1.0 ? n : (n * frac).round().clamp(0, n);

    final t = pulse?.value ?? 0.0;
    final basePhase = t * math.pi * 2;

    for (var i = 0; i < n; i++) {
      final x = gap * (i + 1);
      double base;
      if (i < parsedBars && safePeaks.isNotEmpty) {
        final srcIdx = (parsedBars <= 1 || safePeaks.length <= 1)
            ? 0
            : ((i * (safePeaks.length - 1)) / (parsedBars - 1)).round();
        base = (safePeaks[srcIdx].clamp(0.0, 1.0)) * (h * 0.55);
      } else {
        base = 0.3 * (h * 0.55);
      }

      final anim =
          pulse == null ? 1.0 : (0.86 + 0.14 * math.sin(basePhase + i * 0.35));
      final amp = base * anim;

      final y1 = mid - amp;
      final y2 = mid + amp;
      final p = x <= playedX ? paintActive : paintInactive;
      canvas.drawLine(Offset(x, y1), Offset(x, y2), p);
    }

    if (showPlayhead) {
      final barIdx = ((playedX / gap) - 1).clamp(0.0, (n - 1).toDouble());
      final i0 = barIdx.floor().clamp(0, n - 1);
      final i1 = (i0 + 1).clamp(0, n - 1);
      double peak;
      if (i0 < parsedBars && i1 < parsedBars && safePeaks.isNotEmpty) {
        final f = barIdx - i0;
        final srcIdx0 = (parsedBars <= 1 || safePeaks.length <= 1)
            ? 0
            : ((i0 * (safePeaks.length - 1)) / (parsedBars - 1)).round();
        final srcIdx1 = (parsedBars <= 1 || safePeaks.length <= 1)
            ? 0
            : ((i1 * (safePeaks.length - 1)) / (parsedBars - 1)).round();
        final peak0 = safePeaks[srcIdx0].clamp(0.0, 1.0);
        final peak1 = safePeaks[srcIdx1].clamp(0.0, 1.0);
        peak = peak0 * (1 - f) + peak1 * f;
      } else {
        peak = 0.3;
      }
      final amp = peak * (h * 0.55);
      final playheadPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.85)
        ..strokeWidth = 2;
      canvas.drawLine(Offset(playedX, mid - amp), Offset(playedX, mid + amp),
          playheadPaint);
    }

    if (markers.isNotEmpty && duration.inMilliseconds > 0) {
      final markerPaint = Paint()..color = Colors.red;
      final denom = duration.inMilliseconds;
      for (final m in markers) {
        final fx = (m.position.inMilliseconds / denom).clamp(0.0, 1.0);
        final x = size.width * fx;
        canvas.drawCircle(Offset(x, h - 10), 2.0, markerPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PlaybackWaveformPainter oldDelegate) {
    return oldDelegate.peaks != peaks ||
        oldDelegate.parsedFraction != parsedFraction ||
        oldDelegate.positionFraction != positionFraction ||
        oldDelegate.trimMode != trimMode ||
        oldDelegate.trimStartFrac != trimStartFrac ||
        oldDelegate.trimEndFrac != trimEndFrac ||
        oldDelegate.markers != markers ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor ||
        oldDelegate.barStrokeWidth != barStrokeWidth ||
        oldDelegate.activeBarStrokeWidth != activeBarStrokeWidth ||
        oldDelegate.showPlayhead != showPlayhead ||
        oldDelegate.minBarGap != minBarGap ||
        oldDelegate.duration != duration;
  }
}

/// Placeholder bars: multi-tone blend + pseudo-random jitter, closer to real audio.
List<double> _generatePeaks({required int seed, int count = 180}) {
  final peaks = <double>[];
  for (var i = 0; i < count; i++) {
    final t = i / count;
    // Mix tones so it is not a plain sine
    final w1 = 0.38 + 0.42 * math.sin(t * math.pi * 5.2);
    final w2 = 0.18 * math.sin(t * math.pi * 11.3);
    final w3 = 0.12 * math.sin((t + 0.4) * math.pi * 7.7);
    var v = w1 + w2 + w3;
    // Deterministic jitter from seed+i for varied bar heights
    final jitter = 0.08 * (((seed + i * 31) & 0xff) / 255.0 - 0.5);
    v = (v + jitter).clamp(0.2, 0.9);
    peaks.add(v);
  }
  return peaks;
}
