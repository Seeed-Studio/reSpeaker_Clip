import 'dart:convert';

import 'ai_providers.dart';
import 'llm_config.dart';

Map<String, dynamic> _decodeExtraJsonObject(String? extraJson) {
  final raw = (extraJson ?? '').trim();
  if (raw.isEmpty) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
  } catch (_) {
    // ignore
  }
  return <String, dynamic>{};
}

int? _extractRemoteConfigId(String? extraJson) {
  final m = _decodeExtraJsonObject(extraJson);
  final raw = m['_remote_id'];
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

String? _mergeRemoteConfigId(String? extraJson, int? remoteId) {
  if (remoteId == null) return extraJson;
  final m = _decodeExtraJsonObject(extraJson);
  m['_remote_id'] = remoteId;
  return jsonEncode(m);
}

extension LlmConfigVendorConfigX on LlmConfig {
  int? get llmRemoteConfigId => _extractRemoteConfigId(extraJson);

  String? withLlmRemoteConfigId(int? remoteId) => _mergeRemoteConfigId(extraJson, remoteId);

  /// Build LLM `config_json` object (not stringified)
  Map<String, dynamic> toLlmVendorConfigObject() {
    final m = <String, dynamic>{};
    if (apiKey.trim().isNotEmpty) m['api_key'] = apiKey.trim();
    if ((apiSecret ?? '').trim().isNotEmpty) m['api_secret'] = apiSecret!.trim();
    if ((appId ?? '').trim().isNotEmpty) m['app_id'] = appId!.trim();
    if ((accessKeyId ?? '').trim().isNotEmpty) m['access_key_id'] = accessKeyId!.trim();
    if ((accessKeySecret ?? '').trim().isNotEmpty) m['access_key_secret'] = accessKeySecret!.trim();
    if ((region ?? '').trim().isNotEmpty) m['region'] = region!.trim();
    if ((baseUrl ?? '').trim().isNotEmpty) m['base_url'] = baseUrl!.trim();
    if ((modelName ?? '').trim().isNotEmpty) m['model_name'] = modelName!.trim();
    if ((moduleName ?? '').trim().isNotEmpty) m['module_name'] = moduleName!.trim();

    final extraRaw = (extraJson ?? '').trim();
    if (extraRaw.isNotEmpty) {
      final extra = _decodeExtraJsonObject(extraJson);
      m['extra_json'] = extra.isNotEmpty ? extra : extraRaw;
    }
    return m;
  }

  String get llmVendorCodeOrThrow {
    final code = provider.llmVendorCode;
    if (code == null) {
      throw UnsupportedError('Provider ${provider.name} has no llmVendorCode mapping');
    }
    return code;
  }
}

extension LlmConfigIterableStoredIdX on Iterable<LlmConfig> {
  /// Resolves a persisted [storedId] after the list is refreshed from the server.
  ///
  /// Supports ids like `llm_<remoteNumericId>`, matching by [LlmConfig.llmRemoteConfigId],
  /// and legacy `llm_<vendorCode>` when only one config exists for that code.
  LlmConfig? resolveStoredLlmId(String? storedId) {
    if (storedId == null || storedId.isEmpty) return null;
    for (final c in this) {
      if (c.id == storedId) return c;
    }
    final m = RegExp(r'^llm_(\d+)$').firstMatch(storedId);
    if (m != null) {
      final rid = int.tryParse(m.group(1)!);
      if (rid != null) {
        for (final c in this) {
          if (c.llmRemoteConfigId == rid) return c;
        }
      }
    }
    if (storedId.startsWith('llm_')) {
      final code = storedId.substring(4);
      final matches = where((c) => c.provider.llmVendorCode == code).toList();
      if (matches.length == 1) return matches.first;
    }
    return null;
  }
}

