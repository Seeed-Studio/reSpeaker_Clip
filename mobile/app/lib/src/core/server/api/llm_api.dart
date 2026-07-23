import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../http/api_client.dart';
import '../server_error_codes.dart';
import '../server_exception.dart';

class LlmConfigItem {
  final int? id;
  final String code;
  final bool isDefault;
  final String configJson;

  const LlmConfigItem({
    required this.id,
    required this.code,
    required this.isDefault,
    required this.configJson,
  });

  factory LlmConfigItem.fromJson(Map<String, dynamic> j) => LlmConfigItem(
        id: (j['id'] is num) ? (j['id'] as num).toInt() : int.tryParse((j['id'] ?? '').toString()),
        code: (j['code'] ?? '').toString(),
        isDefault: j['is_default'] == true,
        configJson: () {
          final raw = j['config_json'];
          if (raw == null) return '';
          if (raw is String) return raw;
          if (raw is Map || raw is List) return jsonEncode(raw);
          return raw.toString();
        }(),
      );
}

class LlmConfigListResult {
  final List<LlmConfigItem> items;

  const LlmConfigListResult({required this.items});

  factory LlmConfigListResult.fromJson(Map<String, dynamic> j) => LlmConfigListResult(
        items: (j['items'] is List)
            ? (j['items'] as List)
                .whereType<Map>()
                .map((e) => LlmConfigItem.fromJson(e.cast<String, dynamic>()))
                .toList(growable: false)
            : const <LlmConfigItem>[],
      );
}

class LlmConfigTestResult {
  final bool ok;
  final String message;

  const LlmConfigTestResult({required this.ok, required this.message});

  factory LlmConfigTestResult.fromJson(Map<String, dynamic> j) =>
      LlmConfigTestResult(
        ok: j['ok'] == true,
        message: (j['message'] ?? '').toString(),
      );
}

class LlmPromptTemplateEntry {
  final int? id;
  final String name;
  final String content;
  final bool isDefault;
  final String? shareKey;

  const LlmPromptTemplateEntry({
    required this.id,
    required this.name,
    required this.content,
    required this.isDefault,
    this.shareKey,
  });

  factory LlmPromptTemplateEntry.fromJson(Map<String, dynamic> j) => LlmPromptTemplateEntry(
        id: (j['id'] is num) ? (j['id'] as num).toInt() : int.tryParse((j['id'] ?? '').toString()),
        name: (j['name'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        isDefault: j['is_default'] == true,
        shareKey: (j['share_key'] ?? '').toString().trim().isEmpty ? null : (j['share_key'] ?? '').toString(),
      );


  factory LlmPromptTemplateEntry.fromPublicJson(Map<String, dynamic> j) {
    final type = (j['type'] ?? '').toString().trim().toLowerCase();
    final prompt = (j['prompt'] ?? j['content'] ?? j['system_prompt'] ?? '').toString();
    final name = _publicTypeToDisplayName(type);
    return LlmPromptTemplateEntry(
      id: (j['id'] is num) ? (j['id'] as num).toInt() : int.tryParse((j['id'] ?? '').toString()),
      name: name.isEmpty ? type.replaceAll('_', ' ') : name,
      content: prompt,
      isDefault: true,
      shareKey: null,
    );
  }

  static String _publicTypeToDisplayName(String type) {
    switch (type) {
      case 'meeting_summary':
        return 'Meeting Summary';
      case 'class_summary':
        return 'Class Summary';
      case 'daily_conversation_summary':
      case 'daily_conversation_summay': 
        return 'Daily Conversation Summary';
      default:
        return '';
    }
  }
}

class LlmPromptImportPreview {
  final String name;
  final String content;
  /// Server template id; save as remoteId on import for sync
  final int? id;

  const LlmPromptImportPreview({
    required this.name,
    required this.content,
    this.id,
  });

  factory LlmPromptImportPreview.fromJson(Map<String, dynamic> j) => LlmPromptImportPreview(
        name: (j['name'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        id: (j['id'] is num) ? (j['id'] as num).toInt() : int.tryParse((j['id'] ?? '').toString()),
      );
}

class LlmSessionItem {
  final String sessionId;
  final String title;
  final String createdAt;
  final String updatedAt;
  final int asrResultId;
  final String macAddress;
  final List<LlmSessionMessageItem> messages;

  const LlmSessionItem({
    required this.sessionId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.asrResultId,
    required this.macAddress,
    required this.messages,
  });

  factory LlmSessionItem.fromJson(Map<String, dynamic> j) => LlmSessionItem(
        sessionId: (j['session_id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        createdAt: (j['created_at'] ?? '').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
        asrResultId: (j['asr_result_id'] is num) ? (j['asr_result_id'] as num).toInt() : int.tryParse((j['asr_result_id'] ?? '').toString()) ?? 0,
        macAddress: (j['mac_address'] ?? '').toString(),
        messages: (j['messages'] is List)
            ? (j['messages'] as List)
                .whereType<Map>()
                .map((e) => LlmSessionMessageItem.fromJson(e.cast<String, dynamic>()))
                .toList(growable: false)
            : const <LlmSessionMessageItem>[],
      );
}

class LlmSessionMessageItem {
  final int id;
  final String role;
  final String content;
  final String createdAt;

  const LlmSessionMessageItem({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  factory LlmSessionMessageItem.fromJson(Map<String, dynamic> j) => LlmSessionMessageItem(
        id: (j['id'] is num) ? (j['id'] as num).toInt() : int.tryParse((j['id'] ?? '').toString()) ?? 0,
        role: (j['role'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        createdAt: (j['created_at'] ?? '').toString(),
      );
}

class LlmApi {
  final ApiClient _client;
  LlmApi(this._client);

  static Map<String, dynamic> _ensureOk(Object? data, {int? statusCode}) {
    if (data is! Map) {
      throw ServerException(
        'Request failed: invalid response format',
        messageKey: 'llmErrorResponseFormat',
        statusCode: statusCode,
        data: data,
      );
    }
    final m = data.cast<String, dynamic>();
    final code = (m['code'] is num) ? (m['code'] as num).toInt() : 0;
    if (!ServerErrorCodes.isOk(code)) {
      final msg = (m['message'] ?? '').toString().trim();
      throw ServerException(
        msg.isEmpty ? 'Request failed.' : msg,
        messageKey: msg.isEmpty ? 'errorRequestFailed' : null,
        bizCode: code,
        details: m['details']?.toString(),
        statusCode: statusCode,
        data: data,
      );
    }
    return m;
  }

  Future<LlmConfigListResult> getConfigList() async {
    final resp = await _client.request<Object>('/api/v1/llm/config', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) return const LlmConfigListResult(items: <LlmConfigItem>[]);
    return LlmConfigListResult.fromJson(r.cast<String, dynamic>());
  }

  Future<void> createConfig({
    required String code,
    required Object configJson,
  }) async {
    final body = <String, dynamic>{
      'code': code.trim(),
      'config_json': configJson,
    };
    final resp = await _client.request<Object>('/api/v1/llm/config', method: 'POST', data: body);
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  /// Test LLM config connectivity: `POST /api/v1/llm/config/test`
  Future<LlmConfigTestResult> testConfig({
    required String code,
    required Object configJson,
  }) async {
    final body = <String, dynamic>{
      'code': code.trim(),
      'config_json': configJson,
    };
    const timeout = Duration(seconds: 30);
    final resp = await _client.request<Object>(
      '/api/v1/llm/config/test',
      method: 'POST',
      data: body,
      options: Options(
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'LLM connection test failed: response missing result.',
        messageKey: 'llmTestConnectionMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return LlmConfigTestResult.fromJson(r.cast<String, dynamic>());
  }


  Future<void> updateConfigById({
    required int id,
    required Object configJson,
    String? code,
  }) async {
    final body = <String, dynamic>{'config_json': configJson};
    if (code != null && code.isNotEmpty) {
      body['code'] = code;
    }
    final resp = await _client.request<Object>(
      '/api/v1/llm/config/$id',
      method: 'PUT',
      data: body,
    );
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  Future<void> deleteConfigById(int id) async {
    final resp = await _client.request<Object>(
      '/api/v1/llm/config/$id',
      method: 'DELETE',
    );
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  Future<List<LlmPromptTemplateEntry>> listPublicPromptTemplates() async {
    final resp = await _client.request<Object>('/api/v1/llm/prompt/public', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! List) {
      throw ServerException(
        'Failed to get public templates: response missing result list',
        messageKey: 'llmErrorPublicTemplatesMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return r
        .whereType<Map>()
        .map((e) => LlmPromptTemplateEntry.fromPublicJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// User prompt templates: `GET /api/v1/llm/prompt`
  Future<List<LlmPromptTemplateEntry>> listPromptTemplates() async {
    final resp = await _client.request<Object>('/api/v1/llm/prompt', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! List) return const <LlmPromptTemplateEntry>[];
    return r
        .whereType<Map>()
        .map((e) => LlmPromptTemplateEntry.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<LlmPromptTemplateEntry> getPromptTemplateById(int id) async {
    final resp = await _client.request<Object>('/api/v1/llm/prompt/$id', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'Failed to get template: response missing result',
        messageKey: 'llmErrorGetTemplateMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return LlmPromptTemplateEntry.fromJson(r.cast<String, dynamic>());
  }

  Future<LlmPromptTemplateEntry> createPromptTemplate({
    required String name,
    required String content,
    required bool isDefault,
  }) async {
    final body = <String, dynamic>{
      'name': name.trim(),
      'content': content,
      'is_default': isDefault,
    };
    final resp = await _client.request<Object>(
      '/api/v1/llm/prompt',
      method: 'POST',
      data: body,
      options: Options(
        validateStatus: (_) => true,
        receiveDataWhenStatusError: true,
      ),
    );
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'Failed to create template: response missing result',
        messageKey: 'llmErrorCreateTemplateMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return LlmPromptTemplateEntry.fromJson(r.cast<String, dynamic>());
  }

  Future<void> updatePromptTemplate({
    required int id,
    required String name,
    required String content,
    required bool isDefault,
  }) async {
    final body = <String, dynamic>{
      'name': name.trim(),
      'content': content,
      'is_default': isDefault,
    };
    final resp = await _client.request<Object>(
      '/api/v1/llm/prompt/$id',
      method: 'PUT',
      data: body,
      options: Options(
        validateStatus: (_) => true,
        receiveDataWhenStatusError: true,
      ),
    );
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  Future<void> deletePromptTemplate(int id) async {
    final resp = await _client.request<Object>(
      '/api/v1/llm/prompt/$id',
      method: 'DELETE',
    );
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  Future<LlmPromptImportPreview> previewPromptImport(String key) async {
    final k = key.trim();
    final resp = await _client.request<Object>('/api/v1/llm/prompt/import/$k', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'Failed to preview template: response missing result',
        messageKey: 'llmErrorPreviewTemplateMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return LlmPromptImportPreview.fromJson(r.cast<String, dynamic>());
  }

  Future<LlmPromptImportPreview> importPromptTemplate(String key) async {
    final body = <String, dynamic>{'key': key.trim()};
    final resp = await _client.request<Object>('/api/v1/llm/prompt/import', method: 'POST', data: body);
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'Failed to import template: response missing result',
        messageKey: 'llmErrorImportTemplateMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return LlmPromptImportPreview.fromJson(r.cast<String, dynamic>());
  }

  Future<String> startPromptShare(int id) async {
    final resp = await _client.request<Object>('/api/v1/llm/prompt/$id/share', method: 'PUT');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'Failed to start share: response missing result',
        messageKey: 'llmErrorStartShareMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return (r['share_key'] ?? '').toString();
  }


  Future<void> stopPromptShare(int id) async {
    final resp = await _client.request<Object>('/api/v1/llm/prompt/$id/share', method: 'DELETE');
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  Future<List<LlmSessionItem>> listSessions({
    String? macAddress,
    int? asrResultId,
    bool includeMessages = false,
    int? messageLimit,
  }) async {
    final qp = <String, dynamic>{};
    final mac = macAddress?.trim() ?? '';
    if (mac.isNotEmpty) qp['mac_address'] = mac;
    if (asrResultId != null) qp['asr_result_id'] = asrResultId;
    if (includeMessages) qp['include_messages'] = 'true';
    if (messageLimit != null) qp['message_limit'] = messageLimit;
    final resp = await _client.request<Object>(
      '/api/v1/llm/sessions',
      method: 'GET',
      queryParameters: qp.isEmpty ? null : qp,
    );
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) return const <LlmSessionItem>[];
    final items = r['items'];
    if (items is! List) return const <LlmSessionItem>[];
    return items
        .whereType<Map>()
        .map((e) => LlmSessionItem.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<void> deleteSession(String sessionId) async {
    final sid = sessionId.trim();
    final resp = await _client.request<Object>('/api/v1/llm/sessions/$sid', method: 'DELETE');
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }


  Future<void> deleteSessionMessage(String sessionId, int messageId) async {
    final sid = sessionId.trim();
    debugPrint('[API] DELETE /api/v1/llm/sessions/$sid/messages/$messageId');
    final resp = await _client.request<Object>(
      '/api/v1/llm/sessions/$sid/messages/$messageId',
      method: 'DELETE',
    );
    _ensureOk(resp.data, statusCode: resp.statusCode);
    debugPrint('[API] <- ${resp.statusCode} DELETE session_message ok');
  }

  Future<List<LlmSessionMessageItem>> getSessionMessages(String sessionId) async {
    final sid = sessionId.trim();
    final resp = await _client.request<Object>(
      '/api/v1/llm/sessions/$sid/messages',
      method: 'GET',
    );
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) return const <LlmSessionMessageItem>[];
    final items = r['items'];
    if (items is! List) return const <LlmSessionMessageItem>[];
    return items
        .whereType<Map>()
        .map((e) => LlmSessionMessageItem.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Stream<String> streamSummary({
    required int configId,
    required String input,
    required String macAddress,
    required String systemPrompt,
    required String sessionId,
    int? asrResultId,
    void Function(String sessionId)? onSessionId,
  }) async* {
    if (configId <= 0) {
      throw ServerException(
        'LLM config not synced to server',
        messageKey: 'llmErrorConfigNotSynced',
      );
    }
    final sp = systemPrompt.trim();

    final body = <String, dynamic>{
      'config_id': configId,
      'input': input,
      'system_prompt': sp,
    };
    final mac = macAddress.trim();
    if (mac.isNotEmpty) body['mac_address'] = mac;
    final sid = sessionId.trim();
    if (sid.isNotEmpty) body['session_id'] = sid;
    if (asrResultId != null && asrResultId > 0) body['asr_result_id'] = asrResultId;
    final url = _client.config.baseUri.resolve('/api/v1/llm/chat');
    debugPrint(
      '[API] POST $url (SSE)'
      ' config_id=$configId'
      ' inputLen=${input.length}'
      ' systemPromptLen=${sp.length}'
      ' macLen=${mac.length}'
      ' sessionLen=${sid.length}'
      ' asrResultId=${asrResultId ?? 0}',
    );
    if (sp.isEmpty) {
      debugPrint('[API] !! llm/chat invalid: system_prompt is empty');
      throw ServerException(
        'system_prompt cannot be empty',
        messageKey: 'llmErrorSystemPromptEmpty',
      );
    }

    // Meeting summaries can exceed 30s; extend timeout to avoid context canceled
    const llmChatTimeout = Duration(seconds: 180);
    final resp = await _client.request<ResponseBody>(
      '/api/v1/llm/chat',
      method: 'POST',
      data: body,
      options: Options(
        responseType: ResponseType.stream,
        headers: const {'Accept': 'text/event-stream'},
        sendTimeout: llmChatTimeout,
        receiveTimeout: llmChatTimeout,
        // SSE: still read body on 500+ to parse message/details
        validateStatus: (_) => true,
        receiveDataWhenStatusError: true,
      ),
    );

    final status = resp.statusCode ?? 0;
    final stream = resp.data?.stream;
    debugPrint('[API] <- $status $url (SSE)');
    if (status < 200 || status >= 300) {
      final raw = await _readStreamAsString(stream);
      if (_client.config.enableNetworkLog) {
        final text = raw.trim();
        final shown = text.length > 1200 ? '${text.substring(0, 1200)}…(truncated, len=${text.length})' : text;
        debugPrint('[API]   llm/chat errBody=${shown.isEmpty ? "<empty>" : shown}');
      }
      throw _streamError(raw, statusCode: status);
    }
    if (stream == null) {
      throw ServerException(
        'Request failed: empty response',
        messageKey: 'llmErrorResponseEmpty',
        statusCode: status,
      );
    }
    var chunkCount = 0;
    var totalLen = 0;
    const maxChunksToLog = 20;
    const maxCharsToShow = 180;
    await for (final delta in _streamSseDeltas(stream, sessionId: sessionId, onSessionId: onSessionId)) {
      chunkCount++;
      totalLen += delta.length;
      if (chunkCount <= maxChunksToLog) {
        final shown = delta.length > maxCharsToShow ? '${delta.substring(0, maxCharsToShow)}…' : delta;
        debugPrint('[API]   llm/chat delta#$chunkCount len=${delta.length} text="${shown.replaceAll('\n', '\\n')}"');
      } else if (chunkCount == maxChunksToLog + 1) {
        debugPrint('[API]   llm/chat delta... (suppress further deltas)');
      }
      yield delta;
    }
    debugPrint('[API]   llm/chat done chunks=$chunkCount totalLen=$totalLen');
  }

  Future<String> summarize({
    required int configId,
    required String input,
    required String macAddress,
    required String systemPrompt,
    required String sessionId,
  }) async {
    final buffer = StringBuffer();
    await for (final delta in streamSummary(
      configId: configId,
      input: input,
      macAddress: macAddress,
      systemPrompt: systemPrompt,
      sessionId: sessionId,
    )) {
      buffer.write(delta);
    }
    final summary = buffer.toString();
    if (summary.trim().isEmpty) {
      throw ServerException(
        'Summary is empty',
        messageKey: 'llmErrorSummaryEmpty',
      );
    }
    return summary;
  }

  Future<String> _readStreamAsString(Stream<List<int>>? stream) async {
    if (stream == null) return '';
    final chunks = <int>[];
    await for (final part in stream) {
      chunks.addAll(part);
    }
    if (chunks.isEmpty) return '';
    try {
      return utf8.decode(chunks);
    } catch (_) {
      return String.fromCharCodes(chunks);
    }
  }

  ServerException _streamError(String raw, {int? statusCode}) {
    final text = raw.trim();
    if (text.isEmpty) {
      return ServerException(
        'Request failed',
        messageKey: 'errorRequestFailed',
        statusCode: statusCode,
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final m = decoded.cast<String, dynamic>();
        final code = (m['code'] is num) ? (m['code'] as num).toInt() : null;
        final msg = (m['message'] ?? 'Request failed').toString().trim();
        final details = m['details']?.toString();
        return ServerException(
          msg.isEmpty ? 'Request failed' : msg,
          messageKey: msg.isEmpty ? 'errorRequestFailed' : null,
          bizCode: code,
          errorKey: m['error_key']?.toString(),
          details: details,
          statusCode: statusCode,
          data: decoded,
        );
      }
    } catch (_) {
      // ignore
    }
    return ServerException(text, statusCode: statusCode);
  }

  Stream<String> _streamSseDeltas(
    Stream<List<int>> stream, {
    required String sessionId,
    void Function(String sessionId)? onSessionId,
  }) async* {
    final decoded = const Utf8Decoder().bind(stream.cast<List<int>>());
    await for (final line in decoded.transform(const LineSplitter())) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trimLeft();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;
      if (sessionId.isNotEmpty && payload == sessionId) continue;
      if (payload.startsWith('{')) {
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map) {
            final m = decoded.cast<String, dynamic>();
            final sid = (m['session_id'] ?? m['sessionId'])?.toString().trim();
            if (sid != null && sid.isNotEmpty && onSessionId != null) {
              onSessionId(sid);
            }
            final err = (m['error'])?.toString().trim();
            if (err != null && err.isNotEmpty) {
              throw ServerException(err, messageKey: 'llmErrorStream');
            }
            final content = (m['content'] ?? m['delta'] ?? m['text'])?.toString();
            if (content != null && content.isNotEmpty) {
              yield content;
            }
            continue;
          }
        } catch (_) {
          // fall through to handle as raw text
        }
      }
      final looksLikeUuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
          .hasMatch(payload);
      if (looksLikeUuid && onSessionId != null) {
        onSessionId(payload);
        continue;
      }
      yield payload;
    }
  }
}

