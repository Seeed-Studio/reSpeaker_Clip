import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/feedback/feedback_workflow_provider.dart';
import '../../../core/server/feedback/feedback_workflow_values.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_providers.dart';
import '../../../core/legal/open_legal_url.dart';
import '../../../core/support/support_urls.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../../core/widgets/app_input_box.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../../core/widgets/app_toasts.dart';
import '../../settings/data/app_info_provider.dart';
import 'settings_widgets.dart';

class HelpFeedbackPage extends ConsumerStatefulWidget {
  const HelpFeedbackPage({super.key});

  @override
  ConsumerState<HelpFeedbackPage> createState() => _HelpFeedbackPageState();
}

class _HelpFeedbackPageState extends ConsumerState<HelpFeedbackPage> {
  final _ctrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _userId() {
    final profile = ref.read(userProfileProvider);
    if (profile != null && profile.id > 0) {
      return 'respeaker-user-${profile.id}';
    }
    return 'respeaker-guest';
  }

  String _notifyMode() {
    final env = ref.read(appEnvProvider).valueOrNull ?? kDefaultAppEnv;
    return feedbackWorkflowModeFromAppEnv(env);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final description = _ctrl.text.trim();
    if (description.isEmpty) {
      AppToasts.showWarning(context, message: l10n.feedbackDescriptionRequired);
      return;
    }

    final api = ref.read(feedbackWorkflowApiProvider);
    if (!api.isConfigured) {
      AppToasts.showError(
        context,
        message:
            '${l10n.feedbackSubmitFailed}: API_KEY not configured (see docs/homepage-test)',
      );
      return;
    }

    final version = await ref.read(appVersionProvider.future);
    if (!mounted) return;
    final body = '$description\n\n---\nApp: SenseCraft Voice App v$version';

    setState(() => _submitting = true);
    final loading = AppDialogs.showLoading(
      context,
      message: l10n.processing,
      barrierDismissible: false,
    );
    try {
      await api.submitVoiceFeedback(
        userId: _userId(),
        description: body,
        mode: _notifyMode(),
      );
      if (!mounted) return;
      AppToasts.showSuccess(context, message: l10n.feedbackSubmitSuccess);
      _ctrl.clear();
    } catch (e) {
      if (!mounted) return;
      AppToasts.showError(
        context,
        message: serverErrorDialogMessage(context, e),
      );
    } finally {
      loading.close();
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.helpFeedback),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SettingsSectionLabel(l10n.helpCenter),
          SettingsCard(
            children: [
              SettingsTile(
                title: l10n.productWiki,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.menu_book_outlined,
                        color: AppColors.textSecondary),
                    SizedBox(width: 10),
                    Icon(Icons.chevron_right,
                        color: AppColors.textPlaceholder, size: 28),
                  ],
                ),
                onTap: () =>
                    openLegalUrl(context, SupportUrls.productWiki),
              ),
              SettingsTile(
                title: l10n.contactUs,
                value: SupportUrls.contactEmail,
                onTap: () => openSupportEmail(context),
              ),
            ],
          ),
          SettingsSectionLabel(l10n.feedback),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: AppCard(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
              borderRadius: AppRadii.br18,
              borderColor: AppColors.borderStrong,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.feedbackPrompt,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: AppColors.textTertiary,
                          height: 1.4,
                          fontSize: AppTypography.s14,
                        ),
                  ),
                  const SizedBox(height: 14),
                  AppInputBox(
                    controller: _ctrl,
                    hintText: l10n.feedbackHint,
                    minLines: 4,
                    maxLines: 6,
                    fixedHeight: 120,
                    readOnly: _submitting,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 36),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: AppPrimaryPillButton(
              label: l10n.submitSuggestion,
              onPressed: _submitting ? null : _submit,
              height: 48,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s16,
              ),
              trailing: Icon(Icons.arrow_forward, color: primary),
            ),
          ),
        ],
      ),
    );
  }
}
