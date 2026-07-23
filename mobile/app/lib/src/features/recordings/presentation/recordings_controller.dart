import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/account_db_key.dart';
import '../../../core/storage/account_storage_paths.dart';
import '../../../core/audio/audio_waveform_peaks.dart'
    show
        WaveformPeaksRequest,
        WaveformPeaksResult,
        extractAudioPeaksStream,
        logWaveformPeaksDebug,
        resolveWaveformTargetBars;
import '../data/recordings_repository.dart';
import '../domain/recording.dart';
import '../domain/recording_summary.dart';
import 'folders_providers.dart';

final recordingsListProvider = FutureProvider<List<Recording>>((ref) async {
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  // Files UI needs both normal list + recycle bin filtering on the same page.
  return repo.listAll(includeDeleted: true);
});

/// Invalidate list UIs that depend on recordings DB (full list, counts, banner).
///
/// The **home paged list** is not invalidated here: that would dispose the notifier and
/// re-run [RecordingsListPagedNotifier.refresh], clearing the list and resetting scroll
/// (severe jitter when transfer progress bumps this many times per second). Instead we
/// [RecordingsListPagedNotifier.scheduleReloadAfterDbChange] to refetch the current window.
///
/// Accepts [Ref] (notifiers/providers) or [WidgetRef] (widgets); they share `invalidate`.
///
/// Pass [removedIds] after delete/move-to-recycle so the home list updates immediately
/// even when [reloadAfterDbChange] is deferred during scroll load-more.
void bumpRecordingsLists(
  dynamic ref, {
  Iterable<String>? removedIds,
}) {
  if (removedIds != null) {
    final ids = removedIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isNotEmpty) {
      ref
          .read(recordingsListPagedNotifierProvider.notifier)
          .removeRecordingIds(ids);
    }
  }
  ref.invalidate(recordingsListProvider);
  ref
      .read(recordingsListPagedNotifierProvider.notifier)
      .scheduleReloadAfterDbChange();
  ref.invalidate(recordingsFilterCountsProvider);
  ref.invalidate(transferringBannerRecordingProvider);
  ref.invalidate(recordingsRowCountProvider);
}

final recordingsRowCountProvider = FutureProvider<int>((ref) async {
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  return repo.totalRecordingsRows();
});

// --- Home files: paginated local list + scroll load more ---

const int kRecordingsListPageSize = 30;

class RecordingsPagedState {
  final List<Recording> items;
  final bool hasMore;
  final bool isInitialLoading;
  final bool isLoadingMore;
  final String? errorMessage;

  const RecordingsPagedState({
    this.items = const [],
    this.hasMore = true,
    this.isInitialLoading = true,
    this.isLoadingMore = false,
    this.errorMessage,
  });

  RecordingsPagedState copyWith({
    List<Recording>? items,
    bool? hasMore,
    bool? isInitialLoading,
    bool? isLoadingMore,
    String? errorMessage,
  }) {
    return RecordingsPagedState(
      items: items ?? this.items,
      hasMore: hasMore ?? this.hasMore,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      errorMessage: errorMessage,
    );
  }
}

class RecordingsListPagedNotifier extends Notifier<RecordingsPagedState> {
  String _searchQuery = '';
  bool _loadMoreInFlight = false;
  bool _reloadAfterDbInFlight = false;
  bool _reloadPending = false;
  Timer? _reloadAfterDbDebounce;

  @override
  RecordingsPagedState build() {
    // Rebuild + refresh whenever the active account shard settles. Without this
    // the notifier keeps a stale (possibly closed) DB handle after the account
    // key flaps during login → profile refresh, surfacing as a stuck
    // "database_closed" error that never self-heals.
    ref.watch(accountDbKeyProvider);
    ref.onDispose(() => _reloadAfterDbDebounce?.cancel());
    Future.microtask(() => refresh());
    return const RecordingsPagedState();
  }

  /// Coalesces rapid DB writes (e.g. transfer progress) into one SQLite read per ~100ms.
  void scheduleReloadAfterDbChange() {
    _reloadAfterDbDebounce?.cancel();
    _reloadAfterDbDebounce = Timer(const Duration(milliseconds: 100), () {
      _reloadAfterDbDebounce = null;
      unawaited(reloadAfterDbChange());
    });
  }

  /// Drops rows immediately (e.g. after move-to-recycle) before SQLite reload runs.
  void removeRecordingIds(Set<String> ids) {
    if (ids.isEmpty || state.items.isEmpty) return;
    final next = state.items.where((r) => !ids.contains(r.id)).toList();
    if (next.length == state.items.length) return;
    state = state.copyWith(items: next);
  }

  Future<void> _flushPendingReload() async {
    if (!_reloadPending) return;
    _reloadPending = false;
    await reloadAfterDbChange();
  }

  /// Refetch rows for the current loaded window without clearing the list or resetting scroll.
  Future<void> reloadAfterDbChange() async {
    if (_loadMoreInFlight || state.isLoadingMore) {
      _reloadPending = true;
      return;
    }
    if (_reloadAfterDbInFlight) {
      _reloadPending = true;
      return;
    }

    // [build] already scheduled first [refresh].
    if (state.isInitialLoading && state.items.isEmpty) return;

    if (state.items.isEmpty) {
      await refresh();
      return;
    }

    _reloadAfterDbInFlight = true;
    try {
      final count = state.items.length;
      final limit =
          count < kRecordingsListPageSize ? kRecordingsListPageSize : count;
      final rows = await withFreshRecordingsRepo(
        ref,
        (repo) => repo.listPage(
          offset: 0,
          limit: limit,
          includeDeleted: true,
          searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
        ),
      );
      state = RecordingsPagedState(
        items: rows,
        hasMore: rows.length >= limit,
        isInitialLoading: false,
        isLoadingMore: false,
        errorMessage: null,
      );
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      _reloadAfterDbInFlight = false;
      if (_reloadPending) {
        _reloadPending = false;
        unawaited(reloadAfterDbChange());
      }
    }
  }

  Future<void> refresh({String? searchQuery}) async {
    if (searchQuery != null) {
      _searchQuery = searchQuery.trim();
    }
    state = RecordingsPagedState(
      items: const [],
      hasMore: true,
      isInitialLoading: true,
      isLoadingMore: false,
      errorMessage: null,
    );
    try {
      final rows = await withFreshRecordingsRepo(
        ref,
        (repo) => repo.listPage(
          offset: 0,
          limit: kRecordingsListPageSize,
          includeDeleted: true,
          searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
        ),
      );
      state = RecordingsPagedState(
        items: rows,
        hasMore: rows.length >= kRecordingsListPageSize,
        isInitialLoading: false,
        isLoadingMore: false,
      );
    } catch (e) {
      state = RecordingsPagedState(
        items: const [],
        hasMore: false,
        isInitialLoading: false,
        isLoadingMore: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> loadMore() async {
    if (!state.hasMore ||
        state.isInitialLoading ||
        state.isLoadingMore ||
        _loadMoreInFlight) {
      return;
    }
    _loadMoreInFlight = true;
    state = state.copyWith(isLoadingMore: true);
    try {
      final rows = await withFreshRecordingsRepo(
        ref,
        (repo) => repo.listPage(
          offset: state.items.length,
          limit: kRecordingsListPageSize,
          includeDeleted: true,
          searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
        ),
      );
      final merged = [...state.items, ...rows];
      state = RecordingsPagedState(
        items: merged,
        hasMore: rows.length >= kRecordingsListPageSize,
        isInitialLoading: false,
        isLoadingMore: false,
      );
    } catch (e) {
      state = state.copyWith(isLoadingMore: false, errorMessage: e.toString());
    } finally {
      _loadMoreInFlight = false;
      unawaited(_flushPendingReload());
    }
  }
}

final recordingsListPagedNotifierProvider =
    NotifierProvider<RecordingsListPagedNotifier, RecordingsPagedState>(
        RecordingsListPagedNotifier.new);

class RecordingsFilterCounts {
  final int allActive;
  final int unclassified;
  final int recycle;
  final int deviceSource;
  final int localSource;
  final Map<String, int> perFolderId;

  const RecordingsFilterCounts({
    required this.allActive,
    required this.unclassified,
    required this.recycle,
    required this.deviceSource,
    required this.localSource,
    required this.perFolderId,
  });
}

final recordingsFilterCountsProvider =
    FutureProvider<RecordingsFilterCounts>((ref) async {
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  final folders = await ref.watch(foldersListProvider.future);
  final perFolder = <String, int>{};
  for (final f in folders) {
    perFolder[f.id] = await repo.countRecordingsInFolder(f.id);
  }
  return RecordingsFilterCounts(
    allActive: await repo.countActiveRecordings(),
    unclassified: await repo.countUnclassifiedRecordings(),
    recycle: await repo.countRecycleBinRecordings(),
    deviceSource: await repo.countRecordingsBySource('device'),
    localSource: await repo.countRecordingsBySource('local'),
    perFolderId: perFolder,
  );
});

final transferringBannerRecordingProvider =
    FutureProvider<Recording?>((ref) async {
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  return repo.getFirstActiveTransferringRecording();
});

final recycleBinPurgeProvider = FutureProvider<void>((ref) async {
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  await repo.purgeRecycleBinOlderThan(const Duration(days: 7));
  bumpRecordingsLists(ref);
});

final validateLocalPathsProvider = FutureProvider<void>((ref) async {
  final accountKey = ref.watch(accountDbKeyProvider);
  if (accountKey == null || accountKey.isEmpty) return;

  await AccountStoragePaths.migrateLegacyFilesystemDirs(accountKey);
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  await repo.migrateLegacyLocalPaths(accountKey: accountKey);
  final n = await repo.clearInvalidLocalPaths(accountKey: accountKey);
  if (n > 0) bumpRecordingsLists(ref);
});

final recordingByIdProvider = FutureProvider.family<Recording?, String>((ref, id) async {
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  return repo.getById(id);
});

final recordingSummaryVersionsProvider = FutureProvider.family<List<RecordingSummaryVersion>, String>((ref, recordingId) async {
  final repo = await ref.watch(recordingsRepositoryProvider.future);
  return repo.listSummaryVersions(recordingId);
});

class TransferCompletedEvent {
  final String recordingId;
  final bool success;

  const TransferCompletedEvent({required this.recordingId, required this.success});
}

final transferCompletedEventProvider = StateProvider<TransferCompletedEvent?>((ref) => null);
final waveformPeaksProvider =
    StreamProvider.family<WaveformPeaksResult?, WaveformPeaksRequest>(
        (ref, request) async* {
  final p = request.path.trim();
  if (p.isEmpty) return;
  final bars =
      resolveWaveformTargetBars(durationSeconds: request.durationSeconds);
  if (kDebugMode) {
    debugPrint(
      '[Waveform] provider start path=$p bars=$bars '
      'durSec=${request.durationSeconds ?? '-'}',
    );
  }
  try {
    WaveformPeaksResult? last;
    await for (final r in extractAudioPeaksStream(
      p,
      targetBars: bars,
      durationSeconds: request.durationSeconds,
    )) {
      if (r.peaks.isNotEmpty) {
        last = r;
        if (kDebugMode) {
          logWaveformPeaksDebug(
            'provider-yield',
            peaks: r.peaks,
            parsedFraction: r.parsedFraction,
          );
        }
        yield r;
      }
    }
    if (last == null) {
      if (kDebugMode) {
        debugPrint('[Waveform] provider done path=$p result=null');
      }
      yield null;
    } else if (kDebugMode) {
      debugPrint(
        '[Waveform] provider done path=$p peaks=${last.peaks.length} '
        'frac=${last.parsedFraction.toStringAsFixed(3)}',
      );
    }
  } catch (e, st) {
    if (kDebugMode) debugPrint('[Waveform] extractAudioPeaksStream failed: $e\n$st');
    yield null;
  }
});
