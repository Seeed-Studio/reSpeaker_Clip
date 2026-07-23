import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/server/auth/auth_token_store.dart';
import '../../../core/server/api/user_api.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import 'auth_providers.dart';
import 'widgets/app_text_field.dart';
import '../../ai_config/presentation/guide/ai_config_guide_helper.dart';

class SetPasswordPage extends ConsumerStatefulWidget {
  final String? purpose; // e.g. 'register'
  final String? emailOverride;
  final String? resetCode; // for password reset
  /// SenseCraft / register flow: 6-digit code from email after `getEmailCode` (type=1).
  final String? registerCode;
  /// Carried from [RegisterVerifyCodePage] so fallback [GoRouter.go] restores `entry=`.
  final String? registerVerifyEntry;
  const SetPasswordPage({
    super.key,
    this.purpose,
    this.emailOverride,
    this.resetCode,
    this.registerCode,
    this.registerVerifyEntry,
  });

  @override
  ConsumerState<SetPasswordPage> createState() => _SetPasswordPageState();
}

class _SetPasswordPageState extends ConsumerState<SetPasswordPage> {
  final _pwd = TextEditingController();
  bool _saving = false;
  String? _error;

  /// Email registration uses `purpose=register` *and* `registerCode=…`. Treat
  /// any non-empty [SetPasswordPage.registerCode] as registration so a
  /// missing/ stripped `purpose` query (e.g. bad nav restore) cannot fall
  /// through to the legacy "skip" path that keeps the session logged in.
  bool get _isRegisterFlow =>
      (widget.purpose ?? '').trim() == 'register' ||
      ((widget.registerCode ?? '').trim().isNotEmpty);

  @override
  void dispose() {
    _pwd.dispose();
    super.dispose();
  }

  /// Align with backend [normalizeEmail]: trim + lowercase so Redis register-verified key matches.
  static String _normalizedEmail(String raw) => raw.trim().toLowerCase();

  void _goBack(BuildContext context, String normalizedEmail) {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }
    if (_isRegisterFlow) {
      final v = (widget.registerVerifyEntry ?? 'landing').trim();
      final entry = v == 'register' ? 'register' : 'landing';
      router.go(
        '/register/verify?email=${Uri.encodeComponent(normalizedEmail)}&entry=$entry',
      );
      return;
    }
    final purpose = (widget.purpose ?? '').trim();
    if (purpose == 'reset') {
      router.go(
          '/login/forgot-password?email=${Uri.encodeComponent(normalizedEmail)}');
      return;
    }
    router.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final session = ref.watch(authSessionProvider);
    final email = _normalizedEmail(widget.emailOverride ?? session.email ?? 'user@example.com');

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: _saving ? null : () => _goBack(context, email),
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.secureYourAccount,
                style: const TextStyle(
                  fontSize: AppTypography.s22,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.setPasswordForFuture,
                style: const TextStyle(
                  fontSize: AppTypography.s14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              AppTextField(
                controller: _pwd,
                obscureText: true,
                allowToggleObscure: true,
                labelText: l10n.newPassword,
                hintText: '••••••••',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.info_outline, size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.passwordRule,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: cs.error)),
              ],
              const SizedBox(height: 40),
              AppPrimaryPillButton(
                onPressed: _saving
                    ? null
                    : () async {
                        final router = GoRouter.of(context);
                        setState(() {
                          _error = null;
                        });
                        final p1 = _pwd.text.trim();
                        final ok = _isValidPassword(p1);
                        if (!ok) {
                          setState(() => _error = l10n.passwordInvalid);
                          return;
                        }

                        setState(() => _saving = true);
                        try {
                          if (_isRegisterFlow) {
                            final String rc = (widget.registerCode ?? '').trim();
                            if (rc.isEmpty) {
                              throw ServerException(
                                l10n.registerMissingVerificationCode,
                                messageKey: 'registerMissingVerificationCode',
                              );
                            }
                            final result = await ref.read(authRepositoryProvider).register(
                                  email: email,
                                  password: p1,
                                  username: email,
                                  registerCode: rc,
                                );
                            await AuthTokenStore.saveTokens(
                              accessToken: result.token,
                              refreshToken: result.refreshToken,
                            );
                            await ref.read(userProfileProvider.notifier).setFromLoginAndRefresh(
                                  UserProfile.fromAuthAppUser(result.user),
                                );
                            ref.read(authSessionProvider.notifier).setLoggedIn(
                                  email: _normalizedEmail(result.user.email ?? email),
                                  needsSetPassword: false,
                                );
                            if (!context.mounted) return;
                            await AiConfigGuideHelper.navigateAfterAuthReadyRouter(router);
                            return;
                          } else if ((widget.purpose ?? '').trim() == 'reset') {
                            final c = (widget.resetCode ?? '').trim();
                            if (c.isEmpty) {
                              throw ServerException(l10n.resetPasswordMissingCode);
                            }
                            await ref.read(authRepositoryProvider).resetPassword(
                                  email: email,
                                  code: c,
                                  newPassword: p1,
                                );
                            // After reset, send user to password login
                            ref.read(authSessionProvider.notifier).logout();
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.resetPasswordSuccess)));
                            router.go('/login/password?email=${Uri.encodeComponent(email)}');
                            return;
                          } else {
                            // Legacy third-party set-password when API missing — local placeholder only.
                            await ref.read(authRepositoryProvider).setPassword(email: email, password: p1);
                            ref.read(authSessionProvider.notifier).markPasswordDone();
                          }
                          if (!context.mounted) return;
                          await AiConfigGuideHelper.navigateAfterAuthReadyRouter(router);
                        } catch (e) {
                          if (!mounted) return;
                          final message = e is ServerException
                              ? serverErrorMessage(context, e)
                              : e.toString();
                          setState(() => _error = message);
                        } finally {
                          if (mounted) setState(() => _saving = false);
                        }
                      },
                label: _saving ? l10n.saving : l10n.setPassword,
                height: 48,
                textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isValidPassword(String p) {
    if (p.length < 8 || p.length > 16) return false;
    final hasLetter = RegExp(r'[A-Za-z]').hasMatch(p);
    final hasDigit = RegExp(r'\d').hasMatch(p);
    return hasLetter && hasDigit;
  }
}

