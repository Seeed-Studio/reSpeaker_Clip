import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../auth/data/auth_repository.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../auth/presentation/widgets/app_text_field.dart';

class ChangeEmailPage extends ConsumerStatefulWidget {
  const ChangeEmailPage({super.key});

  @override
  ConsumerState<ChangeEmailPage> createState() => _ChangeEmailPageState();
}

class _ChangeEmailPageState extends ConsumerState<ChangeEmailPage> {
  final _newEmail = TextEditingController();
  final _code = TextEditingController();
  Timer? _timer;
  int _secondsLeft = 0;
  bool _sending = false;
  bool _saving = false;
  bool _verifyFailed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _newEmail.addListener(() {
      if (!mounted) return;
      setState(() {
        if (_verifyFailed) _verifyFailed = false;
      });
    });
    _code.addListener(() {
      if (!mounted) return;
      setState(() {
        if (_verifyFailed) _verifyFailed = false;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _newEmail.dispose();
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
    final nextEmail = _newEmail.text.trim();
    if (!_isValidEmail(nextEmail)) {
      setState(() => _error = l10n.invalidEmail);
      return;
    }
    if (_sending || _secondsLeft > 0) return;
    setState(() {
      _sending = true;
      _error = null;
      _verifyFailed = false;
      _code.clear();
    });
    try {
      // Change email: code goes to the *new* address
      await ref.read(authRepositoryProvider).sendEmailCode(
            email: nextEmail,
            scene: EmailCodeScene.changeEmail,
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

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final nextEmail = _newEmail.text.trim();
    final code = _code.text.trim();
    if (!_isValidEmail(nextEmail)) {
      setState(() => _error = l10n.invalidEmail);
      return;
    }
    if (!_isValidCode(code)) {
      setState(() => _error = l10n.invalidCode6);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).updateEmail(email: nextEmail, code: code);
      if (!mounted) return;
      ref.read(authSessionProvider.notifier).prepareLoginAfterEmailChange(nextEmail);
      try {
        await ref.read(authRepositoryProvider).logout();
      } catch (_) {
        // Best-effort server signOut; local session is cleared below regardless.
      }
      if (!mounted) return;
      await ref.read(authSessionProvider.notifier).logoutFully();
      if (!mounted) return;
      context.go(
        '/login?email=${Uri.encodeComponent(nextEmail)}&email_changed=1',
      );
    } catch (e) {
      if (!mounted) return;
      _timer?.cancel();
      _timer = null;
      setState(() {
        _error = e is ServerException ? serverErrorMessage(context, e) : e.toString();
        _verifyFailed = true;
        _secondsLeft = 0;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final code = _code.text.trim();
    final hasValidCode = _isValidCode(code);
    final newEmail = _newEmail.text.trim();
    final hasValidNewEmail = _isValidEmail(newEmail);

    final String primaryLabel;
    VoidCallback? primaryOnPressed;
    if (hasValidCode && hasValidNewEmail && !_verifyFailed) {
      primaryLabel = _saving ? l10n.saving2 : l10n.save;
      primaryOnPressed = _saving ? null : _save;
    } else if (hasValidCode && hasValidNewEmail && _verifyFailed) {
      if (_sending) {
        primaryLabel = l10n.sendCodeLoading;
        primaryOnPressed = null;
      } else {
        primaryLabel = l10n.sendCode;
        primaryOnPressed = _sendCode;
      }
    } else if (_sending) {
      primaryLabel = l10n.sendCodeLoading;
      primaryOnPressed = null;
    } else if (_secondsLeft > 0) {
      primaryLabel = l10n.resendInSeconds(_secondsLeft);
      primaryOnPressed = null;
    } else {
      primaryLabel = l10n.sendCode;
      primaryOnPressed = hasValidNewEmail ? _sendCode : null;
    }

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(l10n.changeEmail),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.emailAddress,
                style: TextStyle(fontSize: AppTypography.s22, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 10),
              Text(
                l10n.emailAddressDesc,
                style: TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 24),
              AppTextField(
                controller: _newEmail,
                keyboardType: TextInputType.emailAddress,
                hintText: l10n.emailAddress,
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
              const SizedBox(height: 48),
              AppPrimaryPillButton(
                label: primaryLabel,
                height: 56,
                onPressed: primaryOnPressed,
                textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: AppTypography.s16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isValidEmail(String email) => email.contains('@') && email.contains('.') && email.length <= 200;
  static bool _isValidCode(String code) => RegExp(r'^\d{6}$').hasMatch(code);
}

