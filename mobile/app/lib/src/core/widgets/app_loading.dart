import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

class AppLoading extends StatefulWidget {
  final String? message;
  final double spinnerSize;
  final double strokeWidth;

  const AppLoading({
    super.key,
    this.message,
    this.spinnerSize = 28,
    this.strokeWidth = 2.6,
  });

  @override
  State<AppLoading> createState() => _AppLoadingState();
}

class _AppLoadingState extends State<AppLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _pulse(double t, {double phase = 0}) {
    return 0.5 + 0.5 * math.sin((t + phase) * 2 * math.pi);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.message?.trim() ?? '';
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final glowScale = 0.94 + _pulse(t) * 0.12;
        final glowAlpha = 0.08 + _pulse(t, phase: 0.15) * 0.10;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 88,
              height: 88,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: glowScale,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            AppColors.brandPrimary.withValues(alpha: glowAlpha),
                      ),
                    ),
                  ),
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.surfacePrimarySoft,
                          AppColors.surface,
                        ],
                      ),
                      border: Border.all(
                        color: AppColors.brandPrimary.withValues(alpha: 0.18),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: widget.spinnerSize + 8,
                    height: widget.spinnerSize + 8,
                    child: CircularProgressIndicator(
                      strokeWidth: widget.strokeWidth,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.brandPrimary,
                      ),
                      backgroundColor:
                          AppColors.brandPrimary.withValues(alpha: 0.16),
                    ),
                  ),
                ],
              ),
            ),
            if (text.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: AppTypography.s16,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
