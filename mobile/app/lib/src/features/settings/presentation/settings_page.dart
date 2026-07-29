import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../../../core/widgets/app_toasts.dart';
import '../../../core/l10n/app_locale_provider.dart';
import '../../../core/l10n/app_localizations.dart';
import 'settings_widgets.dart';
import '../../../app/theme/app_typography.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/widgets/user_avatar_image.dart';
import '../data/app_info_provider.dart';
import '../data/app_update_service.dart';
import '../data/push_provider.dart';
import '../../../core/cache/app_cache.dart';
import '../../../core/legal/legal_urls.dart';
import '../../../core/legal/open_legal_url.dart';

/// Set to true to show the bell button and Push Notifications row again.
const bool _showBellButton = false;
const bool _showPushNotifications = false;
const bool _showOpenSourceLicenses = false;

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final locale = ref.watch(appLocaleProvider);
    final langLabel = locale.languageCode == 'en' ? 'English' : '简体中文';
    final session = ref.watch(authSessionProvider);
    final me = ref.watch(userProfileProvider);
    final versionAsync = ref.watch(appVersionProvider);
    final cacheSizeAsync = ref.watch(cacheSizeBytesProvider);
    final appUpdateInfo = ref.watch(appUpdateInfoProvider).valueOrNull;
    final hasAppUpdate = appUpdateInfo?.updateAvailable == true &&
        (appUpdateInfo?.downloadUrl.trim().isNotEmpty ?? false);
    final displayName =
        ((me?.name ?? '').trim().isNotEmpty) ? (me?.name ?? '').trim() : '—';
    final displayEmail = ((me?.email ?? session.email ?? '').trim().isNotEmpty)
        ? (me?.email ?? session.email ?? '').trim()
        : '—';
    final avatarUrl = (me?.avatarUrl ?? '').toString().trim();
    final avatarRevision = ref.watch(avatarImageRevisionProvider);

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(l10n.settings),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop()),
        actions: _showBellButton
            ? [
                IconButton(
                  onPressed: () {},
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: const [
                      Icon(Icons.notifications_none_outlined),
                      Positioned(
                        right: -1,
                        top: -1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: AppColors.danger, shape: BoxShape.circle),
                          child: SizedBox(width: 6, height: 6),
                        ),
                      ),
                    ],
                  ),
                ),
              ]
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SizedBox(height: 12),
          _ProfileHeader(
            profileId: me?.id ?? 0,
            name: displayName,
            email: displayEmail,
            avatarUrl: avatarUrl,
            avatarRevision: avatarRevision,
            onTap: () => context.push('/settings/personal'),
          ),
          SettingsSectionLabel(l10n.settings),
          SettingsCard(
            children: [
              SettingsTile(
                title: l10n.permissions,
                onTap: () => context.push('/settings/permissions'),
              ),
              SettingsTile(
                title: l10n.language,
                value: langLabel,
                onTap: () => context.push('/settings/language'),
              ),
              if (_showPushNotifications)
                _PushNotificationsTile(
                    primary: Theme.of(context).colorScheme.primary),
            ],
          ),
          SettingsSectionLabel(l10n.security),
          SettingsCard(
            children: [
              SettingsTile(
                title: l10n.passwordItem,
                onTap: () => context.push('/settings/change-password'),
              ),
              SettingsTile(
                title: l10n.deleteAccount,
                danger: true,
                onTap: () => context.push('/settings/delete-account'),
              ),
            ],
          ),
          SettingsSectionLabel(l10n.community),
          SettingsCard(
            children: [
              SettingsTile(
                title: l10n.followUs,
                onTap: () => context.push('/settings/follow-us'),
              ),
              SettingsTile(
                  title: l10n.helpFeedback,
                  onTap: () => context.push('/settings/help-feedback')),
            ],
          ),
          SettingsSectionLabel(l10n.about),
          SettingsCard(
            children: [
              SettingsTile(
                title: l10n.appVersion,
                value: versionAsync.when(
                  data: (v) => v,
                  loading: () => '—',
                  error: (_, __) => '—',
                ),
                trailing: hasAppUpdate ? const _AppUpdateTrailing() : null,
                onTap: hasAppUpdate
                    ? () => _openLatestAppUpdate(context, ref, appUpdateInfo!)
                    : null,
              ),
              SettingsTile(
                title: l10n.clearCache,
                value: cacheSizeAsync.when(
                  data: (bytes) => formatCacheSize(bytes),
                  loading: () => '—',
                  error: (_, __) => '0 B',
                ),
                onTap: () async {
                  final nav = Navigator.of(context, rootNavigator: true);
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    useRootNavigator: true,
                    builder: (_) =>
                        const Center(child: CircularProgressIndicator()),
                  );
                  try {
                    await clearAppCache();
                    ref.invalidate(cacheSizeBytesProvider);
                    nav.pop();
                    if (!context.mounted) return;
                    AppToasts.showSuccess(context, message: l10n.cacheCleared);
                  } catch (_) {
                    nav.pop();
                    if (context.mounted) {
                      AppToasts.showError(context,
                          message: l10n.clearCacheFailed);
                    }
                  }
                },
              ),
              SettingsTile(
                title: l10n.privacyPolicy2,
                onTap: () =>
                    openLegalUrl(context, LegalUrls.privacyPolicy(context)),
              ),
              SettingsTile(
                title: l10n.userAgreement2,
                onTap: () =>
                    openLegalUrl(context, LegalUrls.userAgreement(context)),
              ),
              if (_showOpenSourceLicenses)
                SettingsTile(
                  title: l10n.openSourceLicenses,
                  onTap: () =>
                      openLegalUrl(context, LegalUrls.openSourceLicenses),
                ),
            ],
          ),
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: AppOutlinedPillButton(
              label: l10n.logOut,
              height: 48,
              borderColor: Colors.transparent,
              foregroundColor: AppColors.danger,
              onPressed: () async {
                final rootNav = Navigator.of(context, rootNavigator: true);
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) =>
                      const Center(child: CircularProgressIndicator()),
                );
                try {
                  // Route via [authRepositoryProvider] so SC-mode hits SC's
                  // `/api/v1/user/logout` (auth host) and self-hosted hits
                  // the business `/api/v1/user/logout`. Either way we still
                  // clear local session afterwards.
                  await ref.read(authRepositoryProvider).logout();
                } catch (_) {
                  // Clear local session even if server sign-out errors
                } finally {
                  await ref.read(authSessionProvider.notifier).logoutFully();
                  if (rootNav.canPop()) rootNav.pop();
                }
                if (!context.mounted) return;
                context.go('/login');
              },
              textStyle: const TextStyle(
                  fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _openLatestAppUpdate(
  BuildContext context,
  WidgetRef ref,
  AppUpdateInfo update,
) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await ref.read(appUpdateServiceProvider).openUpdateUrl(update.downloadUrl);
  } on AppUpdateServiceException catch (e) {
    if (!context.mounted) return;
    if (e.message.contains('not configured')) {
      AppToasts.showError(context, message: l10n.updateServiceNotConfigured);
    } else {
      AppToasts.showError(context, message: e.message);
    }
  } catch (_) {
    if (!context.mounted) return;
    AppToasts.showError(context, message: l10n.updateCheckFailed);
  }
}

class _AppUpdateTrailing extends StatelessWidget {
  const _AppUpdateTrailing();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.danger,
            shape: BoxShape.circle,
          ),
          child: SizedBox(width: 8, height: 8),
        ),
        SizedBox(width: 10),
        Icon(Icons.chevron_right, color: AppColors.danger, size: 24),
      ],
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  final int profileId;
  final String name;
  final String email;
  final String avatarUrl;
  final int avatarRevision;
  final VoidCallback onTap;
  const _ProfileHeader({
    required this.profileId,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.avatarRevision,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadii.br18,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Column(
            children: [
              Stack(
                children: [
                  Container(
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      // Avoid a pale circle flash while the shared cache paints.
                      color: avatarUrl.isNotEmpty
                          ? Colors.transparent
                          : AppColors.surfaceSubtle,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: avatarUrl.isNotEmpty
                        ? UserAvatarImage(
                            imageUrl: avatarImageUrl(
                              avatarUrl: avatarUrl,
                              revision: avatarRevision,
                            ),
                            cacheKey: avatarImageCacheKey(
                              profileId: profileId,
                              avatarUrl: avatarUrl,
                              revision: avatarRevision,
                            ),
                            size: 104,
                            errorWidget: const Icon(
                              Icons.person_outline,
                              size: 46,
                              color: AppColors.textPlaceholder,
                            ),
                          )
                        : const Icon(Icons.person_outline,
                            size: 46, color: AppColors.textPlaceholder),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 3),
                      ),
                      child: const Icon(Icons.edit,
                          size: 18, color: AppColors.surface),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(name,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(email,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textTertiary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PushNotificationsTile extends ConsumerWidget {
  final Color primary;
  const _PushNotificationsTile({required this.primary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = ref.watch(pushEnabledProvider);
    return SettingsSwitchTile(
      title: l10n.pushNotifications,
      value: enabled,
      onChanged: (v) async {
        if (v) {
          final granted = await requestNotificationPermission();
          await ref.read(pushEnabledProvider.notifier).setEnabled(granted);
          if (context.mounted && !granted) {
            AppToasts.showInfo(context,
                message: l10n.notificationPermissionDenied);
          }
        } else {
          await ref.read(pushEnabledProvider.notifier).setEnabled(false);
        }
      },
    );
  }
}
