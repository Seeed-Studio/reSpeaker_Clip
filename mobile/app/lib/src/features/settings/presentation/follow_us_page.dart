import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/legal/open_legal_url.dart';
import '../../../core/l10n/app_localizations.dart';
import 'settings_widgets.dart';

class FollowUsPage extends StatelessWidget {
  const FollowUsPage({super.key});

  static const _links = <_SocialLink>[
    _SocialLink(
      labelKey: _SocialLabelKey.twitter,
      url: 'https://twitter.com/seeedstudio',
      brand: _SocialBrand.twitter,
    ),
    _SocialLink(
      labelKey: _SocialLabelKey.linkedIn,
      url: 'https://www.linkedin.com/company/seeedstudio',
      brand: _SocialBrand.linkedIn,
    ),
    _SocialLink(
      labelKey: _SocialLabelKey.discord,
      url: 'https://discord.com/invite/QqMgVwHT3X',
      brand: _SocialBrand.discord,
    ),
    _SocialLink(
      labelKey: _SocialLabelKey.facebook,
      url: 'https://www.facebook.com/seeedstudiosz/',
      brand: _SocialBrand.facebook,
    ),
  ];

  String _label(AppLocalizations l10n, _SocialLabelKey key) {
    return switch (key) {
      _SocialLabelKey.twitter => l10n.followUsTwitter,
      _SocialLabelKey.linkedIn => l10n.followUsLinkedIn,
      _SocialLabelKey.discord => l10n.followUsDiscord,
      _SocialLabelKey.facebook => l10n.followUsFacebook,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.followUs),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 12, bottom: 24),
        children: [
          SettingsSectionLabel(l10n.community),
          SettingsCard(
            children: [
              for (final link in _links)
                _SocialLinkTile(
                  label: _label(l10n, link.labelKey),
                  brand: link.brand,
                  onTap: () => openLegalUrl(context, link.url),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _SocialLabelKey { twitter, linkedIn, discord, facebook }

enum _SocialBrand { twitter, linkedIn, discord, facebook }

class _SocialLink {
  const _SocialLink({
    required this.labelKey,
    required this.url,
    required this.brand,
  });

  final _SocialLabelKey labelKey;
  final String url;
  final _SocialBrand brand;
}

class _SocialLinkTile extends StatelessWidget {
  const _SocialLinkTile({
    required this.label,
    required this.brand,
    required this.onTap,
  });

  final String label;
  final _SocialBrand brand;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: AppTypography.s14,
          color: AppColors.textPrimary,
        );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            _SocialBrandIcon(brand: brand),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: titleStyle)),
            const Icon(
              Icons.open_in_new,
              color: AppColors.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _SocialBrandIcon extends StatelessWidget {
  const _SocialBrandIcon({required this.brand});

  final _SocialBrand brand;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: _backgroundColor,
        borderRadius: BorderRadius.circular(AppRadii.r10),
      ),
      alignment: Alignment.center,
      child: _glyph,
    );
  }

  Color get _backgroundColor {
    return switch (brand) {
      _SocialBrand.twitter => const Color(0xFF000000),
      _SocialBrand.linkedIn => const Color(0xFF0A66C2),
      _SocialBrand.discord => const Color(0xFF5865F2),
      _SocialBrand.facebook => const Color(0xFF1877F2),
    };
  }

  Widget get _glyph {
    return switch (brand) {
      _SocialBrand.twitter => const Text(
          'X',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 16,
            height: 1,
          ),
        ),
      _SocialBrand.linkedIn => const Text(
          'in',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 15,
            height: 1,
          ),
        ),
      _SocialBrand.discord => const Icon(
          Icons.forum_outlined,
          color: Colors.white,
          size: 20,
        ),
      _SocialBrand.facebook => const Text(
          'f',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 22,
            height: 1,
          ),
        ),
    };
  }
}
