import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../../core/widgets/app_section_label.dart';
import '../../auth/presentation/auth_providers.dart';

class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  ConsumerState<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _oldPwd = TextEditingController();
  final _newPwd = TextEditingController();
  final _newPwd2 = TextEditingController();
  bool _showOld = false;
  bool _showNew1 = false;
  bool _showNew2 = false;
  bool _saving = false;
  bool _profileReady = false;
  String? _error;

  /// `getUserOrgInfo.has_pwd` — only hide old-password when explicitly false.
  bool get _needsOldPassword {
    final hasPwd = ref.watch(userProfileProvider)?.hasPwd;
    return hasPwd != false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureProfileLoaded());
  }

  Future<void> _ensureProfileLoaded() async {
    if (ref.read(userProfileProvider)?.hasPwd != null) {
      if (mounted) setState(() => _profileReady = true);
      return;
    }
    try {
      await ref.read(userProfileProvider.notifier).refresh();
    } catch (_) {
      // Fall back to requiring old password when profile refresh fails.
    }
    if (mounted) setState(() => _profileReady = true);
  }

  @override
  void dispose() {
    _oldPwd.dispose();
    _newPwd.dispose();
    _newPwd2.dispose();
    super.dispose();
  }

  InputDecoration _decoration(BuildContext context, {required String hint, Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.textPlaceholder),
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.r18),
        borderSide: BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.r18),
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.r18),
        borderSide: BorderSide(color: AppColors.brandPrimary),
      ),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final needsOld = _needsOldPassword;
    final oldP = needsOld ? _oldPwd.text.trim() : '';
    final newP = _newPwd.text.trim();
    final newP2 = _newPwd2.text.trim();
    if ((needsOld && oldP.isEmpty) || newP.isEmpty || newP2.isEmpty) {
      setState(() => _error = l10n.fillAllFields);
      return;
    }
    if (!_isValidPassword(newP)) {
      setState(() => _error = l10n.passwordInvalid);
      return;
    }
    if (newP != newP2) {
      setState(() => _error = l10n.passwordMismatch);
      return;
    }
    if (needsOld && oldP == newP) {
      setState(() => _error = l10n.newPasswordSameAsOld);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await ref.read(authRepositoryProvider).changePassword(
            oldPassword: oldP,
            newPassword: newP,
          );
      await ref.read(userProfileProvider.notifier).refresh();
      if (rootNav.canPop()) rootNav.pop();
      if (!mounted) return;
      final successText = needsOld ? l10n.passwordChangedSuccess : l10n.passwordSetSuccess;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successText)));
      context.pop();
    } on ServerException catch (e) {
      if (rootNav.canPop()) rootNav.pop();
      if (!mounted) return;
      setState(() => _error = serverErrorMessage(context, e));
    } catch (e) {
      if (rootNav.canPop()) rootNav.pop();
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!_profileReady) {
      final loadingTitle =
          ref.read(userProfileProvider)?.hasPwd == false ? l10n.setPassword : l10n.changePassword;
      return Scaffold(
        backgroundColor: AppColors.appBackground,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
          title: Text(loadingTitle),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final needsOld = _needsOldPassword;
    final pageTitle = needsOld ? l10n.changePassword : l10n.setPassword;
    final pwdLabel = needsOld ? l10n.newPassword : l10n.password;
    final confirmLabel = needsOld ? l10n.confirmNewPassword : l10n.confirmPasswordLabel;
    final confirmHint = needsOld ? l10n.repeatNewPasswordHint : l10n.repeatPasswordHint;
    final submitLabel = needsOld ? l10n.updatePassword : l10n.setPassword;
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        title: Text(pageTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: [
          if (needsOld) ...[
            AppSectionLabel(l10n.oldPassword, padding: const EdgeInsets.fromLTRB(0, 0, 0, 10)),
            TextField(
              controller: _oldPwd,
              obscureText: !_showOld,
              decoration: _decoration(
                context,
                hint: l10n.oldPasswordHint,
                suffix: IconButton(
                  onPressed: () => setState(() => _showOld = !_showOld),
                  icon: Icon(_showOld ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  color: AppColors.textPlaceholder,
                ),
              ),
            ),
            const SizedBox(height: 18),
          ],
          AppSectionLabel(pwdLabel, padding: const EdgeInsets.fromLTRB(0, 0, 0, 10)),
          TextField(
            controller: _newPwd,
            obscureText: !_showNew1,
            decoration: _decoration(
              context,
              hint: l10n.passwordHintSet,
              suffix: IconButton(
                onPressed: () => setState(() => _showNew1 = !_showNew1),
                icon: Icon(_showNew1 ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                color: AppColors.textPlaceholder,
              ),
            ),
          ),
          const SizedBox(height: 18),
          AppSectionLabel(confirmLabel, padding: const EdgeInsets.fromLTRB(0, 0, 0, 10)),
          TextField(
            controller: _newPwd2,
            obscureText: !_showNew2,
            decoration: _decoration(
              context,
              hint: confirmHint,
              suffix: IconButton(
                onPressed: () => setState(() => _showNew2 = !_showNew2),
                icon: Icon(_showNew2 ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                color: AppColors.textPlaceholder,
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 26),
          AppPrimaryPillButton(
            label: _saving ? l10n.updating : submitLabel,
            onPressed: _saving ? null : _save,
            height: 48,
            textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
          ),
        ],
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
