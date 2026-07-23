import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../recordings/presentation/widgets/recording_session_sheet.dart';
import '../../recordings/presentation/widgets/transfer_notify_listener.dart';
import '../../../app/theme/app_typography.dart';
import '../../device/presentation/device_status_poller.dart';

class HomeShellPage extends ConsumerWidget {
  final Widget child;

  const HomeShellPage({super.key, required this.child});

  int _locationToIndex(String location) {
    if (location.startsWith('/recordings')) return 0; // Files
    if (location.startsWith('/ai-config')) return 2; // AI Config
    return 0;
  }

  void _onTap(BuildContext context, int index) {
    switch (index) {
      case 0:
        context.go('/recordings');
        break;
      case 2:
        context.go('/ai-config');
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.toString();
    final currentIndex = _locationToIndex(location);

    return Scaffold(
      body: TransferNotifyListener(
        child: Stack(
          children: [
            child,
            const DeviceStatusPoller(),
          ],
        ),
      ),
      bottomNavigationBar: _HomeBottomBar(
        currentIndex: currentIndex,
        onTap: (i) => _onTap(context, i),
        onRecordTap: () {
          RecordingSessionSheet.show(context);
        },
      ),
    );
  }
}

class _HomeBottomBar extends StatelessWidget {
  final int currentIndex; // 0: Files, 2: AI Config
  final ValueChanged<int> onTap;
  final VoidCallback onRecordTap;

  const _HomeBottomBar({
    required this.currentIndex,
    required this.onTap,
    required this.onRecordTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final selected = cs.primary;
    final unselected = AppTheme.textSecondary;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;

// Do not wrap the whole bottom bar in SafeArea (it lifts the bar and leaves a gap under tabs).
// Keep the bar flush to the bottom; apply safe insets as inner padding.
    return Container(
      padding: EdgeInsets.only(left: 24, right: 24, top: 8, bottom: 8 + bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
      ),
      child: SizedBox(
        height: 56,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              children: [
                Expanded(
                  child: _TabItem(
                    label: l10n.filesTab,
                    icon: Icons.folder_outlined,
                    selected: currentIndex == 0,
                    selectedColor: selected,
                    unselectedColor: unselected,
                    onTap: () => onTap(0),
                  ),
                ),
                const SizedBox(width: 90), // space for floating record button
                Expanded(
                  child: _TabItem(
                    label: l10n.aiConfigTab,
                    icon: Icons.auto_awesome_outlined,
                    selected: currentIndex == 2,
                    selectedColor: selected,
                    unselectedColor: unselected,
                    onTap: () => onTap(2),
                  ),
                ),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              top: -28,
              child: Center(
                child: _RecordButton(onTap: onRecordTap),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color selectedColor;
  final Color unselectedColor;
  final VoidCallback onTap;

  const _TabItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.selectedColor,
    required this.unselectedColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? selectedColor : unselectedColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontSize: AppTypography.s14,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  final VoidCallback onTap;

  const _RecordButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white, width: 6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Icon(Icons.mic, color: Colors.white, size: 30),
      ),
    );
  }
}

