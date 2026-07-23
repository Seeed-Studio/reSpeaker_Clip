import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/legal/legal_urls.dart';
import '../../../core/legal/open_legal_url.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/auth/auth_email_conflict.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/auth_repository.dart';
import 'auth_providers.dart';
import 'widgets/app_text_field.dart';
import 'widgets/auth_agreement_row.dart';
import 'widgets/auth_brand_header.dart';

class RegisterEmailPage extends ConsumerStatefulWidget {
  final String? presetEmail;
  const RegisterEmailPage({super.key, this.presetEmail});

  @override
  ConsumerState<RegisterEmailPage> createState() => _RegisterEmailPageState();
}

class _RegisterEmailPageState extends ConsumerState<RegisterEmailPage> {
  late final TextEditingController _email = TextEditingController(text: widget.presetEmail ?? '');
  bool _agreed = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final l10n = AppLocalizations.of(context)!;
    final email = _email.text.trim();
    if (!_agreed) {
      setState(() => _error = l10n.agreeToTermsRequired);
      return;
    }
    if (!_isValidEmail(email)) {
      setState(() => _error = l10n.invalidEmail);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).sendEmailCode(
            email: email,
            scene: EmailCodeScene.register,
          );
      if (!mounted) return;
      context.push('/register/verify?email=${Uri.encodeComponent(email)}&entry=register');
    } on ServerException catch (e) {
      if (!mounted) return;
      if (emailAlreadyRegisteredForAuthFlow(e)) {
        try {
          await ref.read(authRepositoryProvider).sendEmailCode(
                email: email,
                scene: EmailCodeScene.login,
              );
        } catch (_) {
          // User can resend on the login screen.
        }
        if (!mounted) return;
        context.push('/login/email?email=${Uri.encodeComponent(email)}&code_sent=1');
        return;
      }
      setState(() => _error = serverErrorMessage(context, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 44),
              const AuthBrandHeader(),
              const SizedBox(height: 34),
              Text(
                l10n.orWithEmail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: AppTypography.s12,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 18),
              AppTextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                hintText: l10n.emailHint,
              ),
              const SizedBox(height: 18),
              AuthAgreementRow(
                value: _agreed,
                onChanged: (v) => setState(() => _agreed = v),
                prefixText: '${l10n.agreeToTerms} ',
                link1Text: l10n.userAgreement,
                onTapLink1: () =>
                    openLegalUrl(context, LegalUrls.userAgreement(context)),
                middleText: ' ${l10n.and} ',
                link2Text: l10n.privacyPolicy,
                onTapLink2: () =>
                    openLegalUrl(context, LegalUrls.privacyPolicy(context)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: cs.error, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 18),
              AppPrimaryPillButton(
                label: _loading ? l10n.continueLoading : l10n.continueAction,
                height: 48,
                onPressed: _loading ? null : _continue,
                textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppTypography.s16),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isValidEmail(String email) =>
      email.contains('@') && email.contains('.') && email.length <= 200;
}

