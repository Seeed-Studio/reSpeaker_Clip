import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';
import 'app_typography.dart';

class AppTheme {
  // Colors come from AppColors for a single source of truth
  static const Color brandPrimary = AppColors.brandPrimary;
  static const Color brandPrimaryTap = AppColors.brandPrimaryTap;
  static const Color textPrimary = AppColors.textPrimaryLegacy;
  static const Color textSecondary = AppColors.groupTitle;
  static const Color bgLight = Color(0xFFF7F9FA);
  static const Color borderLight = AppColors.borderLight;
  static const Color appBg = AppColors.appBackground;

  static ThemeData light() {
    final cs = ColorScheme.fromSeed(
      seedColor: AppColors.brandPrimary,
      brightness: Brightness.light,
      primary: AppColors.brandPrimary,
    ).copyWith(
      surface: AppColors.surface,
    );
    return ThemeData(
      fontFamily: 'Roboto',
      colorScheme: cs,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.appBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.appBackground,
        foregroundColor: AppColors.textPrimaryLegacy,
        titleTextStyle: GoogleFonts.roboto(
          fontSize: AppTypography.s18,
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimaryLegacy,
        ),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: AppColors.brandPrimary,
          foregroundColor: Colors.white,
          elevation: 0,
          textStyle: GoogleFonts.roboto(fontSize: AppTypography.s16, fontWeight: FontWeight.w500),
        ).copyWith(
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return AppColors.brandPrimaryTap;
            }
            return null;
          }),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: const BorderSide(color: AppColors.borderDark, width: 1),
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.textPrimaryLegacy,
          elevation: 0,
          textStyle: GoogleFonts.roboto(fontSize: AppTypography.s16, fontWeight: FontWeight.w500),
        ).copyWith(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected) || states.contains(WidgetState.pressed)) {
              return const BorderSide(color: AppColors.brandPrimary, width: 1.5);
            }
            return const BorderSide(color: AppColors.borderDark, width: 1);
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return AppColors.brandPrimary.withValues(alpha: 0.1);
            }
            return AppColors.surface;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return AppColors.brandPrimary;
            }
            return AppColors.textPrimaryLegacy;
          }),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceSubtle,
        isDense: false,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.brandPrimary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        constraints: const BoxConstraints(minHeight: 48, maxHeight: 48),
        hintStyle: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.6)),
      ),
      textTheme: GoogleFonts.robotoTextTheme(const TextTheme(
        headlineLarge: TextStyle(fontSize: AppTypography.s24, fontWeight: FontWeight.w500, color: AppColors.textPrimaryLegacy, letterSpacing: -0.5),
        headlineMedium: TextStyle(fontSize: AppTypography.s22, fontWeight: FontWeight.w500, color: AppColors.textPrimaryLegacy),
        bodyLarge: TextStyle(fontSize: AppTypography.s16, fontWeight: FontWeight.w400, color: AppColors.textPrimaryLegacy),
        bodyMedium: TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w400, color: AppColors.textSecondary),
        bodySmall: TextStyle(fontSize: AppTypography.s12, fontWeight: FontWeight.w400, color: AppColors.textSecondary),
        labelLarge: TextStyle(fontSize: AppTypography.s12, fontWeight: FontWeight.w500, color: AppColors.textSecondary, letterSpacing: 2),
      )),
    );
  }

  static ThemeData dark() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.brandPrimary,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );
  }
}

