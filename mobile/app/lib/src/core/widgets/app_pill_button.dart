import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_radii.dart';
import '../../app/theme/app_typography.dart';
class AppPrimaryPillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final double height;
  final TextStyle? textStyle;
  final Widget? trailing;

  const AppPrimaryPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 48,
    this.textStyle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.pillRadius),
          textStyle: textStyle ?? const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
        ),
        child: trailing == null
            ? FittedBox(fit: BoxFit.scaleDown, child: Text(label))
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
                  const SizedBox(width: 10),
                  trailing!,
                ],
              ),
      ),
    );
  }
}

class AppOutlinedPillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final double height;
  final Color? foregroundColor;
  final Color? borderColor;
  final Color? backgroundColor;
  final TextStyle? textStyle;
  final Widget? leading;
  final Widget? trailing;
  /// When false button does not expand width, suitable for use in Row.
  final bool fullWidth;

  const AppOutlinedPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 48,
    this.foregroundColor,
    this.borderColor,
    this.backgroundColor,
    this.textStyle,
    this.leading,
    this.trailing,
    this.fullWidth = true,
  });

  @override
  Widget build(BuildContext context) {
    final fg = foregroundColor ?? AppColors.textSecondary;
    final bc = borderColor ?? AppColors.border;
    final bg = backgroundColor ?? AppColors.surface;
    final hasLeading = leading != null;
    final hasTrailing = trailing != null;
    Widget child = hasLeading || hasTrailing
        ? Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasLeading) ...[leading!, const SizedBox(width: 10)],
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (hasTrailing) ...[const SizedBox(width: 10), trailing!],
            ],
          )
        : FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
    final btn = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        side: BorderSide(color: bc),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.pillRadius),
        textStyle: textStyle ??
            const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: AppTypography.s16,
            ),
        minimumSize: Size(fullWidth ? double.infinity : 0, height),
        fixedSize: fullWidth ? null : Size.fromHeight(height),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: child,
    );
    if (fullWidth) {
      return SizedBox(width: double.infinity, height: height, child: btn);
    }
    return SizedBox(height: height, child: btn);
  }
}

/// Shared component: black primary button (e.g. bottom "Add New Configuration")
class AppBlackPillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final double height;
  final Widget? leading;
  final TextStyle? textStyle;

  const AppBlackPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 48,
    this.leading,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.buttonPrimaryBg,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.pillRadius),
          textStyle: textStyle ??
              const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s16,
              ),
          minimumSize: Size(double.infinity, height),
          fixedSize: Size.fromHeight(height),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: leading == null
            ? FittedBox(fit: BoxFit.scaleDown, child: Text(label))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  leading!,
                  const SizedBox(width: 14),
                  FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
                ],
              ),
      ),
    );
  }
}
