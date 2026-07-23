import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../../app/theme/app_colors.dart';
import '../../app/theme/app_radii.dart';
import '../../app/theme/app_typography.dart';
import 'app_loading.dart';
import 'app_pill_button.dart';
import 'app_sheet_action_buttons.dart';
import 'app_toasts.dart';

class AppDialogs {
  AppDialogs._();
  static Future<bool> showDeleteConfirm(
    BuildContext context, {
    String? title,
    required String message,
    String? cancelText,
    String? deleteText,
  }) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showConfirm(
      context,
      title: title ?? l10n?.delete ?? 'Delete',
      message: message,
      cancelText: cancelText,
      confirmText: deleteText ?? l10n?.delete ?? 'Delete',
      confirmStyle: ConfirmStyle.danger,
    );
    return ok;
  }

  static Future<bool> showConfirm(
    BuildContext context, {
    required String title,
    required String message,
    String? cancelText,
    String? confirmText,
    ConfirmStyle confirmStyle = ConfirmStyle.primary,
    bool barrierDismissible = true,
  }) async {
    final l10n = AppLocalizations.of(context);
    final resolvedCancel = cancelText ?? l10n?.cancel ?? 'Cancel';
    final resolvedConfirm = confirmText ?? l10n?.confirm ?? 'Confirm';
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        return _AppDialogShell(
          title: title,
          titleAlign: TextAlign.left,
          actions: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: AppSheetActionButtons(
              secondaryText: resolvedCancel,
              onSecondary: () => Navigator.of(ctx).pop(false),
              primaryText: resolvedConfirm,
              onPrimary: () => Navigator.of(ctx).pop(true),
              primaryEnabled: true,
              secondaryEnabled: true,
              height: 48,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Text(
              message,
              style: const TextStyle(fontSize: AppTypography.s14, color: AppColors.textSecondary, height: 1.35),
            ),
          ),
        );
      },
    );
    return res ?? false;
  }

  /// Same shell and pill buttons as [showConfirm], but accepts arbitrary [content]
  /// (e.g. credential rows). Optional [onSecondaryExtra] / [onPrimaryExtra] run
  /// before the dialog pops (open settings, etc.).
  static Future<bool> showConfirmWithContent(
    BuildContext context, {
    required String title,
    required Widget content,
    String? cancelText,
    String? confirmText,
    bool barrierDismissible = true,
    FutureOr<void> Function()? onSecondaryExtra,
    FutureOr<void> Function()? onPrimaryExtra,
  }) async {
    final l10n = AppLocalizations.of(context);
    final resolvedCancel = cancelText ?? l10n?.cancel ?? 'Cancel';
    final resolvedConfirm = confirmText ?? l10n?.confirm ?? 'Confirm';
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        return _AppDialogShell(
          title: title,
          titleAlign: TextAlign.left,
          actions: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: AppSheetActionButtons(
              secondaryText: resolvedCancel,
              onSecondary: () async {
                await onSecondaryExtra?.call();
                if (ctx.mounted) Navigator.of(ctx).pop(false);
              },
              primaryText: resolvedConfirm,
              onPrimary: () async {
                await onPrimaryExtra?.call();
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              },
              primaryEnabled: true,
              secondaryEnabled: true,
              height: 48,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: content,
          ),
        );
      },
    );
    return res ?? false;
  }

  static AppDialogHandle showLoading(
    BuildContext context, {
    String? message,
    bool barrierDismissible = false,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        return PopScope(
          canPop: barrierDismissible,
          child: Dialog(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.r18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: AppLoading(message: message),
            ),
          ),
        );
      },
    );
    return AppDialogHandle._(navigator);
  }

  /// Blocking loader with updatable progress; returns handle and writable progressMessage (e.g. upload %).
  static ({AppDialogHandle handle, ValueNotifier<String> progressMessage}) showLoadingWithProgress(
    BuildContext context, {
    String initialMessage = 'Processing',
    bool barrierDismissible = false,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final progressMessage = ValueNotifier<String>(initialMessage);
    showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) {
        return PopScope(
          canPop: barrierDismissible,
          child: Dialog(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.r18)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: ValueListenableBuilder<String>(
                valueListenable: progressMessage,
                builder: (_, msg, __) => AppLoading(message: msg),
              ),
            ),
          ),
        );
      },
    );
    return (handle: AppDialogHandle._(navigator), progressMessage: progressMessage);
  }

  static void showSuccess(BuildContext context, {required String message}) =>
      AppToasts.showSuccess(context, message: message);

  static void showWarning(BuildContext context, {required String message}) =>
      AppToasts.showWarning(context, message: message);

  static void showError(BuildContext context, {required String message}) =>
      AppToasts.showError(context, message: message);

  static void showInfo(BuildContext context, {required String message}) =>
      AppToasts.showInfo(context, message: message);

  /// Error alert; dismisses on OK
  static Future<void> showErrorDialog(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmText,
  }) async {
    final l10n = AppLocalizations.of(context);
    final resolvedConfirm = confirmText ?? l10n?.confirm ?? 'OK';
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return _AppDialogShell(
          title: title,
          titleAlign: TextAlign.left,
          actions: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  width: 100,
                  height: 48,
                  child: AppBlackPillButton(
                    label: resolvedConfirm,
                    onPressed: () => Navigator.of(ctx).pop(),
                    height: 48,
                  ),
                ),
              ],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Text(
              message,
              style: const TextStyle(fontSize: AppTypography.s14, color: AppColors.textSecondary, height: 1.35),
            ),
          ),
        );
      },
    );
  }
}

class AppDialogHandle {
  final NavigatorState _navigator;
  bool _closed = false;
  AppDialogHandle._(this._navigator);

  void close() {
    if (_closed) return;
    _closed = true;
    if (_navigator.canPop()) _navigator.pop();
  }
}

enum ConfirmStyle { primary, danger }

class _AppDialogShell extends StatelessWidget {
  final String title;
  final TextAlign titleAlign;
  final Widget child;
  final Widget actions;

  const _AppDialogShell({
    required this.title,
    required this.child,
    required this.actions,
    this.titleAlign = TextAlign.left,
  });

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.65;
    return Dialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.r18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DialogHeader(
              title: title,
              titleAlign: titleAlign,
              onClose: () => Navigator.of(context).pop(),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 4),
                child: child,
              ),
            ),
            actions,
          ],
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  final String title;
  final TextAlign titleAlign;
  final VoidCallback onClose;

  const _DialogHeader({
    required this.title,
    required this.titleAlign,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
      child: SizedBox(
        width: double.infinity,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  title,
                  textAlign: titleAlign,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontSize: AppTypography.s18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        height: 1.25,
                      ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _CloseX(onTap: onClose),
          ],
        ),
      ),
    );
  }
}

class _CloseX extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseX({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.borderLight),
        ),
        child: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
      ),
    );
  }
}

