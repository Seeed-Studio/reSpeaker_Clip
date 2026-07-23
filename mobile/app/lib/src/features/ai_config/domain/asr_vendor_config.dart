import 'dart:convert';

import 'ai_providers.dart';
import 'stt_config.dart';

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

int? _extractRemoteVendorId(String? extraJson) {
  final m = _decodeExtraJsonObject(extraJson);
  final raw = m['_remote_id'];
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

String? _mergeRemoteVendorId(String? extraJson, int? remoteId) {
  if (remoteId == null) return extraJson;
  final m = _decodeExtraJsonObject(extraJson);
  m['_remote_id'] = remoteId;
  return jsonEncode(m);
}

extension SttConfigAsrVendorConfigX on SttConfig {
  int? get asrRemoteVendorId => _extractRemoteVendorId(extraJson);

  String? withAsrRemoteVendorId(int? remoteId) =>
      _mergeRemoteVendorId(extraJson, remoteId);

  /// Build a config_json object matching the ASR vendor spec PDF in docx/ (not stringified here).
  ///
  /// Notes:
  /// - Field names follow the doc; include required keys first.
  /// - Optional keys (e.g. aliyun model/language/ws_url, baidu dev_pid) are added when you set them.
  Map<String, dynamic> toAsrVendorConfigObject() {
    switch (provider) {
      case SttProvider.aliyun:
        final langRaw = (language ?? '').trim();
        final lang = switch (langRaw) {
          '' => null,
          'Auto' => null,
          'English' => 'en',
          'Chinese' => 'zh',
          _ => langRaw, // allow already-normalized values like zh/en
        };
        return <String, dynamic>{
          if (apiKey.trim().isNotEmpty) 'api_key': apiKey.trim(),
          if ((modelName ?? '').trim().isNotEmpty) 'model': modelName,
          if (lang != null && lang.trim().isNotEmpty) 'language': lang,
          if ((appId ?? '').trim().isNotEmpty) 'app_key': (appId ?? '').trim(),
          if ((accessKeyId ?? '').trim().isNotEmpty)
            'access_key_id': (accessKeyId ?? '').trim(),
          if ((accessKeySecret ?? '').trim().isNotEmpty)
            'access_key_secret': (accessKeySecret ?? '').trim(),
          if ((region ?? '').trim().isNotEmpty) 'region': (region ?? '').trim(),
        };

      case SttProvider.funasr:
        return <String, dynamic>{
          'base_url': (baseUrl ?? '').trim(),
          if (apiKey.trim().isNotEmpty) 'api_key': apiKey,
        };

      case SttProvider.openAiWhisper:
        return <String, dynamic>{
          if ((baseUrl ?? '').trim().isNotEmpty) 'base_url': baseUrl,
          if (apiKey.trim().isNotEmpty) 'api_key': apiKey,
        };

      case SttProvider.googleGemini:
        return <String, dynamic>{
          if (apiKey.trim().isNotEmpty) 'api_key': apiKey,
          if ((modelName ?? '').trim().isNotEmpty) 'model': modelName,
        };

      case SttProvider.deepgram:
        return <String, dynamic>{
          if (apiKey.trim().isNotEmpty) 'api_key': apiKey,
        };

      case SttProvider.vosk:
        return <String, dynamic>{
          'base_url': (baseUrl ?? 'http://localhost:2700').trim(),
        };

      case SttProvider.localWhisper:
        return <String, dynamic>{
          'base_url': (baseUrl ?? 'http://localhost:8080').trim(),
          if (apiKey.trim().isNotEmpty) 'api_key': apiKey,
        };

      case SttProvider.iflytek:
        // iFlytek: `model` selects mode. realtime/empty = live (app_id+api_key); file/lfasr/standard = file ASR (app_id+api_secret)
        final modelVal = (modelName ?? '').trim().toLowerCase();
        return <String, dynamic>{
          'app_id': (appId ?? '').trim(),
          'api_key': apiKey.trim(),
          'api_secret': (apiSecret ?? '').trim(),
          if (modelVal.isNotEmpty) 'model': modelVal,
        };

      case SttProvider.baidu:
        final extra = _decodeExtraJsonObject(extraJson);
        final devPid = extra['dev_pid'];
        return <String, dynamic>{
          'app_id': (appId ?? '').trim(),
          'api_key': apiKey,
          'secret_key': (apiSecret ?? '').trim(),
          if (devPid is num) 'dev_pid': devPid,
        };

      case SttProvider.tencent:
        return <String, dynamic>{
          'secret_id': (accessKeyId ?? '').trim(),
          'secret_key': (accessKeySecret ?? '').trim(),
        };

      case SttProvider.doubao:
        final extra = _decodeExtraJsonObject(extraJson);
        return <String, dynamic>{
          'appid': (appId ?? '').trim(),
          'cluster': (extra['cluster'] ?? '').toString().trim(),
          'access_token': (extra['access_token'] ?? '').toString().trim(),
        };

      default:
        throw UnsupportedError(
            'Provider ${provider.name} is not supported by ASR vendor config spec');
    }
  }

  /// Build vendors[].config_json JSON string
  String toAsrVendorConfigJson() => jsonEncode(toAsrVendorConfigObject());

  /// Build vendors[].code / vendors[].type
  String get asrVendorCodeOrThrow {
    final code = provider.asrVendorCode;
    if (code == null) {
      throw UnsupportedError(
          'Provider ${provider.name} has no asrVendorCode mapping');
    }
    return code;
  }
}
