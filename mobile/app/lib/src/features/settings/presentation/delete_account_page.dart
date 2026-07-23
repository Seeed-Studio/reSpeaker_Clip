import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';

class DeleteAccountPage extends ConsumerWidget {
  const DeleteAccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        title: Text(l10n.deleteAccount),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          children: [
            const SizedBox(height: 18),
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadii.r20),
              ),
              child: const Icon(Icons.delete_outline, color: AppColors.danger, size: 34),
            ),
            const SizedBox(height: 18),
            Text(
              l10n.accountDeletion,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w500, fontSize: AppTypography.s18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Text(
              l10n.accountDeletionDesc,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppColors.textTertiary, height: 1.45),
              textAlign: TextAlign.center,
            ),
            const Spacer(),
            AppOutlinedPillButton(
              label: l10n.confirmDeletion,
              onPressed: () async {
                final ok = await AppDialogs.showDeleteConfirm(
                  context,
                  title: l10n.deleteAccountConfirmTitle,
                  message: l10n.deleteAccountConfirmMessage,
                  deleteText: l10n.delete,
                );
                if (!ok) return;
                if (!context.mounted) return;
                final rootNav = Navigator.of(context, rootNavigator: true);
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const Center(child: CircularProgressIndicator()),
                );
                try {
                  // [authRepositoryProvider]: SC-mode purges Voice business data
                  // then deactivates SenseCraft; self-hosted calls Voice only.
                  await ref.read(authRepositoryProvider).deactivateAccount();
                  // On success clear local session
                  ref.read(authSessionProvider.notifier).logout();
                  if (rootNav.canPop()) rootNav.pop();
                  if (!context.mounted) return;
                  context.go('/login');
                } on ServerException catch (e) {
                  if (rootNav.canPop()) rootNav.pop();
                  if (!context.mounted) return;
                  AppDialogs.showInfo(context, message: serverErrorMessage(context, e));
                } catch (e) {
                  if (rootNav.canPop()) rootNav.pop();
                  if (!context.mounted) return;
                  AppDialogs.showInfo(context, message: e.toString());
                }
              },
              foregroundColor: AppColors.danger,
              borderColor: AppColors.danger,
              textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
            ),
            const SizedBox(height: 14),
            AppOutlinedPillButton(
              label: l10n.cancel,
              onPressed: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 36),
            // Text(
            //   'RESPEAKER V 1.0.0',
            //   style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textPlaceholder, letterSpacing: 2),
            // ),
          ],
        ),
      ),
    );
  }
}

