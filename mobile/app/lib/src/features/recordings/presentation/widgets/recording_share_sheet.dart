import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/audio/audio_waveform_peaks.dart'
    show decodeAudioToWavForPlayback, isRawOpusFile;
import '../../../../core/audio/ogg_opus_muxer.dart' show rawOpusToOggOpus;
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_pill_button.dart';
import '../../../recordings/domain/recording.dart';
import '../../utils/recording_export_text.dart';

/// Android-only: native share channel so Huawei/Honor can use hwCHOOSER (direct share quirk).
Future<void> _shareFileViaNativeAndroid(String path) async {
  const channel = MethodChannel('cc.seeed.voice/share');
  await channel.invokeMethod<void>('shareFile', <String, dynamic>{
    'path': path,
  });
}

class RecordingShareSheet extends StatelessWidget {
  final Recording recording;
  final String? summaryExportText;

  const RecordingShareSheet({
    super.key,
    required this.recording,
    this.summaryExportText,
  });

  static Future<void> show(
    BuildContext context,
    Recording recording, {
    String? summaryExportText,
  }) {
    return showAppBottomSheet<void>(
      context,
      builder: (_) => RecordingShareSheet(
        recording: recording,
        summaryExportText: summaryExportText,
      ),
    );
  }

  String? get _transcriptExportText {
    final raw = recording.transcript?.trim();
    if (raw == null || raw.isEmpty) return null;
    return formatTranscriptForExport(raw);
  }

  String? get _summaryExportText {
    final override = summaryExportText?.trim();
    final raw = (override != null && override.isNotEmpty)
        ? override
        : recording.summary?.trim();
    if (raw == null || raw.isEmpty) return null;
    return formatSummaryForExport(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasTranscript = _transcriptExportText?.isNotEmpty == true;
    final hasNote = _summaryExportText?.isNotEmpty == true;
    final canExportAudio =
        recording.localPath != null && recording.localPath!.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.share,
                  style: const TextStyle(
                    fontSize: AppTypography.s18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: const Icon(Icons.close,
                    size: 22, color: AppColors.textSecondary),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 4),
            child: Divider(height: 1, color: AppColors.borderLight),
          ),
          _CopyToClipboardSection(
            transcriptText: _transcriptExportText,
            summaryText: _summaryExportText,
            hasTranscript: hasTranscript,
            hasNote: hasNote,
            copySuccessLabel: l10n.copySuccess,
            copyToClipboardLabel: l10n.copyToClipboard,
            transcriptionLabel: l10n.transcription,
            noteLabel: l10n.note,
          ),
          const SizedBox(height: 14),
          _SectionTitle(l10n.exportFile),
          _ActionRow(
            icon: Icons.graphic_eq,
            label: l10n.audio,
            enabled: canExportAudio,
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textPlaceholder, size: 28),
            onTap: canExportAudio
                ? () => _ExportFileSheet.show(context,
                    recording: recording, kind: _ExportKind.audio)
                : null,
          ),
          _ActionRow(
            icon: Icons.description_outlined,
            label: l10n.transcription,
            enabled: hasTranscript,
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textPlaceholder, size: 28),
            onTap: hasTranscript
                ? () => _ExportFileSheet.show(
                      context,
                      recording: recording,
                      kind: _ExportKind.transcript,
                      exportText: _transcriptExportText!,
                    )
                : null,
          ),
          _ActionRow(
            icon: Icons.note_alt_outlined,
            label: l10n.note,
            enabled: hasNote,
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.textPlaceholder, size: 28),
            onTap: hasNote
                ? () => _ExportFileSheet.show(
                      context,
                      recording: recording,
                      kind: _ExportKind.note,
                      exportText: _summaryExportText!,
                    )
                : null,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: AppTypography.s14,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// Copy-to-clipboard block with in-sheet success hint so it is not covered by the bottom sheet.
class _CopyToClipboardSection extends StatefulWidget {
  final String? transcriptText;
  final String? summaryText;
  final bool hasTranscript;
  final bool hasNote;
  final String copySuccessLabel;
  final String copyToClipboardLabel;
  final String transcriptionLabel;
  final String noteLabel;

  const _CopyToClipboardSection({
    required this.transcriptText,
    required this.summaryText,
    required this.hasTranscript,
    required this.hasNote,
    required this.copySuccessLabel,
    required this.copyToClipboardLabel,
    required this.transcriptionLabel,
    required this.noteLabel,
  });

  @override
  State<_CopyToClipboardSection> createState() =>
      _CopyToClipboardSectionState();
}

class _CopyToClipboardSectionState extends State<_CopyToClipboardSection> {
  bool _showCopySuccess = false;

  void _onCopy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _showCopySuccess = true);
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _showCopySuccess = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_showCopySuccess)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    size: 18, color: AppColors.brandPrimary),
                const SizedBox(width: 6),
                Text(
                  widget.copySuccessLabel,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.brandPrimary,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        _SectionTitle(widget.copyToClipboardLabel),
        _ActionRow(
          icon: Icons.description_outlined,
          label: widget.transcriptionLabel,
          enabled: widget.hasTranscript,
          trailing:
              const Icon(Icons.copy_outlined, color: AppColors.textPlaceholder),
          onTap: widget.hasTranscript
              ? () => _onCopy(widget.transcriptText!.trim())
              : null,
        ),
        _ActionRow(
          icon: Icons.note_alt_outlined,
          label: widget.noteLabel,
          enabled: widget.hasNote,
          trailing:
              const Icon(Icons.copy_outlined, color: AppColors.textPlaceholder),
          onTap:
              widget.hasNote ? () => _onCopy(widget.summaryText!.trim()) : null,
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget trailing;
  final bool enabled;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.trailing,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? AppColors.textPrimary : AppColors.textPlaceholder;
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Icon(icon, color: fg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: AppTypography.s14,
                  color: fg),
            ),
          ),
          IconTheme(
              data: IconThemeData(
                  color: enabled
                      ? AppColors.textPlaceholder
                      : AppColors.textPlaceholder),
              child: trailing),
        ],
      ),
    );

    if (!enabled) return child;
    return InkWell(onTap: onTap, child: child);
  }
}

enum _ExportKind { audio, transcript, note }

class _ExportFileSheet extends StatefulWidget {
  final Recording recording;
  final _ExportKind kind;
  final String exportText;

  const _ExportFileSheet({
    required this.recording,
    required this.kind,
    this.exportText = '',
  });

  static Future<void> show(
    BuildContext context, {
    required Recording recording,
    required _ExportKind kind,
    String exportText = '',
  }) {
    return showAppBottomSheet<void>(
      context,
      builder: (_) => _ExportFileSheet(
        recording: recording,
        kind: kind,
        exportText: exportText,
      ),
    );
  }

  @override
  State<_ExportFileSheet> createState() => _ExportFileSheetState();
}

class _ExportFileSheetState extends State<_ExportFileSheet> {
  late List<String> _formats;
  late String _format;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _formats = _availableFormats(widget.recording, widget.kind);
    _format = _pickDefaultFormat(widget.recording, widget.kind, _formats);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = switch (widget.kind) {
      _ExportKind.audio => l10n.exportRecording,
      _ExportKind.transcript => l10n.exportTranscript,
      _ExportKind.note => l10n.exportNote,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                onTap: () => Navigator.of(context).pop(),
                child: const Icon(Icons.close,
                    size: 22, color: AppColors.textSecondary),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 8),
            child: Divider(height: 1, color: AppColors.borderLight),
          ),
          for (final f in _formats)
            _ExportFormatRadioRow(
              label: f,
              groupValue: _format,
              enabled: !_busy,
              onTap: () => setState(() => _format = f),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 8),
            child: Divider(height: 1, color: AppColors.borderLight),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Text(
                  l10n.exportFormat,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppTypography.s14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _format,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppTypography.s14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppBlackPillButton(
            label: _busy ? l10n.exporting : l10n.export,
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      final file = await _exportToFile(
                        context,
                        widget.recording,
                        widget.kind,
                        _format,
                        exportText: widget.exportText,
                      );
                      if (!mounted || !context.mounted) return;
                      if (file != null) {
                        Navigator.of(context).pop();
                        await Future<void>.delayed(
                            const Duration(milliseconds: 200));
                        File fileToShare = file;
                        if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
                          final copied = await _copyToCacheForShare(file);
                          if (copied != null) fileToShare = copied;
                        }
                        try {
                          if (!kIsWeb && Platform.isAndroid) {
                            // File-only share: Huawei/Honor "Save" treats
                            // EXTRA_TEXT as a second tiny text file.
                            await _shareFileViaNativeAndroid(fileToShare.path);
                          } else {
                            await SharePlus.instance.share(ShareParams(
                                files: [_xFileForShare(fileToShare)]));
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(l10n.shareFailed(e.toString()))));
                          }
                        }
                      }
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            leading: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : null,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// One row of format options (circular radio)
class _ExportFormatRadioRow extends StatelessWidget {
  final String label;
  final String groupValue;
  final bool enabled;
  final VoidCallback onTap;

  const _ExportFormatRadioRow({
    required this.label,
    required this.groupValue,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadii.r12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? AppColors.textPrimary
                      : AppColors.textPlaceholder,
                  fontSize: AppTypography.s16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: RadioGroup<String>(
                groupValue: groupValue,
                onChanged: (_) {
                  if (enabled) onTap();
                },
                child: Radio<String>(
                  value: label,
                  enabled: enabled,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  activeColor: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _availableFormats(Recording r, _ExportKind kind) {
  switch (kind) {
    case _ExportKind.audio:
      return const ['Original', 'Opus', 'MP3', 'WAV'];
    case _ExportKind.transcript:
      return const ['TXT', 'Markdown', 'DOCX', 'PDF'];
    case _ExportKind.note:
      return const ['TXT', 'Markdown', 'DOCX', 'PDF'];
  }
}

String _pickDefaultFormat(Recording r, _ExportKind kind, List<String> formats) {
  if (formats.isEmpty) return 'Original';
  if (kind == _ExportKind.audio) {
    final pth = r.localPath?.toLowerCase().trim();
    if (pth != null && pth.isNotEmpty) {
      final isOpus = r.format?.toLowerCase() == 'opus';
      if (pth.endsWith('.opus') && formats.contains('Opus')) {
        return 'Opus';
      }
      if (pth.endsWith('.caf') && isOpus && formats.contains('Opus')) {
        return 'Opus';
      }
    }
  }
  return formats.first;
}

/// Lossless remux of device **raw** `.opus` into RFC 7845 Ogg Opus (file suffix `.opus`).
Future<File?> _remuxRawOpusForShare(
    File src, Recording r, String exportNameTag) async {
  final dir = await getTemporaryDirectory();
  final baseName = _fileBaseName(r);
  final ts =
      DateTime.now().toIso8601String().replaceAll(':', '').replaceAll('.', '');
  final outPath = p.join(dir.path, '${baseName}_${exportNameTag}_$ts.opus');
  final muxed = await rawOpusToOggOpus(src.path, outPath: outPath);
  if (muxed == null) return null;
  return File(muxed);
}

/// 48 kHz PCM WAV path for export. Device `.opus` is often **raw** Opus (not Ogg) — FFmpeg cannot decode it;
/// this uses the same [decodeAudioToWavForPlayback] pipeline as in-app playback.
Future<String?> _exportPcmWav48kPath(String srcPath) async {
  final f = File(srcPath);
  if (!await f.exists()) return null;
  final ext = p.extension(srcPath).toLowerCase();
  if (ext == '.wav') return srcPath;

  if (ext == '.opus' || ext == '.caf') {
    return decodeAudioToWavForPlayback(srcPath, sampleRate: 48000);
  }

  final dir = await getTemporaryDirectory();
  final outPath = p.join(
      dir.path, 'export_pcm48_${DateTime.now().microsecondsSinceEpoch}.wav');
  final cmd =
      '-nostdin -loglevel error -y -threads 0 -vn -i "${f.path}" -ac 1 -ar 48000 -c:a pcm_s16le "$outPath"';
  final session = await FFmpegKit.execute(cmd);
  final rc = await session.getReturnCode();
  if (rc != null && ReturnCode.isSuccess(rc)) return outPath;
  return null;
}

Future<File?> _copyExportWav(String pcmPath, String baseName, String ts) async {
  final dir = await getTemporaryDirectory();
  final outPath = p.join(dir.path, '${baseName}_wav_$ts.wav');
  if (p.normalize(pcmPath) == p.normalize(outPath)) {
    return File(pcmPath);
  }
  await File(pcmPath).copy(outPath);
  return File(outPath);
}

/// Run export and return the file; does not close sheet or open share. Caller closes then shares.
Future<File?> _exportToFile(
  BuildContext context,
  Recording r,
  _ExportKind kind,
  String format, {
  String exportText = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final l10n = AppLocalizations.of(context)!;
  switch (kind) {
    case _ExportKind.audio:
      final pth = r.localPath;
      if (pth == null || pth.trim().isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.noAudioToExport)));
        return null;
      }
      final file = File(pth);
      if (!await file.exists()) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.audioFileNotFound)));
        return null;
      }
      final ext = p.extension(file.path).toLowerCase();
      if (format == 'Original') {
        // Device `.opus` is usually **raw** packets (not Ogg). Sharing the file verbatim is unplayable
        // in most apps; we only remux into RFC 7845 Ogg Opus — no re-encode, same coded audio.
        if (ext == '.opus' && await isRawOpusFile(file)) {
          try {
            final out = await _remuxRawOpusForShare(file, r, 'original');
            if (out == null) {
              messenger.showSnackBar(SnackBar(
                  content: Text(l10n.transcodeFailed(l10n.ffmpegError))));
              return null;
            }
            return out;
          } catch (e) {
            messenger.showSnackBar(
                SnackBar(content: Text(l10n.transcodeFailed(e.toString()))));
            return null;
          }
        }
        return file;
      }
      if (format == 'Opus') {
        // Same remux as [Original] for device raw Opus — [Opus] vs [Original] only differs for non-Opus sources below.
        if (ext == '.opus' && await isRawOpusFile(file)) {
          try {
            final out = await _remuxRawOpusForShare(file, r, 'opus');
            if (out == null) {
              messenger.showSnackBar(SnackBar(
                  content: Text(l10n.transcodeFailed(l10n.ffmpegError))));
              return null;
            }
            return out;
          } catch (e) {
            messenger.showSnackBar(
                SnackBar(content: Text(l10n.transcodeFailed(e.toString()))));
            return null;
          }
        }
        if (ext == '.opus') {
          return file;
        }
        try {
          final pcmPath = await _exportPcmWav48kPath(file.path);
          if (pcmPath == null) {
            messenger.showSnackBar(SnackBar(
                content: Text(l10n.transcodeFailed(l10n.ffmpegError))));
            return null;
          }
          final dir = await getTemporaryDirectory();
          final baseName = _fileBaseName(r);
          final ts = DateTime.now()
              .toIso8601String()
              .replaceAll(':', '')
              .replaceAll('.', '');
          final outPath = p.join(dir.path, '${baseName}_opus_$ts.ogg');
          final cmd = '-y -i "$pcmPath" -vn -c:a libopus -b:a 64000 "$outPath"';
          final session = await FFmpegKit.execute(cmd);
          final rc = await session.getReturnCode();
          if (rc == null || !ReturnCode.isSuccess(rc)) {
            final logs = await session.getAllLogsAsString() ?? '';
            final msg = logs.isEmpty ? l10n.ffmpegError : logs;
            messenger.showSnackBar(
                SnackBar(content: Text(l10n.transcodeFailed(msg))));
            return null;
          }
          return File(outPath);
        } catch (e) {
          messenger.showSnackBar(
              SnackBar(content: Text(l10n.transcodeFailed(e.toString()))));
          return null;
        }
      }
      if (format == 'WAV') {
        if (ext == '.wav') return file;
        try {
          final baseName = _fileBaseName(r);
          final ts = DateTime.now()
              .toIso8601String()
              .replaceAll(':', '')
              .replaceAll('.', '');
          final pcmPath = await _exportPcmWav48kPath(file.path);
          if (pcmPath == null) {
            messenger.showSnackBar(SnackBar(
                content: Text(l10n.transcodeFailed(l10n.ffmpegError))));
            return null;
          }
          return _copyExportWav(pcmPath, baseName, ts);
        } catch (e) {
          messenger.showSnackBar(
              SnackBar(content: Text(l10n.transcodeFailed(e.toString()))));
          return null;
        }
      }
      if (format == 'MP3') {
        if (ext == '.mp3') return file;
        try {
          final dir = await getTemporaryDirectory();
          final baseName = _fileBaseName(r);
          final ts = DateTime.now()
              .toIso8601String()
              .replaceAll(':', '')
              .replaceAll('.', '');
          final outPath = p.join(dir.path, '${baseName}_mp3_$ts.mp3');

          /// Raw Opus remux is streaming (~same size as source); avoid decoding to multi‑hundred‑MB 48 kHz WAV before MP3.
          String? muxedOggToDelete;
          late final String ffmpegIn;
          if (ext == '.opus' && await isRawOpusFile(file)) {
            final oggPath = p.join(dir.path, '${baseName}_export_mux_$ts.ogg');
            final muxed = await rawOpusToOggOpus(file.path, outPath: oggPath);
            if (muxed == null) {
              messenger.showSnackBar(SnackBar(
                  content: Text(l10n.transcodeFailed(l10n.ffmpegError))));
              return null;
            }
            muxedOggToDelete = muxed;
            ffmpegIn = muxed;
          } else if (ext == '.opus') {
            // Standard Ogg Opus — FFmpeg reads the container directly (no full WAV on disk).
            ffmpegIn = file.path;
          } else if (ext == '.wav') {
            ffmpegIn = file.path;
          } else {
            final pcmPath = await _exportPcmWav48kPath(file.path);
            if (pcmPath == null) {
              messenger.showSnackBar(SnackBar(
                  content: Text(l10n.transcodeFailed(l10n.ffmpegError))));
              return null;
            }
            ffmpegIn = pcmPath;
          }

          final cmd =
              '-nostdin -loglevel error -y -threads 0 -vn -i "$ffmpegIn" -c:a libmp3lame -b:a 192k "$outPath"';
          final session = await FFmpegKit.execute(cmd);
          final rc = await session.getReturnCode();
          try {
            if (rc == null || !ReturnCode.isSuccess(rc)) {
              final logs = await session.getAllLogsAsString() ?? '';
              final msg = logs.isEmpty ? l10n.ffmpegError : logs;
              messenger.showSnackBar(
                  SnackBar(content: Text(l10n.transcodeFailed(msg))));
              return null;
            }
            return File(outPath);
          } finally {
            final oggPath = muxedOggToDelete;
            if (oggPath != null) {
              try {
                await File(oggPath).delete();
              } catch (_) {}
            }
          }
        } catch (e) {
          messenger.showSnackBar(
              SnackBar(content: Text(l10n.transcodeFailed(e.toString()))));
          return null;
        }
      }
      messenger
          .showSnackBar(SnackBar(content: Text(l10n.unsupportedAudioFormat)));
      return null;
    case _ExportKind.transcript:
      final text = exportText.trim();
      if (text.isEmpty) {
        messenger
            .showSnackBar(SnackBar(content: Text(l10n.noTranscriptToExport)));
        return null;
      }
      return _writeTempDocumentFile(
          _fileBaseName(r), 'transcript', format, text);
    case _ExportKind.note:
      final text = exportText.trim();
      if (text.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.noNoteToExport)));
        return null;
      }
      return _writeTempDocumentFile(_fileBaseName(r), 'note', format, text);
  }
}

String _fileBaseName(Recording r) {
  final name = (r.name ?? 'recording').trim();
  final safe = name.isEmpty
      ? 'recording'
      : name.replaceAll(RegExp(r'[\\\\/:*?"<>|]'), '_');
  return safe;
}

/// [XFile] with a MIME hint so iOS / desktop share sheets pick a playable type for Opus (Ogg).
XFile _xFileForShare(File f) {
  final ext = p.extension(f.path).toLowerCase();
  final mime = switch (ext) {
    '.opus' => 'audio/ogg',
    '.ogg' => 'audio/ogg',
    '.wav' => 'audio/wav',
    '.mp3' => 'audio/mpeg',
    '.caf' => 'audio/x-caf',
    '.m4a' => 'audio/mp4',
    '.txt' => 'text/plain',
    '.md' => 'text/markdown',
    '.pdf' => 'application/pdf',
    '.docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    _ => null,
  };
  return mime != null ? XFile(f.path, mimeType: mime) : XFile(f.path);
}

/// On Android/iOS, copy [file] to app cache dir before share.
Future<File?> _copyToCacheForShare(File file) async {
  try {
    if (!await file.exists()) return null;
    final dir = await getTemporaryDirectory();
    final ext = p.extension(file.path).toLowerCase();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final name = 'export_share_$stamp${ext.isEmpty ? '.bin' : ext}';
    final dest = File(p.join(dir.path, name));
    await file.copy(dest.path);
    return dest;
  } catch (_) {
    return null;
  }
}

Future<File> _writeTempTextFile(
    String baseName, String suffix, String ext, String content) async {
  final dir = await getTemporaryDirectory();
  final ts =
      DateTime.now().toIso8601String().replaceAll(':', '').replaceAll('.', '');
  final file = File(p.join(dir.path, '${baseName}_${suffix}_$ts.$ext'));
  await file.writeAsString(content);
  return file;
}

Future<File> _writeTempDocumentFile(
  String baseName,
  String suffix,
  String format,
  String content,
) {
  if (format == 'DOCX') return _writeTempDocxFile(baseName, suffix, content);
  if (format == 'PDF') return _writeTempPdfFile(baseName, suffix, content);
  final ext = (format == 'Markdown') ? 'md' : 'txt';
  return _writeTempTextFile(baseName, suffix, ext, content);
}

Future<File> _writeTempDocxFile(
  String baseName,
  String suffix,
  String content,
) async {
  final dir = await getTemporaryDirectory();
  final ts =
      DateTime.now().toIso8601String().replaceAll(':', '').replaceAll('.', '');
  final file = File(p.join(dir.path, '${baseName}_${suffix}_$ts.docx'));
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', _docxContentTypesXml))
    ..addFile(ArchiveFile.string('_rels/.rels', _docxRootRelsXml))
    ..addFile(ArchiveFile.string(
        'word/_rels/document.xml.rels', _docxDocumentRelsXml))
    ..addFile(ArchiveFile.string('word/styles.xml', _docxStylesXml))
    ..addFile(
        ArchiveFile.string('word/document.xml', _docxDocumentXml(content)));
  await file.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
  return file;
}

Future<File> _writeTempPdfFile(
  String baseName,
  String suffix,
  String content,
) async {
  final dir = await getTemporaryDirectory();
  final ts =
      DateTime.now().toIso8601String().replaceAll(':', '').replaceAll('.', '');
  final file = File(p.join(dir.path, '${baseName}_${suffix}_$ts.pdf'));
  await file.writeAsBytes(_buildTextPdf(content), flush: true);
  return file;
}

String _docxDocumentXml(String content) {
  final paragraphs = content
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map(_docxParagraphXml)
      .join();
  return '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$paragraphs<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
''';
}

String _docxParagraphXml(String text) {
  if (text.isEmpty) return '<w:p/>';
  return '<w:p><w:r><w:t xml:space="preserve">${_xmlEscape(text)}</w:t></w:r></w:p>';
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

const _docxContentTypesXml =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
''';

const _docxRootRelsXml =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
''';

const _docxDocumentRelsXml =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
''';

const _docxStylesXml =
    '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:rPr><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style></w:styles>
''';

Uint8List _buildTextPdf(String content) {
  const pageWidth = 595.0;
  const pageHeight = 842.0;
  const left = 50.0;
  const top = 56.0;
  const bottom = 56.0;
  const fontSize = 11.0;
  const lineHeight = 14.0;
  const maxLineWidth = 82.0;
  final linesPerPage = ((pageHeight - top - bottom) / lineHeight).floor();
  final lines = _wrapPdfText(content, maxLineWidth);
  final pages = <List<String>>[];
  for (var i = 0; i < lines.length; i += linesPerPage) {
    pages.add(lines.sublist(i, (i + linesPerPage).clamp(0, lines.length)));
  }
  if (pages.isEmpty) pages.add(const ['']);

  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '',
    _pdfCjkFontObject,
  ];
  final kids = <String>[];
  for (var i = 0; i < pages.length; i += 1) {
    final pageId = 4 + i * 2;
    final contentId = pageId + 1;
    kids.add('$pageId 0 R');
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth.toInt()} ${pageHeight.toInt()}] /Resources << /Font << /F1 3 0 R >> >> /Contents $contentId 0 R >>',
    );
    objects.add(_pdfStreamObject(_pdfPageStream(
      pages[i],
      left: left,
      y: pageHeight - top,
      fontSize: fontSize,
      lineHeight: lineHeight,
    )));
  }
  objects[1] =
      '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${pages.length} >>';

  final bytes = BytesBuilder();
  void addAscii(String value) => bytes.add(ascii.encode(value));
  addAscii('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i += 1) {
    offsets.add(bytes.length);
    addAscii('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefOffset = bytes.length;
  addAscii('xref\n0 ${objects.length + 1}\n');
  addAscii('0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    addAscii('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  addAscii(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n',
  );
  return bytes.toBytes();
}

List<String> _wrapPdfText(String content, double maxWidth) {
  final out = <String>[];
  for (final rawLine
      in content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    if (rawLine.isEmpty) {
      out.add('');
      continue;
    }
    final buf = StringBuffer();
    var width = 0.0;
    for (final rune in rawLine.runes) {
      final char = String.fromCharCode(rune);
      final charWidth = rune <= 0x7f ? 1.0 : 1.8;
      if (buf.isNotEmpty && width + charWidth > maxWidth) {
        out.add(buf.toString());
        buf.clear();
        width = 0;
      }
      buf.write(char);
      width += charWidth;
    }
    out.add(buf.toString());
  }
  return out;
}

String _pdfPageStream(
  List<String> lines, {
  required double left,
  required double y,
  required double fontSize,
  required double lineHeight,
}) {
  final b = StringBuffer()
    ..writeln('BT')
    ..writeln('/F1 ${_pdfNum(fontSize)} Tf')
    ..writeln('${_pdfNum(left)} ${_pdfNum(y)} Td')
    ..writeln('${_pdfNum(lineHeight)} TL');
  for (final line in lines) {
    if (line.isNotEmpty) b.writeln('<${_pdfUtf16Hex(line)}> Tj');
    b.writeln('T*');
  }
  b.writeln('ET');
  return b.toString();
}

String _pdfStreamObject(String stream) {
  final length = ascii.encode(stream).length;
  return '<< /Length $length >>\nstream\n$stream\nendstream';
}

String _pdfUtf16Hex(String text) {
  final b = StringBuffer();
  for (final unit in text.codeUnits) {
    b.write(unit.toRadixString(16).padLeft(4, '0').toUpperCase());
  }
  return b.toString();
}

String _pdfNum(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2);
}

const _pdfCjkFontObject = '''
<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light /Encoding /UniGB-UCS2-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >> /FontDescriptor << /Type /FontDescriptor /FontName /STSong-Light /Flags 6 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 880 /Descent -120 /CapHeight 700 /StemV 80 >> /DW 1000 >>] >>
''';
