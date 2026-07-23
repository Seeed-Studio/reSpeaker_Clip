import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';
import 'app_pill_button.dart';

class AppSheetActionButtons extends StatelessWidget {
  final String secondaryText;
  final FutureOr<void> Function() onSecondary;
  final String primaryText;
  final FutureOr<void> Function() onPrimary;
  final bool primaryEnabled;
  final bool secondaryEnabled;
  final double height;
  final bool compact;

  const AppSheetActionButtons({
    super.key,
    required this.secondaryText,
    required this.onSecondary,
    required this.primaryText,
    required this.onPrimary,
    this.primaryEnabled = true,
    this.secondaryEnabled = true,
    this.height = 48,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final h = height;
    final gap = 24.0;

    const primaryTextStyle = TextStyle(
      fontWeight: FontWeight.w500,
      fontSize: AppTypography.s16,
    );
    const secondaryTextStyle = TextStyle(
      fontWeight: FontWeight.w500,
      fontSize: AppTypography.s14,
    );
    final secondary = AppOutlinedPillButton(
      label: secondaryText,
      onPressed: secondaryEnabled ? () async => onSecondary() : null,
      height: h,
      fullWidth: !compact,
      foregroundColor: AppColors.textPrimary,
      borderColor: AppColors.borderLight,
      textStyle: secondaryTextStyle,
    );
    final primary = AppBlackPillButton(
      label: primaryText,
      onPressed: primaryEnabled ? () async => onPrimary() : null,
      height: h,
      textStyle: primaryTextStyle,
    );

    if (compact) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          secondary,
          SizedBox(width: gap),
          SizedBox(width: 100, height: h, child: primary),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: secondary),
        SizedBox(width: gap),
        Expanded(child: primary),
      ],
    );
  }
}

