import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

class AppSectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  final bool uppercase;

  const AppSectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(24, 22, 24, 10),
    this.uppercase = true,
  });

  @override
  Widget build(BuildContext context) {
    final label = uppercase ? text.toUpperCase() : text;
    return Padding(
      padding: padding,
      child: Text(
        label,
        style: AppTypography.labelCaps.copyWith(
          fontWeight: FontWeight.w500,
          fontSize: AppTypography.s12,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

