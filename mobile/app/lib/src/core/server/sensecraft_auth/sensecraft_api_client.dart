import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../server_exception.dart';
import 'sensecraft_auth_token_store.dart';
import 'sensecraft_envelope.dart';
import 'sensecraft_error_codes.dart';

/// Dio-backed HTTP client dedicated to the SenseCraft unified auth host.
///
/// Why a separate client (not a tweaked [ApiClient]):
///
/// - Different `baseUri` (`authDomain()`).
/// - Different envelope: `{code,msg,data}` with `code` possibly stringy.
/// - Auth header convention (legacy `portalApiRequest` in `common.js`):
///   `Authorization: <access_token>` — raw token, **no `Bearer` prefix**,
///   no cookies (`credentials: 'omit'`). The **refresh** endpoint is the
///   only exception, using `Authorization: Bearer <refresh_token>`.
/// - Different refresh contract: `GET /api/v1/auth/refreshToken` with
///   `Authorization: Bearer <refresh_token>`, body returns `{ token }`.
/// - Channel header convention: `channel: sensecap_app`.
/// - Different error code namespace ([SenseCraftErrorCodes] 1100x / 1102x / 1700x).
///
/// Lifetime is tied to the user's session: created once per
/// `senseCraftApiClientProvider` build and recreated if the auth env changes.
class SenseCraftApiClient {
  final Uri baseUri;

  /// Channel header per SenseCraft authapi. Statistics-only on
  /// the backend; safe to keep constant for this app.
  static const String _channelHeader = 'sensecap_app';

  static const int _kMaxLogLen = 1200;
  static const Set<String> _kSensitiveKeys = {
    'password', 'token', 'access_token', 'id_token', 'refresh_token',
    'Authorization', 'authorization', 'idToken', 'code',
  };

  final Duration connectTimeout;
  final Duration receiveTimeout;
  final bool enableNetworkLog;

  Future<bool>? _refreshing;

  SenseCraftApiClient({
    required this.baseUri,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.enableNetworkLog = kDebugMode,
  });

  /// Auth endpoints that must run **without** a cached SenseCraft access token.
  ///
  /// Pre-login calls (register, code, password login) can otherwise inherit
  /// a stale `Authorization: Bearer <access_token>` from a previous session
  /// and trigger incorrect validation on some gateways.
  static bool _pathUsesAnonymousSenseCraftAccess(RequestOptions o) {
    final path = o.uri.path;
    return path.contains('/api/v1/auth/getEmailCode') ||
        path.contains('/api/v1/auth/registerByEmail') ||
        path.contains('/api/v1/auth/email/login') ||
        path.contains('/api/v1/auth/oauth/mobile') ||
        path.contains('/api/v1/auth/resetPassword');
  }

  late final Dio _dio = Dio(
    BaseOptions(
      baseUrl: baseUri.toString(),
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: const {
        'Accept': 'application/json',
        'channel': _channelHeader,
      },
    ),
  )..interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (!_pathUsesAnonymousSenseCraftAccess(options)) {
          var tok = SenseCraftAuthTokenStore.cached;
          final accessEmpty = tok == null || tok.trim().isEmpty;
          final refreshNonEmpty =
              (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim().isNotEmpty;
          // Access token missing but refresh present (cold start / expiry) —
          // pull a fresh access via /api/v1/auth/refreshToken before the call.
          if (accessEmpty && refreshNonEmpty) {
            await _refreshTokenIfNeeded();
            tok = SenseCraftAuthTokenStore.cached;
          }
          if (tok != null && tok.trim().isNotEmpty) {
            // Match the legacy `portalApiRequest` (common.js): raw access token
            // in `Authorization` header, no `Bearer` prefix, no cookie. Only
            // the **refresh** endpoint uses `Bearer <refresh_token>`, handled
            // separately in [_refreshTokenIfNeeded].
            options.headers['Authorization'] = tok.trim();
          } else {
            options.headers.remove('Authorization');
            if (enableNetworkLog) {
              debugPrint(
                '[SC-AUTH]   WARNING: missing SenseCraft access token for ${options.uri.path}',
              );
            }
          }
        } else {
          options.headers.remove('Authorization');
        }
        _logRequest(options);
        handler.next(options);
      },
      onResponse: (resp, handler) {
        _logResponse(resp);
        handler.next(resp);
      },
      onError: (e, handler) {
        _logError(e);
        handler.next(e);
      },
    ));

  // ---- Public request surface ----------------------------------------

  /// JSON request. Returns the raw envelope; callers usually wrap with
  /// [parseSenseCraftEnvelope].
  Future<Response<Object?>> requestJson(
    String path, {
    required String method,
    Map<String, dynamic>? queryParameters,
    Object? data,
    Options? options,
  }) {
    // Some gateways only bind JSON bodies when Content-Type is explicit.
    final jsonOptions = (options ?? Options()).copyWith(
      contentType: Headers.jsonContentType,
    );
    return _request(path,
        method: method,
        queryParameters: queryParameters,
        data: data,
        options: jsonOptions);
  }

  /// `multipart/form-data` POST — required by `/api/v1/auth/email/login` and
  /// other endpoints that don't accept JSON.
  Future<Response<Object?>> postForm(
    String path, {
    required Map<String, String> fields,
    Map<String, dynamic>? queryParameters,
  }) {
    final form = FormData();
    fields.forEach((k, v) => form.fields.add(MapEntry(k, v)));
    return _request(
      path,
      method: 'POST',
      data: form,
      queryParameters: queryParameters,
      options: Options(contentType: 'multipart/form-data'),
    );
  }

  Future<Response<Object?>> _request(
    String path, {
    required String method,
    Map<String, dynamic>? queryParameters,
    Object? data,
    Options? options,
  }) async {
    Future<Response<Object?>> doRequest(Options? opt) => _dio.request<Object?>(
          path,
          data: data,
          queryParameters: queryParameters,
          options: (opt ?? Options()).copyWith(method: method),
        );

    final baseExtra = Map<String, dynamic>.from(options?.extra ?? const {});

    try {
      var resp = await doRequest(options);
      // Gateways often return HTTP 200 with `{ code: 11102, msg: Invalid token }`.
      // That never becomes a [DioException], so refresh must run here too.
      final alreadyRetried200 = baseExtra['__sc_retried__'] == true;
      if (!alreadyRetried200 &&
          _envelopeIndicatesAuthInvalid(resp.data) &&
          (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim().isNotEmpty) {
        final ok = await _refreshTokenIfNeeded();
        if (ok) {
          final retryOptions = (options ?? Options()).copyWith(
            method: method,
            extra: {...baseExtra, '__sc_retried__': true},
          );
          try {
            resp = await doRequest(retryOptions);
          } on DioException catch (e2) {
            throw _mapDioError(e2);
          }
        }
      }
      return resp;
    } on DioException catch (e) {
      final se = _mapDioError(e);
      final alreadyRetried = e.requestOptions.extra['__sc_retried__'] == true;
      if (!alreadyRetried && _shouldTryRefresh(se)) {
        final ok = await _refreshTokenIfNeeded();
        if (ok) {
          final retryOptions = (options ?? Options()).copyWith(
            method: method,
            extra: {...e.requestOptions.extra, '__sc_retried__': true},
          );
          try {
            return await doRequest(retryOptions);
          } on DioException catch (e2) {
            throw _mapDioError(e2);
          }
        }
      }
      throw se;
    } catch (e) {
      throw ServerException(
        'Network request failed.',
        messageKey: 'errorNetworkRequestFailed',
        data: e,
      );
    }
  }

  static bool _envelopeIndicatesAuthInvalid(Object? body) {
    if (body is! Map) return false;
    final code = parseSenseCraftCode(body['code']);
    return SenseCraftErrorCodes.isAuthInvalid(code);
  }

  // ---- Refresh -------------------------------------------------------

  bool _shouldTryRefresh(ServerException e) {
    final rt = (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim();
    if (rt.isEmpty) return false;
    if (e.statusCode == 401) return true;
    return SenseCraftErrorCodes.isAuthInvalid(e.bizCode);
  }

  /// `GET /api/v1/auth/refreshToken`
  ///
  /// Per SenseCraft authapi, the refresh token is sent as
  /// `Authorization: Bearer <refresh_token>` (NOT the access token).
  Future<bool> _refreshTokenIfNeeded() async {
    final rt = (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim();
    if (rt.isEmpty) return false;

    _refreshing ??= () async {
      try {
        // Separate Dio so the interceptor's Bearer access_token doesn't
        // overwrite our Bearer refresh_token.
        final dio = Dio(BaseOptions(
          baseUrl: baseUri.toString(),
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
          headers: const {
            'Accept': 'application/json',
            'channel': _channelHeader,
          },
        ));
        final refreshUri = baseUri.resolve('api/v1/auth/refreshToken');
        if (enableNetworkLog) {
          debugPrint('[SC-AUTH] refresh -> GET $refreshUri');
        }
        final resp = await dio.get<Object?>(
          refreshUri.toString(),
          queryParameters: {'refreshToken': rt},
          options: Options(headers: {'Authorization': 'Bearer $rt'}),
        );
        final body = resp.data;
        if (body is! Map) return false;
        final m = body.cast<String, dynamic>();
        final code = parseSenseCraftCode(m['code']);
        if (!SenseCraftErrorCodes.isOk(code)) {
          if (SenseCraftErrorCodes.isAuthInvalid(code) || resp.statusCode == 401) {
            await SenseCraftAuthTokenStore.clear();
          }
          return false;
        }
        final data = m['data'];
        if (data is! Map) return false;
        final newAccess = (data['token'] ?? '').toString().trim();
        if (newAccess.isEmpty) return false;
        // SenseCraft refreshToken endpoint returns only `token`; reuse the
        // existing refresh_token.
        await SenseCraftAuthTokenStore.saveTokens(accessToken: newAccess);
        if (enableNetworkLog) {
          debugPrint('[SC-AUTH] refresh <- ok, newTokenLen=${newAccess.length}');
        }
        return true;
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) {
          await SenseCraftAuthTokenStore.clear();
        }
        if (enableNetworkLog) debugPrint('[SC-AUTH] refresh !! $e');
        return false;
      } catch (e) {
        if (enableNetworkLog) debugPrint('[SC-AUTH] refresh !! $e');
        return false;
      } finally {
        _refreshing = null;
      }
    }();
    return await _refreshing!;
  }

  // ---- Error mapping -------------------------------------------------

  ServerException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      final code = parseSenseCraftCode(m['code']);
      final msg = m['msg']?.toString() ?? m['message']?.toString();
      return ServerException(
        msg ?? '请求失败',
        bizCode: code,
        statusCode: status,
        data: data,
      );
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return ServerException(
        'Network timeout.',
        messageKey: 'errorNetworkTimeout',
        statusCode: status,
        data: data,
      );
    }
    if (e.type == DioExceptionType.connectionError || e.error is SocketException) {
      return ServerException(
        'Network unavailable.',
        messageKey: 'errorNetworkUnavailable',
        statusCode: status,
        data: data,
      );
    }
    return ServerException(
      e.message ?? 'Request failed.',
      messageKey: 'errorRequestFailed',
      statusCode: status,
      data: data,
    );
  }

  // ---- Logging -------------------------------------------------------

  static Object? _sanitizeForLog(Object? input) {
    if (input == null) return null;
    if (input is Map) {
      final out = <String, dynamic>{};
      input.forEach((k, v) {
        final key = k.toString();
        if (_kSensitiveKeys.contains(key)) {
          final s = v?.toString() ?? '';
          out[key] = '<redacted len=${s.length}>';
        } else {
          out[key] = _sanitizeForLog(v);
        }
      });
      return out;
    }
    if (input is List) return input.map(_sanitizeForLog).toList();
    if (input is String) {
      if (input.length > 300) return '<string len=${input.length}>';
      return input;
    }
    return input;
  }

  static String _truncate(String s, {int max = _kMaxLogLen}) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…(truncated, len=${s.length})';
  }

  void _logRequest(RequestOptions options) {
    if (!enableNetworkLog) return;
    debugPrint('[SC-AUTH] ${options.method} ${options.uri}');
    final auth = (options.headers['Authorization'] ?? '').toString();
    if (auth.isNotEmpty) {
      debugPrint('[SC-AUTH]   authHeaderLen=${auth.length}');
    }
    if (options.queryParameters.isNotEmpty) {
      debugPrint('[SC-AUTH]   query=${_truncate(_sanitizeForLog(options.queryParameters).toString())}');
    }
    final body = options.data;
    if (body != null && body is! FormData) {
      if (body is String) {
        try {
          final decoded = jsonDecode(body);
          debugPrint('[SC-AUTH]   bodyJson=${_truncate(jsonEncode(_sanitizeForLog(decoded)))}');
        } catch (_) {
          debugPrint('[SC-AUTH]   body=${_truncate(body)}');
        }
      } else {
        debugPrint('[SC-AUTH]   body=${_truncate(_sanitizeForLog(body).toString())}');
      }
    } else if (body is FormData) {
      debugPrint('[SC-AUTH]   form fields=${body.fields.map((e) => e.key).toList()}');
    }
  }

  void _logResponse(Response resp) {
    if (!enableNetworkLog) return;
    final uri = resp.requestOptions.uri;
    final status = resp.statusCode;
    final raw = resp.data;
    Object? codeRaw;
    String? msgRaw;
    if (raw is Map) {
      final m = raw.cast<String, dynamic>();
      codeRaw = m['code'];
      msgRaw = (m['msg'] ?? m['message'])?.toString();
    }
    debugPrint('[SC-AUTH] <- $status $uri  bizCode=$codeRaw msg=$msgRaw');
    final data = _sanitizeForLog(resp.data);
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      debugPrint('[SC-AUTH]   data=${_truncate(m.toString())}');
      return;
    }
    if (data != null) debugPrint('[SC-AUTH]   data=${_truncate(data.toString())}');
  }

  void _logError(DioException e) {
    if (!enableNetworkLog) return;
    debugPrint('[SC-AUTH] !! ${e.response?.statusCode} ${e.requestOptions.uri} ${e.message}');
    final data = _sanitizeForLog(e.response?.data);
    if (data != null) debugPrint('[SC-AUTH]   errData=${_truncate(data.toString())}');
  }
}
