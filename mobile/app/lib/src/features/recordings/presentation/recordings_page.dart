import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_overlay_tap_dismiss.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_pill_chip.dart';
import '../../../core/widgets/app_dialogs.dart';
import '../../../core/widgets/app_sheet_action_buttons.dart';
import 'recordings_controller.dart';
import 'folders_providers.dart';
import '../data/folders_repository.dart';
import '../data/recordings_repository.dart';
import '../domain/folder.dart';
import '../domain/recording.dart';
import '../utils/recording_display_name.dart';
import '../../device/presentation/widgets/device_selector_dropdown.dart';
import '../../device/presentation/device_controller.dart';
import '../../device/presentation/wifi_transfer_controller.dart';
import 'widgets/fast_sync_wifi_sheet.dart';
import 'widgets/transfer_progress_banner.dart';
import 'transfer_sync_ui.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/validation/user_visible_name.dart';
import '../../../core/widgets/app_section_label.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/server_providers.dart';
import '../../../core/widgets/user_avatar_image.dart';
import '../../auth/presentation/login_landing_page.dart';
import '../../ai_config/presentation/ai_config_providers.dart';
import 'batch_transcribe_sheet.dart';
import 'transcribe_common.dart';
import 'transcription_task_controller.dart';
import '../../ai_config/domain/stt_config.dart';

class RecordingsPage extends ConsumerStatefulWidget {
  const RecordingsPage({super.key});

  @override
  ConsumerState<RecordingsPage> createState() => _RecordingsPageState();
}

enum _SortBy { createdAt, operationTime }

enum _SortOrder { desc, asc }

class _RecordingsPageState extends ConsumerState<RecordingsPage>
    with WidgetsBindingObserver {
  final _searchCtrl = TextEditingController();
  final _recordingsListScrollController = ScrollController();
  bool _selecting = false;
  final Set<String> _selectedIds = <String>{};
  bool _batchTranscribeRunning = false;
  int _batchTranscribeRunId = 0;
  bool _batchTranscribeBannerDismissed = false;
  final ValueNotifier<String> _batchTranscribeProgress = ValueNotifier('');
  static const double _kBatchActionBarHeight = 58;
  static const double _kBatchTranscribeBannerHeight = 100;
  _FilterScope _scope = const _FilterScope.all();

  /// Default: **newest first** (desc). In-memory [_mapToUi] uses the same; DB [RecordingsRepository.listPage]
  /// uses `created_at DESC`. Auto sync / resume matches: [RecordingsRepository.listTransfersToResume]
  /// `COALESCE(transfer_started_at, created_at) DESC` + [_resumeIncompleteTransfers].
  _SortBy _sortBy = _SortBy.createdAt;
  _SortOrder _sortOrder = _SortOrder.desc;
  final _sortButtonKey = GlobalKey();

  static const Duration _kAutoSyncCooldown = Duration(minutes: 5);
  static const String _kPrefSortBy = 'recordings_sort_by';
  static const String _kPrefSortOrder = 'recordings_sort_order';
  bool _autoSyncInFlight = false;
  int _lastVisibleScheduleMs = 0;
  Timer? _searchDebounce;

  /// Keeps the top transfer banner visible through brief BLE leg gaps (e.g. a
  /// clip shorter than one Opus slice: 0 B received, post-stop cancel/retry).
  static const Duration _kTransferBannerLinger = Duration(milliseconds: 1500);
  Recording? _transferBannerLingerRec;
  DateTime? _transferBannerLingerUntil;
  Timer? _transferBannerLingerTimer;
  Recording? _lastTransferringRecFromProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recordingsListScrollController.addListener(_onRecordingsScrollNearEnd);
    _searchCtrl.addListener(_onSearchTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoSyncDeviceIndex(force: false, showSnack: false);
      _loadSortPreference();
      ref.read(reconcileStuckTranscriptionJobsProvider);
    });
  }

  void _onRecordingsScrollNearEnd() {
    if (!_recordingsListScrollController.hasClients) return;
    final pos = _recordingsListScrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 280) {
      ref.read(recordingsListPagedNotifierProvider.notifier).loadMore();
    }
  }

  void _onSearchTextChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      ref
          .read(recordingsListPagedNotifierProvider.notifier)
          .refresh(searchQuery: _searchCtrl.text);
    });
  }

  Future<void> _loadSortPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final by = prefs.getString(_kPrefSortBy);
      final order = prefs.getString(_kPrefSortOrder);
      var changed = false;
      if (by == 'operationTime') {
        if (_sortBy != _SortBy.operationTime) {
          _sortBy = _SortBy.operationTime;
          changed = true;
        }
      }

      if (order == 'asc') {
        if (_sortOrder != _SortOrder.asc) {
          _sortOrder = _SortOrder.asc;
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    } catch (_) {
      // Ignore storage exception, keep default desc
    }
  }

  Future<void> _saveSortPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefSortBy,
          _sortBy == _SortBy.createdAt ? 'createdAt' : 'operationTime');
      await prefs.setString(
          _kPrefSortOrder, _sortOrder == _SortOrder.desc ? 'desc' : 'asc');
    } catch (_) {
      // Ignore storage exception
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounce?.cancel();
    _transferBannerLingerTimer?.cancel();
    _recordingsListScrollController.removeListener(_onRecordingsScrollNearEnd);
    _searchCtrl.removeListener(_onSearchTextChanged);
    _searchCtrl.dispose();
    _recordingsListScrollController.dispose();
    _batchTranscribeProgress.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeAutoSyncDeviceIndex(force: false, showSnack: false);
        bumpRecordingsLists(ref);
        ref.read(reconcileStuckTranscriptionJobsProvider);
      });
    }
  }

  void _scheduleTransferBannerLingerTick(DateTime until) {
    _transferBannerLingerTimer?.cancel();
    final ms = until.difference(DateTime.now()).inMilliseconds;
    if (ms <= 0) return;
    _transferBannerLingerTimer = Timer(Duration(milliseconds: ms + 20), () {
      if (mounted) setState(() {});
    });
  }

  /// Display-only: avoid banner hide/show when [filterTransferBanner] briefly
  /// returns null while the row is still `transferring` in SQLite.
  Recording? _resolveTransferBannerWithLinger({
    required Recording? filtered,
    required List<Recording> items,
  }) {
    final now = DateTime.now();

    if (filtered != null &&
        (filtered.transferState == 'transferring' ||
            filtered.transferState == 'merging')) {
      _transferBannerLingerTimer?.cancel();
      _transferBannerLingerTimer = null;
      _transferBannerLingerRec = filtered;
      _transferBannerLingerUntil = null;
      return filtered;
    }

    final held = _transferBannerLingerRec;
    if (held == null) return filtered;

    Recording? fresh;
    for (final r in items) {
      if (r.id == held.id) {
        fresh = r;
        break;
      }
    }
    if (fresh == null ||
        (fresh.transferState != 'transferring' &&
            fresh.transferState != 'merging')) {
      _transferBannerLingerRec = null;
      _transferBannerLingerUntil = null;
      _transferBannerLingerTimer?.cancel();
      _transferBannerLingerTimer = null;
      return filtered;
    }

    _transferBannerLingerUntil ??= now.add(_kTransferBannerLinger);
    if (now.isBefore(_transferBannerLingerUntil!)) {
      _scheduleTransferBannerLingerTick(_transferBannerLingerUntil!);
      return fresh;
    }

    _transferBannerLingerRec = null;
    _transferBannerLingerUntil = null;
    return filtered;
  }

  void _scheduleMaybeSyncWhenVisible() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastVisibleScheduleMs < 8000)
      return; // avoid scheduling too often
    _lastVisibleScheduleMs = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoSyncDeviceIndex(force: false, showSnack: false);
    });
  }

  Future<void> _maybeAutoSyncDeviceIndex({
    required bool force,
    required bool showSnack,
  }) async {
    if (!mounted) return;
    if (_autoSyncInFlight) return;

    final deviceState = ref.read(deviceControllerProvider);
    final conn = deviceState.connection;
    if (conn == null) return; // must be connected

    final deviceId = conn.device.remoteId.toString();

    // Guard: avoid syncing while any transfer is ongoing.
    if (!force) {
      try {
        final t = await ref.read(transferringBannerRecordingProvider.future);
        if (t != null) return;
      } catch (_) {
        // If provider is not ready, don't block; continue with cooldown gate.
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final key = 'device_index_last_sync_ms::$deviceId';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final last = prefs.getInt(key);
      if (last != null && (nowMs - last) < _kAutoSyncCooldown.inMilliseconds) {
        return;
      }
    }

    _autoSyncInFlight = true;
    try {
      final n = await ref
          .read(deviceControllerProvider.notifier)
          .syncDeviceFileIndex();
      await prefs.setInt(key, nowMs);
      if (showSnack && mounted) {
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.syncedFileEntriesCount(n))),
        );
      }
    } finally {
      _autoSyncInFlight = false;
    }
  }

  void _enterSelectMode({String? initialId}) {
    setState(() {
      _selecting = true;
      _selectedIds.clear();
      if (initialId != null) _selectedIds.add(initialId);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  Future<void> _openCreateFolderSheet() async {
    final repo = await ref.read(foldersRepositoryProvider.future);
    if (!mounted) return;
    final createdId = await showAppBottomSheet<String>(
      context,
      builder: (_) => _CreateFolderSheet(
        onCreate: (name, color, icon) async {
          return repo.create(
              name: name, color: color.toARGB32(), icon: icon.codePoint);
        },
      ),
    );
    if (createdId != null) {
      ref.invalidate(foldersListProvider);
    }
  }

  Future<void> _openFilterSheet() async {
    final picked = await showAppBottomSheet<_FilterScope>(
      context,
      builder: (_) => _FilterSortSheet(
        current: _scope,
        onTapCreateFolder: _openCreateFolderSheet,
        onRenameFolder: (id, currentName) async {
          final l10n = AppLocalizations.of(context)!;
          final repo = await ref.read(foldersRepositoryProvider.future);
          final next = await _showRenameDialog(
            title: l10n.renameFolder,
            initialValue: currentName,
            hintText: l10n.folderNameHint,
            maxNameLength: kFolderNameMaxLength,
          );
          if (next == null) return;
          final trimmed = next.trim();
          if (!isValidFolderName(trimmed)) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.folderNameInvalid)),
            );
            return;
          }
          await repo.rename(id: id, name: trimmed);
          ref.invalidate(foldersListProvider);
        },
        onDeleteFolder: (id) async {
          final l10n = AppLocalizations.of(context)!;
          final ok = await AppDialogs.showDeleteConfirm(
            context,
            title: l10n.deleteFolder,
            message: l10n.deleteFolderMessage,
            deleteText: l10n.delete,
          );
          if (!ok) return;
          final repo = await ref.read(foldersRepositoryProvider.future);
          await repo.deleteFolder(id: id);
          ref.invalidate(foldersListProvider);
          bumpRecordingsLists(ref);
          if (!mounted) return;
          if (_scope.kind == _FilterKind.folder && _scope.folderId == id) {
            setState(() => _scope = const _FilterScope.all());
          }
        },
      ),
    );
    if (!context.mounted) return;
    if (picked != null) setState(() => _scope = picked);
  }

  List<_RecordingUiItem> _applyScope(List<_RecordingUiItem> list) {
    switch (_scope.kind) {
      case _FilterKind.all:
        return list.where((e) => !e.isDeleted).toList();
      case _FilterKind.unclassified:
        return list.where((e) => !e.isDeleted && e.folderId == null).toList();
      case _FilterKind.recycleBin:
        return list.where((e) => e.isDeleted).toList();
      case _FilterKind.folder:
        return list
            .where((e) => !e.isDeleted && e.folderId == _scope.folderId)
            .toList();
    }
  }

  Future<void> _moveToRecycleBin(Set<String> ids) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await AppDialogs.showConfirm(
      context,
      title: l10n.moveToRecycleBin,
      message: l10n.moveToRecycleBinConfirm(ids.length),
      confirmText: l10n.move,
      cancelText: l10n.cancel,
    );
    if (!ok) return;
    final repo = await ref.read(recordingsRepositoryProvider.future);
    final device = ref.read(deviceControllerProvider.notifier);
    for (final id in ids) {
      // Stop BLE download for this row if it is the active transfer; otherwise
      // reconnect would still try to resume (until we exclude deleted rows).
      await device.cancelTransfer(id, errorCode: 'user_cancelled');
      await repo.moveToRecycleBin(id: id);
    }
    bumpRecordingsLists(ref, removedIds: ids);
    if (context.mounted) _exitSelectMode();
  }

  Future<void> _restoreFromRecycleBin(Set<String> ids) async {
    final repo = await ref.read(recordingsRepositoryProvider.future);
    for (final id in ids) {
      await repo.restoreFromRecycleBin(id: id);
    }
    bumpRecordingsLists(ref);
    if (context.mounted) _exitSelectMode();
  }

  Widget _buildBatchActionBar(AppLocalizations l10n) {
    if (_scope.kind == _FilterKind.recycleBin) {
      return _BatchActionBar(
        isInRecycleBin: true,
        onRestore: () => _restoreFromRecycleBin(_selectedIds),
      );
    }
    return _BatchActionBar(
      onGenerate: () {
        if (_selectedIds.length == 1) {
          final id = _selectedIds.first;
          _exitSelectMode();
          context.push('/recordings/$id');
        } else {
          _batchTranscribeSelections(_selectedIds);
        }
      },
      onMoveTo: () => _moveToFolder(_selectedIds),
      onRename: _selectedIds.length == 1
          ? () async {
              final id = _selectedIds.first;
              final repo = await ref.read(recordingsRepositoryProvider.future);
              final rec = await repo.getById(id);
              if (rec == null || !mounted) return;
              final title = resolveRecordingDisplayTitle(rec);
              await _renameRecording(rec.id, title);
            }
          : null,
      onDelete: () => _moveToRecycleBin(_selectedIds),
    );
  }

  Future<void> _batchTranscribeSelections(Set<String> ids) async {
    if (ids.isEmpty || !mounted) return;
    if (_batchTranscribeRunning) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.batchTranscribeAlreadyRunning)),
      );
      return;
    }
    final repo = await ref.read(recordingsRepositoryProvider.future);
    await ensureSttConfigsLoaded(ref);
    if (!mounted) return;
    final first = await repo.getById(ids.first);
    final sttList =
        ref.read(sttConfigsProvider).valueOrNull ?? const <SttConfig>[];
    SttConfig? initStt;
    if (first?.lastSttConfigId != null) {
      try {
        initStt = sttList.firstWhere((c) => c.id == first!.lastSttConfigId);
      } on StateError {
        initStt = null;
      }
    }
    final initSel = TranscribeSheetSelection(
      stt: initStt,
      language: (first?.lastLanguage ?? '').trim().isNotEmpty
          ? first!.lastLanguage!.trim()
          : 'Auto',
      autoSpeaker: first?.lastAutoSpeaker ?? true,
    );
    if (!mounted) return;
    if (!context.mounted) return;
    final sel = await showBatchTranscribeSheet(context, ref, initial: initSel);
    if (sel == null || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final list = ids.toList();
    final runId = ++_batchTranscribeRunId;
    _exitSelectMode();
    setState(() {
      _batchTranscribeRunning = true;
      _batchTranscribeBannerDismissed = false;
    });
    _batchTranscribeProgress.value =
        l10n.batchTranscribingFilesProgress(1, list.length);
    var ok = 0;
    var fail = 0;
    for (var i = 0; i < list.length; i++) {
      final id = list[i];
      if (!mounted) return;
      _batchTranscribeProgress.value =
          l10n.batchTranscribingFilesProgress(i + 1, list.length);
      final rec = await repo.getById(id);
      if (rec == null) {
        fail++;
        continue;
      }
      await repo.updateAiSelection(
        id: rec.id,
        sttConfigId: sel.stt?.id,
        language: sel.language,
        autoSpeaker: sel.autoSpeaker,
      );
      if (rec.transferState != 'done') {
        fail++;
        continue;
      }
      final lifecycleBusy = switch (rec.recordingState) {
        'recording' || 'stopping' || 'transferring' => true,
        _ => false,
      };
      if (lifecycleBusy) {
        fail++;
        continue;
      }
      final asrId = await repo.ensureAsrResultId(rec.id);
      if (asrId == null) {
        fail++;
        continue;
      }
      await repo.updateJobState(rec.id, 'queued');
      ref.invalidate(recordingByIdProvider(rec.id));
      bumpRecordingsLists(ref);
      final fresh = await repo.getById(id) ?? rec;
      final t =
          await ref.read(transcriptionTaskControllerProvider.notifier).run(
                recording: fresh,
                asrResultId: asrId,
                selection: sel,
                uiContext: context.mounted ? context : null,
                allowGatewayTimeoutRetry: false,
              );
      if (t != null) {
        await repo.updateJobState(rec.id, 'done');
        ok++;
      } else {
        fail++;
      }
      bumpRecordingsLists(ref);
    }
    if (mounted && runId == _batchTranscribeRunId) {
      setState(() => _batchTranscribeRunning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.batchTranscribeSummary(ok, fail))),
      );
    }
  }

  Future<void> _moveToFolder(Set<String> ids) async {
    final folders = await ref.read(foldersListProvider.future);
    if (!mounted) return;
    final picked = await showAppBottomSheet<String?>(
      context,
      builder: (_) => _FolderPickerSheet(folders: folders),
    );
    if (picked == null) return;
    final repo = await ref.read(recordingsRepositoryProvider.future);
    for (final id in ids) {
      await repo.moveToFolder(id: id, folderId: picked);
    }
    bumpRecordingsLists(ref);
    if (context.mounted) _exitSelectMode();
  }

  void _showSortPopup(BuildContext context) {
    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final buttonBox =
        _sortButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlayBox == null || buttonBox == null) return;
    final pos = buttonBox.localToGlobal(Offset.zero, ancestor: overlayBox);

    const popupWidth = 240.0;
    const margin = 8.0;
    final left = (pos.dx + buttonBox.size.width - popupWidth)
        .clamp(margin, overlayBox.size.width - popupWidth - margin);
    final top = pos.dy + buttonBox.size.height + 6;

    late OverlayEntry entry;
    void dismiss() {
      if (entry.mounted) entry.remove();
    }

    entry = OverlayEntry(
      builder: (_) => _SortPopup(
        position: Offset(left, top),
        sortBy: _sortBy,
        sortOrder: _sortOrder,
        onPick: (by, order) {
          setState(() {
            _sortBy = by;
            _sortOrder = order;
          });
          _saveSortPreference();
          dismiss();
        },
        onDismiss: dismiss,
      ),
    );
    overlay.insert(entry);
  }

  String _localizedScopeLabel(AppLocalizations l10n,
      [Map<String, Folder>? folderById]) {
    switch (_scope.kind) {
      case _FilterKind.all:
        return l10n.allFiles;
      case _FilterKind.unclassified:
        return l10n.unclassified;
      case _FilterKind.recycleBin:
        return l10n.recycleBin;
      case _FilterKind.folder:
        if (_scope.folderId != null && folderById != null) {
          final name = folderById[_scope.folderId!]?.name;
          if (name != null && name.isNotEmpty) return name;
        }
        return _scope.folderName ?? l10n.folders;
    }
  }

  String _localizedGroupLabel(AppLocalizations l10n, String raw) {
    switch (raw) {
      case 'TODAY':
        return l10n.today;
      case 'YESTERDAY':
        return l10n.yesterday;
      case 'EARLIER':
        return l10n.earlier;
      default:
        return raw;
    }
  }

  void _showItemActionPopup(
      BuildContext anchorContext, String recordingId, String recordingTitle,
      {required bool isInRecycleBin}) {
    final overlay = Overlay.of(anchorContext);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    if (overlayBox == null || anchorBox == null) return;
    final pos = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    const popupWidth = 220.0;
    const popupHeight = 220.0;
    const margin = 8.0;
    final bottomAvoid = MediaQuery.of(anchorContext).viewPadding.bottom + 72;
    final spaceBelow =
        overlayBox.size.height - (pos.dy + anchorBox.size.height) - bottomAvoid;
    final top = spaceBelow >= popupHeight
        ? pos.dy + anchorBox.size.height + 2
        : pos.dy - popupHeight - 2;
    final left = (pos.dx + anchorBox.size.width - popupWidth)
        .clamp(margin, overlayBox.size.width - popupWidth - margin);
    late OverlayEntry overlayEntry;
    overlayEntry = OverlayEntry(
      builder: (ctx) => _ItemActionPopup(
        position: Offset(left, top),
        isInRecycleBin: isInRecycleBin,
        onSelect: (action) async {
          overlayEntry.remove();
          if (action == _ItemAction.generate) {
            anchorContext.push('/recordings/$recordingId');
          } else if (action == _ItemAction.moveToFolder) {
            await _moveToFolder({recordingId});
          } else if (action == _ItemAction.rename) {
            await _renameRecording(recordingId, recordingTitle);
          } else if (action == _ItemAction.recycle) {
            await _moveToRecycleBin({recordingId});
          } else if (action == _ItemAction.restore) {
            await _restoreFromRecycleBin({recordingId});
          }
        },
        onDismiss: () => overlayEntry.remove(),
      ),
    );
    overlay.insert(overlayEntry);
  }

  Future<void> _renameRecording(String id, String currentName) async {
    final l10n = AppLocalizations.of(context)!;
    final repo = await ref.read(recordingsRepositoryProvider.future);
    final next = await _showRenameDialog(
      title: l10n.rename,
      initialValue: currentName,
      hintText: l10n.newName,
      maxNameLength: kUserVisibleNameMaxLength,
    );
    if (next == null) return;
    final trimmed = next.trim();
    if (!isValidUserVisibleName(trimmed)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.renameInvalid)),
      );
      return;
    }
    await repo.db.update(
      'recordings',
      {'name': trimmed, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(id));
    if (mounted) _exitSelectMode();
  }

  Future<String?> _showRenameDialog({
    required String title,
    required String initialValue,
    required String hintText,
    int? maxNameLength,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final ctrl = TextEditingController(
      text: maxNameLength == null
          ? initialValue
          : clipUserVisibleName(initialValue, max: maxNameLength),
    );
    final res = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (ctx) {
        return Dialog(
          backgroundColor: AppColors.surface,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.r18)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetHeader(
                  title: title,
                  onClose: () => Navigator.of(ctx).pop(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLines: 1,
                  inputFormatters: maxNameLength == null
                      ? null
                      : [
                          LengthLimitingTextInputFormatter(maxNameLength),
                        ],
                  decoration: _folderNameFieldDecoration(hintText: hintText),
                ),
                const SizedBox(height: 18),
                AppSheetActionButtons(
                  secondaryText: l10n.cancel,
                  onSecondary: () => Navigator.of(ctx).pop(),
                  primaryText: l10n.save,
                  onPrimary: () => Navigator.of(ctx).pop(ctrl.text.trim()),
                  compact: true,
                ),
              ],
            ),
          ),
        );
      },
    );
    return res;
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMaybeSyncWhenVisible();
    final l10n = AppLocalizations.of(context)!;

    final paged = ref.watch(recordingsListPagedNotifierProvider);
    final rowCountAsync = ref.watch(recordingsRowCountProvider);
    final transferringAsync = ref.watch(transferringBannerRecordingProvider);
    final cs = Theme.of(context).colorScheme;
    final foldersAsync = ref.watch(foldersListProvider);

    ref.listen<TransferCompletedEvent?>(transferCompletedEventProvider,
        (prev, next) {
      if (next == null || !next.success) return;
      bumpRecordingsLists(ref);
      void scrollTop() {
        if (!mounted) return;
        final c = _recordingsListScrollController;
        if (!c.hasClients) return;
        c.animateTo(
          0,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollTop();
        if (!mounted) return;
        if (!_recordingsListScrollController.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) => scrollTop());
        }
      });
    });

    late final Widget body;
    if (paged.isInitialLoading && paged.items.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (paged.errorMessage != null && paged.items.isEmpty) {
      body = Center(
          child: Text('${l10n.recordingsLoadFailed}：${paged.errorMessage}'));
    } else {
      final items = paged.items;
      final dbRowCount = rowCountAsync.valueOrNull ?? -1;
      final isDbEmpty = dbRowCount == 0;
      final folders =
          foldersAsync.maybeWhen(data: (v) => v, orElse: () => <Folder>[]);
      final folderMap = {for (final f in folders) f.id: f};
      final devUi = ref.watch(deviceControllerProvider);
      final activeRecSess =
          ref.read(deviceControllerProvider.notifier).activeRecordingSessionId;
      final wifi = ref.watch(wifiTransferControllerProvider);
      final transcriptionTasks = ref.watch(transcriptionTaskControllerProvider);
      final listAll = _mapToUi(
        items,
        folderMap,
        _sortBy,
        _sortOrder,
        l10n,
        devUi,
        activeRecSess,
        wifi,
        transcriptionTasks,
      );
      final query = _searchCtrl.text.trim().toLowerCase();
      // Search text is applied in SQL via [RecordingsListPagedNotifier.refresh].
      final filteredQuery = listAll;
      final filtered = _applyScope(filteredQuery);
      final grouped = _groupByDay(filtered, _sortBy, _sortOrder, l10n);
      final isNoResults = filtered.isEmpty;
      final showBatchActionBar = _selecting && _selectedIds.isNotEmpty;
      final showBatchTranscribeBanner =
          _batchTranscribeRunning && !_batchTranscribeBannerDismissed;
      final listBottomPadding = 24.0 +
          (showBatchActionBar ? _kBatchActionBarHeight + 8 : 0) +
          (showBatchTranscribeBanner ? _kBatchTranscribeBannerHeight + 16 : 0);
      final transferringRecRaw = transferringAsync.valueOrNull;
      if (transferringRecRaw != null) {
        _lastTransferringRecFromProvider = transferringRecRaw;
      } else if (_lastTransferringRecFromProvider != null &&
          _lastTransferringRecFromProvider!.transferState != 'transferring' &&
          _lastTransferringRecFromProvider!.transferState != 'merging') {
        _lastTransferringRecFromProvider = null;
      }
      final transferringRec =
          transferringRecRaw ?? _lastTransferringRecFromProvider;

      Recording? wifiBannerRec;
      final wifiId = wifi.recordingId;
      if (wifiId != null && wifi.isActive) {
        wifiBannerRec = ref.watch(recordingByIdProvider(wifiId)).valueOrNull;
      }
      // Fast Sync: DB may lag; Wi‑Fi controller may still be completed/failed before clear — linger
      // covers the gap when both go null in the same frame after a very fast sync.
      final fgDevId = devUi.connection?.device.remoteId.toString();
      Recording? topTransferBannerRec;
      if (devUi.firmwareAppearsRecordingOrPaused &&
          activeRecSess != null &&
          activeRecSess.trim().isNotEmpty &&
          fgDevId != null) {
        final liveBannerId = '${fgDevId}_${activeRecSess.trim()}';
        final liveBannerRec =
            ref.watch(recordingByIdProvider(liveBannerId)).valueOrNull;
        if (liveBannerRec != null &&
            liveBannerRec.transferState == 'transferring') {
          topTransferBannerRec = liveBannerRec;
        }
      }
      topTransferBannerRec ??= _pickForegroundTransferringRecording(
              items, fgDevId, devUi, activeRecSess) ??
          transferringRec ??
          wifiBannerRec;

      final hasDeviceForTransferUi = devUi.connection != null || wifi.isActive;
      final devCtrl = ref.read(deviceControllerProvider.notifier);
      Recording? filterTransferBanner(Recording? rec) {
        if (rec == null) return null;
        if (!transferRecordingBelongsToForegroundDevice(rec, fgDevId)) {
          return null;
        }
        final wifiForRow = wifi.isActive && wifi.recordingId == rec.id;
        return shouldShowTransferProgressUi(
          recording: rec,
          hasDeviceOrWifi: hasDeviceForTransferUi,
          foregroundDeviceId: fgDevId,
          activeTransferRecordingId: devUi.activeTransferRecordingId,
          isTransferRunning: devCtrl.isTransferRunningFor(rec.id),
          wifiActiveForRow: wifiForRow,
          liveRecordWhileBleTransfer: deviceLiveRecordWhileBleTransfer(
            rec,
            devUi,
            activeRecordingSessionId: activeRecSess,
          ),
        )
            ? rec
            : null;
      }

      topTransferBannerRec = _resolveTransferBannerWithLinger(
        filtered: filterTransferBanner(topTransferBannerRec),
        items: items,
      );

      body = SafeArea(
        child: Column(
          children: [
            if (_selecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.selectedCount(_selectedIds.length),
                        style: Theme.of(context)
                            .textTheme
                            .displaySmall
                            ?.copyWith(
                                fontWeight: FontWeight.w500,
                                fontSize: AppTypography.s18),
                      ),
                    ),
                    InkWell(
                      onTap: _exitSelectMode,
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(AppRadii.pill)),
                        child: Text(l10n.done,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: AppTypography.s14)),
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DeviceSelectorDropdown(),
                      ),
                    ),
                    InkWell(
                      onTap: () => context.push('/recordings/search'),
                      borderRadius: BorderRadius.zero,
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.search,
                            color: AppColors.textPrimary, size: 28),
                      ),
                    ),
                    const _RecordingsProfileAvatarButton(),
                  ],
                ),
              ),

            // Filter / sort row
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _openFilterSheet,
                      borderRadius: BorderRadius.circular(AppRadii.r12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 6),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                _localizedScopeLabel(l10n, folderMap),
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.w500,
                                      fontSize: AppTypography.s18,
                                      color: AppColors.textPrimary,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down,
                                color: AppColors.textSecondary),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    key: _sortButtonKey,
                    height: 44,
                    child: InkWell(
                      onTap: () => _showSortPopup(context),
                      borderRadius: BorderRadius.circular(AppRadii.r16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(AppRadii.r16),
                          border: Border.all(color: AppColors.borderLight),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _sortBy == _SortBy.createdAt
                                  ? l10n.createTime
                                  : l10n.operationTime,
                              style: const TextStyle(
                                fontSize: AppTypography.s14,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              _sortOrder == _SortOrder.desc
                                  ? Icons.arrow_downward_rounded
                                  : Icons.arrow_upward_rounded,
                              size: 18,
                              color: AppColors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            if (topTransferBannerRec != null && hasDeviceForTransferUi)
              RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Builder(
                    builder: (context) {
                      final bannerRec = topTransferBannerRec!;
                      return DeferredTransferResumeTicker(
                        recording: bannerRec,
                        hasDevice: hasDeviceForTransferUi,
                        child: TransferProgressBanner(
                          key: const ValueKey('recordings_transfer_banner'),
                          recording: bannerRec,
                          primary: cs.primary,
                          hasDevice: hasDeviceForTransferUi,
                          liveRecordWhileBleTransfer:
                              deviceLiveRecordWhileBleTransfer(
                            bannerRec,
                            devUi,
                            activeRecordingSessionId: activeRecSess,
                          ),
                          suppressResync:
                              shouldSuppressResyncWhileDeviceRecording(
                            bannerRec,
                            devUi,
                          ),
                          transferActiveForRecording:
                              (devUi.activeTransferRecordingId ?? '').trim() ==
                                  bannerRec.id.trim(),
                          liveWifi:
                              wifi.isActive && wifi.recordingId == bannerRec.id
                                  ? wifi
                                  : null,
                          useBleTransport: () {
                            final w = wifi;
                            final forThis = w.recordingId == bannerRec.id;
                            return !(forThis && w.isActive);
                          }(),
                          // Fast Sync: show when banner uses BLE, connected, and no other row holds BLE.
                          // While device records/pauses, tap shows sheet — button stays visible (see showFastSync).
                          onFastSync: () {
                            final d = ref.watch(deviceControllerProvider);
                            final w = wifi;
                            final aid = d.activeTransferRecordingId;
                            final forThis = bannerRec.id;
                            if (d.connection == null) {
                              return null;
                            }
                            if (aid != null && aid != forThis) {
                              return null;
                            }
                            final wifiBusy =
                                w.recordingId == bannerRec.id && w.isActive;
                            if (wifiBusy) {
                              return null;
                            }
                            return () {
                              final live = ref.read(deviceControllerProvider);
                              if (live.firmwareAppearsRecordingOrPaused) {
                                showDialog<void>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l10n.fastSync),
                                    content: Text(
                                      l10n.fastSyncUnavailableWhileRecording,
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(),
                                        child: Text(
                                          MaterialLocalizations.of(ctx)
                                              .okButtonLabel,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                return;
                              }
                              showModalBottomSheet<void>(
                                context: context,
                                isDismissible: true,
                                enableDrag: true,
                                useSafeArea: true,
                                builder: (ctx) => FastSyncWifiSheet(
                                  recording: bannerRec,
                                ),
                              );
                            };
                          }(),
                          onRetrySync: () async {
                            final ctrl =
                                ref.read(deviceControllerProvider.notifier);
                            bumpRecordingsLists(ref);
                            final result =
                                await ctrl.retryTransfer(bannerRec.id);
                            if (!context.mounted) return;
                            bumpRecordingsLists(ref);
                            switch (result) {
                              case RetryTransferResult.ok:
                                break;
                              case RetryTransferResult.notConnected:
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content:
                                          Text(l10n.connectDeviceToResync)),
                                );
                                break;
                              case RetryTransferResult
                                    .deviceRecordingOtherSession:
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n
                                        .resyncBlockedWhileRecordingOtherSession),
                                  ),
                                );
                                break;
                              case RetryTransferResult.couldNotStart:
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.resyncCouldNotStart),
                                  ),
                                );
                                break;
                              case RetryTransferResult.failed:
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(l10n.syncFailed)),
                                );
                                break;
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),

            // Only the list area is scrollable (no pull-to-refresh: auto sync on connect + invalidations elsewhere).
            Expanded(
              child: RepaintBoundary(
                child: isNoResults
                    ? LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: _EmptyState(
                                    icon: Icons.search_off,
                                    title: isDbEmpty && query.isEmpty
                                        ? l10n.noRecordingsYet
                                        : l10n.noResults,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      )
                    : ListView(
                        controller: _recordingsListScrollController,
                        cacheExtent: 500,
                        padding: EdgeInsets.only(bottom: listBottomPadding),
                        children: [
                          for (final group in grouped) ...[
                            AppSectionLabel(
                              _localizedGroupLabel(l10n, group.label),
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                            ),
                            ...group.items.map((it) {
                              final selected = _selectedIds.contains(it.id);
                              return Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: _RecordingCard(
                                  item: it,
                                  primary: cs.primary,
                                  topBannerRecordingId:
                                      topTransferBannerRec?.id,
                                  activeTransferRecordingId:
                                      devUi.activeTransferRecordingId,
                                  selecting: _selecting,
                                  selected: selected,
                                  onToggleSelected: () {
                                    setState(() {
                                      if (selected) {
                                        _selectedIds.remove(it.id);
                                      } else {
                                        _selectedIds.add(it.id);
                                      }
                                    });
                                  },
                                  onOpen: () {
                                    if (_selecting) {
                                      setState(() {
                                        if (selected) {
                                          _selectedIds.remove(it.id);
                                        } else {
                                          _selectedIds.add(it.id);
                                        }
                                      });
                                    } else {
                                      context.push('/recordings/${it.id}');
                                    }
                                  },
                                  onLongPress: () =>
                                      _enterSelectMode(initialId: it.id),
                                  onMore: (BuildContext ctx) =>
                                      _showItemActionPopup(ctx, it.id, it.title,
                                          isInRecycleBin: it.isDeleted),
                                  hasDevice: ref
                                          .watch(deviceControllerProvider)
                                          .connection !=
                                      null,
                                  onRetrySync: (recId) async {
                                    final ctrl = ref.read(
                                        deviceControllerProvider.notifier);
                                    bumpRecordingsLists(ref);
                                    final result =
                                        await ctrl.retryTransfer(recId);
                                    if (!context.mounted) return;
                                    bumpRecordingsLists(ref);
                                    switch (result) {
                                      case RetryTransferResult.ok:
                                        break;
                                      case RetryTransferResult.notConnected:
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                              content: Text(
                                                  l10n.connectDeviceToResync)),
                                        );
                                        break;
                                      case RetryTransferResult
                                            .deviceRecordingOtherSession:
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(l10n
                                                .resyncBlockedWhileRecordingOtherSession),
                                          ),
                                        );
                                        break;
                                      case RetryTransferResult.couldNotStart:
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content:
                                                Text(l10n.resyncCouldNotStart),
                                          ),
                                        );
                                        break;
                                      case RetryTransferResult.failed:
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                              content: Text(l10n.syncFailed)),
                                        );
                                        break;
                                    }
                                  },
                                ),
                              );
                            }),
                          ],
                          if (paged.isLoadingMore)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 18),
                              child: Center(
                                child: SizedBox(
                                  width: 26,
                                  height: 26,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: cs.primary,
                                  ),
                                ),
                              ),
                            ),
                          if (!paged.hasMore &&
                              filtered.isNotEmpty &&
                              !paged.isLoadingMore)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                              child: Text(
                                l10n.recordingsListEndHint,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppColors.textTertiary,
                                  fontSize: AppTypography.s12,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      );
    }

    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final showBatchActionBar = _selecting && _selectedIds.isNotEmpty;
    final showBatchTranscribeBanner =
        _batchTranscribeRunning && !_batchTranscribeBannerDismissed;
    final actionBarBottom = (bottomInset > 0 ? bottomInset : 12.0) +
        (showBatchTranscribeBanner ? _kBatchTranscribeBannerHeight + 8.0 : 0.0);

    return Scaffold(
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          if (_batchTranscribeRunning && !_batchTranscribeBannerDismissed)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: _BatchTranscribeFloatingBanner(
                message: _batchTranscribeProgress,
                hint: l10n.batchTranscribingFloatingHint,
                swipeHint: l10n.batchTranscribeSwipeToHide,
                onDismiss: () {
                  if (!mounted) return;
                  setState(() => _batchTranscribeBannerDismissed = true);
                },
              ),
            ),
          if (_batchTranscribeRunning && _batchTranscribeBannerDismissed)
            Positioned(
              right: 12,
              bottom: 20,
              child: _BatchTranscribeRestoreChip(
                tooltip: l10n.batchTranscribeShowProgress,
                onRestore: () {
                  if (!mounted) return;
                  setState(() => _batchTranscribeBannerDismissed = false);
                },
              ),
            ),
          if (showBatchActionBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: actionBarBottom,
              child: Material(
                color: AppColors.surface,
                elevation: 12,
                shadowColor: Colors.black.withValues(alpha: 0.08),
                child: SafeArea(
                  top: false,
                  child: _buildBatchActionBar(l10n),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // _openPlayerForItem removed (details page now handles this flow).
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  const _EmptyState({
    required this.icon,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 96, color: AppColors.gray200),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.textTertiary,
                    fontWeight: FontWeight.w500,
                    fontSize: AppTypography.s18,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingUiItem {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime operationTime;
  final Duration duration;
  final String tag;
  final _RecordingStatus status;
  final String transferState;
  final double? transferProgress; // 0..1
  final String? transferError;
  final String? transferErrorCode;
  final int?
      expectedBytes; // Only available after STOP, used to decide whether to show progress
  final int?
      receivedBytes; // Bytes received, used for display during record-while-sync
  final String?
      deviceId; // Device ID for device recording, used for manual sync
  final String? folderId;
  final bool isDeleted;
  final String source;

  /// Non-empty local file path means synced to local (for legacy data when transfer_state is not correctly done, still hide sync button)
  final String? localPath;

  /// Transcript excerpt for list subtitle (single line); null if no transcript.
  final String? transcriptPreview;

  /// `true` while the firmware is still recording this session (started but
  /// not yet STOP'd). Duration is unknown until STOP, so the row shows a
  /// "Recording…" label instead of a misleading `00:00`.
  final bool isLiveRecording;

  /// `true` only for the row that matches the active firmware record session
  /// while BLE is pulling it — use indeterminate sync UI (no %).
  final bool liveDeviceTransfer;

  /// Payload complete (BLE or Wi‑Fi); local opus parts are being merged into one file.
  final bool localMerging;

  const _RecordingUiItem({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.operationTime,
    required this.duration,
    required this.tag,
    required this.status,
    required this.transferState,
    required this.transferProgress,
    this.transferError,
    this.transferErrorCode,
    required this.expectedBytes,
    this.receivedBytes,
    this.deviceId,
    required this.folderId,
    required this.isDeleted,
    required this.source,
    this.localPath,
    this.transcriptPreview,
    this.isLiveRecording = false,
    this.liveDeviceTransfer = false,
    this.localMerging = false,
  });
}

enum _RecordingStatus {
  syncing,
  done,
  processing,
  notTranscribed,

  /// Device transfer / local merge failed (retry sync entry on row).
  failed,

  /// ASR job failed (`job_state == failed`).
  transcriptionFailed,

  /// Transfer/merge still in progress — hide the trailing status slot (top
  /// banner or inline sync line carries progress instead).
  none,
}

/// Maps the transcription [jobState] to a list-row status when the row is not
/// busy syncing/merging. `queued/transcribing/summarizing` are *active* work
/// (loading spinner); `none` means the user has not run transcription yet.
_RecordingStatus _recordingStatusFromJobState(String jobState) {
  switch (jobState.trim()) {
    case 'done':
      return _RecordingStatus.done;
    case 'queued':
    case 'transcribing':
    case 'summarizing':
      return _RecordingStatus.processing;
    case 'failed':
      return _RecordingStatus.transcriptionFailed;
    default:
      return _RecordingStatus.notTranscribed;
  }
}

class _GroupedItems {
  final String label;
  final List<_RecordingUiItem> items;

  const _GroupedItems(this.label, this.items);
}

/// Group by creation day (TODAY / YESTERDAY / EARLIER), within group sort by [sortBy]/[sortOrder], consistent with home page selection.
List<_GroupedItems> _groupByDay(
  List<_RecordingUiItem> items,
  _SortBy sortBy,
  _SortOrder sortOrder,
  AppLocalizations l10n,
) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));

  final todayItems = <_RecordingUiItem>[];
  final yesterdayItems = <_RecordingUiItem>[];
  final otherItems = <_RecordingUiItem>[];

  for (final it in items) {
    final base = sortBy == _SortBy.createdAt ? it.createdAt : it.operationTime;
    final d = DateTime(base.year, base.month, base.day);
    if (d == today) {
      todayItems.add(it);
    } else if (d == yesterday) {
      yesterdayItems.add(it);
    } else {
      otherItems.add(it);
    }
  }

  int compare(_RecordingUiItem a, _RecordingUiItem b) {
    final timeA = sortBy == _SortBy.createdAt ? a.createdAt : a.operationTime;
    final timeB = sortBy == _SortBy.createdAt ? b.createdAt : b.operationTime;
    final cmp = timeB.compareTo(timeA);
    if (cmp != 0) return sortOrder == _SortOrder.desc ? cmp : -cmp;
    return a.id.compareTo(b.id);
  }

  todayItems.sort(compare);
  yesterdayItems.sort(compare);
  otherItems.sort(compare);

  // Important: group display order must follow asc/desc sort, otherwise it looks unsorted
  final groups = <_GroupedItems>[];
  void addIfNotEmpty(String label, List<_RecordingUiItem> list) {
    if (list.isNotEmpty) groups.add(_GroupedItems(label, list));
  }

  if (sortOrder == _SortOrder.desc) {
    addIfNotEmpty(l10n.today, todayItems);
    addIfNotEmpty(l10n.yesterday, yesterdayItems);
    addIfNotEmpty(l10n.earlier, otherItems);
  } else {
    addIfNotEmpty(l10n.earlier, otherItems);
    addIfNotEmpty(l10n.yesterday, yesterdayItems);
    addIfNotEmpty(l10n.today, todayItems);
  }
  return groups;
}

class _SortPopup extends StatelessWidget {
  final Offset position;
  final _SortBy sortBy;
  final _SortOrder sortOrder;
  final void Function(_SortBy by, _SortOrder order) onPick;
  final VoidCallback onDismiss;

  const _SortPopup({
    required this.position,
    required this.sortBy,
    required this.sortOrder,
    required this.onPick,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppOverlayTapDismiss(
      onDismiss: onDismiss,
      child: Positioned(
        left: position.dx,
        top: position.dy,
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(AppRadii.r18),
          color: Colors.transparent,
          child: Container(
            width: 240,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.r18),
              border: Border.all(color: AppColors.borderLight),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SortRow(
                  label: l10n.createTime,
                  active: sortBy == _SortBy.createdAt,
                  order:
                      sortBy == _SortBy.createdAt ? sortOrder : _SortOrder.desc,
                  onPickBy: () => onPick(_SortBy.createdAt, sortOrder),
                  onPickAsc: () => onPick(_SortBy.createdAt, _SortOrder.asc),
                  onPickDesc: () => onPick(_SortBy.createdAt, _SortOrder.desc),
                ),
                const Divider(height: 1, thickness: 1, color: AppColors.border),
                _SortRow(
                  label: l10n.operationTime,
                  active: sortBy == _SortBy.operationTime,
                  order: sortBy == _SortBy.operationTime
                      ? sortOrder
                      : _SortOrder.desc,
                  onPickBy: () => onPick(_SortBy.operationTime, sortOrder),
                  onPickAsc: () =>
                      onPick(_SortBy.operationTime, _SortOrder.asc),
                  onPickDesc: () =>
                      onPick(_SortBy.operationTime, _SortOrder.desc),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SortRow extends StatelessWidget {
  final String label;
  final bool active;
  final _SortOrder order;
  final VoidCallback onPickBy;
  final VoidCallback onPickAsc;
  final VoidCallback onPickDesc;

  const _SortRow({
    required this.label,
    required this.active,
    required this.order,
    required this.onPickBy,
    required this.onPickAsc,
    required this.onPickDesc,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.textPrimary : AppColors.textSecondary;
    return InkWell(
      onTap: onPickBy,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                    fontSize: AppTypography.s14,
                    fontWeight: FontWeight.w500,
                    color: fg),
              ),
            ),
            _OrderToggle(
              selected: order,
              active: active,
              onAsc: onPickAsc,
              onDesc: onPickDesc,
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderToggle extends StatelessWidget {
  final _SortOrder selected;
  final bool active;
  final VoidCallback onAsc;
  final VoidCallback onDesc;

  const _OrderToggle({
    required this.selected,
    required this.active,
    required this.onAsc,
    required this.onDesc,
  });

  @override
  Widget build(BuildContext context) {
    Color bg(bool on) => on ? AppColors.surfacePrimarySoft : Colors.transparent;
    Color border(bool on) => on
        ? AppColors.brandPrimary.withValues(alpha: 0.22)
        : AppColors.borderLight;
    Color icon(bool on) =>
        on ? AppColors.brandPrimary : AppColors.textSecondary;

    final ascOn = active && selected == _SortOrder.asc;
    final descOn = active && selected == _SortOrder.desc;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadii.r12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onAsc,
            child: Container(
              width: 34,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg(ascOn),
                borderRadius: BorderRadius.circular(AppRadii.r10),
                border: Border.all(color: border(ascOn)),
              ),
              child: Icon(Icons.arrow_upward_rounded,
                  size: 16, color: icon(ascOn)),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: onDesc,
            child: Container(
              width: 34,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg(descOn),
                borderRadius: BorderRadius.circular(AppRadii.r10),
                border: Border.all(color: border(descOn)),
              ),
              child: Icon(Icons.arrow_downward_rounded,
                  size: 16, color: icon(descOn)),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// One-line transcript preview for the home/files list; [null] if none.
String? _transcriptListPreview(String? transcript) {
  final raw = transcript?.trim();
  if (raw == null || raw.isEmpty) return null;
  return raw.replaceAll(RegExp(r'\s+'), ' ');
}

/// Top transfer banner: hide when offline, done/failed, local merge, or sync
/// finished (100% / local merged file) with no in-flight BLE/Wi‑Fi leg.
bool shouldShowTransferProgressUi({
  required Recording recording,
  required bool hasDeviceOrWifi,
  String? foregroundDeviceId,
  required String? activeTransferRecordingId,
  required bool isTransferRunning,
  required bool wifiActiveForRow,
  bool liveRecordWhileBleTransfer = false,
}) {
  if (!hasDeviceOrWifi) return false;
  if (!transferRecordingBelongsToForegroundDevice(
      recording, foregroundDeviceId)) {
    return false;
  }
  if (recording.transferState == 'done' ||
      recording.transferState == 'failed') {
    return false;
  }
  // Local merge is a background processing phase. Keep it on the row itself
  // instead of occupying the global transfer banner.
  if (recording.transferState != 'transferring') return false;

  // Post-stop short clip (< one Opus slice): keep banner through BLE leg gaps
  // and provider reload frames until the first bytes land.
  if (recording.endedAt != null && (recording.receivedBytes ?? 0) <= 0) {
    return true;
  }

  // Download (byte payload) finished for this file: drop the banner right away
  // instead of lingering on the indeterminate "merging" animation (and the
  // hide/show strobe while the state flips transferring → merging). The list
  // row carries the "merging" label while the background merge runs.
  //
  // Skipped while bytes are still expected: record-while-transfer (cap unknown
  // or still moving on device) and active Wi‑Fi batches keep the banner. When a
  // genuine next file is pending it is a separate `transferring` row, so the
  // banner is re-picked for it rather than held open here.
  final transferActiveForRow = (isTransferRunning &&
          transferRecordingBelongsToForegroundDevice(
              recording, foregroundDeviceId)) ||
      (activeTransferRecordingId ?? '').trim() == recording.id.trim();
  if (transferUiDownloadCompletePendingMerge(
        recording: recording,
        liveRecordWhileBleTransfer: liveRecordWhileBleTransfer,
        wifiOwnsProgressForRecording: wifiActiveForRow,
        transferActiveForRecording: transferActiveForRow,
      ) ||
      (!wifiActiveForRow &&
          !liveRecordWhileBleTransfer &&
          !transferActiveForRow &&
          (recording.transferProgress ?? 0) >= 1.0)) {
    return false;
  }

  final fgInFlight = isTransferRunning &&
      transferRecordingBelongsToForegroundDevice(recording, foregroundDeviceId);
  final inFlight = fgInFlight ||
      (activeTransferRecordingId ?? '').trim() == recording.id.trim() ||
      wifiActiveForRow;
  // Keep visible while bytes are actively moving — DB progress can briefly hit 1.0
  // during merge/done writes and would otherwise strobe hide/show.
  if (inFlight) return true;

  final progress = recording.transferProgress ?? 0;
  if (progress >= 1.0) return false;

  final hasLocal = (recording.localPath ?? '').trim().isNotEmpty;
  if (hasLocal && progress >= 0.99) return false;

  return true;
}

Recording? _pickForegroundTransferringRecording(
  List<Recording> items,
  String? foregroundDeviceId,
  DeviceUiState deviceUi,
  String? activeRecordingSessionId,
) {
  final fg = (foregroundDeviceId ?? '').trim();
  if (fg.isEmpty) return null;
  // The row whose bytes are actually streaming right now (the controller's
  // `activeTransferRecordingId`) must own the banner — even if an OLDER,
  // still-`transferring` session sorts ahead of it. Otherwise, when a previous
  // recording is left incomplete and the user records + syncs a NEW one, the
  // banner sticks to the old "device recording / resume later" row while the
  // resume actually pulls the new session. Find the active streaming row in a
  // first pass so it always wins.
  final activeId = (deviceUi.activeTransferRecordingId ?? '').trim();
  if (activeId.isNotEmpty) {
    for (final r in items) {
      if (r.transferState != 'transferring') continue;
      if ((r.transferErrorCode ?? '') == 'user_cancelled') continue;
      if ((r.deviceId ?? '').trim() != fg) continue;
      if (r.id.trim() == activeId) return r;
    }
  }
  // No row is actively streaming: surface the first `transferring` row that
  // still needs bytes. Rows whose bytes are fully received (only the local
  // merge is pending) hand their UI to the list-row "merging" label, so the top
  // banner skips them and only falls back to a download-complete row when
  // nothing else is pending (then the banner is hidden anyway).
  Recording? downloadCompletePendingMerge;
  for (final r in items) {
    if (r.transferState != 'transferring') {
      continue;
    }
    if ((r.transferErrorCode ?? '') == 'user_cancelled') continue;
    if ((r.deviceId ?? '').trim() != fg) continue;
    final liveXfer = deviceLiveRecordWhileBleTransfer(
      r,
      deviceUi,
      activeRecordingSessionId: activeRecordingSessionId,
    );
    if (transferUiDownloadCompletePendingMerge(
      recording: r,
      liveRecordWhileBleTransfer: liveXfer,
    )) {
      downloadCompletePendingMerge ??= r;
      continue;
    }
    return r;
  }
  return downloadCompletePendingMerge;
}

bool _isLocalMergeFailureCode(String? code) {
  switch ((code ?? '').trim()) {
    case 'merge_failed':
    case 'no_valid_audio':
    case 'possibly_incomplete_transfer':
    case 'transfer_merged_missing_slice':
    case 'transfer_gap_missing_slices':
      return true;
    default:
      return false;
  }
}

bool _isRetryableTransferRecoveryCode(String? code) {
  switch ((code ?? '').trim()) {
    case 'device_disconnected_resume':
    case 'device_disconnected_resume_after_reconnect':
    case 'transfer_incomplete_resume':
    case 'stalled_no_data_3min':
    case 'device_recording_resume_later':
    case 'possibly_incomplete_transfer':
    case 'transfer_merged_missing_slice':
    case 'transfer_gap_missing_slices':
    case 'merge_failed':
    case 'no_valid_audio':
      return true;
    default:
      return false;
  }
}

/// Recovery codes that mean "controller will auto-retry" — not a user action.
/// Showing the list sync icon for these causes appear/disappear flicker on
/// short iOS clips (STOP → resume_later → download clears → stall → resume…).
bool _isAutoRetryTransferRecoveryCode(String? code) {
  switch ((code ?? '').trim()) {
    case 'device_recording_resume_later':
    case 'stalled_no_data_3min':
    case 'transfer_incomplete_resume':
    case 'device_disconnected_resume':
    case 'device_disconnected_resume_after_reconnect':
      return true;
    default:
      return false;
  }
}

bool _shouldShowItemRetrySync(
  _RecordingUiItem item, {
  String? activeTransferRecordingId,
  String? topBannerRecordingId,
}) {
  if (item.source != 'device') return false;
  if (item.transferState == 'done' || item.transferState == 'merging') {
    return false;
  }
  if (item.localMerging || item.liveDeviceTransfer) return false;
  // In-flight BLE leg or top banner already owns recovery UI for this row.
  final activeId = (activeTransferRecordingId ?? '').trim();
  if (activeId.isNotEmpty && activeId == item.id.trim()) return false;
  final bannerId = (topBannerRecordingId ?? '').trim();
  if (bannerId.isNotEmpty && bannerId == item.id.trim()) return false;

  if (item.transferState == 'not_started' || item.transferState == 'failed') {
    return true;
  }
  if (item.transferState == 'transferring') {
    final code = item.transferErrorCode;
    if (!_isRetryableTransferRecoveryCode(code)) return false;
    // Keep list passive while the automatic resume pipeline owns the row.
    if (_isAutoRetryTransferRecoveryCode(code)) return false;
    return true;
  }
  return false;
}

List<_RecordingUiItem> _mapToUi(
  List<Recording> items,
  Map<String, Folder> folderById,
  _SortBy sortBy,
  _SortOrder sortOrder,
  AppLocalizations l10n,
  DeviceUiState deviceUi,
  String? activeRecordingSessionId,
  WifiTransferState wifi,
  TranscriptionTaskState transcriptionTasks,
) {
  final list = <_RecordingUiItem>[];
  for (final r in items) {
    // Device recording: prefer parsing from devicePath (firmware uses UTC, convert to local), avoid wrong display of old UTC data in DB
    DateTime displayTime = r.startedAt ?? r.createdAt ?? DateTime.now();
    if (r.source == 'device' && r.devicePath.isNotEmpty) {
      final parsed = parseSessionTimestamp(r.devicePath);
      if (parsed != null) displayTime = parsed;
    }
    final operationTime = r.updatedAt;
    final title = resolveRecordingDisplayTitle(r);
    final durSec = r.durationSeconds ?? 0;
    final transferState = r.transferState;
    final activeRecSess = activeRecordingSessionId;
    final liveDeviceXfer = deviceLiveRecordWhileBleTransfer(
      r,
      deviceUi,
      activeRecordingSessionId: activeRecSess,
    );
    // Align list % with TransferProgressBanner: known total → received/expected; else DB slice progress.
    // Live record / post-stop catch-up: no percentage — indeterminate until DB reflects payload.
    final wifiOwnsRow = wifi.isActive && wifi.recordingId == r.id;
    // Controller still has an in-flight BLE leg for this row: never let a
    // transient `received` overshoot (resume re-pull) collapse the row into the
    // "merging" label — keep showing transfer progress until the leg actually ends.
    final transferActiveForRow =
        (deviceUi.activeTransferRecordingId ?? '').trim() == r.id.trim();
    var transferProgress = transferProgressForDisplay(
      recording: r,
      liveRecordWhileBleTransfer: liveDeviceXfer,
      wifiOwnsProgressForRecording: wifiOwnsRow,
      transferActiveForRecording: transferActiveForRow,
    );
    final wifiMerging =
        wifiOwnsRow && wifi.phase == WifiTransferPhase.mergingFiles;
    final localMerging = wifiMerging ||
        transferUiLocalMergePhase(
          recording: r,
          liveRecordWhileBleTransfer: liveDeviceXfer,
          wifiOwnsProgressForRecording: wifiOwnsRow,
          transferActiveForRecording: transferActiveForRow,
        );
    if (localMerging) {
      transferProgress = null;
    }
    final localMergeFailure = _isLocalMergeFailureCode(r.transferErrorCode) &&
        transferState != 'done';
    final transferIncomplete = transferState == 'transferring' ||
        transferState == 'merging' ||
        localMerging;
    var status = transferIncomplete
        ? _RecordingStatus.none
        : transferState == 'failed' || localMergeFailure
            ? _RecordingStatus.failed
            : _recordingStatusFromJobState(r.jobState);
    if (!transferIncomplete &&
        status != _RecordingStatus.processing &&
        transcriptionTasks.isActive(r.id)) {
      status = _RecordingStatus.processing;
    }

    final folderName = r.folderId == null
        ? l10n.unclassified
        : (folderById[r.folderId!]?.name ?? l10n.folder);

    // Only the row matching the active firmware session shows "Recording…".
    final isLiveRecording = r.source == 'device' &&
        r.endedAt == null &&
        deviceUi.firmwareAppearsRecordingOrPaused &&
        recordingMatchesFirmwareSession(r, activeRecSess);

    list.add(
      _RecordingUiItem(
        id: r.id,
        title: title,
        createdAt: displayTime,
        operationTime: operationTime,
        duration: Duration(seconds: durSec),
        tag: folderName,
        status: status,
        transferState: transferState,
        transferProgress: transferProgress,
        transferError: r.transferError,
        transferErrorCode: r.transferErrorCode,
        expectedBytes: r.expectedBytes,
        receivedBytes: r.receivedBytes,
        deviceId: r.deviceId,
        folderId: r.folderId,
        isDeleted: r.isDeleted,
        source: r.source,
        localPath: r.localPath,
        transcriptPreview: _transcriptListPreview(r.transcript),
        isLiveRecording: isLiveRecording,
        liveDeviceTransfer: liveDeviceXfer,
        localMerging: localMerging,
      ),
    );
  }

  list.sort((a, b) {
    final timeA = sortBy == _SortBy.createdAt ? a.createdAt : a.operationTime;
    final timeB = sortBy == _SortBy.createdAt ? b.createdAt : b.operationTime;
    final cmp = timeB.compareTo(timeA);
    if (cmp != 0) {
      return sortOrder == _SortOrder.desc ? cmp : -cmp;
    }
    return a.id.compareTo(b.id);
  });
  return list;
}

class _RecordingCard extends StatelessWidget {
  final _RecordingUiItem item;
  final Color primary;
  final VoidCallback onOpen;
  final VoidCallback? onLongPress;
  final void Function(BuildContext)? onMore;
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggleSelected;

  /// Whether device is connected (for manual sync button enabled state)
  final bool hasDevice;

  /// Manual sync callback; button only shown when not synced (transferState != 'done' and no localPath)
  final Future<void> Function(String recordingId)? onRetrySync;

  /// When non-null and equal to [item.id], the list row skips detailed sync % / bytes — the top
  /// [TransferProgressBanner] already shows progress for this recording (BLE → Wi‑Fi is one flow).
  final String? topBannerRecordingId;

  /// Foreground BLE transfer id from [DeviceUiState.activeTransferRecordingId].
  final String? activeTransferRecordingId;

  const _RecordingCard({
    required this.item,
    required this.primary,
    required this.onOpen,
    this.onLongPress,
    this.onMore,
    this.selecting = false,
    this.selected = false,
    this.onToggleSelected,
    this.hasDevice = false,
    this.onRetrySync,
    this.topBannerRecordingId,
    this.activeTransferRecordingId,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final transferUiDelegatedToTopBanner =
        topBannerRecordingId != null && topBannerRecordingId == item.id;
    final syncLooksComplete = (item.transferProgress ?? 0) >= 1.0 ||
        ((item.localPath ?? '').trim().isNotEmpty &&
            (item.transferProgress ?? 0) >= 0.99);
    final syncPresentation = resolveTransferSyncStatusForListItem(
      transferState: item.transferState,
      transferProgress: item.transferProgress,
      receivedBytes: item.receivedBytes,
      expectedBytes: item.expectedBytes,
      liveDeviceTransfer: item.liveDeviceTransfer,
      localMerging: item.localMerging,
    );
    final showInlineMerge =
        item.localMerging && !transferUiDelegatedToTopBanner;
    final showInlineSync = showInlineMerge ||
        (hasDevice &&
            !transferUiDelegatedToTopBanner &&
            !syncLooksComplete &&
            (item.transferState == 'transferring' ||
                item.transferState == 'merging' ||
                item.localMerging));
    final inlineStatusLabel = syncPresentation.statusLabel(l10n);
    final titleStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
          fontSize: AppTypography.s16,
        );
    final metaStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: AppColors.textSecondary,
          fontSize: AppTypography.s14,
        );
    return InkWell(
      onTap: onOpen,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: AppCard(
        padding: const EdgeInsets.all(16),
        borderRadius: BorderRadius.circular(AppRadii.r18),
        backgroundColor: AppColors.surface,
        borderColor: AppColors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    style: titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (selecting)
                  InkWell(
                    onTap: onToggleSelected,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: selected ? Colors.black : AppColors.gray200,
                        size: 28,
                      ),
                    ),
                  )
                else if (onMore != null)
                  Builder(
                    builder: (ctx) {
                      return InkWell(
                        onTap: () {
                          onMore!(ctx);
                        },
                        borderRadius: BorderRadius.circular(AppRadii.r18),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.more_horiz,
                              color: AppColors.textTertiary),
                        ),
                      );
                    },
                  ),
              ],
            ),
            // const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.transcriptPreview != null) ...[
                        Text(
                          item.transcriptPreview!,
                          style: metaStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                      ],
                      // Recording time and duration: ensure always visible.
                      // While the firmware is still recording this session,
                      // the duration is unknown (`0:00` would be misleading);
                      // show a status label instead.
                      Text(
                        item.isLiveRecording
                            ? '${_formatDateTime(item.createdAt)}  •  ${l10n.deviceRecording}'
                            : '${_formatDateTime(item.createdAt)}  •  ${_formatDuration(item.duration)}',
                        style: metaStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (showInlineSync) ...[
                        const SizedBox(height: 2),
                        Text(
                          inlineStatusLabel,
                          style: metaStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Retry is an error-recovery entry. Healthy transfers and
                // local merge stay passive to avoid accidental restart.
                if (onRetrySync != null &&
                    _shouldShowItemRetrySync(
                      item,
                      activeTransferRecordingId: activeTransferRecordingId,
                      topBannerRecordingId: topBannerRecordingId,
                    ))
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: InkWell(
                      onTap: () async {
                        if (!hasDevice) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                AppLocalizations.of(context)!
                                    .connectDeviceToResync,
                              ),
                            ),
                          );
                          return;
                        }
                        await onRetrySync!(item.id);
                      },
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.sync,
                          size: 20,
                          color: hasDevice ? primary : AppColors.textTertiary,
                        ),
                      ),
                    ),
                  ),
                _StatusIcon(
                  status: item.status,
                  primary: primary,
                  // Only show check when transcript done; show spinner for syncing/processing
                  syncingNearComplete: false,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _TagChip(label: item.tag, primary: primary),
          ],
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  final Color primary;

  const _TagChip({required this.label, required this.primary});

  @override
  Widget build(BuildContext context) {
    final isGreen = label.toLowerCase() == 'test1';
    final maxWidth = MediaQuery.sizeOf(context).width - 64;
    return AppPillChip(
      label: label,
      icon: Icons.folder_outlined,
      maxWidth: maxWidth,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      backgroundColor:
          isGreen ? primary.withValues(alpha: 0.12) : AppColors.surfaceMuted,
      borderColor:
          isGreen ? primary.withValues(alpha: 0.18) : AppColors.borderStrong,
      foregroundColor: isGreen ? primary : AppColors.textSecondary,
      textStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isGreen ? primary : AppColors.textSecondary,
            fontSize: AppTypography.s12,
            // fontWeight: FontWeight.w500,
          ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final _RecordingStatus status;
  final Color primary;

  /// Deprecated: only show check when transcript done (jobState==done), no longer show check for sync complete
  final bool syncingNearComplete;

  const _StatusIcon({
    required this.status,
    required this.primary,
    this.syncingNearComplete = false,
  });

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case _RecordingStatus.syncing:
        return SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 2.6, color: primary.withValues(alpha: 0.75)),
        );
      case _RecordingStatus.done:
        return Icon(Icons.check_circle, color: primary, size: 22);
      case _RecordingStatus.processing:
        return SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.6, color: primary),
        );
      case _RecordingStatus.notTranscribed:
        return Text(
          AppLocalizations.of(context)!.notTranscribed,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textTertiary,
                fontSize: AppTypography.s12,
              ),
        );
      case _RecordingStatus.transcriptionFailed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: AppColors.dangerStrong,
              size: 18,
            ),
            const SizedBox(width: 4),
            Text(
              AppLocalizations.of(context)!.transcriptionFailedShort,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.dangerStrong,
                    fontSize: AppTypography.s12,
                  ),
            ),
          ],
        );
      case _RecordingStatus.failed:
        return const SizedBox(width: 22, height: 22);
      case _RecordingStatus.none:
        return const SizedBox.shrink();
    }
  }
}

String _formatDateTime(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

String _formatDuration(Duration d) {
  final total = d.inSeconds.abs();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0)
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

enum _ItemAction { generate, moveToFolder, rename, recycle, restore }

class _ItemActionPopup extends StatelessWidget {
  final Offset position;
  final bool isInRecycleBin;
  final void Function(_ItemAction) onSelect;
  final VoidCallback onDismiss;
  const _ItemActionPopup({
    required this.position,
    required this.onSelect,
    required this.onDismiss,
    this.isInRecycleBin = false,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppOverlayTapDismiss(
      onDismiss: onDismiss,
      child: Positioned(
        top: position.dy,
        left: position.dx,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(AppRadii.r18),
          child: Container(
            width: 220,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.r18),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: isInRecycleBin
                  ? [
                      _ActionOption(
                        icon: Icons.restore_outlined,
                        label: l10n.restoreFromRecycleBin,
                        color: AppColors.brandPrimary,
                        onTap: () => onSelect(_ItemAction.restore),
                      ),
                    ]
                  : [
                      _ActionOption(
                        icon: Icons.auto_awesome_outlined,
                        label: l10n.generateAiSummary,
                        color: AppColors.brandPrimary,
                        onTap: () => onSelect(_ItemAction.generate),
                      ),
                      const Divider(
                          height: 1, thickness: 1, color: AppColors.border),
                      _ActionOption(
                        icon: Icons.folder_open_outlined,
                        label: l10n.moveToFolder,
                        color: AppColors.brandPrimary,
                        onTap: () => onSelect(_ItemAction.moveToFolder),
                      ),
                      const Divider(
                          height: 1, thickness: 1, color: AppColors.border),
                      _ActionOption(
                        icon: Icons.edit_outlined,
                        label: l10n.rename,
                        color: AppColors.brandPrimary,
                        onTap: () => onSelect(_ItemAction.rename),
                      ),
                      const Divider(
                          height: 1, thickness: 1, color: AppColors.border),
                      _ActionOption(
                        icon: Icons.delete_outline,
                        label: l10n.moveToRecycleBin,
                        color: AppColors.dangerStrong,
                        onTap: () => onSelect(_ItemAction.recycle),
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionOption(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: label.contains('Recycle')
                          ? AppColors.dangerStrong
                          : AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s14,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchTranscribeFloatingBanner extends StatefulWidget {
  final ValueNotifier<String> message;
  final String hint;
  final String swipeHint;
  final VoidCallback onDismiss;

  const _BatchTranscribeFloatingBanner({
    required this.message,
    required this.hint,
    required this.swipeHint,
    required this.onDismiss,
  });

  @override
  State<_BatchTranscribeFloatingBanner> createState() =>
      _BatchTranscribeFloatingBannerState();
}

class _BatchTranscribeFloatingBannerState
    extends State<_BatchTranscribeFloatingBanner>
    with SingleTickerProviderStateMixin {
  static const Duration _kDismissAnim = Duration(milliseconds: 220);

  double _dragX = 0;
  late final AnimationController _dismissController;
  double _dismissDirection = 0;

  @override
  void initState() {
    super.initState();
    _dismissController = AnimationController(
      vsync: this,
      duration: _kDismissAnim,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          widget.onDismiss();
        }
      });
  }

  @override
  void dispose() {
    _dismissController.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dismissController.isAnimating) return;
    setState(() => _dragX += details.delta.dx);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_dismissController.isAnimating) return;
    final width = context.size?.width ?? 320;
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dragX.abs() > width * 0.28 || velocity.abs() > 650;
    if (shouldDismiss) {
      _dismissDirection = (_dragX != 0 ? _dragX : velocity).sign.toDouble();
      if (_dismissDirection == 0) _dismissDirection = 1;
      _dismissController.forward(from: 0);
    } else {
      setState(() => _dragX = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _dismissController,
      builder: (context, child) {
        final width = MediaQuery.sizeOf(context).width - 32;
        final dismissOffset =
            _dismissDirection * width * 1.15 * _dismissController.value;
        return Transform.translate(
          offset: Offset(_dragX + dismissOffset, 0),
          child: child,
        );
      },
      child: GestureDetector(
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        child: Material(
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadii.r18),
          color: AppColors.surface,
          child: ValueListenableBuilder<String>(
            valueListenable: widget.message,
            builder: (context, msg, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.borderLight,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(AppRadii.r18),
                    ),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      backgroundColor: AppColors.borderLight,
                      color: primary,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.25,
                              color: primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                msg,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      height: 1.3,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                widget.hint,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: AppColors.textSecondary,
                                      height: 1.35,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.swipeHint,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: AppColors.textTertiary,
                                      fontSize: AppTypography.s12,
                                      height: 1.35,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _BatchTranscribeRestoreChip extends StatelessWidget {
  final String tooltip;
  final VoidCallback onRestore;

  const _BatchTranscribeRestoreChip({
    required this.tooltip,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Material(
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        color: primary,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: InkWell(
          onTap: onRestore,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.text_snippet_outlined,
                    color: Colors.white, size: 18),
                const SizedBox(width: 6),
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withValues(alpha: 0.95),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchActionBar extends StatelessWidget {
  final bool isInRecycleBin;
  final VoidCallback? onGenerate;
  final VoidCallback? onMoveTo;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onRestore;

  const _BatchActionBar({
    this.isInRecycleBin = false,
    this.onGenerate,
    this.onMoveTo,
    this.onRename,
    this.onDelete,
    this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget item(IconData icon, String label, VoidCallback? onTap,
        {Color? color}) {
      final enabled = onTap != null;
      final c = enabled
          ? (color ?? AppColors.textTertiary)
          : AppColors.textTertiary.withValues(alpha: 0.45);
      final iconColor = enabled
          ? AppColors.brandPrimary
          : AppColors.brandPrimary.withValues(alpha: 0.35);
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.r12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      color: c, fontWeight: FontWeight.w600, fontSize: 12)),
            ],
          ),
        ),
      );
    }

    if (isInRecycleBin && onRestore != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            item(Icons.restore_outlined, l10n.restoreFromRecycleBin, onRestore,
                color: AppColors.brandPrimary),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          item(Icons.auto_awesome, l10n.generate, onGenerate,
              color: AppColors.textTertiary),
          item(Icons.drive_file_move_outlined, l10n.moveTo, onMoveTo,
              color: AppColors.textTertiary),
          item(Icons.edit_outlined, l10n.rename, onRename,
              color: AppColors.textTertiary),
          item(Icons.delete_outline, l10n.delete, onDelete,
              color: AppColors.dangerStrong),
        ],
      ),
    );
  }
}

enum _FilterKind { all, unclassified, recycleBin, folder }

class _FilterScope {
  final _FilterKind kind;
  final String? folderId;
  final String? folderName;

  const _FilterScope._(this.kind, {this.folderId, this.folderName});

  const _FilterScope.all() : this._(_FilterKind.all);

  const _FilterScope.unclassified() : this._(_FilterKind.unclassified);

  const _FilterScope.recycleBin() : this._(_FilterKind.recycleBin);

  const _FilterScope.folder(String id, String name)
      : this._(_FilterKind.folder, folderId: id, folderName: name);

  String get label {
    switch (kind) {
      case _FilterKind.all:
        return 'All';
      case _FilterKind.unclassified:
        return 'Unclassified';
      case _FilterKind.recycleBin:
        return 'Recycle Bin';
      case _FilterKind.folder:
        return folderName ?? 'Folder';
    }
  }
}

class _FilterSortSheet extends ConsumerWidget {
  final _FilterScope current;
  final VoidCallback onTapCreateFolder;
  final Future<void> Function(String folderId, String currentName)
      onRenameFolder;
  final Future<void> Function(String folderId) onDeleteFolder;

  const _FilterSortSheet({
    required this.current,
    required this.onTapCreateFolder,
    required this.onRenameFolder,
    required this.onDeleteFolder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final countsAsync = ref.watch(recordingsFilterCountsProvider);
    final foldersAsync = ref.watch(foldersListProvider);
    final cs = Theme.of(context).colorScheme;

    return countsAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator(color: cs.primary)),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text('$e'),
      ),
      data: (counts) {
        final folders =
            foldersAsync.maybeWhen(data: (v) => v, orElse: () => <Folder>[]);
        int countFolder(String id) => counts.perFolderId[id] ?? 0;
        return SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SheetHeader(
                  title: l10n.filterSort,
                  onClose: () => Navigator.of(context).pop(),
                ),
                const SizedBox(height: 8),
                _FilterRow(
                  icon: Icons.folder_outlined,
                  label: l10n.allFiles,
                  count: counts.allActive,
                  selected: current.kind == _FilterKind.all,
                  onTap: () =>
                      Navigator.of(context).pop(const _FilterScope.all()),
                ),
                const SizedBox(height: 6),
                _FilterRow(
                  icon: Icons.category_outlined,
                  label: l10n.unclassified,
                  count: counts.unclassified,
                  selected: current.kind == _FilterKind.unclassified,
                  onTap: () => Navigator.of(context)
                      .pop(const _FilterScope.unclassified()),
                ),
                const SizedBox(height: 6),
                _FilterRow(
                  icon: Icons.delete_outline,
                  label: l10n.recycleBin,
                  count: counts.recycle,
                  selected: current.kind == _FilterKind.recycleBin,
                  onTap: () => Navigator.of(context)
                      .pop(const _FilterScope.recycleBin()),
                ),
                const SizedBox(height: 6),
                const Divider(height: 24, color: AppColors.borderLight),
                Row(
                  children: [
                    Text(l10n.folders,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: AppTypography.s14,
                            color: AppColors.textSecondary)),
                    const Spacer(),
                    IconButton(
                        onPressed: onTapCreateFolder,
                        icon: const Icon(Icons.add,
                            size: 24, color: AppColors.textPrimary)),
                  ],
                ),
                for (var i = 0; i < folders.length; i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  _FolderRow(
                    folder: folders[i],
                    count: countFolder(folders[i].id),
                    selected: current.kind == _FilterKind.folder &&
                        current.folderId == folders[i].id,
                    onTap: () => Navigator.of(context).pop(
                        _FilterScope.folder(folders[i].id, folders[i].name)),
                    onMenu: (anchorCtx) async {
                      final act = await _showFolderMenuPopup(anchorCtx);
                      if (act == _FolderMenuAction.rename) {
                        await onRenameFolder(folders[i].id, folders[i].name);
                      } else if (act == _FolderMenuAction.delete) {
                        await onDeleteFolder(folders[i].id);
                      }
                    },
                  ),
                ],
                const SizedBox(height: 10),
                Text(l10n.from,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: AppTypography.s14,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 16),
                Text('${l10n.fromDevice} (${counts.deviceSource})',
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: AppTypography.s14,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 6),
                Text('${l10n.sourceLocal} (${counts.localSource})',
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: AppTypography.s14,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FilterRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterRow({
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.textPrimary : AppColors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.br12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceMuted : Colors.transparent,
          borderRadius: AppRadii.br12,
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$label  ($count)',
                style: TextStyle(
                  fontSize: AppTypography.s14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded,
                  size: 20, color: AppColors.textPrimary),
          ],
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final Folder folder;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final void Function(BuildContext) onMenu;

  const _FolderRow({
    required this.folder,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.textPrimary : AppColors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.br12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceMuted : Colors.transparent,
          borderRadius: AppRadii.br12,
        ),
        child: Row(
          children: [
            Icon(folder.iconData, size: 22, color: folder.colorValue),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${folder.name}  ($count)',
                style: TextStyle(
                  fontSize: AppTypography.s14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded,
                  size: 20, color: AppColors.textPrimary),
            const SizedBox(width: 6),
            Builder(
              builder: (menuCtx) => InkWell(
                onTap: () => onMenu(menuCtx),
                borderRadius: BorderRadius.circular(AppRadii.r8),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.more_horiz,
                      size: 22, color: AppColors.textPlaceholder),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateFolderSheet extends StatefulWidget {
  final Future<String> Function(String name, Color color, IconData icon)
      onCreate;

  const _CreateFolderSheet({required this.onCreate});

  @override
  State<_CreateFolderSheet> createState() => _CreateFolderSheetState();
}

class _CreateFolderSheetState extends State<_CreateFolderSheet> {
  final _nameCtrl = TextEditingController();
  int _colorIdx = 0;
  int _iconIdx = 0;

  static const _colors = <Color>[
    Color(0xFF8FC31F),
    Color(0xFFFF5A3C),
    Color(0xFF2F6BFF),
    Color(0xFFE23BFF),
    Color(0xFF21E6E2),
    Color(0xFFFFC233),
  ];

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
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetHeader(
              title: l10n.createFolder,
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.folderName,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s12,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _nameCtrl,
              maxLines: 1,
              inputFormatters: [
                LengthLimitingTextInputFormatter(kFolderNameMaxLength),
              ],
              decoration:
                  _folderNameFieldDecoration(hintText: l10n.folderNameExample),
            ),
            const SizedBox(height: 18),
            Text(
              l10n.chooseColor,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s12,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < _colors.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: InkWell(
                      onTap: () => setState(() => _colorIdx = i),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _colors[i],
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: i == _colorIdx
                                  ? AppColors.textPrimary
                                  : Colors.transparent,
                              width: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              l10n.chooseIcon,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s12,
              ),
            ),
            const SizedBox(height: 6),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _icons.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemBuilder: (ctx, i) {
                final sel = i == _iconIdx;
                return InkWell(
                  onTap: () => setState(() => _iconIdx = i),
                  borderRadius: BorderRadius.circular(AppRadii.r12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMuted,
                      borderRadius: BorderRadius.circular(AppRadii.r12),
                      border: Border.all(
                          color:
                              sel ? AppColors.textPrimary : Colors.transparent,
                          width: 2),
                    ),
                    child: Icon(_icons[i],
                        color: sel
                            ? AppColors.textPrimary
                            : AppColors.textSecondary),
                  ),
                );
              },
            ),
            const SizedBox(height: 18),
            AppSheetActionButtons(
              secondaryText: l10n.cancel,
              onSecondary: () => Navigator.of(context).pop(),
              primaryText: l10n.save,
              onPrimary: () async {
                final name = _nameCtrl.text.trim();
                if (!isValidFolderName(name)) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.folderNameInvalid)),
                  );
                  return;
                }
                final id = await widget.onCreate(
                    name, _colors[_colorIdx], _icons[_iconIdx]);
                if (!context.mounted) return;
                Navigator.of(context).pop(id);
              },
              compact: true,
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _FolderPickerSheet extends StatelessWidget {
  final List<Folder> folders;
  const _FolderPickerSheet({required this.folders});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetHeader(
              title: l10n.moveToFolder,
              onClose: () => Navigator.of(context).pop(null),
            ),
            const SizedBox(height: 8),
            _FolderPickerRow(
              icon: Icons.category_outlined,
              iconColor: AppColors.textSecondary,
              label: l10n.unclassified,
              onTap: () => Navigator.of(context).pop(null),
            ),
            for (final f in folders) ...[
              const SizedBox(height: 6),
              _FolderPickerRow(
                icon: f.iconData,
                iconColor: f.colorValue,
                label: f.name,
                onTap: () => Navigator.of(context).pop(f.id),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FolderPickerRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;

  const _FolderPickerRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: AppRadii.br12,
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: AppTypography.s14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 22, color: AppColors.textPlaceholder),
          ],
        ),
      ),
    );
  }
}

/// Isolated avatar so account/profile changes rebuild this chip even when the
/// heavy recordings list body is mid-reload.
class _RecordingsProfileAvatarButton extends ConsumerStatefulWidget {
  const _RecordingsProfileAvatarButton();

  @override
  ConsumerState<_RecordingsProfileAvatarButton> createState() =>
      _RecordingsProfileAvatarButtonState();
}

class _RecordingsProfileAvatarButtonState
    extends ConsumerState<_RecordingsProfileAvatarButton> {
  /// Process-wide: avoid re-fetching profile (and blinking the avatar) every
  /// time [RecordingsPage] is recreated when switching bottom tabs.
  static String? _lastRefreshKey;
  static DateTime? _lastRefreshAt;
  bool _refreshing = false;

  static const _minRefreshGap = Duration(seconds: 30);

  void _scheduleProfileRefresh(String refreshKey) {
    if (_refreshing || refreshKey.isEmpty) return;
    final now = DateTime.now();
    final recentlyRefreshed = _lastRefreshKey == refreshKey &&
        _lastRefreshAt != null &&
        now.difference(_lastRefreshAt!) < _minRefreshGap;
    // A refresh may still leave the profile mismatched. Do not let the
    // resulting rebuild start an API request loop.
    if (recentlyRefreshed) return;

    _refreshing = true;
    _lastRefreshKey = refreshKey;
    _lastRefreshAt = now;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await ref.read(userProfileProvider.notifier).refresh();
      } catch (_) {
        // Keep the current avatar; opening Settings can still surface errors.
      } finally {
        if (mounted) {
          setState(() => _refreshing = false);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authSessionProvider);
    final me = ref.watch(userProfileProvider);
    final avatarRevision = ref.watch(avatarImageRevisionProvider);
    final env = ref.watch(appEnvProvider).valueOrNull ?? kDefaultAppEnv;

    final sessionEmail = (session.email ?? '').trim().toLowerCase();
    final refreshKey = '${env.trim().toLowerCase()}|$sessionEmail';
    final profileEmail = (me?.email ?? '').trim().toLowerCase();
    final profileMatchesSession = !session.isLoggedIn ||
        sessionEmail.isEmpty ||
        profileEmail.isEmpty ||
        sessionEmail == profileEmail;

    if (!session.isLoggedIn) {
      // Next login must refresh; do not reuse the previous account's throttle.
      _lastRefreshKey = null;
      _lastRefreshAt = null;
    } else if (sessionEmail.isNotEmpty) {
      // Refresh when account/env changed, or profile is missing/mismatched.
      // Do not clear the visible avatar while a background refresh runs.
      final needsForce = me == null || !profileMatchesSession;
      if (needsForce || _lastRefreshKey != refreshKey) {
        _scheduleProfileRefresh(refreshKey);
      }
    }

    // Use the same profile source as Settings. Account switches are isolated by
    // UserProfileController, so an email-format mismatch must not hide a valid
    // avatar or prevent the shared decoded cache from painting.
    final avatarUrl = (me?.avatarUrl ?? '').toString().trim();
    final profileId = me?.id ?? 0;
    final avatarUrlForImage = avatarImageUrl(
      avatarUrl: avatarUrl,
      revision: avatarRevision,
    );
    final identityKey = avatarImageCacheKey(
      profileId: profileId,
      avatarUrl: avatarUrl,
      revision: avatarRevision,
    );

    return InkWell(
      onTap: () async {
        final currentSession = ref.read(authSessionProvider);
        if (!currentSession.isLoggedIn) {
          await showDialog<void>(
            context: context,
            barrierDismissible: true,
            builder: (_) =>
                const Dialog.fullscreen(child: LoginLandingPage()),
          );
          return;
        }

        // Do not refresh profile here — a late state= rebuild was flashing the
        // settings avatar even when the URL was unchanged.
        if (!context.mounted) return;
        context.push('/settings');
      },
      borderRadius: BorderRadius.zero,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: avatarUrl.isNotEmpty
            ? UserAvatarImage(
                imageUrl: avatarUrlForImage,
                cacheKey: identityKey,
                size: 30,
                borderRadius: BorderRadius.circular(AppRadii.pill),
                errorWidget: const Icon(
                  Icons.person_outline,
                  color: AppColors.textPrimary,
                  size: 30,
                ),
              )
            : const Icon(
                Icons.person_outline,
                color: AppColors.textPrimary,
                size: 30,
              ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  final String title;
  final VoidCallback onClose;

  const _SheetHeader({required this.title, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: AppTypography.s18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onClose,
              child: const Icon(Icons.close,
                  size: 22, color: AppColors.textSecondary),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 12, bottom: 4),
          child: Divider(height: 1, color: AppColors.borderLight),
        ),
      ],
    );
  }
}

enum _FolderMenuAction { rename, delete }

Future<_FolderMenuAction?> _showFolderMenuPopup(BuildContext anchorContext) {
  final completer = Completer<_FolderMenuAction?>();
  final rootNav = Navigator.of(anchorContext, rootNavigator: true);
  final overlay = rootNav.overlay;
  if (overlay == null) {
    completer.complete(null);
    return completer.future;
  }
  final anchorBox = anchorContext.findRenderObject() as RenderBox?;
  if (anchorBox == null) {
    completer.complete(null);
    return completer.future;
  }
  final pos = anchorBox.localToGlobal(Offset.zero);
  const popupWidth = 220.0;
  const popupHeight = 98.0;
  const margin = 8.0;
  final size = MediaQuery.sizeOf(anchorContext);
  final left = (pos.dx + anchorBox.size.width - popupWidth)
      .clamp(margin, size.width - popupWidth - margin);
  final topBelow = pos.dy + anchorBox.size.height + 2;
  double top = (topBelow + popupHeight <= size.height - margin)
      ? topBelow
      : pos.dy - popupHeight - 2;
  top = top.clamp(margin, size.height - popupHeight - margin);

  late OverlayEntry overlayEntry;
  void close([_FolderMenuAction? action]) {
    if (!completer.isCompleted) completer.complete(action);
    overlayEntry.remove();
  }

  overlayEntry = OverlayEntry(
    builder: (ctx) => _FolderMenuPopup(
      position: Offset(left, top),
      onSelect: close,
      onDismiss: () => close(null),
    ),
  );
  overlay.insert(overlayEntry);
  return completer.future;
}

class _FolderMenuPopup extends StatelessWidget {
  final Offset position;
  final void Function(_FolderMenuAction) onSelect;
  final VoidCallback onDismiss;

  const _FolderMenuPopup(
      {required this.position,
      required this.onSelect,
      required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppOverlayTapDismiss(
      onDismiss: onDismiss,
      child: Positioned(
        top: position.dy,
        left: position.dx,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(AppRadii.r18),
          child: Container(
            width: 220,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.r18),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _FolderMenuOption(
                  icon: Icons.edit_outlined,
                  label: l10n.rename,
                  color: AppColors.textPrimary,
                  onTap: () => onSelect(_FolderMenuAction.rename),
                ),
                const Divider(height: 1, thickness: 1, color: AppColors.border),
                _FolderMenuOption(
                  icon: Icons.delete_outline,
                  label: l10n.delete,
                  color: AppColors.dangerStrong,
                  onTap: () => onSelect(_FolderMenuAction.delete),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderMenuOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _FolderMenuOption(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w500,
                      fontSize: AppTypography.s14,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

InputDecoration _folderNameFieldDecoration({required String hintText}) {
  return InputDecoration(
    hintText: hintText,
    filled: true,
    fillColor: AppColors.surfaceMuted,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.r12),
      borderSide: BorderSide.none,
    ),
  );
}
