import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/db/db_provider.dart';
import '../domain/llm_session.dart';
import '../domain/llm_session_message.dart';

final llmSessionRepositoryProvider = FutureProvider<LlmSessionRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return LlmSessionRepository(db);
});

class LlmSessionRepository {
  final Database db;
  LlmSessionRepository(this.db);

  Future<List<LlmSession>> listSessions() async {
    final rows = await db.query('llm_sessions', orderBy: 'updated_at DESC');
    return rows.map(_sessionFromRow).toList();
  }

  Future<List<LlmSessionMessage>> listMessages(String sessionId) async {
    final rows = await db.query(
      'llm_session_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(_messageFromRow).toList();
  }

  Future<void> upsertSessions(List<LlmSession> list) async {
    final batch = db.batch();
    for (final s in list) {
      batch.insert(
        'llm_sessions',
        {
          'session_id': s.sessionId,
          'title': s.title,
          'created_at': s.createdAt?.toIso8601String(),
          'updated_at': s.updatedAt?.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> replaceMessages(String sessionId, List<LlmSessionMessage> list) async {
    final batch = db.batch();
    batch.delete('llm_session_messages', where: 'session_id = ?', whereArgs: [sessionId]);
    for (final m in list) {
      batch.insert(
        'llm_session_messages',
        {
          'id': m.id,
          'session_id': m.sessionId,
          'role': m.role,
          'content': m.content,
          'created_at': m.createdAt?.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteSession(String sessionId) async {
    final batch = db.batch();
    batch.delete('llm_session_messages', where: 'session_id = ?', whereArgs: [sessionId]);
    batch.delete('llm_sessions', where: 'session_id = ?', whereArgs: [sessionId]);
    await batch.commit(noResult: true);
  }

  /// Delete the local cached round that contains [messageId].
  ///
  /// The server deletes a user+assistant round for this endpoint, so the cache
  /// must mirror that behavior or fallback history can show a deleted summary.
  Future<void> deleteMessage(String sessionId, int messageId) async {
    final rows = await db.query(
      'llm_session_messages',
      where: 'session_id = ? AND id = ?',
      whereArgs: [sessionId, messageId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final role = (rows.first['role'] ?? '').toString();
    final ids = <int>{messageId};
    final partnerWhere = role == 'user'
        ? 'session_id = ? AND id > ? AND role = ?'
        : 'session_id = ? AND id < ? AND role = ?';
    final partnerArgs = role == 'user'
        ? <Object>[sessionId, messageId, 'assistant']
        : <Object>[sessionId, messageId, 'user'];
    final partnerOrder = role == 'user' ? 'id ASC' : 'id DESC';
    final partnerRows = await db.query(
      'llm_session_messages',
      columns: ['id'],
      where: partnerWhere,
      whereArgs: partnerArgs,
      orderBy: partnerOrder,
      limit: 1,
    );
    if (partnerRows.isNotEmpty) {
      final id = (partnerRows.first['id'] is num)
          ? (partnerRows.first['id'] as num).toInt()
          : int.tryParse((partnerRows.first['id'] ?? '').toString());
      if (id != null && id > 0) ids.add(id);
    }
    await db.delete(
      'llm_session_messages',
      where:
          'session_id = ? AND id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [sessionId, ...ids],
    );
  }

  LlmSession _sessionFromRow(Map<String, Object?> r) {
    DateTime? parseDt(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return LlmSession(
      sessionId: (r['session_id'] ?? '').toString(),
      title: (r['title'] ?? '').toString(),
      createdAt: parseDt(r['created_at']),
      updatedAt: parseDt(r['updated_at']),
    );
  }

  LlmSessionMessage _messageFromRow(Map<String, Object?> r) {
    DateTime? parseDt(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final id = (r['id'] is num) ? (r['id'] as num).toInt() : int.tryParse((r['id'] ?? '').toString()) ?? 0;
    return LlmSessionMessage(
      id: id,
      sessionId: (r['session_id'] ?? '').toString(),
      role: (r['role'] ?? '').toString(),
      content: (r['content'] ?? '').toString(),
      createdAt: parseDt(r['created_at']),
    );
  }
}
