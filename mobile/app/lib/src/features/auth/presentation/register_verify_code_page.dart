import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/auth/auth_email_conflict.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/auth_repository.dart';
import 'auth_providers.dart';
import 'widgets/app_text_field.dart';

/// Where the user came from before the register OTP screen — used when
/// [GoRouter.canPop] is false (e.g. after popping back from set-password).
enum RegisterVerifyBackTarget {
  /// Login landing → verify (no [RegisterEmailPage] in stack).
  landing,
  /// Register email page → verify.
  registerEmail,
}

class RegisterVerifyCodePage extends ConsumerStatefulWidget {
  final String email;
  final RegisterVerifyBackTarget backTarget;
  const RegisterVerifyCodePage({
    super.key,
    required this.email,
    this.backTarget = RegisterVerifyBackTarget.landing,
  });

  @override
  ConsumerState<RegisterVerifyCodePage> createState() => _RegisterVerifyCodePageState();
}

class _RegisterVerifyCodePageState extends ConsumerState<RegisterVerifyCodePage> {
  final _code = TextEditingController();
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
    // Resend enabled on entry; first code sent from previous page
    _startCountdown(60);
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
            scene: EmailCodeScene.register,
          );
      if (!mounted) return;
      _startCountdown(60);
    } on ServerException catch (e) {
      if (!mounted) return;
      if (emailAlreadyRegisteredForAuthFlow(e)) {
        try {
          await ref.read(authRepositoryProvider).sendEmailCode(
                email: widget.email,
                scene: EmailCodeScene.login,
              );
        } catch (_) {}
        if (!mounted) return;
        context.go('/login/email?email=${Uri.encodeComponent(widget.email)}&code_sent=1');
        return;
      }
      setState(() => _error = serverErrorMessage(context, e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _continue() async {
    final code = _code.text.trim();
    if (!_isValidCode(code)) {
      setState(() => _error = AppLocalizations.of(context)!.invalidCode6);
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).verifyEmailCode(
            email: widget.email,
            code: code,
            scene: EmailCodeScene.register,
          );
      if (!mounted) return;
      // Push (not go) so "back" from set-password pops here and keeps the code
      // the user typed instead of rebuilding this screen.
      context.push(
        '/set-password?purpose=register&email=${Uri.encodeComponent(widget.email)}'
        '&registerCode=${Uri.encodeComponent(code)}'
        '&verifyEntry=${widget.backTarget == RegisterVerifyBackTarget.registerEmail ? 'register' : 'landing'}',
      );
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
      return;
    }
    final e = Uri.encodeComponent(widget.email);
    switch (widget.backTarget) {
      case RegisterVerifyBackTarget.registerEmail:
        router.go('/register?email=$e');
        return;
      case RegisterVerifyBackTarget.landing:
        router.go('/login?email=$e');
        return;
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
          // `onDrag` can interact badly with some OEM IMEs (focus loss / dropped keys).
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
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
                style: const TextStyle(fontSize: AppTypography.s26, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.enterVerificationCodeDesc,
                style: const TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 40),
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
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isValidCode(String code) => RegExp(r'^\d{6}$').hasMatch(code);
}

