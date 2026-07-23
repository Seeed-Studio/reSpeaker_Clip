import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/server/api/llm_api.dart';
import '../../../core/server/server_providers.dart';
import '../domain/llm_session.dart';
import '../domain/llm_session_message.dart';
import 'llm_session_repository.dart';

final llmSessionRemoteRepositoryProvider = FutureProvider<LlmSessionRemoteRepository>((ref) async {
  final api = ref.watch(llmApiProvider);
  final local = await ref.watch(llmSessionRepositoryProvider.future);
  return LlmSessionRemoteRepository(api: api, local: local);
});

class LlmSessionRemoteRepository {
  final LlmApi api;
  final LlmSessionRepository local;

  LlmSessionRemoteRepository({required this.api, required this.local});

  /// Remote-only (throws on failure); on success writes local cache.
  Future<List<LlmSession>> listSessionsRemote({
    String? macAddress,
    int? asrResultId,
    bool includeMessages = false,
    int messageLimit = 100,
  }) async {
    final remote = await api.listSessions(
      macAddress: macAddress,
      asrResultId: asrResultId,
      includeMessages: includeMessages,
      messageLimit: includeMessages ? messageLimit : null,
    );
    final mapped = remote.map((it) => _toSession(it, includeMessages: includeMessages)).toList(growable: false);
    await local.upsertSessions(mapped);
    if (includeMessages) {
      for (final it in remote) {
        final msgs = it.messages.map((m) => _toMessage(it.sessionId, m)).toList(growable: false);
        await local.replaceMessages(it.sessionId, msgs);
      }
    }
    return mapped;
  }

  /// Local cache only (no network).
  Future<List<LlmSession>> listSessionsLocal({bool includeMessages = false}) async {
    final cached = await local.listSessions();
    if (!includeMessages) return cached;
    final out = <LlmSession>[];
    for (final s in cached) {
      final msgs = await local.listMessages(s.sessionId);
      out.add(s.copyWith(messages: msgs));
    }
    return out;
  }

  /// Prefer remote, fall back to local cache on failure.
  ///
  /// When [includeMessages] is true, hydrate each session's messages from the list API payload
  /// and mirror into `llm_session_messages`.
  Future<List<LlmSession>> listSessionsPreferRemote({
    String? macAddress,
    int? asrResultId,
    bool includeMessages = false,
    int messageLimit = 100,
  }) async {
    try {
      return await listSessionsRemote(
        macAddress: macAddress,
        asrResultId: asrResultId,
        includeMessages: includeMessages,
        messageLimit: messageLimit,
      );
    } catch (_) {
      return listSessionsLocal(includeMessages: includeMessages);
    }
  }

  /// Delete session: remote first, then local cache on success.
  Future<void> deleteSession(String sessionId) async {
    await api.deleteSession(sessionId);
    await local.deleteSession(sessionId);
  }

  /// Delete message: remote first, then local cache on success.
  Future<void> deleteMessage(String sessionId, int messageId) async {
    await api.deleteSessionMessage(sessionId, messageId);
    await local.deleteMessage(sessionId, messageId);
  }

  /// Fetch all messages for a session from API and write local cache.
  Future<List<LlmSessionMessage>> getSessionMessagesRemote(String sessionId) async {
    final items = await api.getSessionMessages(sessionId);
    final msgs = items.map((m) => _toMessage(sessionId, m)).toList(growable: false);
    await local.replaceMessages(sessionId, msgs);
    return msgs;
  }


  LlmSession _toSession(LlmSessionItem item, {required bool includeMessages}) {
    DateTime? parseDt(String raw) => raw.isEmpty ? null : DateTime.tryParse(raw);
    return LlmSession(
      sessionId: item.sessionId,
      title: item.title,
      createdAt: parseDt(item.createdAt),
      updatedAt: parseDt(item.updatedAt),
      messages: includeMessages
          ? item.messages.map((m) => _toMessage(item.sessionId, m)).toList(growable: false)
          : null,
    );
  }

  LlmSessionMessage _toMessage(String sessionId, LlmSessionMessageItem item) {
    DateTime? parseDt(String raw) => raw.isEmpty ? null : DateTime.tryParse(raw);
    return LlmSessionMessage(
      id: item.id,
      sessionId: sessionId,
      role: item.role,
      content: item.content,
      createdAt: parseDt(item.createdAt),
    );
  }
}
