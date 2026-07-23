import 'package:flutter/material.dart';

/// Full-screen scrim for [OverlayEntry] menus: tap outside [child] to dismiss.
///
/// Prefer this over wrapping a [Stack] in [GestureDetector] — without an
/// explicit [Positioned.fill] scrim, the hit target may not cover the whole
/// screen and taps on "empty" areas can fall through to the page below.
class AppOverlayTapDismiss extends StatelessWidget {
  const AppOverlayTapDismiss({
    super.key,
    required this.onDismiss,
    required this.child,
  });

  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
          ),
        ),
        child,
      ],
    );
  }
}
