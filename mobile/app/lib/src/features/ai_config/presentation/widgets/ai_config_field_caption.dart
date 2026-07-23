import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_typography.dart';

/// Muted helper line under an AI config field (model name, base URL, etc.).
class AiConfigFieldCaption extends StatelessWidget {
  const AiConfigFieldCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: AppTypography.s12,
          color: AppColors.textPlaceholder,
          height: 1.35,
        ),
      ),
    );
  }
}
