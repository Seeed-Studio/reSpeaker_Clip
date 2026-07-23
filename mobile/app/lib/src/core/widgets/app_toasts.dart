import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_radii.dart';
import '../../app/theme/app_typography.dart';

enum AppToastType { success, warning, error, info }

class AppToasts {
  AppToasts._();

  static void dismiss(BuildContext context) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  static void showSuccess(BuildContext context, {required String message}) =>
      show(context, type: AppToastType.success, message: message);

  static void showWarning(BuildContext context, {required String message}) =>
      show(context, type: AppToastType.warning, message: message);

  static void showError(BuildContext context, {required String message}) =>
      show(context, type: AppToastType.error, message: message);

  static void showInfo(BuildContext context, {required String message}) =>
      show(context, type: AppToastType.info, message: message);

  static void show(
    BuildContext context, {
    required AppToastType type,
    required String message,
    Duration duration = const Duration(seconds: 2),
  }) {
    final (icon, color) = switch (type) {
      AppToastType.success => (Icons.check_circle, AppColors.brandPrimary),
      AppToastType.warning => (Icons.error_outline, const Color(0xFFF59E0B)),
      AppToastType.error => (Icons.cancel, AppColors.dangerStrong),
      AppToastType.info => (Icons.info_outline, AppColors.textSecondary),
    };

    dismiss(context);

    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: duration,
        elevation: 0,
        backgroundColor: Colors.transparent,
        behavior: SnackBarBehavior.floating,
        dismissDirection: DismissDirection.horizontal,
        margin: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          // Stay above bottom bar / keyboard
          16 + bottomPad + (bottomInset > 0 ? bottomInset : 56),
        ),
        padding: EdgeInsets.zero,
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.r18),
            border: Border.all(color: AppColors.borderLight),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppTypography.s14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

