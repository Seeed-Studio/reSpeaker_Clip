import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/server/api/asr_api.dart';
import '../../../core/server/server_providers.dart';
import '../domain/ai_providers.dart';
import '../domain/asr_vendor_config.dart';
import '../domain/stt_config.dart';

final asrConfigRepositoryProvider =
    FutureProvider<AsrConfigRepository>((ref) async {
  final api = ref.watch(asrApiProvider);
  return AsrConfigRepository(api: api);
});

class AsrConfigRepository {
  final AsrApi api;

  AsrConfigRepository({required this.api});

  /// List ASR configs from API (no local merge).
  Future<List<SttConfig>> fetchConfigList() async {
    final remote = await api.getConfig();
    final now = DateTime.now();
    final list = <SttConfig>[];

    if (remote.vendors.isNotEmpty) {
      for (var i = 0; i < remote.vendors.length; i++) {
        final v = remote.vendors[i];
        final cfg = _vendorToSttConfig(v, sortIndex: i, now: now);
        if (cfg != null) list.add(cfg);
      }
      return list;
    }

    if (remote.items.isNotEmpty) {
      for (var i = 0; i < remote.items.length; i++) {
        final v = remote.items[i];
        final id = v.id;
        if (id == null) continue;
        final detail = await api.getConfigById(id);
        final cfg = _vendorToSttConfig(detail, sortIndex: i, now: now);
        if (cfg != null) list.add(cfg);
      }
      return list;
    }

    return list;
  }

  /// Sync single STT config to server (PUT supports submitting only changed vendor).
  Future<void> updateVendorToRemote(SttConfig cfg) async {
    final remoteId = _remoteIdFromExtra(cfg.extraJson);
    if (remoteId == null) return;
    await api.updateConfigById(
      id: remoteId,
      configJson: cfg.toAsrVendorConfigObject(),
      code: cfg.provider.asrVendorCode,
    );
  }

  /// Create ASR config (POST /api/v1/asr/config)
  Future<void> createVendorToRemote(SttConfig cfg) async {
    final code = cfg.provider.asrVendorCode;
    if (code == null) return;
    await api.createConfig(
        code: code, configJson: cfg.toAsrVendorConfigObject());
  }

  /// Test ASR config connectivity (POST /api/v1/asr/config/test)
  Future<AsrConfigTestResult> testConnection(SttConfig cfg) async {
    final code = cfg.asrVendorCodeOrThrow;
    return api.testConfig(
      code: code,
      configJson: cfg.toAsrVendorConfigObject(),
    );
  }

  /// Fetch one vendor for edit screen refresh
  Future<SttConfig?> fetchVendorDetail({
    required int vendorId,
    required int sortIndex,
  }) async {
    final v = await api.getConfigById(vendorId);
    final now = DateTime.now();
    return _vendorToSttConfig(v, sortIndex: sortIndex, now: now);
  }

  /// Build new [SttConfig] without local DB
  SttConfig buildConfigForCreate({
    required SttProvider provider,
    required String name,
    required String apiKey,
    String? apiSecret,
    String? appId,
    String? accessKeyId,
    String? accessKeySecret,
    String? region,
    String? baseUrl,
    String? language,
    String? modelName,
    String? modelPath,
    String? extraJson,
  }) {
    final code = provider.asrVendorCode;
    final id = code != null
        ? 'asr_$code'
        : 'asr-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now();
    return SttConfig(
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
      language: language,
      modelName: modelName,
      modelPath: modelPath,
      extraJson: extraJson,
      sortIndex: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Delete remote vendor: DELETE /api/v1/asr/config/{id}
  Future<void> deleteVendorFromRemote({required int vendorId}) async {
    await api.deleteConfigById(vendorId);
  }

  SttConfig? _vendorToSttConfig(AsrVendorEntry v,
      {required int sortIndex, required DateTime now}) {
    final code = v.code.trim();
    final provider = _providerFromVendorCode(code);
    if (provider == null) return null;

    Map<String, dynamic> m = <String, dynamic>{};
    final raw = v.configJson.trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          m = decoded.map((k, val) => MapEntry(k.toString(), val));
        } else if (decoded is String) {
          final decoded2 = jsonDecode(decoded);
          if (decoded2 is Map) {
            m = decoded2.map((k, val) => MapEntry(k.toString(), val));
          }
        }
      } catch (_) {
        // ignore
      }
    }

    // Use stable id (by code), write remote id in extra_json so each remote fetch does not create duplicate
    final id = 'asr_$code';
    final name = '${provider.label} API';
    final remoteExtra = _attachRemoteId(null, v.id);

    switch (provider) {
      case SttProvider.aliyun:
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          apiKey: (m['api_key'] ?? '').toString(),
          language: (m['language'] ?? '').toString().trim().isEmpty
              ? null
              : (m['language'] ?? '').toString(),
          modelName: (m['model'] ?? '').toString().trim().isEmpty
              ? null
              : (m['model'] ?? '').toString(),
          appId: (m['app_key'] ?? '').toString().trim().isEmpty
              ? null
              : (m['app_key'] ?? '').toString(),
          accessKeyId: (m['access_key_id'] ?? '').toString().trim().isEmpty
              ? null
              : (m['access_key_id'] ?? '').toString(),
          accessKeySecret:
              (m['access_key_secret'] ?? '').toString().trim().isEmpty
                  ? null
                  : (m['access_key_secret'] ?? '').toString(),
          region: (m['region'] ?? '').toString().trim().isEmpty
              ? null
              : (m['region'] ?? '').toString(),
          extraJson: remoteExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      case SttProvider.funasr:
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          apiKey: (m['api_key'] ?? '').toString(),
          baseUrl: (m['base_url'] ?? '').toString().trim().isEmpty
              ? null
              : (m['base_url'] ?? '').toString(),
          extraJson: remoteExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      case SttProvider.openAiWhisper:
      case SttProvider.googleGemini:
      case SttProvider.deepgram:
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          apiKey: (m['api_key'] ?? '').toString(),
          baseUrl: (m['base_url'] ?? '').toString().trim().isEmpty
              ? null
              : (m['base_url'] ?? '').toString(),
          modelName: (m['model'] ?? '').toString().trim().isEmpty
              ? null
              : (m['model'] ?? '').toString(),
          extraJson: remoteExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      case SttProvider.iflytek:
        final modelRaw = (m['model'] ?? '').toString().trim();
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          apiKey: (m['api_key'] ?? '').toString(),
          apiSecret: (m['api_secret'] ?? '').toString().trim().isEmpty
              ? null
              : (m['api_secret'] ?? '').toString(),
          appId: (m['app_id'] ?? '').toString().trim().isEmpty
              ? null
              : (m['app_id'] ?? '').toString(),
          modelName: modelRaw.isEmpty ? null : modelRaw,
          extraJson: remoteExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      case SttProvider.vosk:
      case SttProvider.localWhisper:
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          apiKey: (m['api_key'] ?? '').toString().trim(),
          baseUrl: (m['base_url'] ?? '').toString().trim().isEmpty
              ? null
              : (m['base_url'] ?? '').toString(),
          extraJson: remoteExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      case SttProvider.baidu:
        final devPid = m['dev_pid'];
        final extra = <String, dynamic>{};
        if (devPid is num) extra['dev_pid'] = devPid;
        final nextExtra = _attachRemoteId(jsonEncode(extra), v.id);
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          apiKey: (m['api_key'] ?? '').toString(),
          apiSecret: (m['secret_key'] ?? '').toString().trim().isEmpty
              ? null
              : (m['secret_key'] ?? '').toString(),
          appId: (m['app_id'] ?? '').toString().trim().isEmpty
              ? null
              : (m['app_id'] ?? '').toString(),
          extraJson: nextExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      case SttProvider.tencent:
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          accessKeyId: (m['secret_id'] ?? '').toString().trim().isEmpty
              ? null
              : (m['secret_id'] ?? '').toString(),
          accessKeySecret: (m['secret_key'] ?? '').toString().trim().isEmpty
              ? null
              : (m['secret_key'] ?? '').toString(),
          apiKey: '',
          extraJson: remoteExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      case SttProvider.doubao:
        final extra = <String, dynamic>{
          'cluster': (m['cluster'] ?? '').toString(),
          'access_token': (m['access_token'] ?? '').toString(),
        };
        final nextExtra = _attachRemoteId(jsonEncode(extra), v.id);
        return SttConfig(
          id: id,
          provider: provider,
          name: name,
          apiKey: '',
          appId: (m['appid'] ?? '').toString().trim().isEmpty
              ? null
              : (m['appid'] ?? '').toString(),
          extraJson: nextExtra,
          sortIndex: sortIndex,
          createdAt: now,
          updatedAt: now,
        );

      default:
        // Vendor not in doc: skip remote sync for now
        return null;
    }
  }

  SttProvider? _providerFromVendorCode(String code) {
    return switch (code) {
      'aliyun' => SttProvider.aliyun,
      'funasr' => SttProvider.funasr,
      'openai_whisper' => SttProvider.openAiWhisper,
      'google_gemini' => SttProvider.googleGemini,
      'deepgram' => SttProvider.deepgram,
      'baidu' => SttProvider.baidu,
      'tencent' => SttProvider.tencent,
      'doubao' => SttProvider.doubao,
      'iflytek' => SttProvider.iflytek,
      'vosk' => SttProvider.vosk,
      'local_whisper' => SttProvider.localWhisper,
      _ => null,
    };
  }

  int? _remoteIdFromExtra(String? extraJson) {
    final raw = (extraJson ?? '').trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final v = decoded['_remote_id'];
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
      }
    } catch (_) {
      // ignore
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
