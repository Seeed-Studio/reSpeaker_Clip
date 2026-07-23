import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../log/app_log.dart';
import 'app_database.dart';

/// One-time merge of legacy per-account SQLite files into [AppDatabase]'s default DB.
class DbUnifiedMigration {
  static const _kDone = 'db_unified_migration_v1_done';

  static const _tablesInOrder = <String>[
    'folders',
    'devices',
    'recordings',
    'recording_summaries',
    'jobs',
    'llm_sessions',
    'llm_session_messages',
  ];

  /// Copies rows from `respeaker_app_user_*.db` (and any non-target shards) into
  /// the unified `respeaker_app.db`. Legacy files are kept on disk as backup.
  static Future<void> runIfNeeded(Database target) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kDone) == true) return;

    final targetPath = await AppDatabase.dbPathForUserKey(null);
    final dir = await getApplicationDocumentsDirectory();
    final shards = dir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('respeaker_app'))
        .where((f) => f.path.endsWith('.db'))
        .where((f) => p.normalize(f.path) != p.normalize(targetPath))
        .toList();

    var mergedRows = 0;
    for (final file in shards) {
      Database? src;
      try {
        src = await openDatabase(file.path, readOnly: true);
        for (final table in _tablesInOrder) {
          mergedRows += await _copyTable(src, target, table);
        }
      } catch (e, st) {
        AppLog.w('DbUnifiedMigration: skip ${file.path}', e, st);
      } finally {
        await src?.close();
      }
    }

    await prefs.setBool(_kDone, true);
    AppLog.i(
      'DbUnifiedMigration: done mergedRows=$mergedRows shards=${shards.length} -> $targetPath',
    );
  }

  static Future<int> _copyTable(
    Database src,
    Database dst,
    String table,
  ) async {
    try {
      final rows = await src.query(table);
      if (rows.isEmpty) return 0;
      final batch = dst.batch();
      for (final row in rows) {
        batch.insert(
          table,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      return rows.length;
    } catch (_) {
      return 0;
    }
  }
}
