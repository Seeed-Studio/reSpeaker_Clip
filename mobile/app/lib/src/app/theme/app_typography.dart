import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Design tokens: font sizes / weights / common text styles
///
/// Goals:
/// - Centralize inline `fontSize: 18/22/...` and `fontWeight: w700/...`
/// - Prefer `Theme.of(context).textTheme` + small extras on new screens
class AppTypography {
  AppTypography._();

  /// Font sizes (from existing textTheme + Guide/Search usage)
  static const double s10 = 10;
  static const double s12 = 12;
  static const double s14 = 14;
  static const double s16 = 16;
  static const double s18 = 18;
  static const double s22 = 22;
  static const double s24 = 24;
  static const double s26 = 26;

  /// Headings
  static const TextStyle h1 = TextStyle(
    fontSize: s26,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );

  static const TextStyle h2 = TextStyle(
    fontSize: s24,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );

  /// Body
  static const TextStyle body = TextStyle(
    fontSize: s16,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodyMuted = TextStyle(
    fontSize: s14,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: s12,
    fontWeight: FontWeight.w600,
    color: AppColors.textTertiary,
  );

  /// Uppercase label used in guide/auth-like pages
  static const TextStyle labelCaps = TextStyle(
    fontSize: s12,
    fontWeight: FontWeight.w600,
    color: AppColors.textPlaceholder,
    letterSpacing: 1.2,
  );
}

