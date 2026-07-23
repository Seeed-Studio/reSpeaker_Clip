import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/widgets/app_overlay_tap_dismiss.dart';

Future<T?> showAiProviderPicker<T>({
  required BuildContext anchorContext,
  required List<T> items,
  required String Function(T v) labelOf,
  required T selected,
  String title = 'Provider',
}) async {
  final overlay = Overlay.of(anchorContext);
  final box = anchorContext.findRenderObject() as RenderBox?;
  final ovBox = overlay.context.findRenderObject() as RenderBox?;
  if (box == null || ovBox == null) return null;

  final topLeft = box.localToGlobal(Offset.zero, ancestor: ovBox);
  final size = box.size;
  final screenW = ovBox.size.width;
  final screenH = ovBox.size.height;
  final primary = Theme.of(anchorContext).colorScheme.primary;

  const margin = 24.0;
  const gap = 8.0;
  const maxH = 420.0;
  const minH = 220.0;

  final left = margin;
  final width = (screenW - margin * 2).clamp(240.0, screenW);

  final belowTop = topLeft.dy + size.height + gap;
  final availableBelow = screenH - margin - belowTop;
  final availableAbove = topLeft.dy - margin - gap;

  const itemH = 52.0;
  final desired = (56 + 1 + 12 + items.length * itemH).toDouble().clamp(minH, maxH);

  final placeBelow = availableBelow >= minH || availableBelow >= availableAbove;
  final height = (placeBelow ? availableBelow : availableAbove).clamp(160.0, desired);
  final top = placeBelow ? belowTop : (topLeft.dy - gap - height);

  final completer = Completer<T?>();
  late OverlayEntry entry;
  void dismiss([T? v]) {
    if (entry.mounted) entry.remove();
    if (!completer.isCompleted) completer.complete(v);
  }

  entry = OverlayEntry(
    builder: (ctx) {
      return AppOverlayTapDismiss(
        onDismiss: () => dismiss(null),
        child: Positioned(
          left: left,
          top: top,
          child: Material(
                color: Colors.transparent,
                elevation: 12,
                borderRadius: BorderRadius.circular(AppRadii.r18),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.r18),
                  child: Container(
                    width: width,
                    height: height,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadii.r18),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                          child: Stack(
                            children: [
                              Align(
                                alignment: Alignment.center,
                                child: Text(
                                  title,
                                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        fontSize: AppTypography.s18,
                                        color: AppColors.textPrimary,
                                      ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: InkWell(
                                  onTap: () => dismiss(null),
                                  borderRadius: BorderRadius.circular(999),
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceMuted,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: AppColors.borderLight),
                                    ),
                                    child: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1, thickness: 1, color: AppColors.borderLight),
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                            itemCount: items.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (c, i) {
                              final p = items[i];
                              final isSel = p == selected;
                              return InkWell(
                                onTap: () => dismiss(p),
                                borderRadius: BorderRadius.circular(AppRadii.r18),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                                  decoration: BoxDecoration(
                                    color: isSel ? primary.withValues(alpha: 0.08) : AppColors.surface,
                                    borderRadius: BorderRadius.circular(AppRadii.r18),
                                    border: Border.all(
                                      color: isSel ? primary.withValues(alpha: 0.22) : AppColors.borderLight,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          labelOf(p),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: AppTypography.s14,
                                            fontWeight: FontWeight.w600,
                                            color: isSel ? primary : AppColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      if (isSel) Icon(Icons.check, color: primary),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
      );
    },
  );

  overlay.insert(entry);
  return completer.future;
}

