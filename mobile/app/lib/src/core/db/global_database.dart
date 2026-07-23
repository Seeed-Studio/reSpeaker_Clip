import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../log/app_log.dart';

/// Account-independent SQLite (`respeaker_global.db`).
///
/// Holds data tied to the phone/hardware rather than the logged-in user — most
/// importantly the bound `devices` list, so a BLE device stays available across
/// logout / account switch.
class GlobalDatabase {
  GlobalDatabase._();

  static const _dbName = 'respeaker_global.db';
  static const _dbVersion = 1;

  static const _createDevices = '''
CREATE TABLE devices(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  sn TEXT,
  model TEXT NOT NULL,
  battery_percent INTEGER,
  recording_mode INTEGER NOT NULL DEFAULT 0,
  firmware_version TEXT,
  has_firmware_update INTEGER NOT NULL DEFAULT 0,
  is_online INTEGER NOT NULL DEFAULT 0,
  last_seen TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''';

  static Future<String> dbPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _dbName);
  }

  static Future<Database> open() async {
    final path = await dbPath();
    final db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute(_createDevices);
        await db.execute(
          'CREATE INDEX idx_devices_is_online ON devices(is_online);',
        );
      },
    );
    await _migrateDevicesFromAccountShardsIfEmpty(db);
    return db;
  }

  /// One-time recovery: when the global `devices` table is empty (first run
  /// after devices were account-scoped), pull device rows from every
  /// `respeaker_app*.db` shard so previously-bound devices are not lost.
  static Future<void> _migrateDevicesFromAccountShardsIfEmpty(
    Database db,
  ) async {
    try {
      final existing = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM devices'),
          ) ??
          0;
      if (existing > 0) return;

      final dir = await getApplicationDocumentsDirectory();
      final shards = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('respeaker_app'))
          .where((f) => f.path.endsWith('.db'))
          .toList();

      var imported = 0;
      for (final file in shards) {
        Database? src;
        try {
          src = await openDatabase(file.path, readOnly: true);
          final hasDevices = (await src.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='devices'",
          ))
              .isNotEmpty;
          if (!hasDevices) continue;
          final rows = await src.query('devices');
          if (rows.isEmpty) continue;
          final batch = db.batch();
          for (final row in rows) {
            batch.insert(
              'devices',
              row,
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
          await batch.commit(noResult: true);
          imported += rows.length;
        } catch (e, st) {
          AppLog.w('GlobalDatabase: skip shard ${file.path}', e, st);
        } finally {
          await src?.close();
        }
      }
      if (imported > 0) {
        AppLog.i('GlobalDatabase: migrated $imported device row(s) to global db');
      }
    } catch (e, st) {
      AppLog.w('GlobalDatabase: device migration failed', e, st);
    }
  }
}
