import 'package:flutter/material.dart';

/// Design tokens: colors (sourced from real screen usage where possible).
///
/// Notes:
/// - Centralize existing hard-coded colors first, then replace inline `Color(0xFF...)` over time.
/// - Brand colors already live in `AppTheme`; migrate here for a single place.
class AppColors {
  AppColors._();

  /// Brand / Accent
  static const Color brandPrimary = Color(0xFF8FC31F);
  static const Color brandPrimaryTap = Color(0xFF72AB00);

  /// Surfaces
  /// App scaffold background: unified #F7F7F7
  static const Color appBackground = Color(0xFFF7F7F7);
  /// Sheets, buttons, overlays: white surfaces
  static const Color surface = Colors.white;
  static const Color surfaceSubtle = Color(0xFFF7F7F7);
  static const Color surfaceMuted = Color(0xFFF3F4F6);

  /// Borders
  static const Color border = Color(0xFFEDEDED);
  static const Color borderLight = Color(0xFFE6E6E6);
  static const Color borderStrong = Color(0xFFE5E7EB);
  /// Dark border (e.g. OutlinedButton stroke)
  static const Color borderDark = Color(0xFF333333);

  /// Text (neutral ramp)
  ///
  /// Most screens use `0xFF111827` (Tailwind slate/gray); `AppTheme.textPrimary=0xFF2D3238` also exists.
  /// Both kept for now; unify to one later.
  static const Color textPrimary = Color(0xFF111827);
  static const Color textPrimaryLegacy = Color(0xFF2D3238);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFF9CA3AF);
  static const Color textPlaceholder = Color(0xFFBDBDBD);
  /// Group/Section title (between item title and subtitle)
  static const Color groupTitle = Color(0xFF8E9BA5);

  /// Misc neutrals used across pages/widgets
  static const Color gray300 = Color(0xFFCBD5E1);
  static const Color gray200 = Color(0xFFE5E7EB);
  static const Color grayD1 = Color(0xFFD1D5DB);
  static const Color grayE0 = Color(0xFFE0E0E0);

  /// Semantic
  static const Color danger = Color(0xFFE25555);
  static const Color dangerStrong = Color(0xFFEF4444);
  static const Color success = brandPrimary;

  /// Buttons
  /// Primary actions (confirm/submit/export): black fill
  static const Color buttonPrimaryBg = Color(0xFF111111);

  /// Accent (used in trim UI)
  static const Color accentBlue = Color(0xFF3B82F6);
  static const Color surfacePrimarySoft = Color(0xFFF2F7EF);
}

