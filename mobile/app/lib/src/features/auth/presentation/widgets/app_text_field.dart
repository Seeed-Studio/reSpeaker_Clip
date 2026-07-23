import 'package:flutter/material.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';

/// Shared pill-shaped text field for auth.
///
/// Visual spec (auth screens):
/// - Pill: height 56, radius 20
/// - Light gray fill
/// - Optional ALL-CAPS label (e.g. NEW PASSWORD)
/// - Password visibility toggle
class AppTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final bool allowToggleObscure;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final int? maxLines;
  final int? maxLength;
  final bool enabled;
  /// OTP / code fields should disable suggestions and autocorrect to reduce IME churn.
  final bool enableSuggestions;
  final bool autocorrect;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;
  final double height;
  final double radius;
  final Color? fillColor;

  const AppTextField({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.allowToggleObscure = false,
    this.keyboardType,
    this.onChanged,
    this.validator,
    this.maxLines = 1,
    this.maxLength,
    this.enabled = true,
    this.enableSuggestions = true,
    this.autocorrect = true,
    this.autofillHints,
    this.focusNode,
    this.height = 56,
    this.radius = AppRadii.r12,
    this.fillColor,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _obscured = widget.obscureText;
  }

  @override
  void didUpdateWidget(covariant AppTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.obscureText != widget.obscureText) {
      _obscured = widget.obscureText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = widget.fillColor ?? AppColors.surfaceMuted;
    final borderRadius = BorderRadius.circular(widget.radius);

    final Widget? suffix = widget.allowToggleObscure
        ? IconButton(
            onPressed: widget.enabled
                ? () {
                    setState(() {
                      _obscured = !_obscured;
                    });
                  }
                : null,
            icon: Icon(
              _obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: AppColors.textTertiary,
            ),
          )
        : widget.suffixIcon;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.labelText != null) ...[
          Text(
            widget.labelText!.toUpperCase(),
            style: const TextStyle(
              fontSize: AppTypography.s12,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: widget.controller,
          obscureText: _obscured,
          keyboardType: widget.keyboardType,
          onChanged: widget.onChanged,
          maxLines: widget.maxLines,
          maxLength: widget.maxLength,
          enabled: widget.enabled,
          enableSuggestions: widget.enableSuggestions,
          autocorrect: widget.autocorrect,
          autofillHints: widget.autofillHints,
          focusNode: widget.focusNode,
          textAlignVertical: TextAlignVertical.center,
          style: const TextStyle(
            fontSize: AppTypography.s14,
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            hintText: widget.hintText,
            prefixIcon: widget.prefixIcon,
            suffixIcon: suffix,
            filled: true,
            fillColor: fill,
            isDense: false,
            border: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: const BorderSide(color: AppColors.brandPrimary, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: BorderSide(color: theme.colorScheme.error, width: 1),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: BorderSide(color: theme.colorScheme.error, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            constraints: BoxConstraints(minHeight: widget.height, maxHeight: widget.height),
            hintStyle: const TextStyle(
              fontSize: AppTypography.s14,
              fontWeight: FontWeight.w500,
              color: AppColors.textTertiary,
            ),
          ),
        ),
      ],
    );
  }
}
