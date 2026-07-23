import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/asr_config_repository.dart';
import '../domain/ai_providers.dart';
import '../domain/stt_config.dart';
import '../domain/asr_vendor_config.dart';
import 'widgets/stt_config_editor_sheet.dart';
import 'ai_config_providers.dart';

class SttConfigsPage extends ConsumerStatefulWidget {
  const SttConfigsPage({super.key});

  @override
  ConsumerState<SttConfigsPage> createState() => _SttConfigsPageState();
}

class _SttConfigsPageState extends ConsumerState<SttConfigsPage> {
  final bool _editOrder = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ensureSttConfigsLoaded(ref, force: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncList = ref.watch(sttConfigsProvider);
    final primary = Theme.of(context).colorScheme.primary;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: AppColors.appBackground,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop()),
        title: Text(l10n.sttProviders),
        actions: [
          if (!_editOrder)
            IconButton(
              onPressed: () => _openEditor(context, null),
              icon: Icon(Icons.add, color: primary, size: 26),
              tooltip: l10n.addNewConfiguration,
            ),
        ],
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
                ),
                const SizedBox(height: 12),
                AppBlackPillButton(
                  label: l10n.retry,
                  onPressed: () async {
                    await ensureSttConfigsLoaded(ref, force: true);
                  },
                ),
              ],
            ),
          ),
        ),
        data: (items) {
          return RefreshIndicator(
            onRefresh: () async {
              await ensureSttConfigsLoaded(ref, force: true);
            },
            child: items.isEmpty
                ? LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: ConstrainedBox(
                          constraints:
                              BoxConstraints(minHeight: constraints.maxHeight),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _EmptyState(
                                title: l10n.noProvidersYet,
                                subtitle: l10n.addSttConfigSubtitle,
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 20),
                                child: AppBlackPillButton(
                                  label: l10n.addNewConfiguration,
                                  leading: const Icon(Icons.add,
                                      color: Colors.white),
                                  onPressed: () => _openEditor(context, null),
                                ),
                              ),
                              const SizedBox(height: 36),
                            ],
                          ),
                        ),
                      );
                    },
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.configuredFilesLabel,
                            style: const TextStyle(
                              fontSize: AppTypography.s12,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ReorderableListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                          buildDefaultDragHandles: false,
                          onReorder: (_, __) {},
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final c = items[i];
                            return Padding(
                              key: ValueKey(c.id),
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _ConfigCard(
                                title:
                                    '${c.name} · ${c.provider.labelFor(l10n)}',
                                leadingIcon: Icons.mic_none,
                                onTap: () => _openEditor(context, c),
                                trailing: _editOrder
                                    ? ReorderableDragStartListener(
                                        index: i,
                                        child: const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Icon(Icons.drag_handle,
                                              color: AppColors.textPlaceholder),
                                        ),
                                      )
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            onPressed: () => _deleteConfig(c),
                                            icon: const Icon(
                                                Icons.delete_outline,
                                                color:
                                                    AppColors.textPlaceholder),
                                            tooltip: l10n.delete,
                                          ),
                                          const Icon(Icons.chevron_right,
                                              color: AppColors.textPlaceholder,
                                              size: 28),
                                        ],
                                      ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, SttConfig? existing) async {
    SttConfig? toEdit = existing;
    final vendorId = existing?.asrRemoteVendorId;
    if (existing != null && vendorId != null) {
      try {
        final asrRepo = await ref.read(asrConfigRepositoryProvider.future);
        toEdit = await asrRepo.fetchVendorDetail(
                vendorId: vendorId, sortIndex: existing.sortIndex) ??
            existing;
      } catch (_) {
        toEdit = existing;
      }
    }
    if (!context.mounted) return;
    await showSttConfigEditorSheet(context, existing: toEdit);
    ref.invalidate(sttConfigsProvider);
  }

  Future<void> _deleteConfig(SttConfig config) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await AppDialogs.showDeleteConfirm(
      context,
      title: l10n.deleteConfigurationTitle,
      message: l10n.deleteConfigurationConfirm(config.name),
      deleteText: l10n.delete,
    );
    if (!ok) return;
    final asrRepo = await ref.read(asrConfigRepositoryProvider.future);
    final remoteId = config.asrRemoteVendorId;
    if (remoteId != null) {
      try {
        await asrRepo.deleteVendorFromRemote(vendorId: remoteId);
      } catch (err) {
        if (mounted) {
          final l = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.sttConfigDeleteFailed(err.toString()))),
          );
        }
      }
    }
    ref.invalidate(sttConfigsProvider);
  }
}

class _ConfigCard extends StatelessWidget {
  final String title;
  final IconData leadingIcon;
  final VoidCallback onTap;
  final Widget trailing;

  const _ConfigCard({
    required this.title,
    required this.leadingIcon,
    required this.onTap,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        borderRadius: BorderRadius.circular(AppRadii.r18),
        backgroundColor: AppColors.surface,
        borderColor: AppColors.borderLight,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surfacePrimarySoft,
                borderRadius: BorderRadius.circular(AppRadii.r14),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(leadingIcon, color: primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppTypography.s14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 80, 16, 16),
      child: Column(
        children: [
          const Icon(Icons.mic_none,
              size: 56, color: AppColors.textPlaceholder),
          const SizedBox(height: 12),
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textTertiary)),
        ],
      ),
    );
  }
}
