import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_radii.dart';
class AppPillChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final double? maxWidth;
  final EdgeInsetsGeometry padding;
  final Color backgroundColor;
  final Color borderColor;
  final Color foregroundColor;
  final TextStyle? textStyle;

  const AppPillChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.maxWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.backgroundColor = AppColors.surfaceMuted,
    this.borderColor = AppColors.borderStrong,
    this.foregroundColor = AppColors.textSecondary,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final labelStyle =
        textStyle ?? TextStyle(color: foregroundColor, fontWeight: FontWeight.w500);

    Widget child = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: AppRadii.pillRadius,
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: foregroundColor),
            const SizedBox(width: 6),
          ],
          if (maxWidth != null)
            Flexible(
              child: Text(
                label,
                style: labelStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            Text(label, style: labelStyle),
        ],
      ),
    );

    if (maxWidth != null) {
      child = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: child,
      );
    }

    if (onTap == null) return child;

    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.pillRadius,
      child: child,
    );
  }
}

