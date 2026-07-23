import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../http/api_client.dart';
import '../server_error_codes.dart';
import '../server_exception.dart';

class AsrVendorEntry {
  final int? id;
  final String code;
  final String type;
  final String configJson;

  const AsrVendorEntry({
    required this.id,
    required this.code,
    required this.type,
    required this.configJson,
  });

  factory AsrVendorEntry.fromJson(Map<String, dynamic> j) => AsrVendorEntry(
        id: (j['id'] is num)
            ? (j['id'] as num).toInt()
            : int.tryParse((j['id'] ?? '').toString()),
        code: (j['code'] ?? '').toString(),
        type: (j['type'] ?? j['code'] ?? '').toString(),
        configJson: () {
          final raw = j['config_json'];
          if (raw == null) return '';
          if (raw is String) return raw;
          if (raw is Map || raw is List) return jsonEncode(raw);
          return raw.toString();
        }(),
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        if (type.trim().isNotEmpty) 'type': type,
        'config_json': configJson,
      };
}

class AsrConfigResult {
  final String? defaultVendor;
  final List<String> codes;
  final List<AsrVendorEntry> vendors;
  final List<AsrVendorEntry> items;

  const AsrConfigResult({
    required this.defaultVendor,
    required this.codes,
    required this.vendors,
    required this.items,
  });

  factory AsrConfigResult.fromJson(Map<String, dynamic> j) => AsrConfigResult(
        defaultVendor: j['default_vendor']?.toString(),
        codes: (j['codes'] is List)
            ? (j['codes'] as List)
                .map((e) => e.toString())
                .toList(growable: false)
            : const <String>[],
        vendors: (j['vendors'] is List)
            ? (j['vendors'] as List)
                .whereType<Map>()
                .map((e) => AsrVendorEntry.fromJson(e.cast<String, dynamic>()))
                .toList(growable: false)
            : const <AsrVendorEntry>[],
        items: (j['items'] is List)
            ? (j['items'] as List)
                .whereType<Map>()
                .map((e) => AsrVendorEntry.fromJson(e.cast<String, dynamic>()))
                .toList(growable: false)
            : const <AsrVendorEntry>[],
      );
}

class AsrVendorsResult {
  final List<String> codes;
  final String? defaultVendor;

  const AsrVendorsResult({required this.codes, required this.defaultVendor});

  factory AsrVendorsResult.fromJson(Map<String, dynamic> j) => AsrVendorsResult(
        codes: (j['codes'] is List)
            ? (j['codes'] as List)
                .map((e) => e.toString())
                .toList(growable: false)
            : const <String>[],
        defaultVendor: j['default_vendor']?.toString(),
      );
}

class AsrDefaultVendorResult {
  final String? defaultVendor;

  const AsrDefaultVendorResult({required this.defaultVendor});

  factory AsrDefaultVendorResult.fromJson(Map<String, dynamic> j) =>
      AsrDefaultVendorResult(defaultVendor: j['default_vendor']?.toString());
}

class AsrConfigTestResult {
  final bool ok;
  final String message;

  const AsrConfigTestResult({required this.ok, required this.message});

  factory AsrConfigTestResult.fromJson(Map<String, dynamic> j) =>
      AsrConfigTestResult(
        ok: j['ok'] == true,
        message: (j['message'] ?? '').toString(),
      );
}

class AsrRecognizeSegment {
  final int startMs;
  final int endMs;
  final String text;
  final String speakerId;
  final String speakerLabel;

  const AsrRecognizeSegment(
      {required this.startMs,
      required this.endMs,
      required this.text,
      required this.speakerId,
      required this.speakerLabel});

  bool get hasSpeaker =>
      speakerLabel.trim().isNotEmpty || speakerId.trim().isNotEmpty;

  String get displaySpeaker {
    final label = speakerLabel.trim();
    if (label.isNotEmpty) return label;
    final id = speakerId.trim();
    if (id.isEmpty) return '说话人';
    final n = int.tryParse(id);
    if (n == null) return '说话人 $id';
    return '说话人 ${n + 1}';
  }

  factory AsrRecognizeSegment.fromJson(Map<String, dynamic> j) =>
      AsrRecognizeSegment(
        startMs: (j['start_ms'] is num) ? (j['start_ms'] as num).toInt() : 0,
        endMs: (j['end_ms'] is num) ? (j['end_ms'] as num).toInt() : 0,
        text: (j['text'] ?? '').toString(),
        speakerId: (j['speaker_id'] ?? '').toString(),
        speakerLabel: (j['speaker_label'] ?? '').toString(),
      );
}

class AsrRecognizeResult {
  static const int _speakerMergeMaxGapMs = 8000;
  final int durationMs;
  final List<AsrRecognizeSegment> segments;
  final String text;
  final String? vendorUsed;

  const AsrRecognizeResult({
    required this.durationMs,
    required this.segments,
    required this.text,
    required this.vendorUsed,
  });

  bool get hasSpeakerSegments => segments.any((seg) => seg.hasSpeaker);

  String displayText({String? languageHint}) {
    if (!hasSpeakerSegments) {
      return _normalizeDisplayContent(text, languageHint: languageHint);
    }
    final mergedSegments = _mergeConsecutiveSpeakerSegments(segments);
    // Single speaker for the whole clip: do not repeat "Speaker 1:" every line (gaps >8s also skip merge in original logic).
    if (_allSegmentsShareOneSpeaker(mergedSegments)) {
      final parts = <String>[];
      for (final seg in mergedSegments) {
        final content =
            _normalizeDisplayContent(seg.text, languageHint: languageHint);
        if (content.isNotEmpty) {
          parts.add(content);
        }
      }
      if (parts.isNotEmpty) {
        return parts.join('\n\n');
      }
    }
    final speakerOrder = <String, int>{};
    final speakerPrefix = _speakerPrefix(languageHint);
    final separator = _speakerSeparator(languageHint);
    final blocks = <String>[];
    for (final seg in mergedSegments) {
      final content =
          _normalizeDisplayContent(seg.text, languageHint: languageHint);
      if (content.isEmpty) continue;
      final displaySpeaker =
          _normalizedDisplaySpeaker(seg, speakerOrder, speakerPrefix);
      blocks.add('$displaySpeaker$separator$content');
    }
    return blocks.isEmpty
        ? _normalizeDisplayContent(text, languageHint: languageHint)
        : blocks.join('\n');
  }

  /// Whether every segment is the same speaker (for monologues, drop repeated speaker prefixes).
  static bool _allSegmentsShareOneSpeaker(List<AsrRecognizeSegment> segs) {
    if (segs.isEmpty) {
      return false;
    }
    String? key;
    for (final s in segs) {
      final k = _speakerIdentityKey(s);
      if (k.isEmpty) {
        return false;
      }
      key ??= k;
      if (k != key) {
        return false;
      }
    }
    return true;
  }

  static List<AsrRecognizeSegment> _mergeConsecutiveSpeakerSegments(
    List<AsrRecognizeSegment> input,
  ) {
    final merged = <AsrRecognizeSegment>[];
    for (final seg in input) {
      final content = seg.text.trim();
      if (content.isEmpty) continue;
      if (merged.isEmpty) {
        merged.add(seg);
        continue;
      }
      final last = merged.last;
      final sameSpeaker = _speakerIdentityKey(last) == _speakerIdentityKey(seg);
      if (!sameSpeaker) {
        merged.add(seg);
        continue;
      }
      final gapMs = seg.startMs - last.endMs;
      if (gapMs > _speakerMergeMaxGapMs) {
        merged.add(seg);
        continue;
      }
      final joiner = _buildSegmentJoiner(last.text, gapMs);
      merged[merged.length - 1] = AsrRecognizeSegment(
        startMs: last.startMs,
        endMs: seg.endMs > last.endMs ? seg.endMs : last.endMs,
        text: '${last.text.trim()}$joiner$content',
        speakerId: last.speakerId,
        speakerLabel: last.speakerLabel,
      );
    }
    return merged;
  }

  static String _normalizedDisplaySpeaker(
    AsrRecognizeSegment seg,
    Map<String, int> speakerOrder,
    String speakerPrefix,
  ) {
    final key = _speakerIdentityKey(seg);
    if (key.isEmpty) {
      return speakerPrefix;
    }
    final order = speakerOrder.putIfAbsent(key, () => speakerOrder.length + 1);
    return '$speakerPrefix $order';
  }

  static String _speakerIdentityKey(AsrRecognizeSegment seg) {
    final id = seg.speakerId.trim();
    if (id.isNotEmpty) return 'id:$id';
    final label = seg.speakerLabel.trim();
    if (label.isNotEmpty) return 'label:$label';
    return '';
  }

  static String _buildSegmentJoiner(String text, int gapMs) {
    if (gapMs >= 2500) {
      return ' ';
    }
    if (_needsSpaceJoin(text)) {
      return ' ';
    }
    return ' ';
  }

  static String _speakerPrefix(String? languageHint) {
    final lang = (languageHint ?? '').trim().toLowerCase();
    if (lang == 'en') {
      return 'Speaker';
    }
    return '说话人';
  }

  static String _speakerSeparator(String? languageHint) {
    final lang = (languageHint ?? '').trim().toLowerCase();
    if (lang == 'en') {
      return ': ';
    }
    return '：';
  }

  static bool _needsSpaceJoin(String text) {
    final trimmed = text.trimRight();
    if (trimmed.isEmpty) return false;
    const sentenceEndings = ['.', '!', '?', '。', '！', '？'];
    return sentenceEndings.any(trimmed.endsWith);
  }

  static String _normalizeDisplayContent(
    String input, {
    String? languageHint,
  }) {
    var text = input.trim();
    if (text.isEmpty) return '';

    text = text.replaceAll(RegExp(r'\s+'), ' ');

    final lang = (languageHint ?? '').trim().toLowerCase();
    final shouldNormalizeChineseSpacing =
        lang.isEmpty || lang == 'zh' || lang == 'auto';
    if (!shouldNormalizeChineseSpacing) {
      return text;
    }

    const cjk = r'\u4E00-\u9FFF';
    const cjkPunctuation = r'\u3000-\u303F\uFF00-\uFFEF';
    text =
        _collapseChineseSpacing(text, cjk: cjk, cjkPunctuation: cjkPunctuation);

    return text.trim();
  }

  static String _collapseChineseSpacing(
    String input, {
    required String cjk,
    required String cjkPunctuation,
  }) {
    var text = input;
    final rules = <RegExp>[
      RegExp('([$cjk])\\s+([$cjk])'),
      RegExp('([$cjk])\\s+([$cjkPunctuation])'),
      RegExp('([$cjkPunctuation])\\s+([$cjk])'),
      RegExp('([A-Za-z])\\s+([0-9])'),
      RegExp('([0-9])\\s+([A-Za-z])'),
    ];
    while (true) {
      var next = text;
      for (final rule in rules) {
        next = next.replaceAllMapped(
          rule,
          (match) => '${match.group(1) ?? ''}${match.group(2) ?? ''}',
        );
      }
      if (next == text) {
        return next;
      }
      text = next;
    }
  }

  factory AsrRecognizeResult.fromJson(Map<String, dynamic> j) {
    // Backward compatibility across API shapes:
    // - Legacy: text / duration_ms / segments
    // - New: result_text (screenshots/logs)
    final duration = (j['duration_ms'] is num)
        ? (j['duration_ms'] as num).toInt()
        : ((j['audio_duration_ms'] is num)
            ? (j['audio_duration_ms'] as num).toInt()
            : 0);

    final segRaw = (j['segments'] is List)
        ? (j['segments'] as List)
        : ((j['result_segments'] is List)
            ? (j['result_segments'] as List)
            : null);

    final segments = (segRaw is List)
        ? segRaw
            .whereType<Map>()
            .map((e) => AsrRecognizeSegment.fromJson(e.cast<String, dynamic>()))
            .toList(growable: false)
        : const <AsrRecognizeSegment>[];

    final text = (() {
      final v = j['text'];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      final v2 = j['result_text'];
      if (v2 != null && v2.toString().trim().isNotEmpty) return v2.toString();
      return '';
    })();

    return AsrRecognizeResult(
      durationMs: duration,
      segments: segments,
      text: text,
      vendorUsed: j['vendor_used']?.toString(),
    );
  }

  /// Whether chunked results can use cross-chunk speaker alignment (every chunk has speaker segments, no chunk is plain full text only).
  static bool canAlignChunkedSpeakerResults(List<AsrRecognizeResult?> chunkResults) {
    if (chunkResults.isEmpty) return false;
    if (chunkResults.any((r) => r == null)) return false;
    var anySpeaker = false;
    for (final r in chunkResults) {
      final rs = r!;
      if (rs.hasSpeakerSegments) {
        anySpeaker = true;
      } else if (rs.segments.isNotEmpty) {
        return false;
      } else if (rs.text.trim().isNotEmpty) {
        return false;
      }
    }
    return anySpeaker;
  }

  /// After chunked ASR, each chunk uses its own speaker id/label indices; map **matching** [_speakerIdentityKey] across chunks, then build display on a global timeline.
  ///
  /// Assumes vendors reuse the same `speaker_id` or `speaker_label` for the same person across adjacent chunks; if indices swap at boundaries, display may misassign (unavoidable without diarization).
  static String displayTextForAlignedChunks({
    required List<AsrRecognizeResult> chunkResults,
    required int chunkDurationMs,
    String? languageHint,
  }) {
    if (chunkResults.isEmpty) return '';
    final n = chunkResults.length;
    final compositeToGroup = <String, int>{};
    var nextGroup = 0;

    for (var c = 0; c < n; c++) {
      final keysInChunk = <String>{};
      for (final seg in chunkResults[c].segments) {
        final k = _speakerIdentityKey(seg);
        if (k.isNotEmpty) keysInChunk.add(k);
      }
      final sortedKeys = keysInChunk.toList()..sort();

      for (final key in sortedKeys) {
        final comp = '$c|$key';
        if (compositeToGroup.containsKey(comp)) continue;
        if (c == 0) {
          compositeToGroup[comp] = nextGroup++;
          continue;
        }
        final prevComp = '${c - 1}|$key';
        final prevG = compositeToGroup[prevComp];
        if (prevG != null) {
          compositeToGroup[comp] = prevG;
        } else {
          compositeToGroup[comp] = nextGroup++;
        }
      }
    }

    final remapped = <AsrRecognizeSegment>[];
    for (var c = 0; c < n; c++) {
      final off = c * chunkDurationMs;
      for (final seg in chunkResults[c].segments) {
        final key = _speakerIdentityKey(seg);
        if (key.isEmpty) {
          remapped.add(
            AsrRecognizeSegment(
              startMs: seg.startMs + off,
              endMs: seg.endMs + off,
              text: seg.text,
              speakerId: seg.speakerId,
              speakerLabel: seg.speakerLabel,
            ),
          );
          continue;
        }
        final gid = compositeToGroup.putIfAbsent('$c|$key', () => nextGroup++);
        remapped.add(
          AsrRecognizeSegment(
            startMs: seg.startMs + off,
            endMs: seg.endMs + off,
            text: seg.text,
            speakerId: 'g$gid',
            speakerLabel: '',
          ),
        );
      }
    }
    remapped.sort((a, b) => a.startMs.compareTo(b.startMs));

    var totalDuration = 0;
    for (final e in remapped) {
      if (e.endMs > totalDuration) totalDuration = e.endMs;
    }

    return AsrRecognizeResult(
      durationMs: totalDuration,
      segments: remapped,
      text: '',
      vendorUsed: null,
    ).displayText(languageHint: languageHint);
  }
}

class AsrJobItem {
  final int id;
  final int userId;
  final int asrConfigId;
  final String status;
  final String sourceType;
  final String sourceUrl;
  final String language;
  final String fileId;
  final String macAddress;
  final int? asrResultId;
  final String errorMessage;
  final String createdAt;
  final String updatedAt;
  final String startedAt;
  final String finishedAt;

  const AsrJobItem({
    required this.id,
    required this.userId,
    required this.asrConfigId,
    required this.status,
    required this.sourceType,
    required this.sourceUrl,
    required this.language,
    required this.fileId,
    required this.macAddress,
    required this.asrResultId,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    required this.startedAt,
    required this.finishedAt,
  });

  bool get isDone => status == 'succeeded' || status == 'failed';
  bool get isSucceeded => status == 'succeeded';
  bool get isFailed => status == 'failed';
  bool get isQueued => status == 'pending';
  bool get isRunning => status == 'running';

  factory AsrJobItem.fromJson(Map<String, dynamic> j) => AsrJobItem(
        id: (j['id'] is num) ? (j['id'] as num).toInt() : 0,
        userId: (j['user_id'] is num) ? (j['user_id'] as num).toInt() : 0,
        asrConfigId: (j['asr_config_id'] is num)
            ? (j['asr_config_id'] as num).toInt()
            : 0,
        status: (j['status'] ?? '').toString(),
        sourceType: (j['source_type'] ?? '').toString(),
        sourceUrl: (j['source_url'] ?? '').toString(),
        language: (j['language'] ?? '').toString(),
        fileId: (j['file_id'] ?? '').toString(),
        macAddress: (j['mac_address'] ?? '').toString(),
        asrResultId: (j['asr_result_id'] is num)
            ? (j['asr_result_id'] as num).toInt()
            : int.tryParse((j['asr_result_id'] ?? '').toString()),
        errorMessage: (j['error_message'] ?? '').toString(),
        createdAt: (j['created_at'] ?? '').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
        startedAt: (j['started_at'] ?? '').toString(),
        finishedAt: (j['finished_at'] ?? '').toString(),
      );
}

typedef AsrJobUpdateCallback = Future<void> Function(AsrJobItem job);

class AsrApi {
  final ApiClient _client;
  AsrApi(this._client);

  static const Duration _jobPollInterval = Duration(seconds: 2);
  static const Duration _jobPollMaxInterval = Duration(seconds: 12);
  /// Must match server `pkg/controller/asr` job max runtime (currently 6h); long audio can run for hours.
  static const Duration _jobPollTimeout = Duration(hours: 6);
  static const int _resultFetchRetryCount = 3;

  static Map<String, dynamic> _ensureOk(Object? data, {int? statusCode}) {
    if (data is! Map) {
      throw ServerException(
        'Request failed: invalid response format.',
        messageKey: 'asrRequestFormat',
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
        errorKey: m['error_key']?.toString(),
        details: m['details']?.toString(),
        statusCode: statusCode,
        data: data,
      );
    }
    return m;
  }

  static Map<String, dynamic> _requireResultMap(
    Object? data, {
    required int? statusCode,
    required String missingResultMessage,
    required String missingResultKey,
  }) {
    final m = _ensureOk(data, statusCode: statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        missingResultMessage,
        messageKey: missingResultKey,
        statusCode: statusCode,
        data: data,
      );
    }
    return r.cast<String, dynamic>();
  }

  /// Get ASR config: `GET /api/v1/asr/config`
  Future<AsrConfigResult> getConfig() async {
    final resp =
        await _client.request<Object>('/api/v1/asr/config', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      return const AsrConfigResult(
        defaultVendor: null,
        codes: <String>[],
        vendors: <AsrVendorEntry>[],
        items: <AsrVendorEntry>[],
      );
    }
    return AsrConfigResult.fromJson(r.cast<String, dynamic>());
  }

  /// Create ASR config: `POST /api/v1/asr/config`
  ///
  /// Request body：`{ "code": "...", "config_json": "..." }`
  Future<AsrVendorEntry> createConfig({
    required String code,
    required Object configJson,
  }) async {
    String stringify(Object v) {
      if (v is String) return v;
      try {
        return jsonEncode(v);
      } catch (_) {
        return v.toString();
      }
    }

    final body = <String, dynamic>{
      'code': code.trim(),
      'config_json': configJson,
    };
    final resp = await _client.request<Object>('/api/v1/asr/config',
        method: 'POST', data: body);
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      // Compatibility: backend returns only code/message.
      return AsrVendorEntry(
        id: null,
        code: code,
        type: code,
        configJson: stringify(configJson),
      );
    }
    return AsrVendorEntry.fromJson(r.cast<String, dynamic>());
  }

  /// Test ASR config connectivity: `POST /api/v1/asr/config/test`
  ///
  /// Does not persist config. Returns `{ ok, message }`; vendor auth failures
  /// typically still use HTTP 200 with `ok: false`.
  Future<AsrConfigTestResult> testConfig({
    required String code,
    required Object configJson,
  }) async {
    final body = <String, dynamic>{
      'code': code.trim(),
      'config_json': configJson,
    };
    const timeout = Duration(seconds: 30);
    final resp = await _client.request<Object>(
      '/api/v1/asr/config/test',
      method: 'POST',
      data: body,
      options: Options(
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
    final r = _requireResultMap(
      resp.data,
      statusCode: resp.statusCode,
      missingResultMessage: 'ASR connection test failed: response missing result.',
      missingResultKey: 'asrTestConnectionMissingResult',
    );
    return AsrConfigTestResult.fromJson(r);
  }

  ///
  /// Response: `{result:{id,code,config_json}}`
  Future<AsrVendorEntry> getConfigById(int id) async {
    final resp =
        await _client.request<Object>('/api/v1/asr/config/$id', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'Failed to get config: response missing result.',
        messageKey: 'asrGetConfigMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return AsrVendorEntry.fromJson(r.cast<String, dynamic>());
  }

  ///
  /// Request body：`{ "code": "...", "config_json": "..." }`
  Future<AsrVendorEntry> updateConfigById({
    required int id,
    required Object configJson,
    String? code,
  }) async {
    String stringify(Object v) {
      if (v is String) return v;
      try {
        return jsonEncode(v);
      } catch (_) {
        return v.toString();
      }
    }

    final body = <String, dynamic>{'config_json': configJson};
    if (code != null && code.isNotEmpty) {
      body['code'] = code;
    }
    final resp = await _client.request<Object>(
      '/api/v1/asr/config/$id',
      method: 'PUT',
      data: body,
    );
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      // Compatibility: backend returns only code/message.
      return AsrVendorEntry(
        id: id,
        code: '',
        type: '',
        configJson: stringify(configJson),
      );
    }
    return AsrVendorEntry.fromJson(r.cast<String, dynamic>());
  }

  /// Delete vendor config: `DELETE /api/v1/asr/config/{id}`
  Future<void> deleteConfigById(int id) async {
    final resp = await _client.request<Object>(
      '/api/v1/asr/config/$id',
      method: 'DELETE',
    );
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  /// List ASR vendors: `GET /api/v1/asr/vendors`
  Future<AsrVendorsResult> listVendors() async {
    final resp =
        await _client.request<Object>('/api/v1/asr/vendors', method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      return const AsrVendorsResult(codes: <String>[], defaultVendor: null);
    }
    return AsrVendorsResult.fromJson(r.cast<String, dynamic>());
  }

  /// Get default vendor: `GET /api/v1/asr/config/default`
  Future<AsrDefaultVendorResult> getDefaultVendor() async {
    final resp = await _client.request<Object>('/api/v1/asr/config/default',
        method: 'GET');
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) return const AsrDefaultVendorResult(defaultVendor: null);
    return AsrDefaultVendorResult.fromJson(r.cast<String, dynamic>());
  }

  /// Set default vendor: `PUT /api/v1/asr/config/default`
  Future<AsrDefaultVendorResult> putDefaultVendor({
    required String defaultVendor,
  }) async {
    final body = <String, dynamic>{'default_vendor': defaultVendor.trim()};
    final resp = await _client.request<Object>(
      '/api/v1/asr/config/default',
      method: 'PUT',
      data: body,
    );
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) return const AsrDefaultVendorResult(defaultVendor: null);
    return AsrDefaultVendorResult.fromJson(r.cast<String, dynamic>());
  }

  /// Speech recognition (URL).
  ///
  /// App uses the job flow:
  /// 1. `POST /api/v1/asr/jobs`
  /// 2. Poll `GET /api/v1/asr/jobs/{id}`
  /// 3. On success `GET /api/v1/asr/result/{id}`
  Future<AsrRecognizeResult> recognizeUrl({
    String? fileId,
    required int id,
    required String url,
    String? language,
    bool autoSpeaker = false,
    String? macAddress,
    int? asrResultId,
    AsrJobUpdateCallback? onJobUpdate,
  }) async {
    final job = await createJob(
      fileId: fileId,
      id: id,
      url: url,
      language: language,
      autoSpeaker: autoSpeaker,
      macAddress: macAddress,
    );
    if (onJobUpdate != null) {
      await onJobUpdate(job);
    }
    final finishedJob = await waitJobUntilDone(
      job.id,
      onJobUpdate: onJobUpdate,
      initialStatus: job.status,
    );
    if (finishedJob.isFailed) {
      throw ServerException(
        finishedJob.errorMessage.trim().isEmpty
            ? 'Transcription job failed.'
            : finishedJob.errorMessage,
        messageKey: finishedJob.errorMessage.trim().isEmpty
            ? 'asrTranscribeMissingResult'
            : null,
      );
    }
    final resultId = finishedJob.asrResultId;
    if (resultId == null || resultId <= 0) {
      throw const ServerException(
        'Transcription failed: job finished without asr result id.',
        messageKey: 'asrTranscribeMissingResult',
      );
    }
    return getResultByIdWithRetry(resultId);
  }

  Future<AsrJobItem> createJob({
    String? fileId,
    required int id,
    required String url,
    String? language,
    bool autoSpeaker = false,
    String? macAddress,
  }) async {
    final body = <String, dynamic>{
      if (fileId != null && fileId.trim().isNotEmpty) 'file_id': fileId.trim(),
      'id': id,
      'url': url.trim(),
      if (language != null && language.trim().isNotEmpty)
        'language': language.trim(),
      'auto_speaker': autoSpeaker,
      if (macAddress != null && macAddress.trim().isNotEmpty)
        'mac_address': macAddress.trim(),
    };
    final resp = await _client.request<Object>(
      '/api/v1/asr/jobs',
      method: 'POST',
      data: body,
    );
    final r = _requireResultMap(
      resp.data,
      statusCode: resp.statusCode,
      missingResultMessage: 'Create ASR job failed: response missing result.',
      missingResultKey: 'asrTranscribeMissingResult',
    );
    return AsrJobItem.fromJson(r);
  }

  Future<AsrJobItem> getJobById(int id) async {
    final resp = await _client.request<Object>(
      '/api/v1/asr/jobs/$id',
      method: 'GET',
    );
    final r = _requireResultMap(
      resp.data,
      statusCode: resp.statusCode,
      missingResultMessage: 'Get ASR job failed: response missing result.',
      missingResultKey: 'asrTranscribeMissingResult',
    );
    return AsrJobItem.fromJson(r);
  }

  Future<AsrJobItem> waitJobUntilDone(
    int jobId, {
    Duration pollInterval = _jobPollInterval,
    Duration timeout = _jobPollTimeout,
    AsrJobUpdateCallback? onJobUpdate,
    String? initialStatus,
  }) async {
    final deadline = DateTime.now().add(timeout);
    String? lastStatus = initialStatus;
    var nextInterval = pollInterval;
    while (true) {
      final job = await getJobById(jobId);
      if (job.status != lastStatus) {
        lastStatus = job.status;
        nextInterval = pollInterval;
        if (onJobUpdate != null) {
          await onJobUpdate(job);
        }
      }
      if (job.isDone) return job;
      if (DateTime.now().isAfter(deadline)) {
        throw const ServerException(
          'Transcription job polling timed out.',
          messageKey: 'asrTranscribeMissingResult',
        );
      }
      await Future<void>.delayed(nextInterval);
      final doubled = nextInterval.inMilliseconds * 2;
      final maxMs = _jobPollMaxInterval.inMilliseconds;
      nextInterval = Duration(milliseconds: doubled > maxMs ? maxMs : doubled);
    }
  }

  Future<AsrRecognizeResult> getResultById(int id) async {
    final resp = await _client.request<Object>(
      '/api/v1/asr/result/$id',
      method: 'GET',
    );
    final r = _requireResultMap(
      resp.data,
      statusCode: resp.statusCode,
      missingResultMessage: 'Transcription failed: response missing result.',
      missingResultKey: 'asrTranscribeMissingResult',
    );
    return AsrRecognizeResult.fromJson(r);
  }

  Future<AsrRecognizeResult> getResultByIdWithRetry(int id) async {
    Object? lastError;
    for (var i = 0; i < _resultFetchRetryCount; i++) {
      try {
        return await getResultById(id);
      } catch (e) {
        lastError = e;
        if (i < _resultFetchRetryCount - 1) {
          await Future<void>.delayed(_jobPollInterval);
        }
      }
    }
    if (lastError is Exception) throw lastError;
    throw const ServerException(
      'Transcription failed: unable to fetch ASR result.',
      messageKey: 'asrTranscribeMissingResult',
    );
  }

  ///
  /// Query: file_id?, id, language?, mac_address?, asr_result_id?
  /// Body: application/octet-stream (raw audio bytes)
  Future<AsrRecognizeResult> recognizeBinary({
    required File file,
    String? fileId,
    required int id,
    String? language,
    String? macAddress,
    int? asrResultId,
  }) async {
    final qp = <String, dynamic>{
      if (fileId != null && fileId.trim().isNotEmpty) 'file_id': fileId.trim(),
      'id': id,
      if (language != null && language.trim().isNotEmpty)
        'language': language.trim(),
      if (macAddress != null && macAddress.trim().isNotEmpty)
        'mac_address': macAddress.trim(),
      if (asrResultId != null && asrResultId > 0) 'asr_result_id': asrResultId,
    };
    final bytes = await file.readAsBytes();
    const extendedTimeout = Duration(seconds: 600);
    final resp = await _client.request<Object>(
      '/api/v1/asr/binary',
      method: 'POST',
      queryParameters: qp,
      data: bytes,
      options: Options(
        contentType: 'application/octet-stream',
        sendTimeout: extendedTimeout,
        receiveTimeout: extendedTimeout,
      ),
    );
    final m = _ensureOk(resp.data, statusCode: resp.statusCode);
    final r = m['result'];
    if (r is! Map) {
      throw ServerException(
        'Transcription failed: response missing result.',
        messageKey: 'asrTranscribeMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return AsrRecognizeResult.fromJson(r.cast<String, dynamic>());
  }
}
