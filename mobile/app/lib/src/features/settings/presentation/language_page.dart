import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/l10n/app_locale_provider.dart';
import 'settings_widgets.dart';
import '../../../app/theme/app_typography.dart';

class LanguagePage extends ConsumerStatefulWidget {
  const LanguagePage({super.key});

  @override
  ConsumerState<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends ConsumerState<LanguagePage> {
  late String _langCode; // 'en' | 'zh'

  @override
  void initState() {
    super.initState();
    final locale = ref.read(appLocaleProvider);
    _langCode = (locale.languageCode == 'en') ? 'en' : 'zh';
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
          onPressed: () => context.pop(),
        ),
        title: Text(l10n.language),
        actions: [
          TextButton(
            onPressed: () async {
              final next = _langCode == 'en'
                  ? const Locale('en', '')
                  : const Locale('zh', '');
              final current = ref.read(appLocaleProvider);
              if (!context.mounted) return;
              context.pop();
              if (current != next) {
                await ref.read(appLocaleProvider.notifier).setLocale(next);
              }
            },
            child: Text(
              l10n.save,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s14,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          SettingsSectionLabel(l10n.language),
          SettingsCard(
            children: [
              _LangRow(
                label: l10n.languageEnglish,
                selected: _langCode == 'en',
                onTap: () => setState(() => _langCode = 'en'),
              ),
              _LangRow(
                label: l10n.languageChinese,
                selected: _langCode == 'zh',
                onTap: () => setState(() => _langCode = 'zh'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LangRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _LangRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      title: label,
      trailing: selected
          ? const Icon(Icons.check, color: AppColors.brandPrimary)
          : const SizedBox(width: 24, height: 24),
      onTap: onTap,
    );
  }
}
