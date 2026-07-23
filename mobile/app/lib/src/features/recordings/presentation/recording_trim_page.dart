import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../core/db/account_db_key.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/validation/user_visible_name.dart';
import '../../../core/storage/account_storage_paths.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../../core/widgets/playback_waveform.dart';
import '../../../core/audio/wav_waveform_extractor.dart';
import '../data/recordings_repository.dart';
import '../domain/recording.dart';
import 'recordings_controller.dart';
import 'widgets/recording_player.dart';

/// Result returned by the trim page.
class RecordingTrimResult {
  final String name;
  final Duration start;
  final Duration end;
  final String? newRecordingId;
  final String? newFilePath;

  const RecordingTrimResult({
    required this.name,
    required this.start,
    required this.end,
    required this.newRecordingId,
    required this.newFilePath,
  });
}

class RecordingTrimPage extends ConsumerStatefulWidget {
  final String recordingId;
  const RecordingTrimPage({super.key, required this.recordingId});

  @override
  ConsumerState<RecordingTrimPage> createState() => _RecordingTrimPageState();
}

class _RecordingTrimPageState extends ConsumerState<RecordingTrimPage> {
  RecordingPlayerController? _ctrl;
  Timer? _tick;
  String? _wavePath;
  List<double>? _wavePeaks;
  bool _loadingWave = false;

  PlaybackTrimRange? _range;
  final List<PlaybackTrimRange> _undo = [];
  final List<PlaybackTrimRange> _redo = [];

  late List<double> _peaks; // demo peaks for waveform

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    _ctrl?.dispose();
    super.dispose();
  }

  void _ensureTick() {
    final c = _ctrl;
    if (c == null) return;
    if (!c.isPlaying) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      final c = _ctrl;
      if (c == null) return;
      if (!c.isPlaying) return;
      final stepMs = (200 * c.speed).round();
      final next = c.position + Duration(milliseconds: stepMs);
      if (next >= c.duration) {
        c.setPosition(c.duration);
        c.setPlaying(false);
      } else {
        c.setPosition(next);
      }
      setState(() {});
      _ensureTick();
    });
  }

  void _togglePlay() {
    final c = _ctrl;
    if (c == null) return;
    c.setPlaying(!c.isPlaying);
    setState(() {});
    _ensureTick();
  }

  void _seekTo(Duration pos) {
    final c = _ctrl;
    if (c == null) return;
    c.setPosition(pos);
    _ensureRangeContains(pos);
    setState(() {});
  }

  void _seekBy(Duration delta) {
    final c = _ctrl;
    if (c == null) return;
    c.seekBy(delta);
    setState(() {});
  }

  void _pushUndo(PlaybackTrimRange next) {
    final current = _range;
    if (current != null) _undo.add(current.normalized());
    _redo.clear();
    _range = next.normalized();
    // Keep playhead inside selection for clearer linkage.
    final c = _ctrl;
    final r = _range;
    if (c != null && r != null) {
      if (c.position < r.start) c.setPosition(r.start);
      if (c.position > r.end) c.setPosition(r.end);
    }
    setState(() {});
  }

  void _ensureRangeContains(Duration pos) {
    final r = _range;
    final c = _ctrl;
    if (r == null || c == null) return;
    final len = r.end - r.start;
    if (len <= Duration.zero) return;
    if (pos >= r.start && pos <= r.end) return;
    // Shift selection window (same length) to include playhead.
    var nextStart = pos - Duration(milliseconds: (len.inMilliseconds * 0.2).round());
    if (nextStart < Duration.zero) nextStart = Duration.zero;
    final maxStart = c.duration - len;
    if (nextStart > maxStart) nextStart = maxStart;
    _range = PlaybackTrimRange(start: nextStart, end: nextStart + len).normalized();
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    final current = _range;
    if (current != null) _redo.add(current.normalized());
    _range = _undo.removeLast();
    setState(() {});
  }

  void _redoOnce() {
    if (_redo.isEmpty) return;
    final current = _range;
    if (current != null) _undo.add(current.normalized());
    _range = _redo.removeLast();
    setState(() {});
  }

  Future<void> _saveAs(Recording recording) async {
    final l10n = AppLocalizations.of(context)!;
    final r = _range;
    if (r == null) return;
    final defaultName = (recording.name?.trim().isNotEmpty ?? false)
        ? '${recording.name} ${l10n.trimSuffix}'
        : l10n.trimmedAudio;
    final nameCtrl = TextEditingController(
      text: clipUserVisibleName(defaultName),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.saveAs),
          content: TextField(
            controller: nameCtrl,
            maxLength: kUserVisibleNameMaxLength,
            buildCounter: (context,
                    {required currentLength,
                    required isFocused,
                    maxLength}) =>
                null,
            decoration: InputDecoration(hintText: l10n.newFileNameHint),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.cancel)),
            SizedBox(
              width: 80,
              height: 48,
              child: AppBlackPillButton(
                label: l10n.save,
                onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
              ),
            ),
          ],
        );
      },
    );
    if (result == null) return;
    final trimmed = result.trim();
    if (!isValidUserVisibleName(trimmed)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.renameInvalid)),
      );
      return;
    }
    final name = trimmed;

    final src = recording.localPath;
    if (src == null || !src.toLowerCase().endsWith('.wav')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.trimOnlyWavSupported)),
      );
      return;
    }

    // Create new trimmed WAV file.
    final String accountKey;
    try {
      accountKey = requireAccountDbKey(ref);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorLoginFailed)),
      );
      return;
    }
    final safeName = _sanitizeFileName(name);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final outDir = Directory(
      await AccountStoragePaths.trimmedDirectory(accountKey),
    );
    outDir.createSync(recursive: true);
    final outPath = p.join(outDir.path, '$safeName-$ts.wav');

    // Trim and write.
    await trimWavPcm16ToNewFile(
      sourcePath: src,
      destPath: outPath,
      start: r.start,
      end: r.end,
    );

    final outFile = File(outPath);
    final sizeBytes = await outFile.length();
    final durSec = ((r.end - r.start).inMilliseconds / 1000.0).ceil();

    final repo = await ref.read(recordingsRepositoryProvider.future);
    final newId = await repo.createLocalRecording(
      name: name,
      localPath: outPath,
      durationSeconds: durSec,
      sizeBytes: sizeBytes,
      createdAt: DateTime.now(),
      format: 'wav',
      container: 'wav',
    );
    bumpRecordingsLists(ref);

    if (!mounted) return;
    Navigator.of(context).pop(
      RecordingTrimResult(
        name: name,
        start: r.start,
        end: r.end,
        newRecordingId: newId,
        newFilePath: outPath,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final asyncRec = ref.watch(recordingByIdProvider(widget.recordingId));

    return asyncRec.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(title: Text(l10n.trim)), body: Center(child: Text(e.toString()))),
      data: (rec) {
        final recording = rec ?? _demoRecording(widget.recordingId);
        final duration = Duration(seconds: recording.durationSeconds ?? 8 * 60 + 7);

        _ctrl ??= RecordingPlayerController(duration: duration);
        // Use real WAV peaks if available, else demo peaks.
        final p = recording.localPath;
        if (!_loadingWave && p != null && p.toLowerCase().endsWith('.wav') && p != _wavePath) {
          _loadingWave = true;
          _wavePath = p;
          extractWavPeaks(p, targetBars: 240).then((peaks) {
            if (!mounted) return;
            setState(() {
              _wavePeaks = peaks.isEmpty ? null : peaks;
              _loadingWave = false;
            });
          }).catchError((_) {
            if (!mounted) return;
            setState(() {
              _wavePeaks = null;
              _loadingWave = false;
            });
          });
        }

        _peaks = _wavePeaks ?? _generatePeaks(seed: duration.inMilliseconds, count: 240);

        _range ??= PlaybackTrimRange(
          start: Duration.zero,
          end: Duration(seconds: math.min(90, duration.inSeconds)),
        );

        final c = _ctrl!;
        _ensureTick();

        return Scaffold(
          backgroundColor: AppColors.surface,
          body: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      _PillButton(label: l10n.cancel, onTap: () => context.pop()),
                      const Spacer(),
                      IconButton(
                        onPressed: _undo.isEmpty ? null : _undoOnce,
                        icon: const Icon(Icons.undo, color: AppColors.textTertiary),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: _redo.isEmpty ? null : _redoOnce,
                        icon: const Icon(Icons.redo, color: AppColors.textTertiary),
                      ),
                      const Spacer(),
                      _PillButton(label: l10n.saveAs, onTap: () => _saveAs(recording)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _fmtDate(recording.createdAt ?? DateTime.now()),
                  style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),

                // Ruler (based on total duration)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: _RulerRow(
                    duration: c.duration,
                  ),
                ),
                const SizedBox(height: 6),

                // Main waveform with playhead
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: _TrimWaveformView(
                    height: 190,
                    background: AppColors.surfacePrimarySoft,
                    peaks: _peaks,
                    duration: c.duration,
                    position: c.position,
                    onSeek: (p) => _seekTo(p),
                  ),
                ),

                const SizedBox(height: 18),
                Text(
                  '${_fmtPos(c.position)}  /  ${_fmtPos(c.duration)}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 14),

                // Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      onPressed: () => _seekBy(const Duration(seconds: -5)),
                      icon: const Icon(Icons.skip_previous, color: AppColors.textTertiary),
                    ),
                    const SizedBox(width: 10),
                    _BigPlayButton(isPlaying: c.isPlaying, onTap: _togglePlay),
                    const SizedBox(width: 10),
                    IconButton(
                      onPressed: () => _seekBy(const Duration(seconds: 5)),
                      icon: const Icon(Icons.skip_next, color: AppColors.textTertiary),
                    ),
                  ],
                ),

                const SizedBox(height: 18),

                // Mini trim bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: _MiniTrimBar(
                    peaks: _peaks,
                    duration: c.duration,
                    range: _range!,
                    onChange: (next) => _pushUndo(next),
                  ),
                ),

                const Spacer(),
                _BottomTools(
                  selected: _BottomTool.trim,
                  onSmartEdit: () =>
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.smartEditTodo))),
                  onTrim: () {},
                  onDelete: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.deleteTodo))),
                ),
                const SizedBox(height: 22),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PillButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
      ),
    );
  }
}

class _RulerRow extends StatelessWidget {
  final Duration duration;

  const _RulerRow({required this.duration});

  List<Duration> _labels() {
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0) return const [Duration.zero];

    // Plaud-like: 5 major intervals across the visible timeline.
    // - If audio <= 1min, use 20s as the base interval and show labels within range.
    // - Otherwise, interval = total/5.
    final total = Duration(milliseconds: totalMs);
    final majorIntervals = 5;

    Duration step;
    if (total <= const Duration(minutes: 1)) {
      step = const Duration(seconds: 20);
    } else {
      step = Duration(milliseconds: (total.inMilliseconds / majorIntervals).round());
    }

    final labels = <Duration>[Duration.zero];
    for (var i = 1; i <= majorIntervals; i++) {
      final d = Duration(milliseconds: step.inMilliseconds * i);
      if (d < total) labels.add(d);
    }
    if (labels.isEmpty || labels.last != total) labels.add(total);
    return labels;
  }

  @override
  Widget build(BuildContext context) {
    final labels = _labels();
    return SizedBox(
      height: 32,
      child: LayoutBuilder(
        builder: (context, c) {
          final denom = math.max(1, duration.inMilliseconds);
          final majorCount = math.max(1, labels.length - 1);
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RulerPainter(majorCount: majorCount),
                ),
              ),
              for (final d in labels)
                Positioned(
                  left: (c.maxWidth * (d.inMilliseconds / denom)).clamp(0.0, c.maxWidth - 1),
                  top: 0,
                  child: Transform.translate(
                    offset: const Offset(-10, 0),
                    child: Text(_fmtPos(d), style: const TextStyle(color: Color(0xFF9CA3AF), fontWeight: FontWeight.w500)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  final int majorCount;
  const _RulerPainter({required this.majorCount});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = AppColors.gray200;
    final tick = Paint()
      ..color = AppColors.grayD1
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 1), Offset(size.width, size.height - 1), p);

    // 5 sub-ticks per major interval (including the major tick).
    final ticks = math.max(5, majorCount * 5);
    for (var i = 0; i <= ticks; i++) {
      final x = size.width * (i / ticks);
      final h = (i % 5 == 0) ? 10.0 : 6.0;
      canvas.drawLine(Offset(x, size.height - 1), Offset(x, size.height - 1 - h), tick);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TrimWaveformView extends StatelessWidget {
  final double height;
  final Color background;
  final List<double> peaks;
  final Duration duration; // full duration
  final Duration position; // absolute position within [duration]
  final ValueChanged<Duration> onSeek;

  const _TrimWaveformView({
    required this.height,
    required this.background,
    required this.peaks,
    required this.duration,
    required this.position,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final pos = position;
    final frac = duration.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final x = w * frac;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onSeek(Duration(milliseconds: (duration.inMilliseconds * (d.localPosition.dx / w)).round())),
          onPanUpdate: (d) => onSeek(Duration(milliseconds: (duration.inMilliseconds * (d.localPosition.dx / w)).round())),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppRadii.r8),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SimpleWavePainter(peaks: peaks),
                  ),
                ),
                Positioned(
                  left: x.clamp(12.0, w - 12) - 1,
                  top: 18,
                  bottom: 18,
                  child: Container(width: 2, color: AppColors.accentBlue),
                ),
                Positioned(
                  left: x.clamp(12.0, w - 12) - 6,
                  top: 12,
                  child: _BlueDot(),
                ),
                Positioned(
                  left: x.clamp(12.0, w - 12) - 6,
                  bottom: 12,
                  child: _BlueDot(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BlueDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(color: AppColors.accentBlue, shape: BoxShape.circle),
    );
  }
}

class _SimpleWavePainter extends CustomPainter {
  final List<double> peaks;
  _SimpleWavePainter({required this.peaks});

  @override
  void paint(Canvas canvas, Size size) {
    final safePeaks = peaks.isEmpty ? const <double>[0.6] : peaks;
    final paint = Paint()
      ..color = AppColors.textPrimary
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    final n = math.min(80, safePeaks.length);
    final gap = size.width / (n + 1);
    for (var i = 0; i < n; i++) {
      final src = (n <= 1) ? 0 : ((i * (safePeaks.length - 1)) / (n - 1)).round();
      final amp = safePeaks[src].clamp(0.0, 1.0) * (size.height * 0.38);
      final x = gap * (i + 1);
      canvas.drawLine(Offset(x, mid - amp), Offset(x, mid + amp), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SimpleWavePainter oldDelegate) => oldDelegate.peaks != peaks;
}

class _BigPlayButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onTap;
  const _BigPlayButton({required this.isPlaying, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: Container(
        width: 72,
        height: 72,
        decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle),
        child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 32),
      ),
    );
  }
}

class _MiniTrimBar extends StatelessWidget {
  final List<double> peaks;
  final Duration duration;
  final PlaybackTrimRange range;
  final ValueChanged<PlaybackTrimRange> onChange;

  const _MiniTrimBar({
    required this.peaks,
    required this.duration,
    required this.range,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = 66.0;
        final totalMs = math.max(1, duration.inMilliseconds);
        final sx = (w * (range.start.inMilliseconds / totalMs)).clamp(0.0, w);
        final ex = (w * (range.end.inMilliseconds / totalMs)).clamp(0.0, w);
        final left = math.min(sx, ex);
        final right = math.max(sx, ex);

        void setStartDx(double dx) {
          final ms = (totalMs * (dx / w)).round().clamp(0, totalMs);
          final next = PlaybackTrimRange(start: Duration(milliseconds: ms), end: range.end).normalized();
          onChange(next);
        }

        void setEndDx(double dx) {
          final ms = (totalMs * (dx / w)).round().clamp(0, totalMs);
          final next = PlaybackTrimRange(start: range.start, end: Duration(milliseconds: ms)).normalized();
          onChange(next);
        }

        void moveByDx(double dx) {
          final deltaMs = (totalMs * (dx / w)).round();
          final len = range.end - range.start;
    final maxStart = duration - len;
    var nextStart = range.start + Duration(milliseconds: deltaMs);
    if (nextStart < Duration.zero) nextStart = Duration.zero;
    if (nextStart > maxStart) nextStart = maxStart;
    final next = PlaybackTrimRange(start: nextStart, end: nextStart + len);
          onChange(next);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(AppLocalizations.of(context)!.trimTimeZero, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary)),
                const Spacer(),
                Text(_fmtPos(duration), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textTertiary)),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: h,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceMuted,
                        borderRadius: BorderRadius.circular(AppRadii.r12),
                        border: Border.all(color: AppColors.borderStrong),
                      ),
                      child: CustomPaint(
                        painter: _MiniWavePainter(peaks: peaks),
                      ),
                    ),
                  ),
                  // Selection
                  Positioned(
                    left: left,
                    width: (right - left).clamp(18.0, w),
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (d) => moveByDx(d.delta.dx),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.brandPrimary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppRadii.r12),
                          border: Border.all(color: AppColors.brandPrimary, width: 3),
                        ),
                      ),
                    ),
                  ),
                  // Left handle
                  Positioned(
                    left: left - 10,
                    top: 0,
                    bottom: 0,
                    width: 20,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (d) => setStartDx((left + d.delta.dx).clamp(0.0, w)),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: 10,
                          height: h,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(AppRadii.r8),
                            border: Border.all(color: AppColors.borderStrong),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Right handle
                  Positioned(
                    left: right - 10,
                    top: 0,
                    bottom: 0,
                    width: 20,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (d) => setEndDx((right + d.delta.dx).clamp(0.0, w)),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Container(
                          width: 10,
                          height: h,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(AppRadii.r8),
                            border: Border.all(color: AppColors.borderStrong),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MiniWavePainter extends CustomPainter {
  final List<double> peaks;
  _MiniWavePainter({required this.peaks});

  @override
  void paint(Canvas canvas, Size size) {
    final safePeaks = peaks.isEmpty ? const <double>[0.6] : peaks;
    final p = Paint()
      ..color = AppColors.grayD1
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    final n = math.min(120, safePeaks.length);
    final gap = size.width / (n + 1);
    for (var i = 0; i < n; i++) {
      final src = (n <= 1) ? 0 : ((i * (safePeaks.length - 1)) / (n - 1)).round();
      final amp = safePeaks[src].clamp(0.0, 1.0) * (size.height * 0.35);
      final x = gap * (i + 1);
      canvas.drawLine(Offset(x, mid - amp), Offset(x, mid + amp), p);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniWavePainter oldDelegate) => oldDelegate.peaks != peaks;
}

enum _BottomTool { smartEdit, trim, delete }

class _BottomTools extends StatelessWidget {
  final _BottomTool selected;
  final VoidCallback onSmartEdit;
  final VoidCallback onTrim;
  final VoidCallback onDelete;

  const _BottomTools({
    required this.selected,
    required this.onSmartEdit,
    required this.onTrim,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Color c(_BottomTool t) => selected == t ? AppColors.textPrimary : AppColors.textTertiary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ToolItem(icon: Icons.auto_awesome, label: l10n.smartEdit, color: c(_BottomTool.smartEdit), onTap: onSmartEdit),
        _ToolItem(icon: Icons.content_cut, label: l10n.trim, color: c(_BottomTool.trim), onTap: onTrim),
        _ToolItem(icon: Icons.delete_outline, label: l10n.delete, color: c(_BottomTool.delete), onTap: onDelete),
      ],
    );
  }
}

class _ToolItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ToolItem({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

String _fmtDate(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String _fmtPos(Duration d) {
  final total = d.inSeconds.clamp(0, 999999);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _sanitizeFileName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'trim';
  // Keep it simple and cross-platform.
  final safe = trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
  return safe.length > 40 ? safe.substring(0, 40) : safe;
}

List<double> _generatePeaks({required int seed, int count = 200}) {
  final rnd = math.Random(seed == 0 ? 1 : seed);
  final peaks = <double>[];
  var last = rnd.nextDouble();
  for (var i = 0; i < count; i++) {
    final target = rnd.nextDouble();
    last = (last * 0.75) + (target * 0.25);
    peaks.add((0.25 + last * 0.75).clamp(0.0, 1.0));
  }
  return peaks;
}

Recording _demoRecording(String id) {
  return Recording(
    id: id,
    deviceId: null,
    devicePath: 'demo',
    sessionId: null,
    asrResultId: null,
    recordingState: null,
    startedAt: null,
    endedAt: null,
    tmpPath: null,
    mtu: null,
    lastPacketAt: null,
    transferStartedAt: null,
    transferFinishedAt: null,
    remoteId: null,
    remoteUrl: null,
    transport: null,
    connectionId: null,
    lastSttJobId: null,
    lastSummaryJobId: null,
    name: 'Demo Recording',
    sizeBytes: null,
    durationSeconds: 8 * 60 + 7,
    createdAt: DateTime.now(),
    localPath: null,
    format: null,
    container: null,
    sampleRate: null,
    channels: null,
    bitDepth: null,
    receivedBytes: null,
    expectedBytes: null,
    lastSeq: null,
    crc32: null,
    devicePresent: false,
    transferState: 'done',
    transferProgress: 1.0,
    transferError: null,
    uploadState: 'not_uploaded',
    jobState: 'none',
    transcript: null,
    summary: null,
    currentSummaryId: null,
    transcriptPath: null,
    summaryPath: null,
    lastSttConfigId: null,
    lastLlmConfigId: null,
    lastTemplateId: null,
    lastLanguage: null,
    lastAutoSpeaker: true,
    updatedAt: DateTime.now(),
  );
}

