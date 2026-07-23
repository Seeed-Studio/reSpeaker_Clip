import 'dart:io';

import '../http/api_client.dart';

/// STT-related server API (stub; align with SenseCraft upload/transcribe later)
class SttApi {
  final ApiClient _client;
  SttApi(this._client);

  /// Upload audio and get transcript (stub).
  ///
  /// SenseCraft reference:
  /// - POST /v2/voice-message/transcribe (multipart, field: files)
  /// - resp: {"transcript": "..."}
  Future<String> transcribe({
    required File audioFile,
    String? language,
    String? sttConfigId,
    bool? autoSpeaker,
  }) async {
    final resp = await _client.uploadFiles<Map<String, dynamic>>(
      '/v2/voice-message/transcribe',
      files: [audioFile],
      fieldName: 'files',
      fields: {
        if (language != null) 'language': language,
        if (sttConfigId != null) 'stt_config_id': sttConfigId,
        if (autoSpeaker != null) 'auto_speaker': autoSpeaker.toString(),
      },
    );
    return (resp.data?['transcript'] as String?) ?? '';
  }
}

