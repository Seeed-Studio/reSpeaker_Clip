import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../ai_config/domain/ai_providers.dart';
import '../../ai_config/domain/llm_config.dart';
import '../../ai_config/domain/stt_config.dart';

const _consentPrefsKey = 'ai_data_sharing_consent_signatures_v1';
const _consentVersion = 'v1';

Future<bool> ensureAiDataSharingConsent({
  required BuildContext context,
  required AppLocalizations l10n,
  required bool sendsAudio,
  required bool sendsTranscript,
  SttConfig? stt,
  LlmConfig? llm,
}) async {
  if (!sendsAudio && !sendsTranscript) return true;

  const signature = _consentVersion;

  final prefs = await SharedPreferences.getInstance();
  final accepted = prefs.getStringList(_consentPrefsKey) ?? const <String>[];
  if (accepted.contains(signature)) return true;

  if (!context.mounted) return false;

  final recipients = <String>{
    l10n.aiDataSharingConsentSenseCraftCloud,
    if (sendsAudio && stt != null) stt.provider.labelFor(l10n),
    if (sendsTranscript && llm != null) llm.provider.labelFor(l10n),
    if ((sendsAudio && stt == null) || (sendsTranscript && llm == null))
      l10n.aiDataSharingConsentSelectedAiProviders,
  }.toList(growable: false);

  final ok = await _showAiDataSharingConsentDialog(
    context: context,
    l10n: l10n,
    recipients: recipients,
  );
  if (!ok) return false;

  final next = <String>{...accepted, signature}.toList(growable: false);
  await prefs.setStringList(_consentPrefsKey, next);
  return true;
}

Future<bool> _showAiDataSharingConsentDialog({
  required BuildContext context,
  required AppLocalizations l10n,
  required List<String> recipients,
}) async {
  var agreed = false;
  final res = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(l10n.aiDataSharingConsentTitle),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.aiDataSharingConsentShortMessage(
                      recipients.join(', '),
                    ),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppTypography.s14,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    value: agreed,
                    onChanged: (value) {
                      setState(() => agreed = value == true);
                    },
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      l10n.aiDataSharingConsentCheckbox,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: AppTypography.s14,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.aiDataSharingConsentDecline),
              ),
              FilledButton(
                onPressed:
                    agreed ? () => Navigator.of(dialogContext).pop(true) : null,
                child: Text(l10n.aiDataSharingConsentAllow),
              ),
            ],
          );
        },
      );
    },
  );
  return res == true;
}
