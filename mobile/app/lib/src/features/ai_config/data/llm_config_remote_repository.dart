import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/server/api/llm_api.dart';
import '../../../core/server/server_providers.dart';
import '../domain/ai_providers.dart';
import '../domain/llm_config.dart';
import '../domain/llm_vendor_config.dart';

final llmConfigRemoteRepositoryProvider =
    FutureProvider<LlmConfigRemoteRepository>((ref) async {
  final api = ref.watch(llmApiProvider);
  return LlmConfigRemoteRepository(api: api);
});

class LlmConfigRemoteRepository {
  final LlmApi api;

  LlmConfigRemoteRepository({required this.api});

  /// List LLM configs from API (no local cache merge).
  Future<List<LlmConfig>> fetchConfigList() async {
    final remote = await api.getConfigList();
    final now = DateTime.now();
    final list = <LlmConfig>[];

    if (remote.items.isEmpty) return list;

    for (var i = 0; i < remote.items.length; i++) {
      final item = remote.items[i];
      final provider = _providerFromCode(item.code);
      if (provider == null) continue;
      // Skip when server returns empty config_json
      if (item.configJson.trim().isEmpty) continue;
      final cfg =
          _itemToLlmConfig(item, provider: provider, sortIndex: i, now: now);
      list.add(cfg);
    }
    return list;
  }

  /// Create LLM config on server.
  Future<void> createConfigToRemote(LlmConfig cfg) async {
    final code = cfg.provider.llmVendorCode;
    if (code == null) return;
    await api.createConfig(
        code: code, configJson: cfg.toLlmVendorConfigObject());
  }

  /// Test LLM config connectivity (POST /api/v1/llm/config/test)
  Future<LlmConfigTestResult> testConnection(LlmConfig cfg) async {
    final code = cfg.llmVendorCodeOrThrow;
    return api.testConfig(
      code: code,
      configJson: cfg.toLlmVendorConfigObject(),
    );
  }

  /// Update LLM config on server.
  Future<void> updateConfigToRemote(LlmConfig cfg) async {
    final code = cfg.provider.llmVendorCode;
    if (code == null) return;
    var remoteId = cfg.llmRemoteConfigId;
    remoteId ??= await _resolveRemoteIdByCode(code);
    if (remoteId == null) {
      await createConfigToRemote(cfg);
      return;
    }
    await api.updateConfigById(
      id: remoteId,
      configJson: cfg.toLlmVendorConfigObject(),
      code: cfg.provider.llmVendorCode,
    );
  }

  /// Build a new [LlmConfig] without reading local DB.
  LlmConfig buildConfigForCreate({
    required LlmProvider provider,
    required String name,
    required String apiKey,
    String? apiSecret,
    String? appId,
    String? accessKeyId,
    String? accessKeySecret,
    String? region,
    String? baseUrl,
    String? modelName,
    String? moduleName,
    String? extraJson,
  }) {
    final code = provider.llmVendorCode;
    final id = code != null
        ? 'llm_$code'
        : 'llm-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now();
    return LlmConfig(
      id: id,
      provider: provider,
      name: name,
      apiKey: apiKey,
      apiSecret: apiSecret,
      appId: appId,
      accessKeyId: accessKeyId,
      accessKeySecret: accessKeySecret,
      region: region,
      baseUrl: baseUrl,
      modelName: modelName,
      moduleName: moduleName,
      extraJson: extraJson,
      sortIndex: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Delete LLM config on server.
  Future<void> deleteConfigFromRemote(LlmConfig cfg) async {
    var remoteId = cfg.llmRemoteConfigId;
    final code = cfg.provider.llmVendorCode;
    remoteId ??= (code == null) ? null : await _resolveRemoteIdByCode(code);
    if (remoteId == null) return;
    await api.deleteConfigById(remoteId);
  }

  LlmConfig _itemToLlmConfig(
    LlmConfigItem item, {
    required LlmProvider provider,
    required int sortIndex,
    required DateTime now,
  }) {
    Map<String, dynamic> m = <String, dynamic>{};
    final raw = item.configJson.trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          m = decoded.map((k, v) => MapEntry(k.toString(), v));
        } else if (decoded is String) {
          final decoded2 = jsonDecode(decoded);
          if (decoded2 is Map) {
            m = decoded2.map((k, v) => MapEntry(k.toString(), v));
          }
        }
      } catch (_) {
        // ignore
      }
    }

    String? stringOrNull(Object? v) {
      final s = (v ?? '').toString().trim();
      return s.isEmpty ? null : s;
    }

    String? extraJson;
    if (m.isEmpty && raw.isNotEmpty) {
      extraJson = raw;
    } else {
      final extraRaw = m['extra_json'];
      extraJson = extraRaw == null
          ? null
          : (extraRaw is String ? extraRaw : jsonEncode(extraRaw));
    }

    final id = 'llm_${item.code.trim()}';
    final name = '${provider.label} API';
    final mergedExtra = _attachRemoteId(extraJson, item.id);

    return LlmConfig(
      id: id,
      provider: provider,
      name: name,
      apiKey: (m['api_key'] ?? '').toString(),
      apiSecret: stringOrNull(m['api_secret']),
      appId: stringOrNull(m['app_id']),
      accessKeyId: stringOrNull(m['access_key_id']),
      accessKeySecret: stringOrNull(m['access_key_secret']),
      region: stringOrNull(m['region']),
      baseUrl: stringOrNull(m['base_url']),
      modelName: stringOrNull(m['model_name']) ?? stringOrNull(m['model']),
      moduleName: stringOrNull(m['module_name']),
      extraJson: mergedExtra,
      sortIndex: sortIndex,
      createdAt: now,
      updatedAt: now,
    );
  }

  LlmProvider? _providerFromCode(String code) {
    return switch (code) {
      'openai' => LlmProvider.openAi,
      'anthropic' => LlmProvider.anthropic,
      'google_gemini' => LlmProvider.googleGemini,
      'llama' => LlmProvider.llama,
      'doubao' => LlmProvider.doubao,
      'qwen' => LlmProvider.qwen,
      'deepseek' => LlmProvider.deepseek,
      'openrouter' => LlmProvider.openRouter,
      _ => null,
    };
  }

  Future<int?> _resolveRemoteIdByCode(String code) async {
    final remote = await api.getConfigList();
    for (final item in remote.items) {
      if (item.code == code && item.id != null) return item.id;
    }
    return null;
  }

  String? _attachRemoteId(String? extraJson, int? remoteId) {
    if (remoteId == null) return extraJson;
    Map<String, dynamic> m = <String, dynamic>{};
    if (extraJson != null && extraJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(extraJson);
        if (decoded is Map) {
          m = decoded.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {
        m = <String, dynamic>{};
      }
    }
    m['_remote_id'] = remoteId;
    return jsonEncode(m);
  }
}
