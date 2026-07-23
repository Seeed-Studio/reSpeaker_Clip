import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../sensecraft_auth/sensecraft_auth_token_store.dart';
import '../sensecraft_auth/sensecraft_envelope.dart';
import '../sensecraft_auth/sensecraft_error_codes.dart';
import '../server_exception.dart';

/// Dio-backed HTTP client for the SenseCAP **PaaS** API (portalapi prefix).
///
/// Auth matches the legacy SenseCraft portal / user-center contract
/// ([SenseCraftApiClient] / `portalApiRequest` in `common.js`):
///
/// - `Authorization`: raw SenseCraft **access** token (no `Bearer` prefix)
/// - `channel`: `sensecap_app`
///
/// Token refresh runs against [authBaseUri] (`authDomain()`), not the PaaS
/// host, because `/api/v1/auth/refreshToken` lives on the auth cluster.
class SenseCraftPaasClient {
  final Uri baseUri;
  final Uri authBaseUri;

  static const String _channelHeader = 'sensecap_app';

  static const int _kMaxLogLen = 1200;
  static const Set<String> _kSensitiveKeys = {
    'password', 'token', 'access_token', 'id_token', 'refresh_token',
    'Authorization', 'authorization', 'idToken', 'code',
    'deviceKey', 'device_key',
  };

  final Duration connectTimeout;
  final Duration receiveTimeout;
  final bool enableNetworkLog;

  Future<bool>? _refreshing;

  SenseCraftPaasClient({
    required this.baseUri,
    required this.authBaseUri,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.enableNetworkLog = kDebugMode,
  });

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
        var tok = SenseCraftAuthTokenStore.cached;
        final accessEmpty = tok == null || tok.trim().isEmpty;
        final refreshNonEmpty =
            (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim().isNotEmpty;
        if (accessEmpty && refreshNonEmpty) {
          await _refreshTokenIfNeeded();
          tok = SenseCraftAuthTokenStore.cached;
        }
        if (tok != null && tok.trim().isNotEmpty) {
          options.headers['Authorization'] = tok.trim();
        } else {
          options.headers.remove('Authorization');
          if (enableNetworkLog) {
            debugPrint(
              '[SC-PAAS]   WARNING: missing SenseCraft access token for ${options.uri.path}',
            );
          }
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

  Future<Response<Object?>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) =>
      _request(path, method: 'GET', queryParameters: queryParameters);

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
      final alreadyRetried200 = baseExtra['__sc_paas_retried__'] == true;
      if (!alreadyRetried200 &&
          _portalResponseShouldRefresh(resp.data) &&
          (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim().isNotEmpty) {
        final ok = await _refreshTokenIfNeeded();
        if (ok) {
          final retryOptions = (options ?? Options()).copyWith(
            method: method,
            extra: {...baseExtra, '__sc_paas_retried__': true},
          );
          try {
            resp = await doRequest(retryOptions);
            if (enableNetworkLog) {
              final code = resp.data is Map
                  ? parseSenseCraftCode((resp.data as Map)['code'])
                  : null;
              debugPrint('[SC-PAAS] retry after refresh bizCode=$code');
            }
          } on DioException catch (e2) {
            throw _mapDioError(e2);
          }
        } else if (enableNetworkLog) {
          debugPrint('[SC-PAAS] refresh skipped retry (refresh failed)');
        }
      }
      return resp;
    } on DioException catch (e) {
      final se = _mapDioError(e);
      final alreadyRetried = e.requestOptions.extra['__sc_paas_retried__'] == true;
      if (!alreadyRetried && _shouldTryRefresh(se)) {
        final ok = await _refreshTokenIfNeeded();
        if (ok) {
          final retryOptions = (options ?? Options()).copyWith(
            method: method,
            extra: {...e.requestOptions.extra, '__sc_paas_retried__': true},
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

  /// Reads the standard SenseCraft envelope `{code,msg,data}`; throws a
  /// [ServerException] on non-success codes.
  SenseCraftEnvelope readEnvelope(
    Response<Object?> resp, {
    required String fallbackMessage,
  }) {
    return parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: fallbackMessage,
    );
  }

  // ---- Refresh (auth cluster) ----------------------------------------

  /// Portal may return `11102 Invalid token` when the JWT is not accepted
  /// by this gateway (wrong site/format) even though the access token is
  /// still valid for authapi user-center calls. Do **not** treat that as
  /// "refresh access token" — refreshing then failing used to [clear] the
  /// SenseCraft session and bounce the user to login.
  static bool _portalResponseShouldRefresh(Object? body) {
    if (body is! Map) return false;
    final code = parseSenseCraftCode(body['code']);
    return code == SenseCraftErrorCodes.noAccessKey ||
        code == SenseCraftErrorCodes.refreshTokenExpired;
  }

  bool _shouldTryRefresh(ServerException e) {
    final rt = (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim();
    if (rt.isEmpty) return false;
    if (e.statusCode == 401) return true;
    return SenseCraftErrorCodes.isAuthInvalid(e.bizCode);
  }

  Future<bool> _refreshTokenIfNeeded() async {
    final rt = (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim();
    if (rt.isEmpty) return false;

    _refreshing ??= () async {
      try {
        final dio = Dio(BaseOptions(
          baseUrl: authBaseUri.toString(),
          connectTimeout: connectTimeout,
          receiveTimeout: receiveTimeout,
          headers: const {
            'Accept': 'application/json',
            'channel': _channelHeader,
          },
        ));
        // Resolve against authBaseUri (relative path) so `/authapi` is kept.
        // Also pass `refreshToken` query — some gateways only accept query/Cookie,
        // not Bearer, and return 10009 when the param is missing.
        final refreshUri = authBaseUri.resolve('api/v1/auth/refreshToken');
        if (enableNetworkLog) {
          debugPrint('[SC-PAAS] refresh -> GET $refreshUri');
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
          // Only wipe the session when the refresh token itself is dead.
          // Do not clear on 11102 etc. — portal failures must not log the
          // user out of the whole app.
          if (code == SenseCraftErrorCodes.refreshTokenExpired ||
              code == SenseCraftErrorCodes.refreshTokenInvalid ||
              resp.statusCode == 401) {
            await SenseCraftAuthTokenStore.clear();
          }
          if (enableNetworkLog) {
            debugPrint(
              '[SC-PAAS] refresh <- failed bizCode=$code msg=${m['msg'] ?? m['message']}',
            );
          }
          return false;
        }
        final data = m['data'];
        if (data is! Map) return false;
        final newAccess = (data['token'] ?? '').toString().trim();
        if (newAccess.isEmpty) return false;
        await SenseCraftAuthTokenStore.saveTokens(accessToken: newAccess);
        if (enableNetworkLog) {
          debugPrint('[SC-PAAS] refresh <- ok, newTokenLen=${newAccess.length}');
        }
        return true;
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) {
          await SenseCraftAuthTokenStore.clear();
        }
        if (enableNetworkLog) debugPrint('[SC-PAAS] refresh !! $e');
        return false;
      } catch (e) {
        if (enableNetworkLog) debugPrint('[SC-PAAS] refresh !! $e');
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
        msg ?? 'Request failed.',
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
    debugPrint('[SC-PAAS] ${options.method} ${options.uri}');
    final auth = (options.headers['Authorization'] ?? '').toString();
    if (auth.isNotEmpty) {
      debugPrint('[SC-PAAS]   authHeaderLen=${auth.length}');
    }
    if (options.queryParameters.isNotEmpty) {
      debugPrint(
          '[SC-PAAS]   query=${_truncate(_sanitizeForLog(options.queryParameters).toString())}');
    }
    final body = options.data;
    if (body != null && body is! FormData) {
      if (body is String) {
        try {
          final decoded = jsonDecode(body);
          debugPrint('[SC-PAAS]   bodyJson=${_truncate(jsonEncode(_sanitizeForLog(decoded)))}');
        } catch (_) {
          debugPrint('[SC-PAAS]   body=${_truncate(body)}');
        }
      } else {
        debugPrint('[SC-PAAS]   body=${_truncate(_sanitizeForLog(body).toString())}');
      }
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
    debugPrint('[SC-PAAS] <- $status $uri  bizCode=$codeRaw msg=$msgRaw');
    final data = _sanitizeForLog(resp.data);
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      debugPrint('[SC-PAAS]   data=${_truncate(m.toString())}');
      return;
    }
    if (data != null) debugPrint('[SC-PAAS]   data=${_truncate(data.toString())}');
  }

  void _logError(DioException e) {
    if (!enableNetworkLog) return;
    debugPrint('[SC-PAAS] !! ${e.response?.statusCode} ${e.requestOptions.uri} ${e.message}');
    final data = _sanitizeForLog(e.response?.data);
    if (data != null) debugPrint('[SC-PAAS]   errData=${_truncate(data.toString())}');
  }
}
