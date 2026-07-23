import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/widgets/app_card.dart';
import '../../ai_config/presentation/ai_config_providers.dart';
import '../domain/ai_providers.dart';
import '../domain/llm_config.dart';
import '../domain/prompt_template.dart';
import '../domain/stt_config.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/widgets/app_section_label.dart';

/// AI Configuration (STT / LLM / Prompt Templates).
class AiConfigPage extends ConsumerStatefulWidget {
  const AiConfigPage({super.key});

  @override
  ConsumerState<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends ConsumerState<AiConfigPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ensureSttConfigsLoaded(ref);
      await ensureLlmConfigsLoaded(ref);
      await ensurePromptTemplatesLoaded(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sttAsync = ref.watch(sttConfigsProvider);
    final llmAsync = ref.watch(llmConfigsProvider);
    final tplAsync = ref.watch(promptTemplatesProvider);

    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(l10n.aiConfiguration),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          AppSectionLabel(
            l10n.serviceConfiguration,
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
          ),
          AppCard(
            borderRadius: BorderRadius.circular(AppRadii.r18),
            backgroundColor: AppColors.surface,
            borderColor: AppColors.surface,
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _ServiceRow<SttConfig>(
                  icon: Icons.mic_none,
                  title: l10n.sttService,
                  asyncList: sttAsync,
                  emptySubtitle: l10n.notConfigured,
                  configuredSubtitle: (c) =>
                      '${c.name} · ${c.provider.labelFor(l10n)}',
                  onTap: () => context.push('/ai-config/stt'),
                ),
                const Divider(height: 1, color: AppColors.border),
                _ServiceRow<LlmConfig>(
                  icon: Icons.auto_awesome,
                  title: l10n.llmService,
                  asyncList: llmAsync,
                  emptySubtitle: l10n.notConfigured,
                  configuredSubtitle: (c) =>
                      '${c.name} · ${c.provider.labelFor(l10n)}',
                  onTap: () => context.push('/ai-config/llm'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          AppSectionLabel(
            l10n.promptTemplates,
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
          ),
          // const SizedBox(height: 10),
          tplAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  Text(
                    friendlyLoadErrorMessage(context, e),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppTypography.s14,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ensurePromptTemplatesLoaded(ref, force: true),
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            ),
            data: (tpls) {
              final items = tpls.where((t) => t.isDefault).toList();
              return Column(
                children: [
                  for (final t in items) ...[
                    _TemplateRow(
                      template: t,
                      primary: primary,
                      onTap: () => context.push('/ai-config/templates/${t.id}'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.push('/ai-config/templates'),
                    child: Text(
                      l10n.viewMoreTemplates,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: AppTypography.s12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ServiceRow<T> extends StatelessWidget {
  final IconData icon;
  final String title;
  final AsyncValue<List<T>> asyncList;
  final String emptySubtitle;
  final String Function(T first) configuredSubtitle;
  final VoidCallback onTap;

  const _ServiceRow({
    required this.icon,
    required this.title,
    required this.asyncList,
    required this.emptySubtitle,
    required this.configuredSubtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: AppTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  asyncList.when(
                    loading: () => Text(l10n.loading,
                        style: const TextStyle(color: AppColors.textTertiary)),
                    error: (_, __) => Text(emptySubtitle,
                        style: const TextStyle(color: AppColors.textTertiary)),
                    data: (list) {
                      if (list.isEmpty) {
                        return Text(emptySubtitle,
                            style:
                                const TextStyle(color: AppColors.textTertiary));
                      }
                      return Text(
                        configuredSubtitle(list.first),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: AppTypography.s14,
                          fontWeight: FontWeight.w400,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            asyncList.maybeWhen(
              data: (list) => list.isNotEmpty
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _StatusChip(text: l10n.configured, color: primary),
                        const SizedBox(width: 10),
                        Icon(Icons.check_circle, color: primary),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _StatusChip(
                            text: l10n.configure,
                            color: AppColors.textPlaceholder),
                        const SizedBox(width: 10),
                        const Icon(Icons.add_circle_outline,
                            color: AppColors.textPlaceholder),
                      ],
                    ),
              orElse: () => const Icon(Icons.chevron_right,
                  color: AppColors.textPlaceholder, size: 28),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: AppTypography.s12),
      ),
    );
  }
}

class _TemplateRow extends StatelessWidget {
  final PromptTemplate template;
  final Color primary;
  final VoidCallback onTap;

  const _TemplateRow(
      {required this.template, required this.primary, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = switch (template.name) {
      'Meeting Summary' => l10n.promptTemplateSubtitleMeeting,
      'Class Summary' => l10n.promptTemplateSubtitleClass,
      'Lecture Summary' => l10n.promptTemplateSubtitleLecture,
      'Daily Dialogue' => l10n.promptTemplateSubtitleDailyDialogue,
      'Daily Conversation Summary' => l10n.promptTemplateSubtitleDailyConversation,
      _ => template.isDefault
          ? l10n.promptTemplateSubtitleCustomDefault
          : l10n.promptTemplateSubtitleCustomUser,
    };

    final icon = switch (template.name) {
      'Meeting Summary' => Icons.description_outlined,
      'Class Summary' => Icons.school_outlined,
      'Lecture Summary' => Icons.school_outlined,
      'Daily Dialogue' => Icons.chat_bubble_outline,
      'Daily Conversation Summary' => Icons.chat_bubble_outline,
      _ => Icons.description_outlined,
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          GoRouter.of(context).push('/ai-config/templates/${template.id}'),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        borderRadius: BorderRadius.circular(AppRadii.r18),
        backgroundColor: AppColors.surface,
        borderColor: AppColors.surface,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadii.r14),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, color: AppColors.textSecondary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    template.name,
                    style: const TextStyle(
                      fontSize: AppTypography.s14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textPlaceholder,
                      fontWeight: FontWeight.w400,
                      fontSize: AppTypography.s14,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: AppColors.textPlaceholder, size: 28),
          ],
        ),
      ),
    );
  }
}
