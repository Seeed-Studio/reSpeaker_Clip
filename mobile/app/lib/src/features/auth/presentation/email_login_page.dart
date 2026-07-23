import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/server/api/user_api.dart';
import '../../../core/server/auth/auth_token_store.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/auth_repository.dart';
import 'auth_providers.dart';
import '../../ai_config/presentation/guide/ai_config_guide_helper.dart';
import '../../../core/l10n/app_localizations.dart';
import 'widgets/app_text_field.dart';

class EmailLoginPage extends ConsumerStatefulWidget {
  final String email;
  /// When `true`, [login_landing_page] / register flow already called
  /// `sendEmailCode(… login)` — show resend cooldown instead of the primary
  /// "Send code" action, matching [RegisterVerifyCodePage] behaviour.
  final bool codeAlreadySent;
  const EmailLoginPage({super.key, required this.email, this.codeAlreadySent = false});

  @override
  ConsumerState<EmailLoginPage> createState() => _EmailLoginPageState();
}

class _EmailLoginPageState extends ConsumerState<EmailLoginPage> {
  final TextEditingController _code = TextEditingController();
  final _secondsLeftN = ValueNotifier<int>(0);
  late final Listenable _footerListenable;
  Timer? _timer;
  bool _sending = false;
  bool _verifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _footerListenable = Listenable.merge([_code, _secondsLeftN]);
    // e.g. `/login/email?code_sent=1` — first code already sent; do not
    // duplicate the primary "Send code" action before cooldown (password-login entry
    // omits `code_sent` and must send manually).
    if (widget.codeAlreadySent) {
      _startCountdown(60);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _secondsLeftN.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    _secondsLeftN.value = seconds;
    var s = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      s--;
      if (s <= 0) {
        t.cancel();
        _timer = null;
        _secondsLeftN.value = 0;
      } else {
        _secondsLeftN.value = s;
      }
    });
  }

  Future<void> _sendCode() async {
    if (_sending || _secondsLeftN.value > 0) return;
    setState(() {
      _sending = true;
      _error = null;
      _code.clear();
    });
    try {
      await ref.read(authRepositoryProvider).sendEmailCode(
            email: widget.email,
            scene: EmailCodeScene.login,
          );
      if (!mounted) return;
      _startCountdown(60);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ServerException ? serverErrorMessage(context, e) : e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _continue() async {
    final code = _code.text.trim();
    if (!_isValidCode(code)) {
      final l10n = AppLocalizations.of(context)!;
      setState(() => _error = l10n.invalidCode6);
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final result = await ref.read(authRepositoryProvider).verifyEmailCode(
            email: widget.email,
            code: code,
            scene: EmailCodeScene.login,
          );
      if (result == null) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        throw ServerException(l10n.errorLoginFailed);
      }
      await AuthTokenStore.saveTokens(accessToken: result.token, refreshToken: result.refreshToken);
      await ref.read(userProfileProvider.notifier).setFromLoginAndRefresh(
            UserProfile.fromAuthAppUser(result.user),
          );
      ref.read(authSessionProvider.notifier).setLoggedIn(
            email: (result.user.email ?? widget.email).trim(),
            needsSetPassword: false,
          );
      if (!mounted) return;
      await AiConfigGuideHelper.navigateAfterAuthReady(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ServerException ? serverErrorMessage(context, e) : e.toString();
      });
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _goBack(BuildContext context) {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
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
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: () => _goBack(context),
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.enterVerificationCodeTitle,
                style: TextStyle(fontSize: AppTypography.s26, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.enterVerificationCodeDesc,
                style: TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 34),
              AppTextField(
                controller: _code,
                keyboardType: TextInputType.number,
                hintText: l10n.verificationCode,
                enableSuggestions: false,
                autocorrect: false,
                autofillHints: const [],
                onChanged: (_) {
                  if (_error != null && mounted) {
                    setState(() => _error = null);
                  }
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: cs.error, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 22),
              ListenableBuilder(
                key: ValueKey<String>('$_verifying|$_sending'),
                listenable: _footerListenable,
                builder: (context, _) {
                  final code = _code.text.trim();
                  final hasValidCode = _isValidCode(code);
                  final secondsLeft = _secondsLeftN.value;

                  final String primaryLabel;
                  VoidCallback? primaryOnPressed;
                  if (hasValidCode) {
                    primaryLabel = _verifying ? l10n.continueLoading : l10n.continueAction;
                    primaryOnPressed = _verifying ? null : _continue;
                  } else if (_sending) {
                    primaryLabel = l10n.sendCodeLoading;
                    primaryOnPressed = null;
                  } else if (secondsLeft > 0) {
                    primaryLabel = l10n.resendInSeconds(secondsLeft);
                    primaryOnPressed = null;
                  } else {
                    primaryLabel = l10n.sendCode;
                    primaryOnPressed = _sendCode;
                  }

                  return AppPrimaryPillButton(
                    label: primaryLabel,
                    height: 48,
                    onPressed: primaryOnPressed,
                    textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppTypography.s16),
                  );
                },
              ),
              const SizedBox(height: 64),
              Center(
                child: TextButton(
                  onPressed: () => context.push('/login/password?email=${Uri.encodeComponent(widget.email)}'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    textStyle: const TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500),
                  ),
                  child: Text(
                    l10n.loginWithPassword,
                    style: const TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isValidCode(String code) => RegExp(r'^\d{6}$').hasMatch(code);
}
