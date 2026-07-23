import 'package:dio/dio.dart';

import '../server_exception.dart';
import 'feedback_workflow_values.dart';

/// Voice app feedback workflow client (`POST /v1/workflows/run`).
///
/// No credentials are bundled: set the API key and host via
/// `--dart-define=API_KEY=...` (or `FEEDBACK_WORKFLOW_API_KEY=...`) and
/// `--dart-define=API_BASE=...` (or `FEEDBACK_WORKFLOW_BASE_URL=...`).
/// [isConfigured] is false until an API key is injected.
class FeedbackWorkflowApi {
  FeedbackWorkflowApi({
    Dio? dio,
    String? apiKey,
    String? baseUrl,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 120),
              sendTimeout: const Duration(seconds: 120),
            )),
        _apiKey = (apiKey ?? _resolveApiKey()).trim(),
        _baseUri = Uri.parse(
          ((baseUrl ?? _resolveBaseUrl()).trim().isEmpty
                  ? _defaultBaseUrl
                  : (baseUrl ?? _resolveBaseUrl()))
              .replaceAll(RegExp(r'/+$'), ''),
        );

  /// Feedback workflow host. Inject via --dart-define=FEEDBACK_WORKFLOW_BASE_URL
  /// (or API_BASE). Placeholder default; requests are disabled until configured.
  static const _defaultBaseUrl = 'https://your-feedback-host.example.com/v1';

  static const _kBaseUrlPrimary = String.fromEnvironment(
    'FEEDBACK_WORKFLOW_BASE_URL',
    defaultValue: '',
  );
  static const _kBaseUrlAlt = String.fromEnvironment(
    'API_BASE',
    defaultValue: '',
  );
  static const _kApiKeyPrimary = String.fromEnvironment(
    'FEEDBACK_WORKFLOW_API_KEY',
    defaultValue: '',
  );
  static const _kApiKeyAlt = String.fromEnvironment(
    'API_KEY',
    defaultValue: '',
  );

  final Dio _dio;
  final String _apiKey;
  final Uri _baseUri;

  bool get isConfigured => _apiKey.isNotEmpty;

  static String _resolveApiKey() {
    if (_kApiKeyPrimary.isNotEmpty) return _kApiKeyPrimary;
    if (_kApiKeyAlt.isNotEmpty) return _kApiKeyAlt;
    return '';
  }

  static String _resolveBaseUrl() {
    if (_kBaseUrlPrimary.isNotEmpty) return _kBaseUrlPrimary;
    if (_kBaseUrlAlt.isNotEmpty) return _kBaseUrlAlt;
    return _defaultBaseUrl;
  }

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $_apiKey',
      };

  Future<Map<String, dynamic>> submitVoiceFeedback({
    required String userId,
    required String description,
    required String mode,
  }) async {
    _ensureConfigured();
    final payload = {
      'inputs': {
        'form_type': FeedbackWorkflowValues.formTypeVoiceFeedback,
        'description': description,
        'mode': mode,
      },
      'response_mode': 'blocking',
      'user': userId,
    };

    try {
      final res = await _dio.post<Map<String, dynamic>>(
        _uri('/workflows/run').toString(),
        data: payload,
        options: Options(
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/json',
          },
        ),
      );
      return Map<String, dynamic>.from(res.data ?? const {});
    } on DioException catch (e) {
      throw _mapDio(e);
    }
  }

  void _ensureConfigured() {
    if (!isConfigured) {
      throw ServerException(
        'Feedback workflow API key is not configured. '
        'Set --dart-define=API_KEY=... to enable feedback submission.',
      );
    }
  }

  Uri _uri(String path) => _baseUri.replace(path: '${_baseUri.path}$path');

  ServerException _mapDio(DioException e) {
    final status = e.response?.statusCode;
    final body = e.response?.data;
    final detail = body is Map
        ? (body['message'] ?? body['msg'] ?? body.toString()).toString()
        : body?.toString();
    return ServerException(
      detail?.trim().isNotEmpty == true
          ? detail!.trim()
          : (e.message ?? 'Network error'),
      statusCode: status,
    );
  }
}
