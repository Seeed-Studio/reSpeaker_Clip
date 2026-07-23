import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';

class AuthBrandHeader extends StatelessWidget {
  /// Brand name (e.g. SenseCraft Voice)
  final String title;
  final String? subtitle;
  final double iconSize;
  final double iconRadius;
  final Widget? icon;

  const AuthBrandHeader({
    super.key,
    this.title = 'SenseCraft Voice',
    this.subtitle,
    this.iconSize = 52,
    this.iconRadius = AppRadii.r14,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: iconSize,
          height: iconSize,
          decoration: BoxDecoration(
            color: AppColors.brandPrimary,
            borderRadius: BorderRadius.circular(iconRadius),
          ),
          child: Center(
            child: icon ?? const Icon(Icons.terminal, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: AppTypography.s22,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
            letterSpacing: -0.4,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            style: const TextStyle(
              fontSize: AppTypography.s12,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
              letterSpacing: 1.2,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

