import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';
import '../../domain/ai_providers.dart';
import '../../domain/asr_vendor_config.dart';
import '../../domain/llm_config.dart';
import '../../domain/stt_config.dart';
import '../../data/asr_config_repository.dart';
import '../ai_config_providers.dart';
import 'guide_widgets.dart';
import '../widgets/llm_config_editor_sheet.dart';
import '../widgets/stt_config_editor_sheet.dart';
import 'ai_config_guide_helper.dart';

enum _GuideStep { welcome, stt, llm, done }

/// Guided setup flow for STT + LLM configurations.
///
/// Route: `/ai-config/guide`
class AiConfigGuideFlowPage extends ConsumerStatefulWidget {
  const AiConfigGuideFlowPage({super.key});

  @override
  ConsumerState<AiConfigGuideFlowPage> createState() =>
      _AiConfigGuideFlowPageState();
}

class _AiConfigGuideFlowPageState extends ConsumerState<AiConfigGuideFlowPage> {
  _GuideStep _step = _GuideStep.welcome;

  Future<void> _openSttEditor([SttConfig? existing]) async {
    SttConfig? toEdit = existing;
    final vendorId = existing?.asrRemoteVendorId;
    if (existing != null && vendorId != null) {
      try {
        final asrRepo = await ref.read(asrConfigRepositoryProvider.future);
        toEdit = await asrRepo.fetchVendorDetail(
                vendorId: vendorId, sortIndex: existing.sortIndex) ??
            existing;
      } catch (_) {
        toEdit = existing;
      }
    }
    if (!mounted) return;
    await showSttConfigEditorSheet(context, existing: toEdit);
    ref.invalidate(sttConfigsProvider);
  }

  Future<void> _openLlmEditor([LlmConfig? existing]) async {
    await showLlmConfigEditorSheet(context, existing: existing);
    ref.invalidate(llmConfigsProvider);
  }

  Future<void> _skipGuide() async {
    await AiConfigGuideHelper.markDone(ref: ref);
    if (!mounted) return;
    context.go('/recordings');
  }

  @override
  Widget build(BuildContext context) {
    final sttAsync = ref.watch(sttConfigsProvider);
    final llmAsync = ref.watch(llmConfigsProvider);

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      body: SafeArea(
        child: switch (_step) {
          _GuideStep.welcome => _WelcomeStep(
              onSkip: _skipGuide,
              onStart: () => setState(() => _step = _GuideStep.stt),
            ),
          _GuideStep.stt => _SttStep(
              onSkip: _skipGuide,
              onBack: () => setState(() => _step = _GuideStep.welcome),
              onNext: _goNextFromStt,
              asyncList: sttAsync,
              onAdd: () => _openSttEditor(null),
              onEdit: (c) => _openSttEditor(c),
            ),
          _GuideStep.llm => _LlmStep(
              onSkip: _skipGuide,
              onBack: () => setState(() => _step = _GuideStep.stt),
              onNext: _goNextFromLlm,
              asyncList: llmAsync,
              onAdd: () => _openLlmEditor(null),
              onEdit: (c) => _openLlmEditor(c),
            ),
          _GuideStep.done => _DoneStep(
              sttProviderLabel: sttAsync.maybeWhen(
                data: (l) => l.isNotEmpty
                    ? l.first.name
                    : AppLocalizations.of(context)!.notConfigured,
                orElse: () => AppLocalizations.of(context)!.notConfigured,
              ),
              llmProviderLabel: llmAsync.maybeWhen(
                data: (l) => l.isNotEmpty
                    ? l.first.name
                    : AppLocalizations.of(context)!.notConfigured,
                orElse: () => AppLocalizations.of(context)!.notConfigured,
              ),
              onFinish: _finishSetup,
            ),
        },
      ),
    );
  }

  void _goNextFromLlm() {
    debugPrint('goNextFromLlm----');
    FocusManager.instance.primaryFocus?.unfocus();
    final hasAny = ref
        .read(llmConfigsProvider)
        .maybeWhen(data: (l) => l.isNotEmpty, orElse: () => false);
    if (!hasAny)
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.pleaseAddLlm)));
    setState(() => _step = _GuideStep.done);
  }

  void _goNextFromStt() {
    debugPrint('goNextFromStt----');
    FocusManager.instance.primaryFocus?.unfocus();
    final hasAny = ref
        .read(sttConfigsProvider)
        .maybeWhen(data: (l) => l.isNotEmpty, orElse: () => false);
    if (!hasAny)
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.pleaseAddStt)));
    setState(() => _step = _GuideStep.llm);
  }

  Future<void> _finishSetup() async {
    ref.invalidate(llmConfigsProvider);
    ref.invalidate(sttConfigsProvider);

    if (!mounted) return;
    await AiConfigGuideHelper.markDone(ref: ref);
    if (!mounted) return;
    context.go('/recordings');
  }
}

class _WelcomeStep extends StatelessWidget {
  final VoidCallback onStart;
  final VoidCallback onSkip;

  const _WelcomeStep({required this.onStart, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportH =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
                ? constraints.maxHeight
                : MediaQuery.of(context).size.height;
        const horizontal = 20.0;
        return CustomScrollView(
          physics: const ClampingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(horizontal, 12, horizontal, 0),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onSkip,
                    child: Text(
                      AppLocalizations.of(context)!.skip,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                        fontSize: AppTypography.s16,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(horizontal, 0, horizontal, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: viewportH * 0.04),
                    Center(
                      child: Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          color: AppColors.buttonPrimaryBg,
                          borderRadius: BorderRadius.circular(AppRadii.r26),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 22,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: const Icon(Icons.auto_awesome,
                            color: AppColors.surface, size: 52),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      AppLocalizations.of(context)!.guideWelcomeTitle,
                      style: const TextStyle(
                        fontSize: AppTypography.s22,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      AppLocalizations.of(context)!.guideWelcomeSubtitle,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: AppTypography.s14,
                        height: 1.35,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    _GuideServiceCard(
                      icon: Icons.mic_none,
                      title: AppLocalizations.of(context)!.guideSttServiceTitle,
                      subtitle:
                          AppLocalizations.of(context)!.guideSttServiceSubtitle,
                    ),
                    const SizedBox(height: 14),
                    _GuideServiceCard(
                      icon: Icons.chat_bubble_outline,
                      title: AppLocalizations.of(context)!.guideLlmServiceTitle,
                      subtitle:
                          AppLocalizations.of(context)!.guideLlmServiceSubtitle,
                    ),
                  ],
                ),
              ),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(horizontal, 8, horizontal, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(),
                    GuidePrimaryButton(
                        label: AppLocalizations.of(context)!.getStarted,
                        onTap: onStart),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LlmStep extends StatelessWidget {
  final VoidCallback onSkip;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final Future<void> Function() onAdd;
  final Future<void> Function(LlmConfig existing) onEdit;
  final AsyncValue<List<LlmConfig>> asyncList;

  const _LlmStep({
    required this.onSkip,
    required this.onBack,
    required this.onNext,
    required this.asyncList,
    required this.onAdd,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final first = asyncList.maybeWhen(
        data: (l) => l.isNotEmpty ? l.first : null, orElse: () => null);
    final l10n = AppLocalizations.of(context)!;
    return GuideFormScaffold(
      onSkip: onSkip,
      title: l10n.llmConfigurationTitle,
      subtitle: l10n.llmConfigurationSubtitle,
      headerIcon: Icons.auto_awesome,
      footer: GuideBottomNav(
        backLabel: l10n.guideBackLabel,
        nextLabel: l10n.guideNextStepLabel,
        onBack: onBack,
        onNext: onNext,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (first != null)
            _GuideConfigCard(
              title: l10n.llmProviderTitle,
              subtitle: '${first.provider.label} · ${first.name}',
              configured: true,
              onTap: () => onEdit(first),
            ),
          const SizedBox(height: 12),
          _GuideAddButton(label: l10n.addConfiguration, onTap: onAdd),
          const SizedBox(height: 24),
          Text(
            l10n.guideAddEditLaterHint,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppTypography.s14,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _SttStep extends StatelessWidget {
  final VoidCallback onSkip;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final Future<void> Function() onAdd;
  final Future<void> Function(SttConfig existing) onEdit;
  final AsyncValue<List<SttConfig>> asyncList;

  const _SttStep({
    required this.onSkip,
    required this.onBack,
    required this.onNext,
    required this.asyncList,
    required this.onAdd,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final first = asyncList.maybeWhen(
        data: (l) => l.isNotEmpty ? l.first : null, orElse: () => null);
    final l10n = AppLocalizations.of(context)!;
    return GuideFormScaffold(
      onSkip: onSkip,
      title: l10n.sttConfigurationTitle,
      subtitle: l10n.sttConfigurationSubtitle,
      headerIcon: Icons.mic_none,
      footer: GuideBottomNav(
        backLabel: l10n.guideBackLabel,
        nextLabel: l10n.guideNextStepLabel,
        onBack: onBack,
        onNext: onNext,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (first != null)
            _GuideConfigCard(
              title: l10n.sttProviderTitle,
              subtitle: '${first.provider.label} · ${first.name}',
              configured: true,
              onTap: () => onEdit(first),
            ),
          const SizedBox(height: 32),
          _GuideAddButton(label: l10n.addConfiguration, onTap: onAdd),
          const SizedBox(height: 24),
          Text(
            l10n.guideAddEditLaterHint,
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppTypography.s14,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _GuideAddButton extends StatelessWidget {
  final String label;
  final Future<void> Function() onTap;
  const _GuideAddButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: () async => onTap(),
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surfaceMuted,
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.borderLight),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.r12)),
        ),
        icon: const Icon(Icons.add, size: 22),
        label: Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
      ),
    );
  }
}

class _GuideConfigCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool configured;
  final VoidCallback? onTap;

  const _GuideConfigCard({
    required this.title,
    required this.subtitle,
    required this.configured,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadii.r12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.surfaceSubtle,
                borderRadius: BorderRadius.circular(AppRadii.r12),
              ),
              child: Icon(configured ? Icons.check_rounded : Icons.settings,
                  color: AppColors.textPrimary, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                        fontSize: AppTypography.s14),
                  ),
                ],
              ),
            ),
            if (configured)
              const Icon(Icons.chevron_right,
                  color: AppColors.textSecondary, size: 22),
          ],
        ),
      ),
    );
  }
}

class _DoneStep extends StatelessWidget {
  final String sttProviderLabel;
  final String llmProviderLabel;
  final VoidCallback onFinish;

  const _DoneStep({
    required this.sttProviderLabel,
    required this.llmProviderLabel,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minScrollableHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
                ? constraints.maxHeight
                : MediaQuery.of(context).size.height;
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minScrollableHeight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 34),
                Text(
                  AppLocalizations.of(context)!.guideAllSetTitle,
                  style: const TextStyle(
                      fontSize: AppTypography.s22,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary),
                ),
                const SizedBox(height: 10),
                Text(
                  AppLocalizations.of(context)!.guideAllSetSubtitle,
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppTypography.s14,
                      fontWeight: FontWeight.w500),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 22),
                _ProviderSummaryCard(
                  leading: Icons.mic_none,
                  title: AppLocalizations.of(context)!.guideSttProviderLabel,
                  value: sttProviderLabel,
                ),
                const SizedBox(height: 14),
                _ProviderSummaryCard(
                  leading: Icons.auto_awesome,
                  title: AppLocalizations.of(context)!.guideLlmProviderLabel,
                  value: llmProviderLabel,
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceMuted,
                    borderRadius: BorderRadius.circular(AppRadii.r12),
                    border: Border.all(color: AppColors.borderLight),
                  ),
                  child: Text(
                    AppLocalizations.of(context)!.guideUpdateLaterHint,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                        height: 1.35),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 28),
                GuideDarkButton(
                    label: AppLocalizations.of(context)!.finishSetup,
                    onTap: onFinish),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GuideServiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _GuideServiceCard(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadii.r12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.surfaceSubtle,
              borderRadius: BorderRadius.circular(AppRadii.r12),
            ),
            child: Icon(icon, color: AppColors.textPrimary, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                        fontSize: AppTypography.s14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderSummaryCard extends StatelessWidget {
  final IconData leading;
  final String title;
  final String value;

  const _ProviderSummaryCard({
    required this.leading,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.r12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(AppRadii.r12),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Icon(leading, color: AppColors.textSecondary, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontWeight: FontWeight.w500,
                        fontSize: AppTypography.s14)),
                const SizedBox(height: 3),
                Text(value,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                        fontSize: AppTypography.s16)),
              ],
            ),
          ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(AppRadii.r14),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: const Icon(Icons.check_rounded,
                size: 18, color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}
