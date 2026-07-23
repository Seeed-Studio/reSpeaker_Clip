import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/app_pill_button.dart';
import 'auth_providers.dart';
import 'widgets/app_text_field.dart';
import '../../../app/theme/app_typography.dart';

class LinkIdentityPage extends ConsumerWidget {
  final String provider;

  const LinkIdentityPage({super.key, required this.provider});

  String _providerIconAsset(String provider) {
    final p = provider.trim().toLowerCase();
    switch (p) {
      case 'apple':
        return 'assets/png/apple.png';
      case 'google':
        return 'assets/png/google.png';
      case 'github':
      default:
        return 'assets/png/github.png';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final controller = TextEditingController();
    final iconAsset = _providerIconAsset(provider);

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
              IconButton(
                onPressed: () {
                  final router = GoRouter.of(context);
                  if (router.canPop()) {
                    router.pop();
                  } else {
                    router.go('/login');
                  }
                },
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(AppRadii.r12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(iconAsset, width: 24, height: 24, fit: BoxFit.contain),
                    const SizedBox(width: 8),
                    Text(
                      '${l10n.authenticatedVia} ${provider.toUpperCase()}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            letterSpacing: 1.5,
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w500,
                            fontSize: AppTypography.s14,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                l10n.linkYourIdentity,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s18,
                      color: AppTheme.textPrimary,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.linkIdentityDescription,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 24),
              AppTextField(
                controller: controller,
                labelText: l10n.email,
                keyboardType: TextInputType.emailAddress,
                hintText: l10n.emailHint,
                suffixIcon: const Icon(Icons.mail_outline),
              ),
              const SizedBox(height: 18),
              AppPrimaryPillButton(
                label: l10n.verifyAndContinue,
                onPressed: () {
                  final email = controller.text.trim();
                  if (!(email.contains('@') && email.contains('.'))) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.enterValidEmail)));
                    return;
                  }
                  ref.read(authSessionProvider.notifier).linkEmail(email);
                  context.go('/set-password');
                },
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F7F7),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFEDEDED), width: 1),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.shield_outlined, color: cs.primary, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.dataPrivacy,
                            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                  letterSpacing: 1.5,
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.w500,
                                  fontSize: AppTypography.s14,
                                ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            l10n.dataPrivacyDescription,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary, fontSize: AppTypography.s14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

