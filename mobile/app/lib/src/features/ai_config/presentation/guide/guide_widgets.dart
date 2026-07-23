import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/widgets/app_pill_button.dart';

enum GuideConnectionState { idle, success, failed }

class GuideFieldLabel extends StatelessWidget {
  final String text;
  const GuideFieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w500,
        fontSize: AppTypography.s12,
        letterSpacing: 1.2,
      ),
    );
  }
}

class GuideTextField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final String? hintText;

  const GuideTextField({
    super.key,
    required this.controller,
    required this.enabled,
    this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(
          color: AppColors.textPlaceholder,
          fontWeight: FontWeight.w500,
          fontSize: AppTypography.s14,
        ),
        isDense: true,
        filled: true,
        fillColor: AppColors.surfaceMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r12),
          borderSide: const BorderSide(color: AppColors.brandPrimary, width: 2),
        ),
      ),
      style: TextStyle(
        color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
        fontWeight: FontWeight.w500,
        fontSize: AppTypography.s14,
      ),
    );
  }
}

class GuideSelectField extends StatelessWidget {
  final String value;
  final VoidCallback onTap;

  const GuideSelectField({super.key, required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r12),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadii.r12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppTypography.s14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const Icon(Icons.expand_more, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class GuideConnectionButton extends StatelessWidget {
  final String label;
  final GuideConnectionState state;
  final bool enabled;
  final VoidCallback onTap;

  const GuideConnectionButton({
    super.key,
    required this.label,
    required this.state,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color borderColor() {
      if (!enabled) return AppColors.border;
      return switch (state) {
        GuideConnectionState.idle => AppColors.border,
        GuideConnectionState.success => Theme.of(context).colorScheme.primary,
        GuideConnectionState.failed => AppColors.danger,
      };
    }

    Color textColor() {
      if (!enabled) return AppColors.textPlaceholder;
      return switch (state) {
        GuideConnectionState.idle => AppColors.textTertiary,
        GuideConnectionState.success => Theme.of(context).colorScheme.primary,
        GuideConnectionState.failed => AppColors.danger,
      };
    }

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: borderColor()),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi, color: textColor()),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(color: textColor(), fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GuideBottomNav extends StatelessWidget {
  final String backLabel;
  final String nextLabel;
  final VoidCallback onBack;
  final VoidCallback onNext;

  const GuideBottomNav({
    super.key,
    required this.backLabel,
    required this.nextLabel,
    required this.onBack,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    const buttonHeight = 48.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 36 + bottomInset),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          AppOutlinedPillButton(
            label: backLabel,
            onPressed: onBack,
            height: buttonHeight,
            fullWidth: false,
            backgroundColor: AppColors.surface,
            borderColor: AppColors.borderLight,
            foregroundColor: AppColors.textSecondary,
            textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: buttonHeight,
            child: InkWell(
              onTap: onNext,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                decoration: BoxDecoration(
                  color: AppColors.buttonPrimaryBg,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Center(
                  child: Text(
                    nextLabel,
                    style: const TextStyle(
                      color: AppColors.surface,
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s14,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GuidePrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const GuidePrimaryButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.buttonPrimaryBg,
          foregroundColor: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.pill)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
        ),
        child: Text(label),
      ),
    );
  }
}

class GuideDarkButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const GuideDarkButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.buttonPrimaryBg,
          foregroundColor: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.pill)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label),
            const SizedBox(width: 10),
            const Icon(Icons.arrow_forward, size: 18),
          ],
        ),
      ),
    );
  }
}

class GuideFormScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData headerIcon;
  final VoidCallback onSkip;
  final Widget child;
  final Widget footer;

  const GuideFormScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    this.headerIcon = Icons.auto_awesome,
    required this.onSkip,
    required this.child,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: onSkip,
                child: Text(AppLocalizations.of(context)!.skip, style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceMuted,
                        borderRadius: BorderRadius.circular(AppRadii.r12),
                      ),
                      child: Icon(headerIcon, color: AppColors.textPrimary, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: AppTypography.s22,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500,
                              fontSize: AppTypography.s14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                child,
              ],
            ),
          ),
        ),
        footer,
      ],
    );
  }
}

