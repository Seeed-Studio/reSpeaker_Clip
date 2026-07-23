import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../device/presentation/device_controller.dart';
import '../recordings_controller.dart';

/// Listen for transfer complete event; when record-while-sync finishes in background show "Sync complete" toast.
class TransferNotifyListener extends ConsumerWidget {
  const TransferNotifyListener({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<TransferCompletedEvent?>(transferCompletedEventProvider, (prev, next) {
      if (next == null) return;
      if (!context.mounted) return;
      // Snackbar on success only; list shows failures
      if (next.success) {
        final devUi = ref.read(deviceControllerProvider);
        if (devUi.firmwareAppearsRecordingOrPaused) {
          // Background sync of another row while device records — list UI is enough.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            ref.read(transferCompletedEventProvider.notifier).state = null;
          });
          return;
        }
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.syncComplete),
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      }
      // Defer clear so [RecordingsPage] (and others) can read [next] in the same notify cycle.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(transferCompletedEventProvider.notifier).state = null;
      });
    });
    return child;
  }
}
