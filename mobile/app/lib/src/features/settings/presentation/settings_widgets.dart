import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/widgets/app_section_label.dart';

class SettingsSectionLabel extends StatelessWidget {
  final String text;
  const SettingsSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return AppSectionLabel(text);
  }
}

class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const SettingsCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ClipRRect(
        borderRadius: AppRadii.br18,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadii.br18,
            border: Border.all(color: AppColors.surface),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withValues(alpha: 0.5),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          
          // Material wraps InkWell splash and clips to radius so long-press does not show a gray box edge.
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(height: 1, thickness: 1, color: AppColors.border),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  final String title;
  final String? value;
  final VoidCallback? onTap;
  final bool danger;
  final Widget? trailing;

  const SettingsTile({
    super.key,
    required this.title,
    this.value,
    this.onTap,
    this.danger = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          // fontWeight: FontWeight.w500,
          fontSize: AppTypography.s14,
          color: danger ? AppColors.danger : AppColors.textPrimary,
        );

    final valueWidget = value == null
        ? null
        : Text(
            value!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textTertiary),
          );

    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal:12, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(title, style: titleStyle)),
          if (trailing != null) ...[
            trailing!,
          ] else ...[
            if (valueWidget != null) ...[
              valueWidget,
              const SizedBox(width: 10),
            ],
            const Icon(Icons.chevron_right, color: AppColors.textPlaceholder,size: 24),
          ],
        ],
      ),
    );

    if (onTap == null) return child;
    return InkWell(onTap: onTap, child: child);
  }
}

class SettingsSwitchTile extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w500,
          fontSize: AppTypography.s14,
          color: AppColors.textPrimary,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      child: Row(
        children: [
          Expanded(child: Text(title, style: titleStyle)),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeColor: Theme.of(context).colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

class SettingsPillAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const SettingsPillAction({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.pillRadius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfacePrimarySoft,
          borderRadius: AppRadii.pillRadius,
          border: Border.all(color: primary.withValues(alpha: 0.25)),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: primary, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

