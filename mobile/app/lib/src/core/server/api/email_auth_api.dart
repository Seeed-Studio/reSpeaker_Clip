import '../http/api_client.dart';
import '../server_error_codes.dart';
import '../server_exception.dart';
import 'auth_api.dart';
import '../crypto/password_hasher.dart';

enum EmailCodeScene { register, login, changeEmail, resetPassword }

extension EmailCodeSceneX on EmailCodeScene {
  String get value => switch (this) {
        EmailCodeScene.register => 'register',
        EmailCodeScene.login => 'login',
        EmailCodeScene.changeEmail => 'change_email',
        EmailCodeScene.resetPassword => 'reset_password',
      };
}

class EmailAuthApi {
  final ApiClient _client;
  EmailAuthApi(this._client);
  Future<bool> isRegistered({required String email}) async {
    return false;
  }

  /// `POST /api/v1/user/email/send_code`
  Future<void> sendCode({required String email, required EmailCodeScene scene}) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/email/send_code',
      method: 'POST',
      data: {'email': email, 'scene': scene.value},
    );
    _ensureOk(resp.data, statusCode: resp.statusCode);
  }

  /// `POST /api/v1/user/email/verify_code`
  ///
  /// Backend may or may not return token+user on verify (depending on scene).
  Future<AuthAppLoginResult?> verifyCode({
    required String email,
    required String code,
    required EmailCodeScene scene,
  }) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/email/verify_code',
      method: 'POST',
      data: {'email': email, 'code': code, 'scene': scene.value},
    );
    final data = resp.data;
    final parsed = _ensureOk(data, statusCode: resp.statusCode);
    final result = parsed['result'];
    if (result is Map) {
      final m = result.cast<String, dynamic>();
      if ((m['token'] ?? '').toString().trim().isNotEmpty) {
        return AuthAppLoginResult.fromJson(m);
      }
    }
    return null;
  }

  /// `POST /api/v1/user/register`
  Future<AuthAppLoginResult> register({
    required String email,
    required String password,
    String? username,
  }) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/register',
      method: 'POST',
      data: {
        'email': email,
        'password': md5Hex(password),
        'username': (username ?? email),
      },
    );
    final parsed = _ensureOk(resp.data, statusCode: resp.statusCode);
    final result = parsed['result'];
    if (result is! Map) {
      throw ServerException(
        'Registration failed: response missing result.',
        messageKey: 'authRegisterMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return AuthAppLoginResult.fromJson(result.cast<String, dynamic>());
  }

  /// `POST /api/v1/user/email/login`
  Future<AuthAppLoginResult> loginWithPassword({required String email, required String password}) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/email/login',
      method: 'POST',
      data: {'email': email, 'password': md5Hex(password)},
    );
    final parsed = _ensureOk(resp.data, statusCode: resp.statusCode);
    final result = parsed['result'];
    if (result is! Map) {
      throw ServerException(
        'Login failed: response missing result.',
        messageKey: 'authLoginMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return AuthAppLoginResult.fromJson(result.cast<String, dynamic>());
  }

  Map<String, dynamic> _ensureOk(Object? data, {int? statusCode}) {
    if (data is! Map) {
      throw ServerException(
        'Request failed: invalid response format.',
        messageKey: 'authRequestFormat',
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
}

