import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_radii.dart';
import '../../app/theme/app_typography.dart';

class AppInputBox extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final int? minLines;
  final int? maxLines;
  final double? fixedHeight;
  final bool readOnly;

  const AppInputBox({
    super.key,
    required this.controller,
    required this.hintText,
    this.minLines,
    this.maxLines,
    this.fixedHeight,
    this.readOnly = false,
  });

  InputDecoration _decoration() => InputDecoration(
        hintText: hintText,
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r18),
          borderSide: const BorderSide(color: AppColors.borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r18),
          borderSide: const BorderSide(color: AppColors.borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.r18),
          borderSide: const BorderSide(color: AppColors.borderLight, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      );

  TextStyle get _textStyle => const TextStyle(
        fontSize: AppTypography.s14,
        fontWeight: FontWeight.w400,
        color: AppColors.textPrimary,
      );

  @override
  Widget build(BuildContext context) {
    if (fixedHeight != null) {
      return SizedBox(
        height: fixedHeight,
        child: TextField(
          controller: controller,
          readOnly: readOnly,
          maxLines: null, 
          expands: true, 
          textAlignVertical: TextAlignVertical.top, 
          style: _textStyle,
          decoration: _decoration(),
        ),
      );
    }

    // Normal: single or multi-line per minLines/maxLines
    return TextField(
      controller: controller,
      readOnly: readOnly,
      minLines: minLines,
      maxLines: maxLines,
      style: _textStyle,
      decoration: _decoration(),
    );
  }
}

