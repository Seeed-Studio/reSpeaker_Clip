import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/server/api/llm_api.dart';
import '../../../core/server/server_providers.dart';
import '../domain/prompt_template.dart';

final promptTemplateRemoteRepositoryProvider =
    Provider<PromptTemplateRemoteRepository>((ref) {
  return PromptTemplateRemoteRepository(api: ref.watch(llmApiProvider));
});

/// Prompt templates are API-only (no local SQLite cache), same as STT/LLM.
class PromptTemplateRemoteRepository {
  final LlmApi api;

  PromptTemplateRemoteRepository({required this.api});

  /// Public defaults (`/llm/prompt/public`) + user templates (`/llm/prompt`).
  Future<List<PromptTemplate>> fetchTemplateList() async {
    final now = DateTime.now();
    final public = await api.listPublicPromptTemplates();
    final user = await api.listPromptTemplates();

    final list = <PromptTemplate>[];
    final seenRemoteIds = <int>{};

    for (var i = 0; i < public.length; i++) {
      final entry = public[i];
      final t = _entryToTemplate(
        entry,
        isDefault: true,
        sortIndex: i - public.length,
        now: now,
      );
      if (t.remoteId != null) seenRemoteIds.add(t.remoteId!);
      list.add(t);
    }

    for (var i = 0; i < user.length; i++) {
      final entry = user[i];
      final remoteId = entry.id;
      if (remoteId != null && seenRemoteIds.contains(remoteId)) continue;
      list.add(
        _entryToTemplate(
          entry,
          isDefault: entry.isDefault,
          sortIndex: i,
          now: now,
        ),
      );
    }
    return list;
  }

  Future<PromptTemplate> createTemplate({
    required String name,
    required String prompt,
    int iconCode = 0,
  }) async {
    final created = await api.createPromptTemplate(
      name: name,
      content: prompt,
      isDefault: false,
    );
    return _entryToTemplate(
      created,
      isDefault: false,
      sortIndex: 0,
      now: DateTime.now(),
      iconCode: iconCode,
    );
  }

  Future<void> updateTemplate(PromptTemplate t) async {
    final remoteId = t.remoteId ?? await _resolveRemoteId(t);
    if (remoteId == null) {
      await api.createPromptTemplate(
        name: t.name,
        content: t.prompt,
        isDefault: t.isDefault,
      );
      return;
    }
    await api.updatePromptTemplate(
      id: remoteId,
      name: t.name,
      content: t.prompt,
      isDefault: t.isDefault,
    );
  }

  Future<void> deleteTemplate(PromptTemplate t) async {
    final remoteId = t.remoteId ?? await _resolveRemoteId(t);
    if (remoteId == null) return;
    await api.deletePromptTemplate(remoteId);
  }

  Future<LlmPromptImportPreview> previewImportByKey(String key) async {
    return api.previewPromptImport(key);
  }

  Future<PromptTemplate?> importTemplateByKey(String key) async {
    final preview = await api.importPromptTemplate(key);
    if (preview.name.trim().isEmpty && preview.content.trim().isEmpty) {
      return null;
    }
    final now = DateTime.now();
    final remoteId = preview.id;
    return PromptTemplate(
      id: remoteId != null
          ? PromptTemplate.idForRemote(remoteId)
          : 'tpl_import_${now.microsecondsSinceEpoch}',
      remoteId: remoteId,
      name: preview.name.isEmpty ? 'Imported Template' : preview.name,
      prompt: preview.content,
      isDefault: false,
      isImported: true,
      iconCode: 0,
      sortIndex: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<String> startShare(PromptTemplate t) async {
    await updateTemplate(t);
    final remoteId = t.remoteId ?? await _resolveRemoteId(t);
    if (remoteId == null) return '';
    return api.startPromptShare(remoteId);
  }

  Future<void> stopShare(PromptTemplate t) async {
    final remoteId = t.remoteId ?? await _resolveRemoteId(t);
    if (remoteId == null) return;
    await api.stopPromptShare(remoteId);
  }

  PromptTemplate _entryToTemplate(
    LlmPromptTemplateEntry entry, {
    required bool isDefault,
    required int sortIndex,
    required DateTime now,
    int iconCode = 0,
    bool isImported = false,
  }) {
    final remoteId = entry.id;
    return PromptTemplate(
      id: remoteId != null
          ? PromptTemplate.idForRemote(remoteId)
          : 'tpl_${now.microsecondsSinceEpoch}_$sortIndex',
      remoteId: remoteId,
      name: entry.name,
      prompt: entry.content,
      isDefault: isDefault,
      shareKey: entry.shareKey,
      isImported: isImported,
      iconCode: iconCode,
      sortIndex: sortIndex,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<int?> _resolveRemoteId(PromptTemplate t) async {
    if (t.remoteId != null) return t.remoteId;
    final remote = await api.listPromptTemplates();
    for (final r in remote) {
      if (r.name == t.name && r.content == t.prompt) return r.id;
    }
    return null;
  }
}
