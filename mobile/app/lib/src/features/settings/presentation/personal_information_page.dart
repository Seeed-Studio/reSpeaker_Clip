import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/api/user_api.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/auth/user_profile_store.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/user_avatar_image.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/avatar_gallery_permission.dart';
import 'settings_widgets.dart';

/// Effective account binding: user center [UserSecurityInfo.accountType] when
/// available, else profile [UserProfile.provider] (legacy fallback).
String _accountBindingType(UserSecurityInfo? sec, UserProfile? me) {
  final a = (sec?.accountType ?? '').trim().toLowerCase();
  if (a.isNotEmpty) return a;
  return (me?.provider ?? '').trim().toLowerCase();
}

class PersonalInformationPage extends ConsumerStatefulWidget {
  const PersonalInformationPage({super.key});

  @override
  ConsumerState<PersonalInformationPage> createState() => _PersonalInformationPageState();
}

class _PersonalInformationPageState extends ConsumerState<PersonalInformationPage> {
  late final TextEditingController _nickname = TextEditingController();
  File? _avatarFile;
  UserSecurityInfo? _security;
  final _picker = ImagePicker();
  bool _saving = false;

  void _safeBack() {
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings');
    }
  }

  @override
  void initState() {
    super.initState();
    final me = UserProfileStore.cached;
    _nickname.text = (me?.name ?? '').trim().isEmpty ? '' : (me?.name ?? '').trim();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadSecurityInfo();
    });
  }

  Future<void> _loadSecurityInfo() async {
    try {
      final info = await ref.read(authRepositoryProvider).getSecurityInfo();
      if (!mounted) return;
      setState(() => _security = info);
    } catch (_) {
      // Older backends / network: keep OAuth rows on profile.provider only.
    }
  }

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    if (!await ensureAvatarGalleryAccess(context)) return;
    if (!mounted) return;

    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
    if (picked != null) {
      if (!mounted) return;
      setState(() => _avatarFile = File(picked.path));
      return;
    }

    if (!mounted) return;
    await promptAvatarGalleryAccessIfBlocked(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primary = Theme.of(context).colorScheme.primary;
    final nickLen = _nickname.text.characters.length;
    final me = ref.watch(userProfileProvider);
    final avatarRevision = ref.watch(avatarImageRevisionProvider);
    final displayEmail = (me?.email ?? '').trim();
    final binding = _accountBindingType(_security, me);

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _safeBack),
        title: Text(l10n.personalInformation),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () async {
                    final currentName = (me?.name ?? '').trim();
                    final nextName = _nickname.text.trim();
                    final shouldUpdateName = nextName.isNotEmpty && nextName != currentName;
                    final shouldUpdateAvatar = _avatarFile != null;

                    if (!shouldUpdateName && !shouldUpdateAvatar) {
                      _safeBack();
                      return;
                    }
                    setState(() => _saving = true);
                    final rootNav = Navigator.of(context, rootNavigator: true);
                    showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const Center(child: CircularProgressIndicator()),
                    );
                    try {
                      String? avatarUrl;
                      if (_avatarFile != null) {
                        final up = await ref.read(authRepositoryProvider).uploadAvatar(_avatarFile!);
                        avatarUrl = up.publicUrl.trim();
                      }
                      // Route via [authRepositoryProvider] so SC-mode hits
                      // `PUT /api/v1/user/updateProfile` (auth host) and self-hosted
                      // hits `PUT /api/v1/user`. [uploadAvatar] uses the same auth
                      // host presign in SC mode and business presign when self-hosted.
                      final updated = await ref.read(authRepositoryProvider).updateProfile(
                            name: shouldUpdateName ? nextName : null,
                            avatarUrl: avatarUrl,
                          );
                      if (updated != null) {
                        ref.read(userProfileProvider.notifier).setFromLogin(updated);
                      } else {
                        if (shouldUpdateName) {
                          ref.read(userProfileProvider.notifier).updateNameLocal(nextName);
                        }
                        if (avatarUrl != null && avatarUrl.trim().isNotEmpty) {
                          ref.read(userProfileProvider.notifier).updateAvatarUrlLocal(avatarUrl);
                        }
                      }
                      try {
                        await ref.read(userProfileProvider.notifier).refresh();
                      } catch (_) {
                        // ignore
                      }
                      if (shouldUpdateAvatar) {
                        ref.read(userProfileProvider.notifier).markAvatarImageChanged();
                      }
                      if (mounted) {
                        setState(() => _avatarFile = null);
                      }
                      if (rootNav.canPop()) rootNav.pop();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.profileUpdated)));
                      _safeBack();
                    } on ServerException catch (e) {
                      if (rootNav.canPop()) rootNav.pop();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(serverErrorMessage(context, e))));
                    } catch (e) {
                      if (rootNav.canPop()) rootNav.pop();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            AppLocalizations.of(context)!.loadFailed(e.toString()),
                          ),
                        ),
                      );
                    } finally {
                      if (mounted) setState(() => _saving = false);
                    }
                  },
            child: Text(l10n.save, style: TextStyle(color: AppColors.brandPrimary, fontSize: AppTypography.s16)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SizedBox(height: 10),
          Center(
            child: InkWell(
              onTap: _pickAvatar,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: Stack(
                children: [
                  Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      color: (_avatarFile != null ||
                              (me?.avatarUrl ?? '').toString().trim().isNotEmpty)
                          ? Colors.transparent
                          : AppColors.surfaceSubtle,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: _avatarFile != null
                        ? ClipOval(child: Image.file(_avatarFile!, fit: BoxFit.cover))
                        : (me?.avatarUrl ?? '').toString().trim().isNotEmpty
                            ? UserAvatarImage(
                                imageUrl: avatarImageUrl(
                                  avatarUrl: me!.avatarUrl!.trim(),
                                  revision: avatarRevision,
                                ),
                                cacheKey: avatarImageCacheKey(
                                  profileId: me.id,
                                  avatarUrl: me.avatarUrl!.trim(),
                                  revision: avatarRevision,
                                ),
                                size: 140,
                                errorWidget: const Icon(
                                  Icons.person_outline,
                                  size: 54,
                                  color: AppColors.textPlaceholder,
                                ),
                              )
                            : const Icon(Icons.person_outline, size: 54, color: AppColors.textPlaceholder),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 10,
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 4),
                      ),
                      child: const Icon(Icons.photo_camera_outlined, color: AppColors.surface),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              l10n.tapToChangeProfilePhoto,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textPlaceholder),
            ),
          ),
          const SizedBox(height: 18),
          SettingsSectionLabel(l10n.nickname),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _nickname,
                        onChanged: (_) => setState(() {}),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: AppTypography.s18),
                        decoration: const InputDecoration(border: InputBorder.none),
                      ),
                    ),
                    Text(
                      '$nickLen/50',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textPlaceholder),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1, thickness: 1, color: AppColors.border),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SettingsSectionLabel(l10n.boundEmail),
          SettingsCard(
            children: [
              SettingsTile(
                title: displayEmail.isEmpty ? '—' : displayEmail,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.chevron_right, color: AppColors.textPlaceholder),
                  ],
                ),
                onTap: () => context.push('/settings/change-email'),
              ),
            ],
          ),
          SettingsSectionLabel(l10n.connectedAccounts),
          SettingsCard(
            children: [
              _ConnectedAccountRow(
                iconAsset: 'assets/png/apple.png',
                label: 'Apple',
                status: binding == 'apple' ? l10n.connected : l10n.notConnected,
                statusStrong: binding == 'apple',
              ),
              _ConnectedAccountRow(
                iconAsset: 'assets/png/google.png',
                label: 'Google',
                status: binding == 'google' ? l10n.connected : l10n.notConnected,
                statusStrong: binding == 'google',
              ),
              _ConnectedAccountRow(
                iconAsset: 'assets/png/github.png',
                label: 'GitHub',
                status: binding == 'github' ? l10n.connected : l10n.notConnected,
                statusStrong: binding == 'github',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectedAccountRow extends StatelessWidget {
  final String iconAsset;
  final String label;
  final String status;
  final bool statusStrong;

  const _ConnectedAccountRow({
    required this.iconAsset,
    required this.label,
    required this.status,
    this.statusStrong = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        children: [
          Image.asset(iconAsset, width: 26, height: 26, fit: BoxFit.contain),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500))),
          Text(
            status,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: statusStrong ? AppColors.textPrimary : AppColors.textPlaceholder,
                  fontWeight: statusStrong ? FontWeight.w500 : FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

