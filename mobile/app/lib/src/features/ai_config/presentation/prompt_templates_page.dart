import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/validation/text_charset.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../../core/widgets/app_input_box.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/prompt_template_remote_repository.dart';
import '../domain/prompt_template.dart';
import 'ai_config_providers.dart';

enum _TemplateSortBy { createdAt}

void _showTemplateSyncError(
  BuildContext context,
  AppLocalizations l10n,
  Object e,
) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(friendlyLoadErrorMessage(context, e))),
  );
}

class PromptTemplatesPage extends ConsumerStatefulWidget {
  const PromptTemplatesPage({super.key});

  @override
  ConsumerState<PromptTemplatesPage> createState() => _PromptTemplatesPageState();
}

class _PromptTemplatesPageState extends ConsumerState<PromptTemplatesPage> {
  final _TemplateSortBy _sortBy = _TemplateSortBy.createdAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ensurePromptTemplatesLoaded(ref, force: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final asyncList = ref.watch(promptTemplatesProvider);

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Text(l10n.templatesTitle),
        centerTitle: true,
      ),
      body: asyncList.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  friendlyLoadErrorMessage(context, e),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppTypography.s14,
                  ),
                ),
                const SizedBox(height: 12),
                AppBlackPillButton(
                  label: l10n.retry,
                  onPressed: () async {
                    await ensurePromptTemplatesLoaded(ref, force: true);
                  },
                ),
              ],
            ),
          ),
        ),
        data: (items) {
          final list = _sorted(items, _sortBy);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Row(
                children: [
                  Text(
                    l10n.promptTemplates,
                    style: TextStyle(
                      fontSize: AppTypography.s12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final t in list) ...[
                _TemplateCard(
                  template: t,
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 32),
              AppBlackPillButton(
                label: l10n.addNewTemplate,
                leading: const Icon(Icons.add, color: Colors.white),
                onPressed: () => context.push('/ai-config/templates/new'),
              ),
              const SizedBox(height: 14),
              _ImportWithKeyButton(onTap: () => _openImportTemplateSheet(context)),
              const SizedBox(height: 14),
              Text(
                l10n.tapTemplateToEdit,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textPlaceholder, fontSize: AppTypography.s14, fontWeight: FontWeight.w400),
              ),
            ],
          );
        },
      ),
    );
  }

  List<PromptTemplate> _sorted(List<PromptTemplate> items, _TemplateSortBy sortBy) {
    final defaults = items.where((e) => e.isDefault).toList()..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final customs = items.where((e) => !e.isDefault).toList()
      ..sort((a, b) {
        final ta = sortBy == _TemplateSortBy.createdAt ? a.createdAt : a.updatedAt;
        final tb = sortBy == _TemplateSortBy.createdAt ? b.createdAt : b.updatedAt;
        return tb.compareTo(ta);
      });
    return [...defaults, ...customs];
  }

  Future<void> _openImportTemplateSheet(BuildContext context) async {
    final imported = await showAppBottomSheet<bool>(
      context,
      builder: (_) => const _ImportTemplateSheet(),
    );
    if (imported == true) ref.invalidate(promptTemplatesProvider);
  }
}

class PromptTemplateCreatePage extends ConsumerStatefulWidget {
  const PromptTemplateCreatePage({super.key});

  @override
  ConsumerState<PromptTemplateCreatePage> createState() => _PromptTemplateCreatePageState();
}

class _PromptTemplateCreatePageState extends ConsumerState<PromptTemplateCreatePage> {
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  int _iconIdx = 0;

  static const _icons = <IconData>[
    Icons.work_outline,
    Icons.favorite_border,
    Icons.menu_book_outlined,
    Icons.lightbulb_outline,
    Icons.home_outlined,
    Icons.music_note_outlined,
    Icons.fitness_center_outlined,
    Icons.flight_takeoff_outlined,
  ];

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        title: Text(AppLocalizations.of(context)!.createTemplate),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _FieldLabel(AppLocalizations.of(context)!.templateNameLabel),
          const SizedBox(height: 8),
          AppInputBox(controller: _name, hintText: AppLocalizations.of(context)!.hintMeetingMinutes, maxLines: 1),
          const SizedBox(height: 24),
          _FieldLabel(AppLocalizations.of(context)!.chooseIcon),
          const SizedBox(height: 8),
          _IconGrid(
            icons: _icons,
            selectedIndex: _iconIdx,
            onSelect: (i) => setState(() => _iconIdx = i),
          ),
          const SizedBox(height: 24),
          _FieldLabel(AppLocalizations.of(context)!.promptContentLabel),
          const SizedBox(height: 8),
          AppInputBox(controller: _prompt, hintText: AppLocalizations.of(context)!.hintEnterPrompt, fixedHeight: 200),
          const SizedBox(height: 22),
          AppBlackPillButton(
            label: AppLocalizations.of(context)!.save,
            onPressed: () async {
              final l10n = AppLocalizations.of(context)!;
              final name = _name.text.trim();
              final prompt = _prompt.text.trim();
              if (!isValidPromptTemplateName(name) ||
                  !isValidPromptTemplateContent(prompt)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.promptTemplateFieldsInvalid)),
                );
                return;
              }
              final remoteRepo =
                  ref.read(promptTemplateRemoteRepositoryProvider);
              try {
                await remoteRepo.createTemplate(
                  name: name,
                  prompt: prompt,
                  iconCode: _icons[_iconIdx].codePoint,
                );
              } catch (e) {
                if (context.mounted) {
                  _showTemplateSyncError(context, l10n, e);
                }
                return;
              }
              ref.invalidate(promptTemplatesProvider);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}

class _ImportTemplateSheet extends ConsumerStatefulWidget {
  const _ImportTemplateSheet();

  @override
  ConsumerState<_ImportTemplateSheet> createState() => _ImportTemplateSheetState();
}

class _ImportTemplateSheetState extends ConsumerState<_ImportTemplateSheet> {
  final _keyCtrl = TextEditingController();

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetHeader(title: AppLocalizations.of(context)!.importTemplate, onClose: () => Navigator.of(context).pop(false)),
            const SizedBox(height: 10),
            Text(
              AppLocalizations.of(context)!.enterKeyToImport,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textPlaceholder, fontSize: AppTypography.s14, fontWeight: FontWeight.w400),
            ),
            const SizedBox(height: 18),
            _FieldLabel(AppLocalizations.of(context)!.templateKey),
            const SizedBox(height: 6),
            AppInputBox(controller: _keyCtrl, hintText: AppLocalizations.of(context)!.hintShareKey, maxLines: 1),
            const SizedBox(height: 18),
            AppBlackPillButton(
              label: AppLocalizations.of(context)!.importAction,
              leading: const Icon(Icons.download, color: Colors.white),
              onPressed: () async {
                final key = _keyCtrl.text.trim();
                if (key.isEmpty) return;
                final remoteRepo =
                    ref.read(promptTemplateRemoteRepositoryProvider);
                try {
                  final t = await remoteRepo.importTemplateByKey(key);
                  if (!context.mounted) return;
                  if (t == null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.invalidKeyOrSharingStopped)));
                    return;
                  }
                  Navigator.of(context).pop(true);
                } catch (e) {
                  if (!context.mounted) return;
                  final l10n = AppLocalizations.of(context)!;
                  final msg = friendlyLoadErrorMessage(context, e);
                  await AppDialogs.showErrorDialog(
                    context,
                    title: l10n.importTemplate,
                    message: msg,
                    confirmText: l10n.confirm,
                  );
                }
              },
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                AppLocalizations.of(context)!.cancel,
                style: const TextStyle(color: AppColors.textPlaceholder, fontSize: AppTypography.s14, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PromptTemplateDetailPage extends ConsumerStatefulWidget {
  final String templateId;
  const PromptTemplateDetailPage({super.key, required this.templateId});

  @override
  ConsumerState<PromptTemplateDetailPage> createState() => _PromptTemplateDetailPageState();
}

class _PromptTemplateDetailPageState extends ConsumerState<PromptTemplateDetailPage> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  bool _didInitShareKey = false;
  String? _shareKey;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _prompt = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncList = ref.watch(promptTemplatesProvider);

    return asyncList.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) {
        final l10n = AppLocalizations.of(context)!;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.templateDetails)),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    friendlyLoadErrorMessage(context, e),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  AppBlackPillButton(
                    label: l10n.retry,
                    onPressed: () async {
                      await ensurePromptTemplatesLoaded(ref, force: true);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
      data: (items) {
        final tpl = items.where((e) => e.id == widget.templateId).firstOrNull;
        if (tpl == null) return Scaffold(body: Center(child: Text(AppLocalizations.of(context)!.notFound)));

        _name.text = _name.text.isEmpty ? tpl.name : _name.text;
        _prompt.text = _prompt.text.isEmpty ? tpl.prompt : _prompt.text;
        if (!_didInitShareKey) {
          _didInitShareKey = true;
          _shareKey = tpl.shareKey;
        }

        return Scaffold(
          backgroundColor: AppColors.appBackground,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
            title: Text(AppLocalizations.of(context)!.templateDetails),
            centerTitle: true,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _FieldLabel(AppLocalizations.of(context)!.templateNameLabel),
              const SizedBox(height: 8),
              AppInputBox(controller: _name, hintText: AppLocalizations.of(context)!.templateNameHint, maxLines: 1, readOnly: tpl.isDefault),
              const SizedBox(height: 18),
              _FieldLabel(AppLocalizations.of(context)!.promptContentLabel),
              const SizedBox(height: 8),
              AppInputBox(controller: _prompt, hintText: AppLocalizations.of(context)!.promptHint, fixedHeight: 200, readOnly: tpl.isDefault),
              // Share only for user-owned templates, not imported
              if (!tpl.isDefault && !tpl.isImported) ...[
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.shareTemplateLabel,
                        style: const TextStyle(fontSize: AppTypography.s12, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
                      ),
                    ),
                    if (_shareKey != null)
                      TextButton.icon(
                        onPressed: () async {
                          final remoteRepo =
                              ref.read(promptTemplateRemoteRepositoryProvider);
                          try {
                            await remoteRepo.stopShare(tpl);
                            ref.invalidate(promptTemplatesProvider);
                            if (!mounted) return;
                            setState(() => _shareKey = null);
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  friendlyLoadErrorMessage(context, e),
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.share_outlined, size: 16, color: AppColors.textPlaceholder),
                        label: Text(
                          AppLocalizations.of(context)!.stopSharingLabel,
                          style: const TextStyle(color: AppColors.textPlaceholder, fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_shareKey == null)
                  _DashedAction(
                    label: AppLocalizations.of(context)!.generateShareKey,
                    icon: Icons.key_outlined,
                    onTap: () async {
                      final remoteRepo =
                          ref.read(promptTemplateRemoteRepositoryProvider);
                      try {
                        final key = await remoteRepo.startShare(tpl);
                        ref.invalidate(promptTemplatesProvider);
                        if (!mounted) return;
                        setState(() => _shareKey = key);
                      } catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              friendlyLoadErrorMessage(context, e),
                            ),
                          ),
                        );
                      }
                    },
                  )
                else
                  _ShareKeyCard(
                    keyText: _shareKey!,
                    onCopy: () async {
                      await Clipboard.setData(ClipboardData(text: _shareKey!));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.copied)));
                    },
                  ),
                const SizedBox(height: 10),
                Text(
                  AppLocalizations.of(context)!.shareKeyDescription,
                  style: const TextStyle(color: AppColors.textPlaceholder, fontSize: AppTypography.s14, fontWeight: FontWeight.w400),
                ),
              ],
              if (!tpl.isDefault) ...[
                const SizedBox(height: 22),
                AppBlackPillButton(
                  label: AppLocalizations.of(context)!.saveChanges,
                  onPressed: () => _save(ref, tpl),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => _delete(ref, tpl),
                  child: Text(
                    AppLocalizations.of(context)!.deleteTemplateTitle,
                    style: const TextStyle(color: AppColors.dangerStrong, fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _save(WidgetRef ref, PromptTemplate tpl) async {
    final l10n = AppLocalizations.of(context)!;
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (!isValidPromptTemplateName(name) ||
        !isValidPromptTemplateContent(prompt)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.promptTemplateFieldsInvalid)),
      );
      return;
    }
    final remoteRepo = ref.read(promptTemplateRemoteRepositoryProvider);
    final next = tpl.copyWith(
      name: name,
      prompt: prompt,
    );
    try {
      await remoteRepo.updateTemplate(next);
    } catch (e) {
      if (mounted) {
        _showTemplateSyncError(context, l10n, e);
      }
      return;
    }
    ref.invalidate(promptTemplatesProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete(WidgetRef ref, PromptTemplate tpl) async {
    final ok = await AppDialogs.showDeleteConfirm(
      context,
      title: AppLocalizations.of(context)!.deleteTemplateTitle,
      message: AppLocalizations.of(context)!.deleteTemplateConfirm(tpl.name),
      deleteText: AppLocalizations.of(context)!.delete,
    );
    if (!ok) return;
    final remoteRepo = ref.read(promptTemplateRemoteRepositoryProvider);
    try {
      await remoteRepo.deleteTemplate(tpl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyLoadErrorMessage(context, e))),
        );
      }
      return;
    }
    ref.invalidate(promptTemplatesProvider);
    if (mounted) Navigator.of(context).pop();
  }
}

class _TemplateCard extends StatelessWidget {
  final PromptTemplate template;
  const _TemplateCard({required this.template});

  @override
  Widget build(BuildContext context) {
    final isUser = !template.isDefault;
    final icon = _iconFor(template);
    final desc = _descFor(context, template);
    final created = _fmtCreated(context, template.createdAt);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => GoRouter.of(context).push('/ai-config/templates/${template.id}'),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        borderRadius: BorderRadius.circular(AppRadii.r18),
        backgroundColor: isUser ? AppColors.surfacePrimarySoft : AppColors.surface,
        borderColor: isUser ? AppColors.brandPrimary : AppColors.borderLight,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isUser ? AppColors.brandPrimary.withValues(alpha: 0.14) : AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadii.r14),
                border: Border.all(color: isUser ? AppColors.brandPrimary.withValues(alpha: 0.25) : AppColors.borderLight),
              ),
              child: Icon(icon, color: isUser ? AppColors.brandPrimary : AppColors.textSecondary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    template.name,
                    style: const TextStyle(fontSize: AppTypography.s14, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    created,
                    style: const TextStyle(color: AppColors.textPlaceholder, fontSize: AppTypography.s14, fontWeight: FontWeight.w400),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: const TextStyle(color: AppColors.textPlaceholder, fontSize: AppTypography.s14, fontWeight: FontWeight.w400),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: isUser ? AppColors.brandPrimary : AppColors.textPlaceholder,size: 28),
          ],
        ),
      ),
    );
  }
}

class _ImportWithKeyButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ImportWithKeyButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: SizedBox(
        height: 58,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.key_outlined, color: AppColors.textSecondary),
            const SizedBox(width: 12),
            Text(AppLocalizations.of(context)!.importWithKey, style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontWeight: FontWeight.w500,
          fontSize: AppTypography.s12,
        ),
      );
}

class _IconGrid extends StatelessWidget {
  final List<IconData> icons;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _IconGrid({required this.icons, required this.selectedIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: icons.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
      ),
      itemBuilder: (ctx, i) {
        final sel = i == selectedIndex;
        return InkWell(
          onTap: () => onSelect(i),
          borderRadius: BorderRadius.circular(AppRadii.r18),
          child: Container(
            decoration: BoxDecoration(
              color: sel ? AppColors.surfacePrimarySoft : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.r18),
              border: Border.all(color: sel ? AppColors.brandPrimary : Colors.transparent, width: 2),
            ),
            child: Center(
              child: Icon(icons[i], color: sel ? AppColors.brandPrimary : AppColors.textSecondary, size: 28),
            ),
          ),
        );
      },
    );
  }
}

class _SheetHeader extends StatelessWidget {
  final String title;
  final VoidCallback onClose;

  const _SheetHeader({required this.title, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: AppTypography.s18,
          color: AppColors.textPrimary,
        );

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Stack(
        children: [
          Positioned(
            right: 0,
            top: 0,
            child: InkWell(
              onTap: onClose,
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
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SizedBox(
              height: 32,
              child: Center(child: Text(title, style: titleStyle)),
            ),
          ),
        ],
      ),
    );
  }
}
class _DashedAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _DashedAction({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: CustomPaint(
        painter: _DashedRRectBorderPainter(
          color: AppColors.brandPrimary.withValues(alpha: 0.55),
          radius: AppRadii.r18,
          dash: 8,
          gap: 6,
          strokeWidth: 2,
        ),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.surfacePrimarySoft,
            borderRadius: BorderRadius.circular(AppRadii.r18),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: AppColors.brandPrimary),
              const SizedBox(width: 12),
              Text(label, style: const TextStyle(color: AppColors.brandPrimary, fontWeight: FontWeight.w500, fontSize: AppTypography.s16)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareKeyCard extends StatelessWidget {
  final String keyText;
  final VoidCallback onCopy;
  const _ShareKeyCard({required this.keyText, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surfacePrimarySoft,
        borderRadius: BorderRadius.circular(AppRadii.r18),
        border: Border.all(color: AppColors.brandPrimary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.templateKey, style: const TextStyle(color: AppColors.brandPrimary, fontWeight: FontWeight.w500, fontSize: AppTypography.s12, letterSpacing: 1.2)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  keyText,
                  style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600, fontSize: AppTypography.s14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              InkWell(
                onTap: onCopy,
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.copy, size: 18, color: AppColors.brandPrimary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DashedRRectBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double dash;
  final double gap;
  final double strokeWidth;

  const _DashedRRectBorderPainter({
    required this.color,
    required this.radius,
    required this.dash,
    required this.gap,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics().toList();
    for (final m in metrics) {
      var distance = 0.0;
      while (distance < m.length) {
        final len = math.min(dash, m.length - distance);
        final seg = m.extractPath(distance, distance + len);
        canvas.drawPath(seg, paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.radius != radius ||
        oldDelegate.dash != dash ||
        oldDelegate.gap != gap ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

String _fmtCreated(BuildContext context, DateTime dt) {
  final loc = Localizations.localeOf(context).toString();
  return DateFormat.yMMMd(loc).format(dt);
}

/// Allowed template icons (const for tree-shake). Must match _icons in _PromptTemplateCreatePageState.
const _templateIconSet = <IconData>[
  Icons.work_outline,
  Icons.favorite_border,
  Icons.menu_book_outlined,
  Icons.lightbulb_outline,
  Icons.home_outlined,
  Icons.music_note_outlined,
  Icons.fitness_center_outlined,
  Icons.flight_takeoff_outlined,
];

IconData _iconFor(PromptTemplate t) {
  if (t.iconCode != 0) {
    for (final id in _templateIconSet) {
      if (id.codePoint == t.iconCode) return id;
    }
  }
  // Fallback for old data before migration.
  return switch (t.name) {
    'Meeting Summary' => Icons.description_outlined,
    'Lecture Summary' => Icons.school_outlined,
    'Daily Dialogue' => Icons.chat_bubble_outline,
    _ => Icons.description_outlined,
  };
}

String _descFor(BuildContext context, PromptTemplate t) {
  final l10n = AppLocalizations.of(context)!;
  return switch (t.name) {
    'Meeting Summary' => l10n.promptTemplateSubtitleMeeting,
    'Lecture Summary' => l10n.promptTemplateSubtitleLecture,
    'Class Summary' => l10n.promptTemplateSubtitleClass,
    'Daily Dialogue' => l10n.promptTemplateSubtitleDailyDialogue,
    'Daily Conversation Summary' => l10n.promptTemplateSubtitleDailyConversation,
    _ => t.isDefault
        ? l10n.promptTemplateSubtitleCustomDefault
        : l10n.promptTemplateSubtitleCustomUser,
  };
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
