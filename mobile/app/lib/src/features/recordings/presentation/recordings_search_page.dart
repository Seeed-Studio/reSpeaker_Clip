import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../core/widgets/app_date_picker.dart';
import '../../../core/widgets/app_sheet_action_buttons.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_pill_chip.dart';
import '../../../core/l10n/app_localizations.dart';
import 'folders_providers.dart';
import 'recordings_controller.dart';
import 'search_history_helper.dart';
import '../domain/folder.dart';
import '../domain/recording.dart';
import '../utils/recording_display_name.dart';
import '../utils/content_utils.dart' show isErrorLikeContent;
import '../../../app/theme/app_typography.dart';
import '../../device/presentation/device_controller.dart';

/// One row in the "From device" filter sheet (`id` is BLE device id).
class _DeviceFilterEntry {
  final String id;
  final String label;
  const _DeviceFilterEntry(this.id, this.label);
}

/// Sentinel for "All devices" in the choice sheet (`null` means dismissed).
const String _kDeviceFilterAll = '';

List<_DeviceFilterEntry> _buildDeviceFilterEntries({
  required List<Recording> recordings,
  required List<Device> devices,
  required AppLocalizations l10n,
}) {
  final labels = <String, String>{
    for (final d in devices)
      d.id: d.name.trim().isNotEmpty ? d.name.trim() : l10n.defaultDeviceName,
  };
  final ids = <String>{for (final d in devices) d.id};
  for (final r in recordings) {
    if (r.isDeleted) continue;
    final id = r.deviceId?.trim();
    if (id != null && id.isNotEmpty) ids.add(id);
  }
  final entries = <_DeviceFilterEntry>[
    for (final id in ids)
      _DeviceFilterEntry(
        id,
        labels[id] ?? l10n.defaultDeviceName,
      ),
  ];
  entries.sort((a, b) => a.label.compareTo(b.label));
  return entries;
}

class RecordingsSearchPage extends ConsumerStatefulWidget {
  const RecordingsSearchPage({super.key});

  @override
  ConsumerState<RecordingsSearchPage> createState() =>
      _RecordingsSearchPageState();
}

enum _TranscriptFilter { all, transcribed, notTranscribed }

enum _TimePreset {
  sinceRegistration,
  last7Days,
  last30Days,
  last3Months,
  last6Months,
  lastYear,
}

class _RecordingsSearchPageState extends ConsumerState<RecordingsSearchPage> {
  final _searchCtrl = TextEditingController();
  final _focusNode = FocusNode();

  _TimePreset _timePreset = _TimePreset.sinceRegistration;
  DateTimeRange? _customRange;
  String? _deviceIdFilter; // null => All
  _TranscriptFilter _transcriptFilter = _TranscriptFilter.all;

  List<String> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadRecentSearches();
    // Auto focus the input.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  Future<void> _loadRecentSearches() async {
    final list = await SearchHistoryHelper.getRecentSearches();
    if (!mounted) return;
    setState(() => _recent = list);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _pushRecent(String q) async {
    final v = q.trim();
    if (v.isEmpty) return;
    await SearchHistoryHelper.addSearch(v);
    await _loadRecentSearches();
  }

  String _folderName(BuildContext context, Recording r, Map<String, Folder> folderById) {
    final l10n = AppLocalizations.of(context)!;
    final id = r.folderId;
    if (id == null) return l10n.unclassified;
    return folderById[id]?.name ?? l10n.folder;
  }

  String _titleFor(Recording r) => resolveRecordingDisplayTitle(r);

  String _middleEllipsis(String s, {int head = 28, int tail = 28}) {
    final t = s.trim();
    if (t.length <= head + tail + 3) return t;
    return '${t.substring(0, head)}…${t.substring(t.length - tail)}';
  }

  String _excerptAround(String text, String query, {int radius = 24}) {
    final t = text.trim();
    final q = query.trim();
    if (t.isEmpty) return '';
    if (q.isEmpty) return _middleEllipsis(t);
    final idx = t.toLowerCase().indexOf(q.toLowerCase());
    if (idx < 0) return _middleEllipsis(t);
    final start = (idx - radius).clamp(0, t.length);
    final end = (idx + q.length + radius).clamp(0, t.length);
    final leftDots = start > 0 ? '…' : '';
    final rightDots = end < t.length ? '…' : '';
    return '$leftDots${t.substring(start, end)}$rightDots';
  }

  List<Recording> _filterAndSort({
    required List<Recording> all,
    required Map<String, Folder> folderById,
    required String query,
  }) {
    final q = query.trim().toLowerCase();
    final now = DateTime.now();

    DateTimeRange? effectiveRange() {
      if (_customRange != null) return _normalizeSearchDateRange(_customRange!);
      switch (_timePreset) {
        case _TimePreset.sinceRegistration:
          return null;
        case _TimePreset.last7Days:
          return _normalizeSearchDateRange(DateTimeRange(
            start: _startOfDay(now.subtract(const Duration(days: 6))),
            end: now,
          ));
        case _TimePreset.last30Days:
          return _normalizeSearchDateRange(DateTimeRange(
            start: _startOfDay(now.subtract(const Duration(days: 29))),
            end: now,
          ));
        case _TimePreset.last3Months:
          return _normalizeSearchDateRange(DateTimeRange(
            start: _subtractCalendarMonths(now, 3),
            end: now,
          ));
        case _TimePreset.last6Months:
          return _normalizeSearchDateRange(DateTimeRange(
            start: _subtractCalendarMonths(now, 6),
            end: now,
          ));
        case _TimePreset.lastYear:
          return _normalizeSearchDateRange(DateTimeRange(
            start: _subtractCalendarMonths(now, 12),
            end: now,
          ));
      }
    }

    final range = effectiveRange();

    bool matchesQuery(Recording r) {
      if (q.isEmpty) return true;
      final title = _titleFor(r).toLowerCase();
      final tr = (r.transcript ?? '').toLowerCase();
      final sum = (r.summary ?? '').toLowerCase();
      return title.contains(q) || tr.contains(q) || sum.contains(q);
    }

    bool matchesTranscriptFilter(Recording r) {
      final hasTranscript = r.transcript?.trim().isNotEmpty == true;
      switch (_transcriptFilter) {
        case _TranscriptFilter.all:
          return true;
        case _TranscriptFilter.transcribed:
          return hasTranscript;
        case _TranscriptFilter.notTranscribed:
          return !hasTranscript;
      }
    }

    bool matchesDeviceFilter(Recording r) {
      if (_deviceIdFilter == null) return true;
      return r.deviceId == _deviceIdFilter;
    }

    DateTime? _displayTime(Recording r) {
      if (r.source == 'device' && r.devicePath.isNotEmpty) {
        final parsed = parseSessionTimestamp(r.devicePath);
        if (parsed != null) return parsed;
      }
      return r.createdAt;
    }

    bool matchesTime(Recording r) {
      if (range == null) return true;
      final t = _displayTime(r);
      if (t == null) return false;
      return !t.isBefore(range.start) && !t.isAfter(range.end);
    }

    final list = all
        .where((r) => !r.isDeleted)
        .where(matchesQuery)
        .where(matchesTranscriptFilter)
        .where(matchesDeviceFilter)
        .where(matchesTime)
        .toList();

    // Default: newest first (same intent as home [RecordingsPage] createdAt + desc; sync queue is oldest-first separately).
    list.sort((a, b) {
      final aa = _displayTime(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bb = _displayTime(b) ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bb.compareTo(aa);
    });
    return list;
  }

  String _timeLabel() {
    final l10n = AppLocalizations.of(context)!;
    if (_customRange != null) return l10n.custom;
    switch (_timePreset) {
      case _TimePreset.sinceRegistration:
        return l10n.creationTime;
      case _TimePreset.last7Days:
        return l10n.last7Days;
      case _TimePreset.last30Days:
        return l10n.last30Days;
      case _TimePreset.last3Months:
        return l10n.last3Months;
      case _TimePreset.last6Months:
        return l10n.last6Months;
      case _TimePreset.lastYear:
        return l10n.lastYear;
    }
  }

  String _deviceLabel(List<_DeviceFilterEntry> entries) {
    final l10n = AppLocalizations.of(context)!;
    if (_deviceIdFilter == null) return l10n.fromDevice;
    for (final e in entries) {
      if (e.id == _deviceIdFilter) return e.label;
    }
    return l10n.fromDevice;
  }

  String _transcriptLabel() {
    final l10n = AppLocalizations.of(context)!;
    switch (_transcriptFilter) {
      case _TranscriptFilter.all:
        return l10n.transcriptStatus;
      case _TranscriptFilter.transcribed:
        return l10n.transcribed;
      case _TranscriptFilter.notTranscribed:
        return l10n.notTranscribed;
    }
  }

  Future<void> _openTranscriptFilter() async {
    final res = await showAppBottomSheet<_TranscriptFilter>(
      context,
      builder: (_) => _SingleChoiceSheet<_TranscriptFilter>(
        title: AppLocalizations.of(context)!.transcriptStatus,
        value: _transcriptFilter,
        items: [
          _ChoiceItem(_TranscriptFilter.all, AppLocalizations.of(context)!.all),
          _ChoiceItem(_TranscriptFilter.transcribed, AppLocalizations.of(context)!.transcribed),
          _ChoiceItem(_TranscriptFilter.notTranscribed, AppLocalizations.of(context)!.notTranscribed),
        ],
      ),
    );
    if (res == null) return;
    setState(() => _transcriptFilter = res);
  }

  Future<void> _openDeviceFilter(List<_DeviceFilterEntry> entries) async {
    final l10n = AppLocalizations.of(context)!;
    final res = await showAppBottomSheet<String>(
      context,
      builder: (_) => _SingleChoiceSheet<String>(
        title: l10n.fromDevice,
        value: _deviceIdFilter ?? _kDeviceFilterAll,
        items: [
          _ChoiceItem(_kDeviceFilterAll, l10n.all),
          ...entries.map((e) => _ChoiceItem(e.id, e.label)),
        ],
      ),
    );
    if (res == null) return;
    setState(() => _deviceIdFilter = res == _kDeviceFilterAll ? null : res);
  }

  Future<void> _openTimeFilter() async {
    final res = await showAppBottomSheet<_TimeFilterResult>(
      context,
      builder: (_) =>
          _TimeFilterSheet(preset: _timePreset, range: _customRange),
    );
    if (res == null) return;
    setState(() {
      _timePreset = res.preset;
      _customRange =
          res.range == null ? null : _normalizeSearchDateRange(res.range!);
    });
  }

  bool get _hasActiveSearchFilters =>
      _customRange != null ||
      _timePreset != _TimePreset.sinceRegistration ||
      _deviceIdFilter != null ||
      _transcriptFilter != _TranscriptFilter.all;

  @override
  Widget build(BuildContext context) {
    final asyncRecordings = ref.watch(recordingsListProvider);
    final asyncFolders = ref.watch(foldersListProvider);
    final asyncDevices = ref.watch(devicesListProvider);
    final l10n = AppLocalizations.of(context)!;

    final query = _searchCtrl.text;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  InkWell(
                    onTap: () => context.pop(),
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.arrow_back_ios_new, size: 20),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Material(
                      color: AppColors.surfaceMuted,
                      shape: const RoundedRectangleBorder(
                        borderRadius: AppRadii.br18,
                      ),
                      child: TextField(
                        controller: _searchCtrl,
                        focusNode: _focusNode,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (v) => _pushRecent(v),
                        decoration: InputDecoration(
                          hintText: l10n.searchRecordingsOrQa,
                          prefixIcon: const Icon(Icons.search),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: _openTimeFilter,
                    borderRadius: BorderRadius.circular(AppRadii.r18),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceMuted,
                        borderRadius: BorderRadius.circular(AppRadii.r14),
                      ),
                      child: const Icon(Icons.tune),
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: asyncRecordings.maybeWhen(
                data: (items) {
                  final deviceEntries = asyncDevices.maybeWhen(
                    data: (devices) => _buildDeviceFilterEntries(
                      recordings: items,
                      devices: devices,
                      l10n: l10n,
                    ),
                    orElse: () => _buildDeviceFilterEntries(
                      recordings: items,
                      devices: const [],
                      l10n: l10n,
                    ),
                  );
                  return Row(
                    children: [
                      Expanded(
                        child: _FilterDrop(
                          label: _timeLabel(),
                          active:
                              _customRange != null ||
                              _timePreset != _TimePreset.sinceRegistration,
                          onTap: _openTimeFilter,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FilterDrop(
                          label: _deviceLabel(deviceEntries),
                          active: _deviceIdFilter != null,
                          onTap: () => _openDeviceFilter(deviceEntries),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FilterDrop(
                          label: _transcriptLabel(),
                          active: _transcriptFilter != _TranscriptFilter.all,
                          onTap: _openTranscriptFilter,
                        ),
                      ),
                    ],
                  );
                },
                orElse: () => Row(
                  children: [
                    Expanded(child: _FilterDrop(label: l10n.creationTime)),
                    const SizedBox(width: 12),
                    Expanded(child: _FilterDrop(label: l10n.fromDevice)),
                    const SizedBox(width: 12),
                    Expanded(child: _FilterDrop(label: l10n.transcriptStatus)),
                  ],
                ),
              ),
            ),

            Expanded(
              child: asyncRecordings.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text(l10n.loadFailed(e.toString()))),
                data: (items) {
                  final folderMap = asyncFolders.maybeWhen(
                    data: (v) => {for (final f in v) f.id: f},
                    orElse: () => <String, Folder>{},
                  );
                  final results = _filterAndSort(
                    all: items,
                    folderById: folderMap,
                    query: query,
                  );

                  if (query.trim().isEmpty && !_hasActiveSearchFilters) {
                    return _RecentSearches(
                      items: _recent,
                      onClear: () async {
                        await SearchHistoryHelper.clear();
                        await _loadRecentSearches();
                      },
                      onTapChip: (q) {
                        _searchCtrl.text = q;
                        _searchCtrl.selection = TextSelection.collapsed(
                          offset: q.length,
                        );
                        _pushRecent(q);
                        setState(() {});
                      },
                    );
                  }

                  if (results.isEmpty) {
                    return const _SearchEmptyHint();
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                    itemCount: results.length + 1,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (_, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            l10n.totalResults(results.length),
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500,
                              fontSize: AppTypography.s12,
                            ),
                          ),
                        );
                      }
                      final r = results[i - 1];
                      final title = _titleFor(r);
                      final folderName = _folderName(context, r, folderMap);
                      String snippetSource = '';
                      if (r.summary?.trim().isNotEmpty == true && !isErrorLikeContent(r.summary)) {
                        snippetSource = r.summary!;
                      } else if (r.transcript?.trim().isNotEmpty == true && !isErrorLikeContent(r.transcript)) {
                        snippetSource = r.transcript!;
                      }
                      final snippet = snippetSource.isEmpty
                          ? ''
                          : _excerptAround(snippetSource, query);
                      // Device recording: parse time from devicePath UTC→local like home list
                      final displayCreatedAt = _displayCreatedAt(r);
                      return _SearchResultCard(
                        title: title,
                        folderName: folderName,
                        snippet: snippet,
                        query: query,
                        createdAt: displayCreatedAt,
                        durationSeconds: r.durationSeconds,
                        onTap: () {
                          _pushRecent(query);
                          context.push('/recordings/${r.id}');
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterDrop extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;
  const _FilterDrop({required this.label, this.active = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.textPrimary : AppColors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r12),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadii.r12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontSize: AppTypography.s14,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, size: 18, color: fg),
          ],
        ),
      ),
    );
  }
}

class _RecentSearches extends StatelessWidget {
  final List<String> items;
  final VoidCallback onClear;
  final void Function(String q) onTapChip;

  const _RecentSearches({
    required this.items,
    required this.onClear,
    required this.onTapChip,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l10n.recentSearches,
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: AppTypography.s12,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: onClear,
                child: Text(
                  l10n.clear,
                  style: const TextStyle(
                    fontSize: AppTypography.s12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final s in items)
                AppPillChip(
                  label: s,
                  onTap: () => onTapChip(s),
                  backgroundColor: AppColors.surfaceMuted,
                  borderColor: AppColors.borderStrong,
                  foregroundColor: AppColors.textSecondary,
                  textStyle: const TextStyle(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                    fontSize: AppTypography.s12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 70),
          const _SearchEmptyHint(),
        ],
      ),
    );
  }
}

class _SearchEmptyHint extends StatelessWidget {
  const _SearchEmptyHint();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.manage_search, size: 76, color: AppColors.gray200),
            const SizedBox(height: 10),
            Text(
              l10n.searchEmptyHint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppTypography.s12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  final String title;
  final String folderName;
  final String snippet;
  final String query;
  final DateTime? createdAt;
  final int? durationSeconds;
  final VoidCallback onTap;

  const _SearchResultCard({
    required this.title,
    required this.folderName,
    required this.snippet,
    required this.query,
    required this.createdAt,
    required this.durationSeconds,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final titleStyle = const TextStyle(
      fontWeight: FontWeight.w500,
      fontSize: AppTypography.s16,
      color: AppColors.textPrimary,
    );
    final metaStyle = const TextStyle(
      color: AppColors.textSecondary,
      fontSize: AppTypography.s12,
    );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: titleStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          if (snippet.isNotEmpty)
            AppCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              borderRadius: AppRadii.br18,
              backgroundColor: AppColors.surfaceSubtle,
              borderColor: AppColors.border,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.chat_bubble_outline,
                    color: AppColors.textPlaceholder,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _HighlightedText(text: snippet, query: query),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${_fmtDateTime(createdAt)}  •  ${_fmtDuration(durationSeconds)}',
                style: metaStyle,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _FolderChip(label: folderName),
        ],
      ),
    );
  }
}

class _FolderChip extends StatelessWidget {
  final String label;
  const _FolderChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width - 64;
    return AppPillChip(
      label: label,
      icon: Icons.folder_outlined,
      maxWidth: maxWidth,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      backgroundColor: AppColors.surfaceMuted,
      borderColor: AppColors.borderStrong,
      foregroundColor: AppColors.textSecondary,
      textStyle: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: AppTypography.s12,
      ),
    );
  }
}

class _HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  const _HighlightedText({required this.text, required this.query});

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    final baseStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: AppColors.textSecondary,
      fontStyle: FontStyle.italic,
      height: 1.4,
      fontSize: AppTypography.s14,
    );
    final hiStyle = baseStyle?.copyWith(
      color: AppColors.brandPrimary,
      fontStyle: FontStyle.italic,
      fontSize: AppTypography.s14,
    );
    if (q.isEmpty) {
      return Text(
        text,
        style: baseStyle,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }

    final lower = text.toLowerCase();
    final ql = q.toLowerCase();
    final spans = <TextSpan>[];
    var i = 0;
    while (i < text.length) {
      final idx = lower.indexOf(ql, i);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(i), style: baseStyle));
        break;
      }
      if (idx > i) {
        spans.add(TextSpan(text: text.substring(i, idx), style: baseStyle));
      }
      spans.add(
        TextSpan(text: text.substring(idx, idx + q.length), style: hiStyle),
      );
      i = idx + q.length;
    }
    return RichText(
      text: TextSpan(children: spans),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Device recording: parse from devicePath (UTC→local), same as list displayTime
DateTime? _displayCreatedAt(Recording r) {
  if (r.source == 'device' && r.devicePath.isNotEmpty) {
    final parsed = _parseSessionTimestamp(r.devicePath);
    if (parsed != null) return parsed;
  }
  return r.createdAt;
}

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _endOfDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

/// Inclusive calendar-day range for search filters (date picker returns midnight).
DateTimeRange _normalizeSearchDateRange(DateTimeRange raw) {
  var start = _startOfDay(raw.start);
  var end = _endOfDay(raw.end);
  if (end.isBefore(start)) end = _endOfDay(start);
  return DateTimeRange(start: start, end: end);
}

DateTime _subtractCalendarMonths(DateTime from, int months) {
  var year = from.year;
  var month = from.month - months;
  while (month < 1) {
    month += 12;
    year--;
  }
  final lastDay = DateTime(year, month + 1, 0).day;
  final day = from.day.clamp(1, lastDay);
  return DateTime(year, month, day);
}

DateTime? _parseSessionTimestamp(String path) => parseSessionTimestamp(path);

String _fmtDateTime(DateTime? dt) {
  if (dt == null) return '--';
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

String _fmtDuration(int? seconds) {
  if (seconds == null) return '--:--';
  final s = seconds.clamp(0, 999999);
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final ss = s % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }
  return '${m.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
}

class _ChoiceItem<T> {
  final T value;
  final String label;
  const _ChoiceItem(this.value, this.label);
}

class _SingleChoiceSheet<T> extends StatefulWidget {
  final String title;
  final T value;
  final List<_ChoiceItem<T>> items;
  const _SingleChoiceSheet({
    required this.title,
    required this.value,
    required this.items,
  });

  @override
  State<_SingleChoiceSheet<T>> createState() => _SingleChoiceSheetState<T>();
}

class _SingleChoiceSheetState<T> extends State<_SingleChoiceSheet<T>> {
  late T _selected = widget.value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHeader(
            title: widget.title,
            onClose: () => Navigator.of(context).pop(),
          ),
          const SizedBox(height: 8),
          for (final it in widget.items) ...[
            _SelectRow(
              label: it.label,
              selected: it.value == _selected,
              onTap: () => setState(() => _selected = it.value),
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 8),
          AppSheetActionButtons(
            secondaryText: AppLocalizations.of(context)!.clear,
            onSecondary: () =>
                setState(() => _selected = widget.items.first.value),
            primaryText: AppLocalizations.of(context)!.apply,
            onPrimary: () => Navigator.of(context).pop(_selected),
            compact: true,
          ),
        ],
      ),
    );
  }
}

class _SelectRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SelectRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  fontSize: AppTypography.s14,
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
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

class _TimeFilterResult {
  final _TimePreset preset;
  final DateTimeRange? range;
  const _TimeFilterResult({required this.preset, required this.range});
}

class _TimeFilterSheet extends StatefulWidget {
  final _TimePreset preset;
  final DateTimeRange? range;
  const _TimeFilterSheet({required this.preset, required this.range});

  @override
  State<_TimeFilterSheet> createState() => _TimeFilterSheetState();
}

class _TimeFilterSheetState extends State<_TimeFilterSheet> {
  late _TimePreset _preset = widget.preset;
  DateTimeRange? _range;

  @override
  void initState() {
    super.initState();
    _range = widget.range;
  }

  Future<void> _pickStart() async {
    final l10n = AppLocalizations.of(context)!;
    final init =
        _range?.start ?? DateTime.now().subtract(const Duration(days: 7));
    final d = await showAppDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: l10n.selectDate,
    );
    if (d == null) return;
    setState(() {
      final end = _range?.end ?? d;
      _range = DateTimeRange(start: d, end: end.isBefore(d) ? d : end);
      _preset = _TimePreset.sinceRegistration;
    });
  }

  Future<void> _pickEnd() async {
    final l10n = AppLocalizations.of(context)!;
    final init = _range?.end ?? DateTime.now();
    final d = await showAppDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: l10n.selectDate,
    );
    if (d == null) return;
    setState(() {
      final start = _range?.start ?? d;
      _range = DateTimeRange(start: start.isAfter(d) ? d : start, end: d);
      _preset = _TimePreset.sinceRegistration;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Long content: scroll to avoid overflow on small landscape screens
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetHeader(
              title: l10n.creationTime,
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _DateBox(
                    label: l10n.startsAt,
                    value: _range == null
                        ? l10n.selectDate
                        : _fmtDateOnly(_range!.start),
                    onTap: _pickStart,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  '—',
                  style: TextStyle(
                    color: AppColors.textPlaceholder,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DateBox(
                    label: l10n.endsAt,
                    value: _range == null
                        ? l10n.selectDate
                        : _fmtDateOnly(_range!.end),
                    onTap: _pickEnd,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _PresetRow(
              label: l10n.last7Days,
              selected: _preset == _TimePreset.last7Days && _range == null,
              onTap: () => setState(() {
                _preset = _TimePreset.last7Days;
                _range = null;
              }),
            ),
            _PresetRow(
              label: l10n.last30Days,
              selected: _preset == _TimePreset.last30Days && _range == null,
              onTap: () => setState(() {
                _preset = _TimePreset.last30Days;
                _range = null;
              }),
            ),
            _PresetRow(
              label: l10n.last3Months,
              selected: _preset == _TimePreset.last3Months && _range == null,
              onTap: () => setState(() {
                _preset = _TimePreset.last3Months;
                _range = null;
              }),
            ),
            _PresetRow(
              label: l10n.last6Months,
              selected: _preset == _TimePreset.last6Months && _range == null,
              onTap: () => setState(() {
                _preset = _TimePreset.last6Months;
                _range = null;
              }),
            ),
            _PresetRow(
              label: l10n.lastYear,
              selected: _preset == _TimePreset.lastYear && _range == null,
              onTap: () => setState(() {
                _preset = _TimePreset.lastYear;
                _range = null;
              }),
            ),
            _PresetRow(
              label: l10n.sinceRegistration,
              selected:
                  _preset == _TimePreset.sinceRegistration && _range == null,
              onTap: () => setState(() {
                _preset = _TimePreset.sinceRegistration;
                _range = null;
              }),
            ),
            const SizedBox(height: 10),
            AppSheetActionButtons(
              secondaryText: l10n.clear,
              onSecondary: () => setState(() {
                _preset = _TimePreset.sinceRegistration;
                _range = null;
              }),
              primaryText: l10n.apply,
              onPrimary: () => Navigator.of(
                context,
              ).pop(_TimeFilterResult(preset: _preset, range: _range)),
              compact: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _DateBox extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  const _DateBox({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadii.br12,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: AppRadii.br12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppTypography.s12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: AppTypography.s14,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _PresetRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _SelectRow(label: label, selected: selected, onTap: onTap),
    );
  }
}

String _fmtDateOnly(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
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
