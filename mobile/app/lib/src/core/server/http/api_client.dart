import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_token_store.dart';
import '../auth/server_auth_provider.dart';
import '../server_error_codes.dart';
import '../server_config.dart';
import '../server_exception.dart';

int? _parseGoBizCode(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

/// Voice business backend stores opaque refresh tokens (e.g. UUID in Redis).
/// SenseCraft refresh tokens are JWTs (`eyJ...` + dots). Calling business
/// `POST /api/v1/user/refresh` with a SenseCraft JWT clears [AuthTokenStore]
/// on failure and surfaces bogus `tokenInvalid` / `rbacNoUserId` errors.
bool _isVoiceBusinessRefreshToken(String? raw) {
  final rt = (raw ?? '').trim();
  if (rt.isEmpty) return false;
  // HS256 / RS256 / ES384 JWTs from SenseCraft all start with `eyJ` and have
  // dot-separated segments.
  if (rt.startsWith('eyJ') && rt.contains('.')) return false;
  return true;
}

class ApiClient {
  final ServerConfig config;
  final ServerAuthProvider auth;
  Future<bool>? _refreshing;

  static const int _kMaxLogLen = 1200;
  static const Set<String> _kSensitiveKeys = {
    'password',
    'token',
    'access_token',
    'id_token',
    'refresh_token',
    'authorization',
    'client_secret',
    'code_verifier',
    'identityToken',
    'authorizationCode',
    'old_password',
    'new_password',
  };

  static Object? _maskValue(Object? v) {
    if (v == null) return null;
    final s = v.toString();
    if (s.isEmpty) return s;
    return '<redacted len=${s.length}>';
  }

  static Object? _sanitizeForLog(Object? input) {
    if (input == null) return null;
    if (input is Map) {
      final out = <String, dynamic>{};
      input.forEach((k, v) {
        final key = k.toString();
        if (_kSensitiveKeys.contains(key)) {
          out[key] = _maskValue(v);
        } else {
          out[key] = _sanitizeForLog(v);
        }
      });
      return out;
    }
    if (input is List) {
      return input.map(_sanitizeForLog).toList();
    }
    if (input is String) {
      // Keep logs small
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
    if (!config.enableNetworkLog) return;
    final qp = options.queryParameters.isEmpty ? null : _sanitizeForLog(options.queryParameters);
    final body = options.data == null ? null : _sanitizeForLog(options.data);
    final authHeader = (options.headers['Authorization'] ?? options.headers['authorization'])?.toString();
    debugPrint('[API] ${options.method} ${options.uri}');
    if (authHeader != null && authHeader.trim().isNotEmpty) {
      // Log length only, not body, to verify token attachment
      debugPrint('[API]   authHeaderLen=${authHeader.length}');
    } else {
      debugPrint('[API]   authHeaderLen=0');
    }
    if (qp != null) debugPrint('[API]   query=${_truncate(qp.toString())}');
    if (body != null) debugPrint('[API]   body=${_truncate(body.toString())}');
  }

  void _logResponse(Response resp) {
    if (!config.enableNetworkLog) return;
    final uri = resp.requestOptions.uri;
    final status = resp.statusCode;
    Object? data = resp.data;
    data = _sanitizeForLog(data);
    // Standard envelope: also log biz code/message
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      final code = m['code'];
      final msg = m['message'];
      debugPrint('[API] <- $status $uri  bizCode=$code msg=$msg');
      debugPrint('[API]   data=${_truncate(m.toString())}');
      return;
    }
    debugPrint('[API] <- $status $uri');
    if (data != null) debugPrint('[API]   data=${_truncate(data.toString())}');
  }

  void _logError(DioException e) {
    if (!config.enableNetworkLog) return;
    final status = e.response?.statusCode;
    final uri = e.requestOptions.uri;
    debugPrint('[API] !! $status $uri ${e.message}');
    final data = _sanitizeForLog(e.response?.data);
    if (data != null) debugPrint('[API]   errData=${_truncate(data.toString())}');
  }

  late final Dio _dio = Dio(
    BaseOptions(
      baseUrl: config.baseUri.toString(),
      connectTimeout: config.connectTimeout,
      receiveTimeout: config.receiveTimeout,
      headers: const {
        'Accept': 'application/json',
      },
    ),
  )..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final headers = await auth.headers();
          options.headers.addAll(headers);

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
      ),
    );

  ApiClient({required this.config, required this.auth});

  /// Runtime safety net for the "SC JWT leaked into [AuthTokenStore]" failure
  /// mode. When the business backend rejects our token with `code=2008` and a
  /// detail like
  /// `json: cannot unmarshal number into …Claims.jti of type string`,
  /// the cached token cannot have been minted by the business backend (its own
  /// JWTs use a string `jti`). Refresh will not help — wipe the store so the
  /// next bootstrap or SC redirect re-runs `external/sensecraft/login`.
  Future<void> _purgeTokenIfNotBusinessJwt(ServerException e) async {
    if (e.bizCode != ServerErrorCodes.tokenInvalid) return;
    final details = (e.details ?? '').toLowerCase();
    if (!details.contains('jti') && !details.contains('claims')) return;
    final tok = (AuthTokenStore.cached ?? '').trim();
    if (tok.isEmpty) return;
    if (config.enableNetworkLog) {
      debugPrint(
        '[API] purging stale non-business JWT from AuthTokenStore '
        '(bizCode=${e.bizCode}, details="${e.details}")',
      );
    }
    await AuthTokenStore.purgeIfNotBusinessJwt();
  }

  bool _shouldTryRefresh(ServerException e) {
    final path = config.refreshTokenPath.trim();
    if (path.isEmpty) return false;
    final rt = AuthTokenStore.refreshTokenCached;
    if (!_isVoiceBusinessRefreshToken(rt)) return false;
    final hasRefresh = rt != null && rt.trim().isNotEmpty;
    if (!hasRefresh) return false;
    final httpUnauthorized = e.statusCode == 401;
    final bizUnauthorized = ServerErrorCodes.isAuthInvalid(e.bizCode);
    return httpUnauthorized || bizUnauthorized;
  }

  Future<bool> _refreshTokenIfNeeded() async {
    final path = config.refreshTokenPath.trim();
    final rt = (AuthTokenStore.refreshTokenCached ?? '').trim();
    if (path.isEmpty || rt.isEmpty || !_isVoiceBusinessRefreshToken(rt)) {
      return false;
    }

    _refreshing ??= () async {
      try {
        // Separate Dio to avoid interceptor recursion
        final dio = Dio(
          BaseOptions(
            baseUrl: config.baseUri.toString(),
            connectTimeout: config.connectTimeout,
            receiveTimeout: config.receiveTimeout,
            headers: const {'Accept': 'application/json'},
          ),
        );
        if (config.enableNetworkLog) {
          debugPrint('[API] refresh -> POST ${config.baseUri.resolve(path)}');
        }
        final resp = await dio.request<Object>(
          path,
          data: {'refresh_token': rt},
          options: Options(method: 'POST'),
        );
        final data = resp.data;
        if (data is! Map) return false;
        final m = data.cast<String, dynamic>();
        final biz = _parseGoBizCode(m['code']) ?? 0;
        if (!ServerErrorCodes.isOk(biz)) {
          // Invalid/expired refresh_token: clear local tokens (logged out)
          if (biz == ServerErrorCodes.tokenInvalid || biz == ServerErrorCodes.tokenExpired || resp.statusCode == 401) {
            await AuthTokenStore.clear();
          }
          return false;
        }
        final result = m['result'];
        if (result is! Map) return false;
        final r = result.cast<String, dynamic>();
        final newAccess = (r['token'] ?? r['access_token'] ?? '').toString().trim();
        final newRefresh = (r['refresh_token'] ?? '').toString().trim();
        if (newAccess.isEmpty) return false;
        await AuthTokenStore.saveTokens(accessToken: newAccess, refreshToken: newRefresh.isEmpty ? rt : newRefresh);
        if (config.enableNetworkLog) {
          debugPrint('[API] refresh <- ok, newTokenLen=${newAccess.length}');
        }
        return true;
      } on DioException catch (e) {
        // Refresh failed (401 / 2008, etc.): clear tokens, force login
        final status = e.response?.statusCode;
        final data = e.response?.data;
        int? biz;
        if (data is Map) {
          final m = data.cast<String, dynamic>();
          biz = _parseGoBizCode(m['code']);
        }
        if (status == 401 || biz == ServerErrorCodes.tokenInvalid || biz == ServerErrorCodes.tokenExpired) {
          await AuthTokenStore.clear();
        }
        if (config.enableNetworkLog) {
          debugPrint('[API] refresh !! $e');
        }
        return false;
      } catch (e) {
        if (config.enableNetworkLog) {
          debugPrint('[API] refresh !! $e');
        }
        return false;
      } finally {
        _refreshing = null;
      }
    }();

    return await _refreshing!;
  }

  Future<Response<T>> request<T>(
    String path, {
    required String method,
    Map<String, dynamic>? queryParameters,
    Object? data,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    Future<Response<T>> doRequest(Options? opt) => _dio.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: (opt ?? Options()).copyWith(method: method),
        cancelToken: cancelToken,
      );

    try {
      final resp = await doRequest(options);
      return resp;
    } on DioException catch (e) {
      final se = _mapDioError(e);
      await _purgeTokenIfNotBusinessJwt(se);
      final alreadyRetried = (e.requestOptions.extra['__retried__'] == true);
      if (!alreadyRetried && _shouldTryRefresh(se)) {
        final ok = await _refreshTokenIfNeeded();
        if (ok) {
          final nextExtra = {...e.requestOptions.extra, '__retried__': true};
          final nextOptions = (options ?? Options()).copyWith(method: method, extra: nextExtra);
          try {
            return await doRequest(nextOptions);
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

  Future<Response<T>> uploadFiles<T>(
    String path, {
    required List<File> files,
    String fieldName = 'files',
    Map<String, dynamic>? fields,
    Map<String, dynamic>? queryParameters,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      final form = FormData();
      if (fields != null) {
        fields.forEach((k, v) => form.fields.add(MapEntry(k, v?.toString() ?? '')));
      }
      for (final f in files) {
        form.files.add(
          MapEntry(
            fieldName,
            await MultipartFile.fromFile(f.path),
          ),
        );
      }
      final resp = await _dio.post<T>(
        path,
        data: form,
        queryParameters: queryParameters,
        onSendProgress: onSendProgress,
        cancelToken: cancelToken,
        options: Options(contentType: 'multipart/form-data'),
      );
      return resp;
    } on DioException catch (e) {
      throw _mapDioError(e);
    } catch (e) {
      throw ServerException(
        'Upload failed.',
        messageKey: 'errorUploadFailed',
        data: e,
      );
    }
  }

  ServerException _mapDioError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    // If server returns our standard envelope, carry bizCode/details.
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      final bizCode = _parseGoBizCode(m['code']);
      final msg = m['message']?.toString();
      final errorKey = m['error_key']?.toString();
      final details = m['details']?.toString();
      if (bizCode != null || msg != null || details != null || errorKey != null) {
        return ServerException(
          msg ?? '请求失败',
          bizCode: bizCode,
          errorKey: errorKey,
          details: details,
          statusCode: status,
          data: data,
        );
      }
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
    if (e.type == DioExceptionType.connectionError) {
      return ServerException(
        'Network unavailable.',
        messageKey: 'errorNetworkUnavailable',
        statusCode: status,
        data: data,
      );
    }
    if (e.error is SocketException) {
      return ServerException(
        'Network unavailable.',
        messageKey: 'errorNetworkUnavailable',
        statusCode: status,
        data: data,
      );
    }
    if (status != null) {
      return ServerException(
        'Request failed.',
        messageKey: 'errorRequestFailed',
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
}

