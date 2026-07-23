import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import '../l10n/app_localizations.dart';
import '../widgets/app_pill_button.dart';
import 'legal_urls.dart';
import 'open_legal_url.dart';
import 'privacy_policy_consent_store.dart';

/// Blocks the app until the user accepts the privacy policy on first launch.
///
/// **Android only** (Chinese app-store requirement). iOS / desktop skip this gate.
/// After the user taps Agree once, the choice is persisted and the page will not
/// show again until the app is reinstalled or app data is cleared.
///
/// Refuse exits the app (Agree / Refuse must both be explicit; returning past
/// the dialog without consent is not allowed).
class PrivacyPolicyGate extends StatefulWidget {
  final Widget child;

  const PrivacyPolicyGate({super.key, required this.child});

  /// Privacy consent is required on Android builds only.
  static bool get isRequired => !kIsWeb && Platform.isAndroid;

  @override
  State<PrivacyPolicyGate> createState() => _PrivacyPolicyGateState();
}

class _PrivacyPolicyGateState extends State<PrivacyPolicyGate> {
  late bool _accepted;

  @override
  void initState() {
    super.initState();
    _accepted =
        !PrivacyPolicyGate.isRequired || PrivacyPolicyConsentStore.hasAccepted;
  }

  Future<void> _onAgree() async {
    await PrivacyPolicyConsentStore.accept();
    if (!mounted) return;
    setState(() => _accepted = true);
  }

  void _onRefuse() {
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_accepted) return widget.child;

    final l10n = AppLocalizations.of(context);
    if (l10n == null) {
      return const ColoredBox(color: AppColors.appBackground);
    }

    return Material(
      color: AppColors.appBackground,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.privacyConsentTitle,
                style: const TextStyle(
                  fontSize: AppTypography.s18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: AppTypography.s14,
                        height: 1.45,
                        color: AppColors.textSecondary,
                      ),
                      children: [
                        TextSpan(text: l10n.privacyConsentBodyPrefix),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: GestureDetector(
                            onTap: () => openLegalUrl(
                              context,
                              LegalUrls.userAgreement(context),
                            ),
                            behavior: HitTestBehavior.opaque,
                            child: Text(
                              l10n.userAgreement,
                              style: const TextStyle(
                                fontSize: AppTypography.s14,
                                height: 1.45,
                                color: AppColors.brandPrimary,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                        TextSpan(text: ' ${l10n.and} '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: GestureDetector(
                            onTap: () => openLegalUrl(
                              context,
                              LegalUrls.privacyPolicy(context),
                            ),
                            behavior: HitTestBehavior.opaque,
                            child: Text(
                              l10n.privacyPolicy,
                              style: const TextStyle(
                                fontSize: AppTypography.s14,
                                height: 1.45,
                                color: AppColors.brandPrimary,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                        TextSpan(text: l10n.privacyConsentBodySuffix),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: AppOutlinedPillButton(
                      label: l10n.privacyConsentRefuse,
                      height: 48,
                      onPressed: _onRefuse,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppPrimaryPillButton(
                      label: l10n.privacyConsentAgree,
                      height: 48,
                      onPressed: _onAgree,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
