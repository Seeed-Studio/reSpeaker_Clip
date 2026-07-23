import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';

class AuthAgreementRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String prefixText;
  final String link1Text;
  final VoidCallback? onTapLink1;
  final String middleText;
  final String link2Text;
  final VoidCallback? onTapLink2;

  const AuthAgreementRow({
    super.key,
    required this.value,
    required this.onChanged,
    required this.prefixText,
    required this.link1Text,
    this.onTapLink1,
    required this.middleText,
    required this.link2Text,
    this.onTapLink2,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 26,
          height: 26,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            activeColor: cs.primary,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
                children: [
                  TextSpan(text: '$prefixText '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: GestureDetector(
                      onTap: onTapLink1,
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        link1Text,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.brandPrimary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                  TextSpan(text: ' $middleText '),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: GestureDetector(
                      onTap: onTapLink2,
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        link2Text,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.brandPrimary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

