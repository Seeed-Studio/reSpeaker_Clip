// Per-account SQLite: `respeaker_app_{userId}.db` (see [AppDatabase.dbPathForUserKey]).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../log/app_log.dart';
import 'account_db_key.dart';
import 'app_database.dart';
import 'global_database.dart';

/// SQLite opened per logged-in account (`respeaker_app_{userId}.db`).
final databaseProvider = FutureProvider<Database>((ref) async {
  final key = ref.watch(accountDbKeyProvider);
  if (key == null || key.isEmpty) {
    throw StateError('Database unavailable: user not logged in');
  }

  final dbPath = await AppDatabase.dbPathForUserKey(key);
  AppLog.i('databaseProvider: open accountKey=$key path=$dbPath');
  final db = await AppDatabase.openForUserKey(key);
  ref.onDispose(() async {
    await db.close();
  });
  return db;
});

/// Account-independent SQLite (`respeaker_global.db`), e.g. the bound device
/// list. Opened once and kept across logout / account switch.
final globalDatabaseProvider = FutureProvider<Database>((ref) async {
  final db = await GlobalDatabase.open();
  ref.onDispose(() async {
    await db.close();
  });
  return db;
});

// Account-wide cache invalidation: [account_scope_invalidation.dart].
