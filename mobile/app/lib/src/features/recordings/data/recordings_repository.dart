import 'dart:io';
import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/storage/account_storage_paths.dart';
import '../../../core/log/app_log.dart';
import '../domain/recording.dart';
import '../domain/recording_summary.dart';
import '../utils/recording_display_name.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final recordingsRepositoryProvider =
    FutureProvider<RecordingsRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return RecordingsRepository(db);
});

bool isRecordingsDatabaseClosedError(Object e) =>
    e is DatabaseException && e.toString().contains('database_closed');

/// Runs [action] against the current [RecordingsRepository], retrying once if
/// SQLite was closed (e.g. account shard switched while BLE/sync still runs).
Future<T> withFreshRecordingsRepo<T>(
  Ref ref,
  Future<T> Function(RecordingsRepository repo) action,
) async {
  try {
    return await action(await ref.read(recordingsRepositoryProvider.future));
  } catch (e) {
    if (!isRecordingsDatabaseClosedError(e)) rethrow;
    AppLog.w('withFreshRecordingsRepo: database closed, reopening shard', e);
    ref.invalidate(databaseProvider);
    ref.invalidate(recordingsRepositoryProvider);
    return await action(await ref.read(recordingsRepositoryProvider.future));
  }
}

/// Same as [withFreshRecordingsRepo] for work that continues after a sheet
/// is dismissed (uses [ProviderScope.containerOf] on [rootContext]).
Future<T> withFreshRecordingsRepoContainer<T>(
  ProviderContainer container,
  Future<T> Function(RecordingsRepository repo) action,
) async {
  try {
    return await action(
        await container.read(recordingsRepositoryProvider.future));
  } catch (e) {
    if (!isRecordingsDatabaseClosedError(e)) rethrow;
    AppLog.w(
        'withFreshRecordingsRepoContainer: database closed, reopening shard', e);
    container.invalidate(databaseProvider);
    container.invalidate(recordingsRepositoryProvider);
    return await action(
        await container.read(recordingsRepositoryProvider.future));
  }
}

/// [withFreshRecordingsRepo] for widget callers that hold a [WidgetRef]
/// (which is not a [Ref], so it cannot use the [Ref] overload above).
Future<T> withFreshRecordingsRepoW<T>(
  WidgetRef ref,
  Future<T> Function(RecordingsRepository repo) action,
) async {
  try {
    return await action(await ref.read(recordingsRepositoryProvider.future));
  } catch (e) {
    if (!isRecordingsDatabaseClosedError(e)) rethrow;
    AppLog.w('withFreshRecordingsRepoW: database closed, reopening shard', e);
    ref.invalidate(databaseProvider);
    ref.invalidate(recordingsRepositoryProvider);
    return await action(await ref.read(recordingsRepositoryProvider.future));
  }
}

/// Drop-in for long BLE transfers: same call sites as [RecordingsRepository]
/// but re-resolves the provider handle and retries on `database_closed`.
class TransferRecordingsRepository {
  TransferRecordingsRepository(this._ref);

  final Ref _ref;

  Future<Recording?> getById(String id) =>
      withFreshRecordingsRepo(_ref, (r) => r.getById(id));

  Future<void> updateTransfer({
    required String id,
    required String state,
    double? progress,
    String? error,
    String? errorCode,
    String? localPath,
    int? sizeBytes,
    int? receivedBytes,
    int? expectedBytes,
    int? lastSeq,
    int? crc32,
    int? mtu,
    DateTime? lastPacketAt,
    DateTime? transferStartedAt,
    DateTime? transferFinishedAt,
    bool clearTransferFinishedAt = false,
    String? recordingState,
    String? tmpPath,
    int? durationSeconds,
  }) =>
      withFreshRecordingsRepo(
        _ref,
        (r) => r.updateTransfer(
          id: id,
          state: state,
          progress: progress,
          error: error,
          errorCode: errorCode,
          localPath: localPath,
          sizeBytes: sizeBytes,
          receivedBytes: receivedBytes,
          expectedBytes: expectedBytes,
          lastSeq: lastSeq,
          crc32: crc32,
          mtu: mtu,
          lastPacketAt: lastPacketAt,
          transferStartedAt: transferStartedAt,
          transferFinishedAt: transferFinishedAt,
          clearTransferFinishedAt: clearTransferFinishedAt,
          recordingState: recordingState,
          tmpPath: tmpPath,
          durationSeconds: durationSeconds,
        ),
      );
}

class RecordingsRepository {
  final Database db;
  static const _uuid = Uuid();
  static final Random _rng = Random.secure();

  RecordingsRepository(this.db);


  /// Ensure a recording has a stable session_id (to chain LLM sessions for one recording).
  ///
  /// - If session_id exists: return it
  /// - If empty: generate uuid v4, write to recordings.session_id and return
  Future<String?> ensureSessionId(String id) async {
    final existing = await getById(id);
    if (existing == null) return null;
    final sid = (existing.sessionId ?? '').trim();
    if (sid.isNotEmpty) return sid;
    final next = _uuid.v4();
    await updateSessionId(id: id, sessionId: next);
    return next;
  }

  Future<void> updateSessionId(
      {required String id, required String sessionId}) async {
    final now = DateTime.now().toIso8601String();
    final sid = sessionId.trim();
    if (sid.isEmpty) return;
    await db.update(
      'recordings',
      {'session_id': sid, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Ensure a recording has a stable unique asr_result_id (for server to aggregate sessions/results by recording).
  ///
  /// - If exists: return it
  /// - If empty: generate a positive int and write to recordings.asr_result_id
  Future<int?> ensureAsrResultId(String id) async {
    final existing = await getById(id);
    if (existing == null) return null;
    final v = existing.asrResultId;
    if (v != null && v > 0) return v;
    final next = await _generateUniqueAsrResultId();
    await updateAsrResultId(id: id, asrResultId: next);
    return next;
  }

  Future<void> updateAsrResultId(
      {required String id, required int asrResultId}) async {
    final now = DateTime.now().toIso8601String();
    if (asrResultId <= 0) return;
    await db.update(
      'recordings',
      {'asr_result_id': asrResultId, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> _generateUniqueAsrResultId() async {
    // Range 1..(2^31-1), avoid negative/overflow, compatible with server int32 semantics.
    for (var i = 0; i < 40; i++) {
      final candidate = _rng.nextInt(0x7fffffff - 1) + 1;
      final rows = await db.query(
        'recordings',
        columns: const ['id'],
        where: 'asr_result_id = ?',
        whereArgs: [candidate],
        limit: 1,
      );
      if (rows.isEmpty) return candidate;
    }
    // Very low probability: repeated collision. Fallback to timestamp-based candidate and retry once.
    final fallback = (DateTime.now().microsecondsSinceEpoch & 0x7fffffff);
    if (fallback > 0) {
      final rows = await db.query(
        'recordings',
        columns: const ['id'],
        where: 'asr_result_id = ?',
        whereArgs: [fallback],
        limit: 1,
      );
      if (rows.isEmpty) return fallback;
    }
    throw Exception(
        'Failed to generate asrResultId: too many uniqueness conflicts');
  }

  Future<List<Recording>> listAll({bool includeDeleted = false}) async {
    final rows = await db.query(
      'recordings',
      where: includeDeleted ? null : 'is_deleted = 0',
      // Newest recording first (aligns with home default: SortBy.createdAt + desc).
      // Device transfer queue ([listTransfersToResume]) uses the same newest-first axis.
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Home list pagination (local SQLite). Order matches [listAll].
  Future<List<Recording>> listPage({
    required int offset,
    required int limit,
    bool includeDeleted = false,
    String? searchQuery,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];

    if (!includeDeleted) {
      clauses.add('is_deleted = 0');
    }

    final q = (searchQuery ?? '').trim();
    if (q.isNotEmpty) {
      // Strip LIKE wildcards; args are bound (no SQL injection).
      final safe = q.replaceAll('%', '').replaceAll('_', '');
      if (safe.isNotEmpty) {
        final like = '%$safe%';
        clauses.add("(IFNULL(name, '') LIKE ? OR device_path LIKE ?)");
        args.addAll([like, like]);
      }
    }

    final where = clauses.isEmpty ? null : clauses.join(' AND ');
    final rows = await db.query(
      'recordings',
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  /// All rows (any folder / deleted), for global empty-state.
  Future<int> totalRecordingsRows() async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM recordings');
    return _firstInt(rows) ?? 0;
  }

  Future<int> countActiveRecordings() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM recordings WHERE is_deleted = 0',
    );
    return _firstInt(rows) ?? 0;
  }

  Future<int> countUnclassifiedRecordings() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM recordings WHERE is_deleted = 0 AND folder_id IS NULL',
    );
    return _firstInt(rows) ?? 0;
  }

  Future<int> countRecycleBinRecordings() async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM recordings WHERE is_deleted = 1',
    );
    return _firstInt(rows) ?? 0;
  }

  Future<int> countRecordingsInFolder(String folderId) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM recordings WHERE is_deleted = 0 AND folder_id = ?',
      [folderId],
    );
    return _firstInt(rows) ?? 0;
  }

  Future<int> countRecordingsBySource(String source) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM recordings WHERE is_deleted = 0 AND source = ?',
      [source],
    );
    return _firstInt(rows) ?? 0;
  }

  /// Top banner: newest active transfer/merge row (same ordering intent as full-list scan).
  Future<Recording?> getFirstActiveTransferringRecording() async {
    final rows = await db.query(
      'recordings',
      where:
          "is_deleted = 0 AND transfer_state IN ('transferring', 'merging') AND IFNULL(transfer_error_code, '') != ?",
      whereArgs: const ['user_cancelled'],
      orderBy:
          "CASE transfer_state WHEN 'transferring' THEN 0 WHEN 'merging' THEN 1 ELSE 2 END, transfer_started_at DESC, updated_at DESC",
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Rows interrupted mid-merge (app kill); background queue resumes on startup.
  Future<List<Recording>> listMergingTransfers() async {
    final rows = await db.query(
      'recordings',
      where:
          "is_deleted = 0 AND transfer_state = 'merging' AND source = 'device'",
      orderBy: 'transfer_started_at ASC, updated_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Done device recordings with a merged local file — for duration re-probe.
  Future<List<Recording>> listDoneDeviceRecordingsWithLocalPath() async {
    final rows = await db.query(
      'recordings',
      where:
          "is_deleted = 0 AND source = 'device' AND transfer_state = 'done' "
          "AND local_path IS NOT NULL AND local_path != ''",
      orderBy: 'updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  static int? _firstInt(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return null;
    final v = rows.first.values.first;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  Future<List<Recording>> listRecycleBin() async {
    final rows = await db.query('recordings',
        where: 'is_deleted = 1', orderBy: 'deleted_at DESC');
    return rows.map(_fromRow).toList();
  }

  Future<void> moveToFolder({required String id, String? folderId}) async {
    final now = DateTime.now().toIso8601String();
    await db.update('recordings', {'folder_id': folderId, 'updated_at': now},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> moveToRecycleBin({required String id}) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'recordings',
      {'is_deleted': 1, 'deleted_at': now, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> restoreFromRecycleBin({required String id}) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'recordings',
      {'is_deleted': 0, 'deleted_at': null, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Permanently delete recycle bin entries older than given duration and remove local files (audio, transcript, summary, etc.).
  /// Call once at app startup, e.g. purgeRecycleBinOlderThan(Duration(days: 7)).
  Future<int> purgeRecycleBinOlderThan(Duration duration) async {
    final cutoff = DateTime.now().subtract(duration).toIso8601String();
    final rows = await db.query(
      'recordings',
      columns: ['id', 'local_path', 'transcript_path', 'summary_path'],
      where: 'is_deleted = 1 AND deleted_at <= ?',
      whereArgs: [cutoff],
    );
    int count = 0;
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null) continue;
      for (final pathKey in ['local_path', 'transcript_path', 'summary_path']) {
        final path = r[pathKey] as String?;
        if (path == null || path.trim().isEmpty) continue;
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      await db.delete('recordings', where: 'id = ?', whereArgs: [id]);
      count++;
    }
    return count;
  }

  /// Rewrites unified-era paths (`recordings/device/…` → `recordings_{accountKey}/device/…`).
  Future<int> migrateLegacyLocalPaths({required String accountKey}) async {
    if (accountKey.trim().isEmpty) return 0;
    final rows = await db.query(
      'recordings',
      columns: ['id', 'local_path', 'transcript_path', 'summary_path'],
    );
    var count = 0;
    final now = DateTime.now().toIso8601String();
    for (final r in rows) {
      final id = r['id'] as String?;
      if (id == null) continue;
      final updates = <String, Object?>{};
      for (final col in ['local_path', 'transcript_path', 'summary_path']) {
        final raw = (r[col] as String?)?.trim();
        if (raw == null || raw.isEmpty) continue;
        final next =
            AccountStoragePaths.rewriteLegacyRecordingPath(raw, accountKey);
        if (next != null && next != raw) {
          updates[col] = next;
        }
      }
      if (updates.isEmpty) continue;
      updates['updated_at'] = now;
      await db.update('recordings', updates, where: 'id = ?', whereArgs: [id]);
      count++;
    }
    return count;
  }

  /// On app startup: if file at local_path does not exist (e.g. sandbox path changed after reinstall), clear local_path.
  /// Returns count cleared. UI will show "sync to device first", user can re-download from device.
  Future<int> clearInvalidLocalPaths({required String accountKey}) async {
    final rows = await db.query(
      'recordings',
      columns: ['id', 'local_path'],
      where: 'local_path IS NOT NULL AND local_path != ?',
      whereArgs: [''],
    );
    int count = 0;
    final now = DateTime.now().toIso8601String();
    for (final r in rows) {
      final path = (r['local_path'] as String?)?.trim();
      if (path == null || path.isEmpty) continue;
      final effective =
          AccountStoragePaths.rewriteLegacyRecordingPath(path, accountKey) ??
              path;
      try {
        if (effective != path) {
          if (await File(effective).exists()) {
            await db.update(
              'recordings',
              {'local_path': effective, 'updated_at': now},
              where: 'id = ?',
              whereArgs: [r['id']],
            );
            continue;
          }
        }
        if (!await File(effective).exists()) {
          await db.update(
            'recordings',
            {'local_path': null, 'updated_at': now},
            where: 'id = ?',
            whereArgs: [r['id']],
          );
          count++;
        }
      } catch (_) {}
    }
    return count;
  }

  Future<List<Recording>> listByDeviceId(String deviceId) async {
    final rows = await db.query(
      'recordings',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// List recordings on device with incomplete transfer (transfer_state == 'transferring'), for resume after reconnect.
  /// Excludes recycle-bin rows so deleted items are not resumed on reconnect.
  Future<List<Recording>> listIncompleteTransfers(String deviceId) async {
    final rows = await db.query(
      'recordings',
      where:
          'device_id = ? AND transfer_state = ? AND source = ? AND is_deleted = 0',
      whereArgs: [deviceId, 'transferring', 'device'],
      orderBy: 'transfer_started_at DESC, created_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// List transfers that can be retried (transferring or failed), for resume/retry after reconnect.
  ///
  /// **Sync queue = newest first (DESC)** — matches home list ([listPage] `created_at DESC`):
  /// `COALESCE(transfer_started_at, created_at)` descending so the latest recording syncs first.
  /// Same ordering as [DeviceController] `_resumeIncompleteTransfers` in-memory sort.
  Future<List<Recording>> listTransfersToResume(String deviceId) async {
    final rows = await db.query(
      'recordings',
      where:
          'device_id = ? AND transfer_state IN (?, ?) AND source = ? AND is_deleted = 0',
      whereArgs: [deviceId, 'transferring', 'failed', 'device'],
      orderBy: 'COALESCE(transfer_started_at, created_at) DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> deleteById(String id) async {
    await db.delete('recordings', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateTransfer({
    required String id,
    required String state, // not_started | transferring | merging | done | failed
    double? progress, // 0..1
    String? error,

    /// Optional error code for i18n (e.g. device_session_missing).
    String? errorCode,
    String? localPath,
    int? sizeBytes,
    int? receivedBytes,
    int? expectedBytes,
    int? lastSeq,
    int? crc32,
    int? mtu,
    DateTime? lastPacketAt,
    DateTime? transferStartedAt,
    DateTime? transferFinishedAt,
    /// When true, clears [transfer_finished_at] (e.g. Fast Sync gave up but BLE can continue).
    bool clearTransferFinishedAt = false,
    String? recordingState,
    String? tmpPath,
    int? durationSeconds,
  }) async {
    final now = DateTime.now().toIso8601String();
    final updates = <String, Object?>{
      'transfer_state': state,
      'updated_at': now,
    };
    if (progress != null) updates['transfer_progress'] = progress;
    if (error != null) updates['transfer_error'] = error;
    if (errorCode != null) updates['transfer_error_code'] = errorCode;
    if (localPath != null) updates['local_path'] = localPath;
    if (sizeBytes != null) updates['size_bytes'] = sizeBytes;
    if (receivedBytes != null) updates['received_bytes'] = receivedBytes;
    if (expectedBytes != null) updates['expected_bytes'] = expectedBytes;
    if (lastSeq != null) updates['last_seq'] = lastSeq;
    if (crc32 != null) updates['crc32'] = crc32;
    if (mtu != null) updates['mtu'] = mtu;
    if (lastPacketAt != null) {
      updates['last_packet_at'] = lastPacketAt.toIso8601String();
    }
    if (transferStartedAt != null) {
      updates['transfer_started_at'] = transferStartedAt.toIso8601String();
    }
    if (clearTransferFinishedAt) {
      updates['transfer_finished_at'] = null;
    } else if (transferFinishedAt != null) {
      updates['transfer_finished_at'] = transferFinishedAt.toIso8601String();
    }
    if (recordingState != null) updates['recording_state'] = recordingState;
    if (tmpPath != null) updates['tmp_path'] = tmpPath;
    if (durationSeconds != null) updates['duration_seconds'] = durationSeconds;
    await db.update('recordings', updates, where: 'id = ?', whereArgs: [id]);
  }

  /// Update basic metadata for a device recording after STOP.
  ///
  /// This is used when we start BLE transfer *during* recording
  /// (real-time sync), and only know the final duration / end time
  /// after `AT+STOP` completes.
  Future<void> updateDeviceRecordingMeta({
    required String id,
    int? durationSeconds,
    DateTime? startedAt,
    DateTime? endedAt,
  }) async {
    final now = DateTime.now().toIso8601String();
    final updates = <String, Object?>{
      'updated_at': now,
    };
    if (durationSeconds != null) {
      updates['duration_seconds'] = durationSeconds;
    }
    if (startedAt != null) {
      updates['started_at'] = startedAt.toIso8601String();
    }
    if (endedAt != null) {
      updates['ended_at'] = endedAt.toIso8601String();
    }
    if (updates.length <= 1) {
      // Nothing to update beyond updated_at.
      return;
    }
    await db.update('recordings', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateDevicePresent(
      {required String id, required bool present}) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'recordings',
      {'device_present': present ? 1 : 0, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Create a "pending transfer" recording entry right after device stops recording.
  ///
  /// This allows Files list to show "Syncing xx%" immediately, even if App restarts.
  Future<String> createPendingDeviceRecording({
    required String deviceId,
    required String devicePath,
    required String name,
    required int durationSeconds,
    DateTime? createdAt,
    String? sessionId,
    String? format,
    String? container,
    int? sampleRate,
    int? channels,
    int? bitDepth,
    DateTime? startedAt,
    DateTime? endedAt,
    int? mtu,
    String? tmpPath,
  }) async {
    final id = '${deviceId}_$devicePath';
    final now = DateTime.now().toIso8601String();
    final created = (createdAt ?? DateTime.now()).toIso8601String();
    final nowDt = DateTime.now();
    final existing = await getById(id);
    final preserveReceived = existing?.receivedBytes ?? 0;
    final preserveExpected = existing?.expectedBytes;
    final preserveProgress = existing?.transferProgress;
    final preserveTransferStartedAt = existing?.transferStartedAt;
    final asrResultId =
        (existing?.asrResultId != null && existing!.asrResultId! > 0)
            ? existing.asrResultId
            : await _generateUniqueAsrResultId();
    await db.insert(
      'recordings',
      {
        'id': id,
        'device_id': deviceId,
        'device_path': devicePath,
        'session_id': sessionId,
        'asr_result_id': asrResultId,
        'recording_state': 'transferring',
        'started_at': startedAt?.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'tmp_path': tmpPath,
        'mtu': mtu,
        'last_packet_at': null,
        'transfer_started_at': (preserveTransferStartedAt ?? nowDt)
            .toIso8601String(),
        'transfer_finished_at': null,
        'remote_id': null,
        'remote_url': null,
        'transport': 'ble',
        'connection_id': null,
        'last_stt_job_id': null,
        'last_summary_job_id': null,
        'name': name,
        'size_bytes': preserveExpected,
        'duration_seconds': durationSeconds,
        'created_at': created,
        'local_path': null,
        'format': format,
        'container': container,
        'sample_rate': sampleRate,
        'channels': channels,
        'bit_depth': bitDepth,
        'folder_id': null,
        'source': 'device',
        'is_deleted': 0,
        'deleted_at': null,
        'device_present': 1,
        'transfer_state': 'transferring',
        'transfer_progress':
            preserveReceived > 0 ? (preserveProgress ?? 0.0) : 0.0,
        'transfer_error': null,
        'transfer_error_code': null,
        'received_bytes': preserveReceived,
        'expected_bytes': preserveExpected,
        'last_seq': null,
        'crc32': null,
        'upload_state': 'not_uploaded',
        'job_state': 'none',
        'transcript': null,
        'summary': null,
        'current_summary_id': null,
        'transcript_path': null,
        'summary_path': null,
        'last_stt_config_id': null,
        'last_llm_config_id': null,
        'last_template_id': null,
        'last_language': null,
        'last_auto_speaker': 1,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return id;
  }

  // listAll moved above (supports includeDeleted)

  Future<Recording?> getById(String id) async {
    final rows = await db.query('recordings',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Rows with an in-flight transcription job (for startup / list reconcile).
  Future<List<Recording>> listTranscriptionJobsInProgress() async {
    final rows = await db.query(
      'recordings',
      where: "is_deleted = 0 AND job_state IN ('queued', 'transcribing')",
      orderBy: 'updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> updateJobState(String id, String jobState,
      {double? progress, String? sttJobId}) async {
    final now = DateTime.now().toIso8601String();
    final updates = <String, Object?>{
      'job_state': jobState,
      'updated_at': now,
    };
    if (sttJobId != null) {
      updates['last_stt_job_id'] =
          sttJobId.trim().isEmpty ? null : sttJobId.trim();
    }
    await db.update(
      'recordings',
      updates,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateTranscript(String id, String transcript) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'recordings',
      {'transcript': transcript, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> clearTranscript(String id) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'recordings',
      {
        'transcript': null,
        'transcript_path': null,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateSummary(
    String id,
    String summary, {
    String? defaultTitlePrefix,
  }) async {
    // v15: summary becomes versioned. Keep old method name for call-sites,
    // but change behavior to "append a new summary version and set current".
    await addSummaryVersion(
      recordingId: id,
      content: summary,
      defaultTitlePrefix: defaultTitlePrefix,
    );
  }

  Future<void> clearSummary(String id) async {
    // Remove all summary versions and clear current selection.
    final now = DateTime.now().toIso8601String();
    await db.delete('recording_summaries',
        where: 'recording_id = ?', whereArgs: [id]);
    await db.update(
      'recordings',
      {
        'summary': null,
        'summary_path': null,
        'current_summary_id': null,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<RecordingSummaryVersion>> listSummaryVersions(
      String recordingId) async {
    final rows = await db.query(
      'recording_summaries',
      where: 'recording_id = ?',
      whereArgs: [recordingId],
      orderBy: 'version ASC',
    );
    DateTime parseDt(Object? v) =>
        v is String ? (DateTime.tryParse(v) ?? DateTime.now()) : DateTime.now();
    int parseInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
    int? parseNullableInt(Object? v) {
      if (v == null) return null;
      final parsed = parseInt(v);
      return parsed > 0 ? parsed : null;
    }

    return rows.map((r) {
      return RecordingSummaryVersion(
        id: r['id'] as String,
        recordingId: r['recording_id'] as String,
        version: parseInt(r['version']),
        title: (r['title'] as String?)?.trim() ?? '',
        content: (r['content'] as String?) ?? '',
        remoteSessionId: (r['remote_session_id'] as String?)?.trim(),
        remoteMessageId: parseNullableInt(r['remote_message_id']),
        createdAt: parseDt(r['created_at']),
        updatedAt: parseDt(r['updated_at']),
      );
    }).toList(growable: false);
  }

  Future<String> addSummaryVersion({
    required String recordingId,
    required String content,
    String? title,
    String? titlePrefix,

    /// Fallback title prefix when both title and titlePrefix are empty (i18n)
    String? defaultTitlePrefix,
    String? remoteSessionId,
    int? remoteMessageId,
  }) async {
    final now = DateTime.now().toIso8601String();
    final maxRows = await db.rawQuery(
      'SELECT MAX(version) AS v FROM recording_summaries WHERE recording_id = ?',
      [recordingId],
    );
    final maxV = (maxRows.isNotEmpty ? maxRows.first['v'] : null);
    final nextVersion =
        (maxV is int ? maxV : (maxV is num ? maxV.toInt() : 0)) + 1;
    final id = '${recordingId}__sum_v${nextVersion}__${_uuid.v4()}';
    final hasExplicitTitle = title != null && title.trim().isNotEmpty;
    final prefix = hasExplicitTitle
        ? title.trim()
        : ((titlePrefix != null && titlePrefix.trim().isNotEmpty)
            ? titlePrefix.trim()
            : (defaultTitlePrefix ?? 'Summary'));
    final resolvedTitle = hasExplicitTitle ? prefix : '$prefix V$nextVersion';
    await db.insert(
      'recording_summaries',
      {
        'id': id,
        'recording_id': recordingId,
        'version': nextVersion,
        'title': resolvedTitle,
        'content': content,
        'remote_session_id': (remoteSessionId ?? '').trim().isEmpty
            ? null
            : remoteSessionId!.trim(),
        'remote_message_id': (remoteMessageId != null && remoteMessageId > 0)
            ? remoteMessageId
            : null,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Keep a denormalized copy on recordings for list previews.
    await db.update(
      'recordings',
      {
        'summary': content,
        'current_summary_id': id,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [recordingId],
    );
    return id;
  }

  /// Delete local summary row matching remote map (no-op if missing).
  Future<void> deleteSummaryVersionByRemote({
    required String recordingId,
    required String remoteSessionId,
    required int remoteMessageId,
  }) async {
    final sid = remoteSessionId.trim();
    if (sid.isEmpty || remoteMessageId <= 0) return;
    final rows = await db.query(
      'recording_summaries',
      columns: ['id'],
      where:
          'recording_id = ? AND remote_session_id = ? AND remote_message_id = ?',
      whereArgs: [recordingId, sid, remoteMessageId],
      orderBy: 'version DESC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    final summaryId = (rows.first['id'] as String?) ?? '';
    if (summaryId.trim().isEmpty) return;
    await deleteSummaryVersion(recordingId: recordingId, summaryId: summaryId);
  }

  Future<void> setCurrentSummary({
    required String recordingId,
    required String summaryId,
  }) async {
    final rows = await db.query(
      'recording_summaries',
      columns: ['content'],
      where: 'id = ? AND recording_id = ?',
      whereArgs: [summaryId, recordingId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final content = (rows.first['content'] as String?) ?? '';
    final now = DateTime.now().toIso8601String();
    await db.update(
      'recordings',
      {
        'current_summary_id': summaryId,
        'summary': content,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [recordingId],
    );
  }

  Future<void> deleteSummaryVersion({
    required String recordingId,
    required String summaryId,
  }) async {
    await db.delete('recording_summaries',
        where: 'id = ? AND recording_id = ?',
        whereArgs: [summaryId, recordingId]);

    // Pick latest remaining as current.
    final remain = await db.query(
      'recording_summaries',
      where: 'recording_id = ?',
      whereArgs: [recordingId],
      orderBy: 'version DESC',
      limit: 1,
    );

    final now = DateTime.now().toIso8601String();
    if (remain.isEmpty) {
      await db.update(
        'recordings',
        {
          'current_summary_id': null,
          'summary': null,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [recordingId],
      );
      return;
    }

    final nextId = remain.first['id'] as String;
    final nextContent = (remain.first['content'] as String?) ?? '';
    await db.update(
      'recordings',
      {
        'current_summary_id': nextId,
        'summary': nextContent,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [recordingId],
    );
  }

  Future<void> updateAiSelection({
    required String id,
    String? sttConfigId,
    String? llmConfigId,
    String? templateId,
    String? language,
    bool? autoSpeaker,
  }) async {
    final now = DateTime.now().toIso8601String();
    final updates = <String, Object?>{'updated_at': now};
    if (sttConfigId != null) updates['last_stt_config_id'] = sttConfigId;
    if (llmConfigId != null) updates['last_llm_config_id'] = llmConfigId;
    if (templateId != null) updates['last_template_id'] = templateId;
    if (language != null) updates['last_language'] = language;
    if (autoSpeaker != null) updates['last_auto_speaker'] = autoSpeaker ? 1 : 0;
    await db.update('recordings', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> upsertFromDeviceFile({
    required String? deviceId,
    required String devicePath,
    required String? name,
    required int? sizeBytes,
    required int? durationSeconds,
    required DateTime? createdAt,
    DateTime? startedAt,
  }) async {
    // IMPORTANT: this must NOT override local fields (local_path, transcript,
    // summary, transfer state, AI selection, etc). We only upsert device metadata.
    final id = deviceId != null ? '${deviceId}_$devicePath' : _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final createdIso = (createdAt ?? DateTime.now()).toIso8601String();
    final startedIso = startedAt?.toIso8601String();

    // Insert if new (do not replace).
    await db.insert(
      'recordings',
      {
        'id': id,
        'device_id': deviceId,
        'device_path': devicePath,
        'name': name,
        'size_bytes': sizeBytes,
        'duration_seconds': durationSeconds,
        'created_at': createdIso,
        'started_at': startedIso,
        'source': 'device',
        'device_present': 1,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // Update device meta for existing row. Do not overwrite duration/size etc. with null.
    final existing = await getById(id);
    final existingName = (existing?.name ?? '').trim();
    final shouldUpdateName = name != null &&
        (existingName.isEmpty || isFirmwareStyleRecordingName(existingName));
    final updateMap = <String, Object?>{
      'device_id': deviceId,
      'device_path': devicePath,
      // If device did not provide createdAt, do not write null; use stable value so Create Time sort is meaningful.
      'created_at': createdIso,
      if (startedIso != null) 'started_at': startedIso,
      'source': 'device',
      'device_present': 1,
      'updated_at': now,
      if (shouldUpdateName) 'name': name,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
    };
    await db.update('recordings', updateMap, where: 'id = ?', whereArgs: [id]);
  }

  /// Create a new local recording entry (e.g. after trimming "Save As").
  ///
  /// Returns the new recording id.
  Future<String> createLocalRecording({
    required String name,
    required String localPath,
    required int durationSeconds,
    required int sizeBytes,
    DateTime? createdAt,
    String? format,
    String? container,
    int? sampleRate,
    int? channels,
    int? bitDepth,
    DateTime? startedAt,
    DateTime? endedAt,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final created = (createdAt ?? DateTime.now()).toIso8601String();
    final nowDt = DateTime.now();
    final asrResultId = await _generateUniqueAsrResultId();
    await db.insert(
      'recordings',
      {
        'id': id,
        'device_id': null,
        'device_path': 'local',
        'session_id': null,
        'asr_result_id': asrResultId,
        'recording_state': 'done',
        'started_at': startedAt?.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'tmp_path': null,
        'mtu': null,
        'last_packet_at': null,
        'transfer_started_at': nowDt.toIso8601String(),
        'transfer_finished_at': nowDt.toIso8601String(),
        'remote_id': null,
        'remote_url': null,
        'transport': null,
        'connection_id': null,
        'last_stt_job_id': null,
        'last_summary_job_id': null,
        'name': name,
        'size_bytes': sizeBytes,
        'duration_seconds': durationSeconds,
        'created_at': created,
        'local_path': localPath,
        'format': format,
        'container': container,
        'sample_rate': sampleRate,
        'channels': channels,
        'bit_depth': bitDepth,
        'folder_id': null,
        'source': 'local',
        'is_deleted': 0,
        'deleted_at': null,
        'device_present': 0,
        'transfer_state': 'done',
        'transfer_progress': 1.0,
        'transfer_error': null,
        'transfer_error_code': null,
        'received_bytes': sizeBytes,
        'expected_bytes': sizeBytes,
        'last_seq': null,
        'crc32': null,
        'upload_state': 'not_uploaded',
        'job_state': 'none',
        'transcript': null,
        'summary': null,
        'current_summary_id': null,
        'transcript_path': null,
        'summary_path': null,
        'last_stt_config_id': null,
        'last_llm_config_id': null,
        'last_template_id': null,
        'last_language': null,
        'last_auto_speaker': 1,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return id;
  }

  Recording _fromRow(Map<String, Object?> r) {
    DateTime? parseDt(Object? v) => v is String ? DateTime.tryParse(v) : null;
    int? parseInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    double? parseDouble(Object? v) =>
        v is double ? v : (v is num ? v.toDouble() : null);

    return Recording(
      id: r['id'] as String,
      deviceId: r['device_id'] as String?,
      devicePath: r['device_path'] as String,
      sessionId: r['session_id'] as String?,
      asrResultId: parseInt(r['asr_result_id']),
      recordingState: r['recording_state'] as String?,
      startedAt: parseDt(r['started_at']),
      endedAt: parseDt(r['ended_at']),
      tmpPath: r['tmp_path'] as String?,
      mtu: parseInt(r['mtu']),
      lastPacketAt: parseDt(r['last_packet_at']),
      transferStartedAt: parseDt(r['transfer_started_at']),
      transferFinishedAt: parseDt(r['transfer_finished_at']),
      remoteId: r['remote_id'] as String?,
      remoteUrl: r['remote_url'] as String?,
      transport: r['transport'] as String?,
      connectionId: r['connection_id'] as String?,
      lastSttJobId: r['last_stt_job_id'] as String?,
      lastSummaryJobId: r['last_summary_job_id'] as String?,
      name: r['name'] as String?,
      sizeBytes: parseInt(r['size_bytes']),
      durationSeconds: parseInt(r['duration_seconds']),
      createdAt: parseDt(r['created_at']),
      localPath: r['local_path'] as String?,
      format: r['format'] as String?,
      container: r['container'] as String?,
      sampleRate: parseInt(r['sample_rate']),
      channels: parseInt(r['channels']),
      bitDepth: parseInt(r['bit_depth']),
      receivedBytes: parseInt(r['received_bytes']),
      expectedBytes: parseInt(r['expected_bytes']),
      lastSeq: parseInt(r['last_seq']),
      crc32: parseInt(r['crc32']),
      folderId: r['folder_id'] as String?,
      source: (r['source'] as String?) ??
          (r['device_id'] == null ? 'local' : 'device'),
      isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
      deletedAt: parseDt(r['deleted_at']),
      devicePresent: (r['device_present'] as int? ?? 1) == 1,
      transferState: (r['transfer_state'] as String?) ?? 'not_started',
      transferProgress: parseDouble(r['transfer_progress']),
      transferError: r['transfer_error'] as String?,
      transferErrorCode: r['transfer_error_code'] as String?,
      uploadState: (r['upload_state'] as String?) ?? 'not_uploaded',
      jobState: (r['job_state'] as String?) ?? 'none',
      transcript: r['transcript'] as String?,
      summary: r['summary'] as String?,
      currentSummaryId: r['current_summary_id'] as String?,
      transcriptPath: r['transcript_path'] as String?,
      summaryPath: r['summary_path'] as String?,
      lastSttConfigId: r['last_stt_config_id'] as String?,
      lastLlmConfigId: r['last_llm_config_id'] as String?,
      lastTemplateId: r['last_template_id'] as String?,
      lastLanguage: r['last_language'] as String?,
      lastAutoSpeaker: (r['last_auto_speaker'] as int? ?? 1) == 1,
      updatedAt: parseDt(r['updated_at']) ?? DateTime.now(),
    );
  }
}
