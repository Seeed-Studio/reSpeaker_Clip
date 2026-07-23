import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../core/legal/legal_urls.dart';
import '../../../core/legal/open_legal_url.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../app/router/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/server/api/user_api.dart';
import '../../../core/server/auth/auth_token_store.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/server/auth/auth_email_conflict.dart';
import '../data/auth_repository.dart';
import '../../../core/widgets/app_pill_button.dart';
import 'auth_providers.dart';
import '../../ai_config/presentation/guide/ai_config_guide_helper.dart';
import 'oauth_user_cancel.dart';
import 'third_party_login_provider.dart';
import 'widgets/auth_brand_header.dart';
import 'widgets/app_text_field.dart';
import 'widgets/auth_agreement_row.dart';

class LoginLandingPage extends ConsumerStatefulWidget {
  /// Optional email from query (e.g. after registration — user must request login OTP).
  final String? presetEmail;
  /// After change-email success: show a one-shot toast on this page.
  final bool showEmailChangedToast;

  const LoginLandingPage({
    super.key,
    this.presetEmail,
    this.showEmailChangedToast = false,
  });

  @override
  ConsumerState<LoginLandingPage> createState() => _LoginLandingPageState();
}

class _LoginLandingPageState extends ConsumerState<LoginLandingPage> {
  late final TextEditingController _email;
  bool _agreed = false;
  bool _loadingEmail = false;
  String? _emailError;

  @override
  void initState() {
    super.initState();
    _email = TextEditingController(text: _resolvePresetEmail());
    if (widget.showEmailChangedToast) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.emailChangedSuccess)),
        );
      });
    }
  }

  @override
  void didUpdateWidget(LoginLandingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = (widget.presetEmail ?? '').trim();
    if (next.isNotEmpty && next != _email.text.trim()) {
      _email.text = next;
    }
    if (widget.showEmailChangedToast && !oldWidget.showEmailChangedToast) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.emailChangedSuccess)),
        );
      });
    }
  }

  String _resolvePresetEmail() {
    final fromQuery = (widget.presetEmail ?? '').trim();
    if (fromQuery.isNotEmpty) {
      AuthSessionController.pendingLoginPresetEmail = null;
      return fromQuery;
    }
    return (AuthSessionController.consumePendingLoginPresetEmail() ?? '').trim();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  bool _ensureAgreed(BuildContext context) {
    if (_agreed) return true;
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.agreeToTermsRequired)),
    );
    return false;
  }

  void _showOAuthError(BuildContext context, Object e) {
    final l10n = AppLocalizations.of(context)!;
    if (e is ServerException) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(serverErrorMessage(context, e))),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.appleSignInError(e.toString()))),
    );
  }

  Future<void> _signInWithApple(BuildContext context) async {
    if (!_ensureAgreed(context)) return;

    final rootNav = Navigator.of(context, rootNavigator: true);
    var loadingClosed = false;

    void closeLoadingIfNeeded() {
      if (loadingClosed) return;
      if (rootNav.canPop()) {
        rootNav.pop();
      }
      loadingClosed = true;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final available = await SignInWithApple.isAvailable();
      if (!available) {
        if (!context.mounted) return;
        closeLoadingIfNeeded();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.appleSignInNotSupported)),
        );
        return;
      }

      // Email scope only: fullName is only sent once and may contain emoji that
      // the auth backend cannot store in a utf8 `name` column (MySQL 1366).
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
      );
      final idToken = (credential.identityToken ?? '').trim();
      final accessToken = credential.authorizationCode.trim();
      if (idToken.isEmpty || accessToken.isEmpty) {
        if (!context.mounted) return;
        closeLoadingIfNeeded();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.appleSignInNoToken)),
        );
        return;
      }

      final repo = ref.read(authRepositoryProvider);
      final result = await repo.appLogin(
        AuthAppLoginRequest(provider: 'apple', accessToken: accessToken, idToken: idToken),
      );
      await AuthTokenStore.saveTokens(accessToken: result.token, refreshToken: result.refreshToken);
      await ref.read(userProfileProvider.notifier).setFromLoginAndRefresh(
            UserProfile.fromAuthAppUser(result.user),
          );

      final email = (result.user.email ?? '').trim();
      if (!context.mounted) return;

      closeLoadingIfNeeded();
      ref.read(authSessionProvider.notifier).setLoggedIn(email: email, needsSetPassword: false);
      await AiConfigGuideHelper.navigateAfterAuthReadyRouter(ref.read(appRouterProvider));
    } on SignInWithAppleAuthorizationException catch (e) {
      if (!context.mounted) return;
      closeLoadingIfNeeded();
      if (e.code == AuthorizationErrorCode.canceled) return;
      final l10n = AppLocalizations.of(context)!;
      final msg = switch (e.code) {
        AuthorizationErrorCode.notHandled => l10n.appleSignInNotHandled,
        AuthorizationErrorCode.notInteractive => l10n.appleSignInNotInteractive,
        AuthorizationErrorCode.credentialExport => l10n.appleSignInCredentialExport,
        AuthorizationErrorCode.credentialImport => l10n.appleSignInCredentialImport,
        AuthorizationErrorCode.matchedExcludedCredential => l10n.appleSignInMatchedExcluded,
        AuthorizationErrorCode.failed => l10n.appleSignInFailed,
        AuthorizationErrorCode.invalidResponse => l10n.appleSignInInvalidResponse,
        AuthorizationErrorCode.unknown => l10n.appleSignInUnknown,
        AuthorizationErrorCode.canceled => l10n.appleSignInCanceled,
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!context.mounted) return;
      closeLoadingIfNeeded();
      if (isOAuthUserCancelled(e)) return;
      _showOAuthError(context, e);
    } finally {
      if (context.mounted) {
        closeLoadingIfNeeded();
      }
    }
  }

  Future<void> _continueWithEmail(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final router = GoRouter.of(context);
    final email = _email.text.trim();
    if (!_agreed) {
      setState(() => _emailError = l10n.agreeToTermsRequired);
      return;
    }
    if (!_isValidEmail(email)) {
      setState(() => _emailError = '请输入正确的邮箱');
      return;
    }

    setState(() {
      _loadingEmail = true;
      _emailError = null;
    });

    final repo = ref.read(authRepositoryProvider);
    try {
      // Temp: isRegistered API picks register vs login.
      // isRegistered() currently returns false to exercise register first.
      final registered = await repo.isRegistered(email: email);
      if (registered) {
        await repo.sendEmailCode(email: email, scene: EmailCodeScene.login);
        if (!mounted) return;
        router.push('/login/email?email=${Uri.encodeComponent(email)}&code_sent=1');
        return;
      }

      try {
        await repo.sendEmailCode(email: email, scene: EmailCodeScene.register);
        if (!mounted) return;
        router.push('/register/verify?email=${Uri.encodeComponent(email)}');
        return;
      } on ServerException catch (e) {
        if (emailAlreadyRegisteredForAuthFlow(e)) {
          if (!mounted) return;
          try {
            await repo.sendEmailCode(email: email, scene: EmailCodeScene.login);
          } catch (_) {
            // Still enter login screen; user can tap resend.
          }
          if (!mounted) return;
          router.push('/login/email?email=${Uri.encodeComponent(email)}&code_sent=1');
          return;
        }
        rethrow;
      }
    } on ServerException catch (e) {
      if (!mounted) return;
      setState(() => _emailError = serverErrorMessage(context, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _emailError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingEmail = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showThirdParty = ref.watch(showThirdPartyLoginProvider);
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bottomInset = MediaQuery.of(context).viewInsets.bottom;
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + bottomInset),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        const SizedBox(height: 44),
                        const AuthBrandHeader(),
                        const SizedBox(height: 54),
                        if (showThirdParty) ...[
                          Row(
                            children: [
                              Expanded(child: Divider(color: AppColors.borderLight, thickness: 1)),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Text(
                                  l10n.externalIdentity,
                                  style: const TextStyle(
                                    fontSize: AppTypography.s12,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.textSecondary,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                              Expanded(child: Divider(color: AppColors.borderLight, thickness: 1)),
                            ],
                          ),
                          const SizedBox(height: 24),
                          if (Platform.isIOS || Platform.isMacOS) ...[
                            _ThirdPartyButton(
                              label: l10n.continueWithApple,
                              iconAsset: 'assets/png/apple.png',
                              onTap: () => _signInWithApple(context),
                            ),
                            const SizedBox(height: 14),
                          ],
                          _ThirdPartyButton(
                            label: l10n.continueWithGoogle,
                            iconAsset: 'assets/png/google.png',
                            onTap: () {
                              if (!_ensureAgreed(context)) return;
                              context.go(
                                '/login/authorize?provider=google&agreed=1',
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                          _ThirdPartyButton(
                            label: l10n.continueWithGithub,
                            iconAsset: 'assets/png/github.png',
                            onTap: () {
                              if (!_ensureAgreed(context)) return;
                              context.go(
                                '/login/authorize?provider=github&agreed=1',
                              );
                            },
                          ),
                          const SizedBox(height: 40),
                          Row(
                            children: [
                              Expanded(child: Divider(color: AppColors.borderLight, thickness: 1)),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                child: Text(
                                  l10n.orWithEmail,
                                  style: const TextStyle(
                                    fontSize: AppTypography.s12,
                                    color: AppColors.textSecondary,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ),
                              Expanded(child: Divider(color: AppColors.borderLight, thickness: 1)),
                            ],
                          ),
                          const SizedBox(height: 18),
                        ],
                        AppTextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          hintText: l10n.emailHint,
                        ),
                        const SizedBox(height: 18),
                        AppPrimaryPillButton(
                          label: _loadingEmail ? l10n.continueLoading : l10n.continueAction,
                          height: 48,
                          onPressed: _loadingEmail ? null : () => _continueWithEmail(context),
                          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppTypography.s16),
                        ),
                        if (_emailError != null) ...[
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _emailError!,
                              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                        const Spacer(),
                        AuthAgreementRow(
                          value: _agreed,
                          onChanged: (v) => setState(() => _agreed = v),
                          prefixText: l10n.agreePrefixLanding,
                          link1Text: l10n.userAgreement,
                          onTapLink1: () =>
                              openLegalUrl(context, LegalUrls.userAgreement(context)),
                          middleText: l10n.and,
                          link2Text: l10n.privacyPolicy,
                          onTapLink2: () =>
                              openLegalUrl(context, LegalUrls.privacyPolicy(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static bool _isValidEmail(String email) => email.contains('@') && email.contains('.') && email.length <= 200;
}

class _ThirdPartyButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final String iconAsset;

  const _ThirdPartyButton({
    required this.label,
    required this.onTap,
    required this.iconAsset,
  });

  @override
  Widget build(BuildContext context) {
    return AppOutlinedPillButton(
      label: label,
      onPressed: onTap,
      height: 56,
      backgroundColor: AppColors.surface,
      borderColor: AppColors.borderLight,
      foregroundColor: AppColors.textPrimary,
      textStyle: const TextStyle(
        fontSize: AppTypography.s16,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      leading: Image.asset(
        iconAsset,
        width: 24,
        height: 24,
        fit: BoxFit.contain,
      ),
    );
  }
}

