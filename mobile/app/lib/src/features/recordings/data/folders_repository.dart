import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';

import '../../../core/db/db_provider.dart';
import '../domain/folder.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final foldersRepositoryProvider = FutureProvider<FoldersRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return FoldersRepository(db);
});

class FoldersRepository {
  final Database db;
  static const _uuid = Uuid();

  FoldersRepository(this.db);

  Future<List<Folder>> listAll() async {
    final rows = await db.query('folders', orderBy: 'sort_index ASC, created_at DESC');
    return rows.map(_fromRow).toList();
  }

  Future<Folder?> getById(String id) async {
    final rows = await db.query('folders', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<String> create({
    required String name,
    required int color,
    required int icon,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final sortIndex = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'folders',
      {
        'id': id,
        'name': name,
        'color': color,
        'icon': icon,
        'sort_index': sortIndex,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return id;
  }

  Future<void> rename({required String id, required String name}) async {
    final now = DateTime.now().toIso8601String();
    await db.update('folders', {'name': name, 'updated_at': now}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteFolder({required String id}) async {
    // Unassign recordings in this folder.
    final now = DateTime.now().toIso8601String();
    await db.update('recordings', {'folder_id': null, 'updated_at': now}, where: 'folder_id = ?', whereArgs: [id]);
    await db.delete('folders', where: 'id = ?', whereArgs: [id]);
  }

  Folder _fromRow(Map<String, Object?> r) {
    DateTime parseDt(Object? v) => v is String ? (DateTime.tryParse(v) ?? DateTime.now()) : DateTime.now();
    int parseInt(Object? v, int def) => v is int ? v : (v is num ? v.toInt() : def);
    return Folder(
      id: r['id'] as String,
      name: (r['name'] as String?) ?? 'Folder',
      color: parseInt(r['color'], 0xFF8FC31F),
      icon: parseInt(r['icon'], Icons.folder.codePoint),
      sortIndex: parseInt(r['sort_index'], 0),
      createdAt: parseDt(r['created_at']),
      updatedAt: parseDt(r['updated_at']),
    );
  }
}

