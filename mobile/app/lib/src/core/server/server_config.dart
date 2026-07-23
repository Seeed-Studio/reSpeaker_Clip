import 'package:flutter/foundation.dart';

@immutable
class ServerConfig {
  final Uri baseUri;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final bool enableNetworkLog;
  /// Refresh token endpoint path (relative), e.g. `/api/v1/user/token/refresh`.
  ///
  /// When empty, refresh logic is disabled.
  final String refreshTokenPath;

  const ServerConfig({
    required this.baseUri,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.enableNetworkLog = kDebugMode,
    this.refreshTokenPath = '',
  });

  Uri resolve(String path, {Map<String, String>? queryParameters}) {
    final uri = baseUri.resolve(path);
    if (queryParameters == null || queryParameters.isEmpty) return uri;
    return uri.replace(queryParameters: {...uri.queryParameters, ...queryParameters});
  }
}

