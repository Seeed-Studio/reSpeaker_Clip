import '../http/api_client.dart';
import '../server_exception.dart';
import '../server_error_codes.dart';

class AuthAppLoginRequest {
  final String provider; // apple/google/github
  final String accessToken;
  final String idToken;
  /// OAuth code flow support (recommended for GitHub).
  ///
  /// - code: authorization code returned by provider
  /// - code_verifier: PKCE verifier (required if authorize used code_challenge)
  /// - redirect_uri: must match the one used in authorize step
  final String? code;
  final String? codeVerifier;
  final String? redirectUri;

  const AuthAppLoginRequest({
    required this.provider,
    required this.accessToken,
    required this.idToken,
    this.code,
    this.codeVerifier,
    this.redirectUri,
  });

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'provider': provider,
      'access_token': accessToken,
      'id_token': idToken,
    };
    final c = (code ?? '').trim();
    final cv = (codeVerifier ?? '').trim();
    final ru = (redirectUri ?? '').trim();
    if (c.isNotEmpty) {
      m['code'] = c;
      m['oauth_code'] = c;
    }
    if (cv.isNotEmpty) {
      m['code_verifier'] = cv;
      m['verifier'] = cv;
      m['codeVerifier'] = cv;
    }
    if (ru.isNotEmpty) m['redirect_uri'] = ru;
    return m;
  }
}

class AuthAppUser {
  final String? id;
  final String? name;
  final String? email;
  final bool? emailVerified;
  final String? avatarUrl;
  final String? provider;
  final String? role;

  const AuthAppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.emailVerified,
    required this.avatarUrl,
    required this.provider,
    required this.role,
  });

  factory AuthAppUser.fromJson(Map<String, dynamic> j) => AuthAppUser(
        id: j['id']?.toString(),
        name: j['name']?.toString(),
        email: j['email']?.toString(),
        emailVerified: j['email_verified'] is bool ? (j['email_verified'] as bool) : null,
        avatarUrl: j['avatar_url']?.toString(),
        provider: j['provider']?.toString(),
        role: j['role']?.toString(),
      );
}

class AuthAppLoginResult {
  final String token;
  final String refreshToken;
  final AuthAppUser user;

  const AuthAppLoginResult({required this.token, required this.refreshToken, required this.user});

  factory AuthAppLoginResult.fromJson(Map<String, dynamic> j) => AuthAppLoginResult(
        token: (j['token'] ?? '').toString(),
        refreshToken: (j['refresh_token'] ?? '').toString(),
        user: AuthAppUser.fromJson((j['user'] as Map).cast<String, dynamic>()),
      );
}

class AuthAppLoginResponse {
  final int code;
  final String? message;
  final String? details;
  final AuthAppLoginResult? result;

  const AuthAppLoginResponse({
    required this.code,
    required this.message,
    required this.details,
    required this.result,
  });

  factory AuthAppLoginResponse.fromJson(Map<String, dynamic> j) => AuthAppLoginResponse(
        code: (j['code'] is num) ? (j['code'] as num).toInt() : 0,
        message: j['message']?.toString(),
        details: j['details']?.toString(),
        result: j['result'] is Map ? AuthAppLoginResult.fromJson((j['result'] as Map).cast<String, dynamic>()) : null,
      );
}

class AuthApi {
  final ApiClient _client;
  AuthApi(this._client);

  /// Swagger: `POST /api/v1/user/app/login`
  ///
  /// Body:
  /// - provider: apple/google/github
  /// - access_token
  /// - id_token
  ///
  /// Response:
  /// - code/message/details/result.token/result.user
  Future<AuthAppLoginResult> appLogin(AuthAppLoginRequest req) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/app/login',
      method: 'POST',
      data: req.toJson(),
    );

    final data = resp.data;
    if (data is! Map) {
      throw ServerException(
        'Login failed: invalid response format.',
        messageKey: 'authLoginResponseFormat',
        statusCode: resp.statusCode,
        data: data,
      );
    }
    final parsed = AuthAppLoginResponse.fromJson(data.cast<String, dynamic>());
    if (!ServerErrorCodes.isOk(parsed.code) || parsed.result == null || parsed.result!.token.trim().isEmpty) {
      final msg = (parsed.message ?? '').trim();
      throw ServerException(
        msg.isEmpty ? 'Login failed.' : msg,
        messageKey: msg.isEmpty ? 'authLoginFailed' : null,
        bizCode: ServerErrorCodes.isOk(parsed.code) ? null : parsed.code,
        details: parsed.details,
        statusCode: resp.statusCode,
        data: data,
      );
    }
    return parsed.result!;
  }
}

