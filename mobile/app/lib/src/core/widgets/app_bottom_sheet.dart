import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_radii.dart';
const double kAppSheetTopGap = 120.0;

class AppSheetDragHandle extends StatelessWidget {
  const AppSheetDragHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 44,
        height: 5,
        decoration: BoxDecoration(
          color: AppColors.gray200,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
      ),
    );
  }
}

class AppBottomSheetShell extends StatelessWidget {
  final Widget child;
  final bool showDragHandle;

  const AppBottomSheetShell({
    super.key,
    required this.child,
    this.showDragHandle = true,
  });

  @override
  Widget build(BuildContext context) {
    // Extend the sheet background through the home-indicator inset; pad content above it.
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadii.r28)),
      child: Material(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showDragHandle) ...[
                const SizedBox(height: 16),
                const AppSheetDragHandle(),
                const SizedBox(height: 18),
              ],
              Flexible(fit: FlexFit.loose, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

Future<T?> showAppBottomSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  double topGap = kAppSheetTopGap,
  bool showDragHandle = true,
  Color? barrierColor,
  bool isDismissible = true,
  /// Animation duration; default 150ms for snappy sheets
  Duration? transitionDuration,
}) {
  final h = MediaQuery.of(context).size.height;
  final duration = transitionDuration ?? const Duration(milliseconds: 150);
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    backgroundColor: Colors.transparent,
    barrierColor: barrierColor,
    sheetAnimationStyle: AnimationStyle(
      duration: duration,
      reverseDuration: duration,
    ),
    builder: (ctx) {
      final nav = Navigator.of(ctx, rootNavigator: useRootNavigator);
      final keyboardInset = MediaQuery.viewInsetsOf(ctx).bottom;
      void dismiss() {
        if (isDismissible && nav.canPop()) nav.pop();
      }

      final panel = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: h - topGap - keyboardInset),
        child: AppBottomSheetShell(
          showDragHandle: showDragHandle,
          child: builder(ctx),
        ),
      );

      // Full-height route child: explicit scrim tap + framework drag on the panel.
      // Align-only layouts often miss barrier hits; a full-screen Stack does not.
      // Lift the panel above the keyboard; the custom Stack layout does not inherit
      // [showModalBottomSheet]'s default inset handling when pinned to bottom: 0.
      return SizedBox(
        height: h,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: dismiss,
              ),
            ),
            AnimatedPositioned(
              duration: duration,
              curve: Curves.easeOut,
              left: 0,
              right: 0,
              bottom: keyboardInset,
              child: panel,
            ),
          ],
        ),
      );
    },
  );
}

