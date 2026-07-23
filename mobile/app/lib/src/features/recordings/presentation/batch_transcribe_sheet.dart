import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../ai_config/domain/stt_config.dart';
import '../../ai_config/presentation/ai_config_providers.dart';
import 'transcribe_common.dart';

Future<TranscribeSheetSelection?> showBatchTranscribeSheet(
  BuildContext context,
  WidgetRef ref, {
  TranscribeSheetSelection? initial,
}) async {
  await ensureSttConfigsLoaded(ref);
  if (!context.mounted) return null;
  return showAppBottomSheet<TranscribeSheetSelection>(
    context,
    builder: (_) => _BatchTranscribeSheet(initial: initial),
  );
}

class _BatchTranscribeSheet extends ConsumerStatefulWidget {
  final TranscribeSheetSelection? initial;
  const _BatchTranscribeSheet({this.initial});

  @override
  ConsumerState<_BatchTranscribeSheet> createState() =>
      _BatchTranscribeSheetState();
}

class _BatchTranscribeSheetState extends ConsumerState<_BatchTranscribeSheet> {
  bool _autoSpeaker = true;
  String _language = 'Auto';
  SttConfig? _stt;
  bool _didAutoPickDefaults = false;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    if (init != null) {
      _autoSpeaker = init.autoSpeaker;
      _language = init.language;
      _stt = init.stt;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ensureSttConfigsLoaded(ref);
    });
  }

  Future<T?> _pickFromList<T>(
    BuildContext sheetContext, {
    required String title,
    required List<T> items,
    required String Function(T) labelOf,
    T? selected,
  }) async {
    return showAppBottomSheet<T>(
      sheetContext,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            title: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s14,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          for (final it in items)
            ListTile(
              title: Text(labelOf(it)),
              trailing: selected != null && it == selected
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onTap: () => Navigator.of(ctx).pop(it),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sttAsync = ref.watch(sttConfigsProvider);
    final sttList = sttAsync.valueOrNull ?? const <SttConfig>[];
    final displayStt = _stt ?? (sttList.isNotEmpty ? sttList.first : null);
    final locale = Localizations.localeOf(context);
    final autoSpeakerEnabled = displayStt != null &&
        configSupportsSpeakerDiarization(
          displayStt,
          language: _language,
          locale: locale,
        );
    final effectiveAutoSpeaker = autoSpeakerEnabled && _autoSpeaker;
    if (!_didAutoPickDefaults && (sttAsync.hasValue || sttAsync.hasError)) {
      _didAutoPickDefaults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          if (_stt == null && displayStt != null) {
            _stt = displayStt;
          }
        });
      });
    }

    final canRun = displayStt != null;

    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.text_snippet_outlined,
                    size: 22, color: AppColors.textPrimary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.batchTranscribe,
                    style: const TextStyle(
                      fontSize: AppTypography.s18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
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
            _SheetRow(
              label: l10n.autoSpeakerLabeling,
              trailing: Switch(
                value: effectiveAutoSpeaker,
                onChanged: autoSpeakerEnabled
                    ? (v) => setState(() => _autoSpeaker = v)
                    : null,
              ),
            ),
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
                      fontSize: AppTypography.s14,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right,
                      color: AppColors.textPlaceholder, size: 28),
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
            _SheetRow(
              label: l10n.sttModel,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayStt?.name ?? l10n.select,
                    style: const TextStyle(
                      color: AppColors.textPlaceholder,
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s14,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right,
                      color: AppColors.textPlaceholder, size: 28),
                ],
              ),
              onTap: () async {
                final list = sttAsync.valueOrNull ?? const <SttConfig>[];
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
            const SizedBox(height: 24),
            AppBlackPillButton(
              label: l10n.generateNow,
              onPressed: canRun
                  ? () {
                      Navigator.of(context).pop(
                        TranscribeSheetSelection(
                          stt: displayStt,
                          language: _language,
                          autoSpeaker: effectiveAutoSpeaker,
                        ),
                      );
                    }
                  : null,
            ),
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

  const _SheetRow({
    required this.label,
    required this.trailing,
    this.onTap,
  });

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
