import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/auth_repository.dart';
import 'auth_providers.dart';
import 'widgets/app_text_field.dart';
import 'widgets/auth_brand_header.dart';

class ForgotPasswordPage extends ConsumerStatefulWidget {
  final String? presetEmail;
  const ForgotPasswordPage({super.key, this.presetEmail});

  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  Timer? _timer;
  int _secondsLeft = 0;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final preset = (widget.presetEmail ?? '').trim();
    if (preset.isNotEmpty) _email.text = preset;
    _code.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _secondsLeft = seconds);
    var s = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      s--;
      if (s <= 0) {
        t.cancel();
        _timer = null;
        if (mounted) setState(() => _secondsLeft = 0);
      } else {
        if (mounted) setState(() => _secondsLeft = s);
      }
    });
  }

  Future<void> _sendCode() async {
    final l10n = AppLocalizations.of(context)!;
    final email = _email.text.trim();
    if (!_isValidEmail(email)) {
      setState(() => _error = l10n.invalidEmail);
      return;
    }
    if (_sending || _secondsLeft > 0) return;
    setState(() {
      _sending = true;
      _error = null;
      _code.clear();
    });
    try {
      await ref.read(authRepositoryProvider).sendEmailCode(
            email: email,
            scene: EmailCodeScene.resetPassword,
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
    final l10n = AppLocalizations.of(context)!;
    final email = _email.text.trim();
    final code = _code.text.trim();
    if (!_isValidEmail(email)) {
      setState(() => _error = l10n.invalidEmail);
      return;
    }
    if (!_isValidCode(code)) {
      setState(() => _error = l10n.invalidCode6);
      return;
    }

    try {
      if (!mounted) return;
      // Next screen sets new password: reset API validates code
      context.go('/set-password?purpose=reset&email=${Uri.encodeComponent(email)}&code=${Uri.encodeComponent(code)}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is ServerException ? serverErrorMessage(context, e) : e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final code = _code.text.trim();
    final hasValidCode = _isValidCode(code);

    final String primaryLabel;
    VoidCallback? primaryOnPressed;
    if (hasValidCode) {
      primaryLabel = l10n.continueAction;
      primaryOnPressed = _continue;
    } else if (_sending) {
      primaryLabel = l10n.sendCodeLoading;
      primaryOnPressed = null;
    } else if (_secondsLeft > 0) {
      primaryLabel = l10n.resendInSeconds(_secondsLeft);
      primaryOnPressed = null;
    } else {
      primaryLabel = l10n.sendCode;
      primaryOnPressed = _sendCode;
    }

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => context.pop(),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    foregroundColor: AppColors.textSecondary,
                    textStyle: const TextStyle(fontSize: AppTypography.s16, fontWeight: FontWeight.w500),
                  ),
                  child: Text(l10n.cancel),
                ),
              ),
              const SizedBox(height: 12),
              const Center(child: AuthBrandHeader()),
              const SizedBox(height: 26),
              Text(
                l10n.forgotPasswordTitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.forgotPasswordDesc,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 26),
              AppTextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                hintText: l10n.emailExample,
              ),
              const SizedBox(height: 14),
              AppTextField(
                controller: _code,
                keyboardType: TextInputType.number,
                hintText: l10n.verificationCode,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(color: cs.error, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 22),
              AppPrimaryPillButton(
                label: primaryLabel,
                height: 48,
                onPressed: primaryOnPressed,
                textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppTypography.s16),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isValidEmail(String email) => email.contains('@') && email.contains('.') && email.length <= 200;
  static bool _isValidCode(String code) => RegExp(r'^\d{6}$').hasMatch(code);
}

