import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/legal/legal_urls.dart';
import '../../../core/legal/open_legal_url.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/server/auth/auth_token_store.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/api/user_api.dart';
import '../../../core/server/server_error_codes.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import 'widgets/auth_brand_header.dart';
import 'widgets/app_text_field.dart';
import 'widgets/auth_agreement_row.dart';
import 'auth_providers.dart';
import '../../ai_config/presentation/guide/ai_config_guide_helper.dart';

class PasswordLoginPage extends ConsumerStatefulWidget {
  final String? presetEmail;
  const PasswordLoginPage({super.key, this.presetEmail});

  @override
  ConsumerState<PasswordLoginPage> createState() => _PasswordLoginPageState();
}

class _PasswordLoginPageState extends ConsumerState<PasswordLoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loggingIn = false;
  bool _agreed = false;
  String? _error;
  AppLocalizations? _l10n;

  @override
  void initState() {
    super.initState();
    final preset = (widget.presetEmail ?? '').trim();
    if (preset.isNotEmpty) {
      _emailController.text = preset;
    }
  }

  @override
  void didUpdateWidget(covariant PasswordLoginPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = (widget.presetEmail ?? '').trim();
    final old = (oldWidget.presetEmail ?? '').trim();
    if (next.isNotEmpty && next != old && _emailController.text.trim().isEmpty) {
      _emailController.text = next;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (_l10n == null) return;
    if (!_agreed) {
      setState(() {
        _error = _l10n!.fillEmailCodeAndAgree;
      });
      return;
    }
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error = _l10n!.emailOrPasswordEmpty;
      });
      return;
    }

    if (!email.contains('@') || !email.contains('.')) {
      setState(() {
        _error = _l10n!.invalidEmail;
      });
      return;
    }

    setState(() {
      _loggingIn = true;
      _error = null;
    });

    try {
      final result = await ref
          .read(authRepositoryProvider)
          .loginWithPassword(email: email, password: password);
      await AuthTokenStore.saveTokens(accessToken: result.token, refreshToken: result.refreshToken);
      await ref.read(userProfileProvider.notifier).setFromLoginAndRefresh(
            UserProfile.fromAuthAppUser(result.user),
          );
      final e = (result.user.email ?? email).trim();
      ref.read(authSessionProvider.notifier).setLoggedIn(email: e, needsSetPassword: false);
      if (!mounted) return;
      await AiConfigGuideHelper.navigateAfterAuthReady(context);
    } on ServerException catch (e) {
      if (!mounted) return;
      // 2001: user not found -> enter register flow
      if (e.bizCode == ServerErrorCodes.userNotFound) {
        context.go('/register?email=${Uri.encodeComponent(email)}');
        return;
      }
      setState(() => _error = serverErrorMessage(context, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    _l10n = l10n; // Store for use in async methods
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
              const SizedBox(height: 24),
              const Center(child: AuthBrandHeader()),
              const SizedBox(height: 26),
              Text(
                l10n.passwordLoginTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 26),
              AppTextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                hintText: l10n.emailHint,
              ),
              const SizedBox(height: 14),
              AppTextField(
                controller: _passwordController,
                obscureText: true,
                allowToggleObscure: true,
                hintText: l10n.password,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    final email = _emailController.text.trim();
                    final q = email.isEmpty ? '' : '?email=${Uri.encodeComponent(email)}';
                    context.push('/login/forgot-password$q');
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: AppColors.textSecondary,
                    textStyle: const TextStyle(fontSize: AppTypography.s12, fontWeight: FontWeight.w500),
                  ),
                  child: Text(l10n.forgotPasswordLink),
                ),
              ),
              const SizedBox(height: 10),
              AuthAgreementRow(
                value: _agreed,
                onChanged: (v) => setState(() => _agreed = v),
                prefixText: l10n.agreeToTerms,
                link1Text: l10n.userAgreement,
                onTapLink1: () =>
                    openLegalUrl(context, LegalUrls.userAgreement(context)),
                middleText: l10n.and,
                link2Text: l10n.privacyPolicy,
                onTapLink2: () =>
                    openLegalUrl(context, LegalUrls.privacyPolicy(context)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 22),
              AppPrimaryPillButton(
                label: _loggingIn ? l10n.signingIn : l10n.signIn,
                height: 48,
                onPressed: _loggingIn ? null : _handleLogin,
                textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: () {
                    final email = _emailController.text.trim();
                    final q = email.isEmpty ? '' : '?email=${Uri.encodeComponent(email)}';
                    context.push('/login/email$q');
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    textStyle: const TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500),
                  ),
                  child: Text(l10n.loginWithEmailCode),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
