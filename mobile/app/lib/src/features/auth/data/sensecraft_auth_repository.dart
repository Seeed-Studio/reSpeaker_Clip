import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/server/api/auth_api.dart' show AuthAppLoginResponse;
import '../../../core/server/api/user_api.dart';
import '../../../core/server/auth/auth_token_store.dart';
import '../../../core/server/crypto/password_hasher.dart';
import '../../../core/server/http/api_client.dart';
import '../../../core/server/sensecraft_auth/sensecraft_api_client.dart';
import '../../../core/server/sensecraft_auth/sensecraft_auth_env.dart';
import '../../../core/server/sensecraft_auth/sensecraft_auth_token_store.dart';
import '../../../core/server/sensecraft_auth/sensecraft_envelope.dart';
import '../../../core/server/sensecraft_auth/sensecraft_error_codes.dart';
import '../../../core/server/server_error_codes.dart';
import '../../../core/server/server_exception.dart';
import 'auth_repository.dart';

/// [AuthRepository] backed by the SenseCraft unified auth service.
///
/// Talks to **two** backends per request:
///
/// 1. SenseCraft auth (`authDomain()`) — performs the actual login /
///    register / OAuth / password mgmt. Returns a SenseCraft session
///    (access + refresh token + user info).
/// 2. Business backend (`bizDomain()`) — receives the SenseCraft access
///    token via `POST /api/v1/user/external/sensecraft/login` and returns
///    a business JWT that is stored in [AuthTokenStore] for every
///    subsequent business API call.
///
/// Why two? The business backend signs its own HS256 JWT with a local
/// `jwt_key` and keeps its own `users` table — SenseCraft tokens cannot be
/// validated by it. See `feat/sensecraft-auth-migration` design notes.
///
/// Status:
/// - SenseCraft auth calls match the authapi contract.
/// - Business token exchange (route A): `POST .../external/sensecraft/login`
///   is the only supported way to obtain an [AuthTokenStore] token. Failures
///   **always** throw a [ServerException] (no debug fallback). Earlier we
///   wrote the SenseCraft JWT into [AuthTokenStore] in `kDebugMode` to keep
///   local UI clickable, but the business backend signs JWTs with its own
///   `jwt_key` (string `jti`) and SenseCraft JWTs carry a numeric `jti`, so
///   every subsequent business request failed with
///   `code 2008 — json: cannot unmarshal number into …Claims.jti of type string`.
///   Surfacing the exchange failure early is strictly better than that.
class SenseCraftAuthRepository implements AuthRepository {
  final SenseCraftApiClient _sc;

  /// Business backend client (carries Voice JWT from token exchange).
  final ApiClient _biz;

  SenseCraftAuthRepository({
    required SenseCraftApiClient senseCraftClient,
    required ApiClient businessClient,
  })  : _sc = senseCraftClient,
        _biz = businessClient;

  // =====================================================================
  // Email verification code
  // =====================================================================

  /// `POST /api/v1/auth/getEmailCode` (`application/json`)
  ///
  /// Payload matches SenseCraft App `getEmailCode` body shape (`email`,
  /// `language`, `type`, `domain`). **Type 4** (login code) is defined in
  /// OpenAPI §6.1; legacy RN comments often only list types 1–2 for
  /// register/forgot screens.
  ///
  /// - `type`: 1=register, 2=reset password, 3=bind, 4=login code ([_sceneToType]).
  /// - `domain`: SenseCraft app uses **2 = craft** (`VerCode.js`: `domain = 2`).
  /// - `language`: **cn** when auth host contains `.cn`, else **en** (same as RN
  ///   `baseUrl.indexOf('cn') !== -1 ? 'cn' : 'en'`).
  @override
  Future<void> sendEmailCode({
    required String email,
    required EmailCodeScene scene,
  }) async {
    final type = _sceneToType(scene);
    final resp = await _sc.requestJson(
      '/api/v1/auth/getEmailCode',
      method: 'POST',
      data: {
        'email': email,
        'language': _languageCode(),
        'type': type,
        'domain': SenseCraftDomainCode.craft,
      },
    );
    final body = resp.data;
    if (body is! Map) {
      throw ServerException(
        'Send verification code failed.',
        messageKey: 'authRequestFormat',
        statusCode: resp.statusCode,
        data: body,
      );
    }
    final m = body.cast<String, dynamic>();
    final code = parseSenseCraftCode(m['code']);
    // 17004: previous code still valid / rate limited — user can open the
    // email they already received (e.g. went back from verify screen).
    if (SenseCraftErrorCodes.isOk(code) ||
        code == SenseCraftErrorCodes.verifyCodeNotExpired) {
      return;
    }
    final msg = (m['msg'] ?? m['message'])?.toString().trim();
    throw ServerException(
      msg != null && msg.isNotEmpty ? msg : 'Send verification code failed.',
      bizCode: code,
      statusCode: resp.statusCode,
      data: body,
    );
  }

  /// SenseCraft does not expose a standalone verify-code endpoint for the
  /// login scene — login is performed directly via `/api/v1/auth/email/login`
  /// with `loginCode` (see [loginWithEmailCode]).
  ///
  /// For the register scene, the code is verified implicitly by the
  /// `registerByEmail` call. For reset password, by `resetPassword`. For
  /// change email, by `changeEmail`.
  @override
  Future<AuthAppLoginResult?> verifyEmailCode({
    required String email,
    required String code,
    required EmailCodeScene scene,
  }) async {
    switch (scene) {
      case EmailCodeScene.login:
        return loginWithEmailCode(email: email, loginCode: code);
      case EmailCodeScene.register:
      case EmailCodeScene.resetPassword:
      case EmailCodeScene.changeEmail:
        // No standalone verify endpoint — code is consumed by the
        // follow-up register/reset/changeEmail call.
        return null;
    }
  }

  /// Convenience helper: email + login code → session.
  ///
  /// `POST /api/v1/auth/email/login` with `account` + `loginCode`.
  Future<AuthAppLoginResult> loginWithEmailCode({
    required String email,
    required String loginCode,
  }) async {
    final resp = await _sc.postForm(
      '/api/v1/auth/email/login',
      fields: {'account': email, 'loginCode': loginCode},
    );
    final env = parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Login failed.',
    );
    final session = _parseLoginPayload(
      env.requireDataMap(
        statusCode: resp.statusCode,
        fallbackMessage: 'Login failed: missing data.',
      ),
      provider: 'sensecraft',
    );
    return _exchangeForBusinessToken(session: session);
  }

  // =====================================================================
  // Email register & password login
  // =====================================================================

  /// `POST /api/v1/auth/registerByEmail`
  ///
  /// Per doc §6.2, requires a prior `getEmailCode` (type=1). The `username`
  /// field maps to `userName`. Password is MD5(lowercase hex).
  @override
  Future<AuthAppLoginResult> register({
    required String email,
    required String password,
    String? username,
    String? registerCode,
  }) async {
    // SenseCraft / `registerByEmail` expects `registerCode` as a JSON **string**
    // (e.g. `"123456"`), not a number — keep a typed [String] and a typed map.
    final String registerCodeStr = (registerCode ?? '').trim();
    if (registerCodeStr.isEmpty) {
      throw ServerException(
        'Registration requires the email verification code from the previous step.',
        messageKey: 'registerMissingVerificationCode',
      );
    }
    // Body matches authapi oauth/mobile only (no `domain` /
    // `language` — those belong to `getEmailCode`, not `registerByEmail`).
    final bodyMap = <String, dynamic>{
      'email': email,
      'registerCode': registerCodeStr,
      'userName': (username ?? email),
      'password': md5Hex(password),
    };
    final resp = await _sc.requestJson(
      '/api/v1/auth/registerByEmail',
      method: 'POST',
      // Pre-encode so `registerCode` is always `"474364"` in JSON, never a bare number.
      data: jsonEncode(bodyMap),
    );
    final env = parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Register failed.',
    );
    final data = env.requireDataMap(
      statusCode: resp.statusCode,
      fallbackMessage: 'Register failed: missing data.',
    );
    // Per doc, register response only returns `{ userId }`; client must
    // follow up with a password login to obtain tokens.
    final userId = (data['userId'] ?? '').toString();
    if (userId.isEmpty) {
      throw ServerException('Register failed: missing userId.', statusCode: resp.statusCode);
    }
    return loginWithPassword(email: email, password: password);
  }

  /// `POST /api/v1/auth/email/login` with `account` + `password` (MD5).
  ///
  /// Per doc §6.3 the body is multipart/form-data.
  @override
  Future<AuthAppLoginResult> loginWithPassword({
    required String email,
    required String password,
  }) async {
    final resp = await _sc.postForm(
      '/api/v1/auth/email/login',
      fields: {'account': email, 'password': md5Hex(password)},
    );
    final env = parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Login failed.',
    );
    final session = _parseLoginPayload(
      env.requireDataMap(
        statusCode: resp.statusCode,
        fallbackMessage: 'Login failed: missing data.',
      ),
      provider: 'sensecraft',
    );
    return _exchangeForBusinessToken(session: session);
  }

  /// SenseCraft has no public "is email registered" probe — return false so
  /// the caller falls through to the actual register/login flow and lets
  /// the backend error (e.g. 11013 email already used) drive UX.
  @override
  Future<bool> isRegistered({required String email}) async => false;

  // =====================================================================
  // Third-party OAuth
  // =====================================================================

  /// `POST /api/v1/auth/oauth/mobile`
  ///
  /// Body per doc §4: { accountType, platform, idToken | code }.
  @override
  Future<AuthAppLoginResult> appLogin(AuthAppLoginRequest req) async {
    final body = <String, dynamic>{
      'accountType': req.provider,
      'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    };
    final code = (req.code ?? '').trim();
    final idToken = req.idToken.trim();
    if (req.provider.toLowerCase() == 'github' && code.isNotEmpty) {
      body['code'] = code;
    } else if (idToken.isNotEmpty) {
      body['idToken'] = idToken;
    } else if (code.isNotEmpty) {
      body['code'] = code;
    }

    final resp = await _sc.requestJson(
      '/api/v1/auth/oauth/mobile',
      method: 'POST',
      data: body,
    );
    final env = parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Third-party login failed.',
    );
    final session = _parseLoginPayload(
      env.requireDataMap(
        statusCode: resp.statusCode,
        fallbackMessage: 'Third-party login failed: missing data.',
      ),
      provider: req.provider,
    );
    return _exchangeForBusinessToken(session: session);
  }

  // =====================================================================
  // Password mgmt
  // =====================================================================

  /// `PUT /api/v1/auth/resetPassword`
  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final resp = await _sc.requestJson(
      '/api/v1/auth/resetPassword',
      method: 'PUT',
      data: {
        'email': email,
        'code': code,
        'password': md5Hex(newPassword),
      },
    );
    parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Reset password failed.',
    );
  }

  /// `PUT /api/v1/user/changePassword`
  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final resp = await _sc.requestJson(
      '/api/v1/user/changePassword',
      method: 'PUT',
      data: {
        'oldPassword': oldPassword.isEmpty ? '' : md5Hex(oldPassword),
        'password': md5Hex(newPassword),
      },
    );
    parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Change password failed.',
    );
  }

  // =====================================================================
  // Profile
  // =====================================================================

  /// `PUT /api/v1/user/changeEmail`
  ///
  /// Requires a prior `getEmailCode` with `type=3` (bind / change email) sent to
  /// the **new** address. Do not use [updateProfile] for email changes.
  @override
  Future<UserProfile?> updateEmail({
    required String email,
    required String code,
  }) async {
    final resp = await _sc.requestJson(
      '/api/v1/user/changeEmail',
      method: 'PUT',
      data: {
        'newEmail': email.trim(),
        'code': code.trim(),
      },
    );
    parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Change email failed.',
    );
    try {
      return await getMe();
    } catch (_) {
      return null;
    }
  }

  /// `PUT /api/v1/user/updateProfile`
  ///
  /// Only sends fields the caller wants to change (non-empty [name] /
  /// [avatarUrl]); unchanged fields are omitted from the JSON body.
  ///
  /// Some SenseCraft gateways (e.g. intranet test) return **404** for this
  /// route even though authapi docs may list it. When that happens
  /// and [AuthTokenStore] has a Voice business JWT (token exchange OK), we
  /// fall back to [ApiClient] `PUT /api/v1/user` so nickname / avatar still
  /// persist on the Voice backend. That endpoint returns `result: null` on
  /// success, so we always call [getMe] afterwards (same as the SC success
  /// path).
  @override
  Future<UserProfile?> updateProfile({String? name, String? avatarUrl}) async {
    final body = <String, dynamic>{};
    final n = (name ?? '').trim();
    final a = (avatarUrl ?? '').trim();
    if (n.isNotEmpty) body['nickname'] = n;
    if (a.isNotEmpty) body['avatar_url'] = a;
    if (body.isEmpty) return null;

    try {
      final resp = await _sc.requestJson(
        '/api/v1/user/updateProfile',
        method: 'PUT',
        data: body,
      );
      parseSenseCraftEnvelope(
        resp.data,
        statusCode: resp.statusCode,
        fallbackMessage: 'Update profile failed.',
      );
    } on ServerException catch (e) {
      if (e.statusCode != 404) rethrow;
      await _updateProfileOnBusinessBackendOrThrow(
        name: name,
        avatarUrl: avatarUrl,
      );
    }
    try {
      return await getMe();
    } catch (_) {
      return null;
    }
  }

  /// SenseCraft authapi: avatar presign uses numeric `file_type=1` (not the
  /// string `avatar`), plus `content_type` and `file_name`. Public URL is in
  /// `access_url` — see [UserPresignUpload.fromResultMap].
  @override
  Future<OssUploadResult> uploadAvatar(File file) async {
    if (!file.existsSync()) {
      throw ServerException(
        'Upload failed: file not found.',
        messageKey: 'userApiUploadFileNotFound',
      );
    }
    const type = 'avatar';
    final contentType = UserApi.guessImageContentTypeForPath(file.path);
    final fileName = p.basename(file.path);
    final ct = (contentType ?? '').trim();

    final query = <String, dynamic>{
      'file_type': '1',
      'file_name': fileName,
      if (ct.isNotEmpty) 'content_type': ct,
    };

    final presignResp = await _sc.requestJson(
      '/api/v1/user/presignUpload',
      method: 'GET',
      queryParameters: query,
    );
    final env = parseSenseCraftEnvelope(
      presignResp.data,
      statusCode: presignResp.statusCode,
      fallbackMessage: 'Presign upload failed.',
    );
    final rawMap = _senseCraftPresignDataMap(env.data);
    final presign = UserPresignUpload.fromResultMap(rawMap);
    return UserApi.uploadFileViaPresign(
      file: file,
      presign: presign,
      type: type,
      contentType: contentType,
      presignStatusCode: presignResp.statusCode,
      presignResponseForError: presignResp.data,
    );
  }

  /// Voice business `PUT /api/v1/user` (same contract as [UserApi.updateProfile]);
  /// the HTTP handler returns `result: null` on success.
  Future<void> _updateProfileOnBusinessBackendOrThrow({
    String? name,
    String? avatarUrl,
  }) async {
    final token = (AuthTokenStore.cached ?? '').trim();
    if (token.isEmpty) {
      throw ServerException(
        'SenseCraft profile API is unavailable (404). '
        'Complete Voice (business) login so we can save your nickname there.',
        statusCode: 404,
      );
    }

    final data = <String, dynamic>{};
    final au = (avatarUrl ?? '').trim();
    final nn = (name ?? '').trim();
    if (au.isNotEmpty) data['avatar_url'] = au;
    if (nn.isNotEmpty) data['name'] = nn;
    if (data.isEmpty) return;

    final resp = await _biz.request<Object>(
      '/api/v1/user',
      method: 'PUT',
      data: data,
    );
    final raw = resp.data;
    if (raw is! Map) {
      throw ServerException(
        'Update profile failed: invalid response.',
        statusCode: resp.statusCode,
        data: raw,
      );
    }
    final m = raw.cast<String, dynamic>();
    final code = _parseVoiceBizCode(m['code']);
    if (code == null || !ServerErrorCodes.isOk(code)) {
      throw ServerException(
        m['message']?.toString() ?? 'Update profile failed.',
        bizCode: code,
        statusCode: resp.statusCode,
        data: raw,
      );
    }
  }

  static int? _parseVoiceBizCode(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  static Map<String, dynamic> _senseCraftPresignDataMap(Object? data) {
    if (data is! Map) {
      throw ServerException(
        'Presign upload failed: response missing data.',
        messageKey: 'userApiUploadMissingResult',
      );
    }
    final m = data.cast<String, dynamic>();
    final nested = m['result'] ?? m['data'];
    if (nested is Map) {
      return nested.cast<String, dynamic>();
    }
    return m;
  }

  /// `GET /api/v1/user/getUserOrgInfo`
  ///
  /// `Authorization: Bearer` and query `token` are attached in
  /// [SenseCraftApiClient] for every `/api/v1/user/*` request when an access
  /// token is available (refresh runs first if only the refresh token is
  /// present).
  @override
  Future<UserProfile> getMe() async {
    final resp = await _sc.requestJson(
      '/api/v1/user/getUserOrgInfo',
      method: 'GET',
    );
    final env = parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Get user info failed.',
    );
    final data = env.requireDataMap(
      statusCode: resp.statusCode,
      fallbackMessage: 'Get user info failed: missing data.',
    );
    return _parseUserOrgInfo(data);
  }

  /// `GET /api/v1/user/getSecurityInfo`
  @override
  Future<UserSecurityInfo> getSecurityInfo() async {
    final resp = await _sc.requestJson(
      '/api/v1/user/getSecurityInfo',
      method: 'GET',
    );
    final env = parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Get security info failed.',
    );
    final data = env.requireDataMap(
      statusCode: resp.statusCode,
      fallbackMessage: 'Get security info failed: missing data.',
    );
    return UserSecurityInfo.fromJson(data);
  }

  // =====================================================================
  // Session
  // =====================================================================

  /// `POST /api/v1/user/signOut`
  ///
  /// NOTE: this is the per-doc name; the self-hosted backend uses
  /// `logout` for the same semantics. Mapping documented on
  /// [AuthRepository.logout].
  @override
  Future<void> logout() async {
    try {
      final resp = await _sc.requestJson(
        '/api/v1/user/signOut',
        method: 'POST',
      );
      parseSenseCraftEnvelope(
        resp.data,
        statusCode: resp.statusCode,
        fallbackMessage: 'Sign out failed.',
      );
    } on DioException {
      // Best-effort: swallow network errors so local state still clears.
    } finally {
      await SenseCraftAuthTokenStore.clear();
    }
  }

  /// SenseCraft mode account deletion is two steps:
  /// 1. Voice business `POST /api/v1/user/deactivate` — purge LLM/ASR configs,
  ///    sessions, transcriptions, templates, etc. (requires business JWT).
  /// 2. SenseCraft `POST /api/v1/user/logout` — deactivate the unified-auth
  ///    account (per doc §6.9). Mapped to [deactivateAccount] (not [logout]).
  @override
  Future<void> deactivateAccount() async {
    // Voice first while the exchanged business JWT is still valid.
    await UserApi(_biz).deactivate();
    final resp = await _sc.requestJson(
      '/api/v1/user/logout',
      method: 'POST',
    );
    parseSenseCraftEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Deactivate account failed.',
    );
    await SenseCraftAuthTokenStore.clear();
  }

  // =====================================================================
  // Legacy local-only placeholders
  // =====================================================================

  @override
  Future<void> setPassword({required String email, required String password}) async {}

  @override
  Future<void> markSkipSetPassword({required String email}) async {}

  // =====================================================================
  // Internals
  // =====================================================================

  /// SenseCraft OpenAPI §6.1 `type`: **4 = login verification code** (updated from
  /// the old RN code which only used 1/2; sending 4 matches the docs, used for `EmailCodeScene.login`).
  static int _sceneToType(EmailCodeScene scene) {
    // 1=register, 2=resetPassword, 3=bind, 4=login verification code.
    switch (scene) {
      case EmailCodeScene.register:
        return 1;
      case EmailCodeScene.resetPassword:
        return 2;
      case EmailCodeScene.changeEmail:
        return 3;
      case EmailCodeScene.login:
        return 4;
    }
  }

  static String _languageCodeForClient(SenseCraftApiClient sc) {
    // Mirrors SenseCraft `VerCode.js`: cn if API host is China cluster.
    final host = sc.baseUri.host;
    if (host.contains('.cn')) return 'cn';
    return 'en';
  }

  String _languageCode() => _languageCodeForClient(_sc);

  /// Parses `/api/v1/auth/email/login` and `/api/v1/auth/oauth/mobile`
  /// success payload into [_SenseCraftSession] (token bundle + the user
  /// fields the doc exposes).
  ///
  /// Fields (per doc §6.3 / §6.4):
  ///   token, refresh_token, user_id, account, nickname, org_id?, email?
  _SenseCraftSession _parseLoginPayload(
    Map<String, dynamic> data, {
    required String provider,
  }) {
    final token = (data['token'] ?? '').toString().trim();
    final refreshToken = (data['refresh_token'] ?? '').toString().trim();
    if (token.isEmpty) {
      throw ServerException('Login failed: missing token.', data: data);
    }
    final email = (data['email'] ?? data['account'] ?? '').toString().trim();
    final user = AuthAppUser(
      id: (data['user_id'] ?? '').toString(),
      name: (data['nickname'] ?? '').toString(),
      email: email.isEmpty ? null : email,
      emailVerified: null,
      avatarUrl: null,
      provider: provider,
      role: null,
    );
    return _SenseCraftSession(
      accessToken: token,
      refreshToken: refreshToken,
      user: user,
    );
  }

  UserProfile _parseUserOrgInfo(Map<String, dynamic> data) {
    final idStr = (data['user_id'] ?? '').toString();
    final id = int.tryParse(idStr) ?? 0;
    return UserProfile(
      id: id,
      name: (data['nickname'] ?? data['account'] ?? '').toString(),
      email: (data['email'] ?? data['account'] ?? '').toString(),
      emailVerified: true,
      avatarUrl: (data['avatar_url'] ?? '').toString(),
      provider: 'sensecraft',
      role: null,
      hasPwd: data['has_pwd'] is bool ? (data['has_pwd'] as bool) : null,
    );
  }

  /// Step 2: hand the SenseCraft access token to the business backend in
  /// exchange for a business JWT (route A).
  ///
  /// Contract:
  ///
  /// ```
  /// POST {bizDomain}/api/v1/user/external/sensecraft/login
  /// body: { sensecraft_access_token: "...", sensecraft_refresh_token?: "..." }
  /// resp envelope.result: { token, refresh_token, user: { id, email, name, ... } }
  /// ```
  ///
  /// Success path: save business tokens to [AuthTokenStore] and return.
  ///
  /// Failure path:
  /// - **release** — throw a [ServerException]. We never silently fall back
  ///   to using the SenseCraft JWT for [ApiClient], because that JWT can't
  ///   be validated by the business backend (`jti` type mismatch, different
  ///   `jwt_key`) and would surface as a 401 → forced logout the first time
  ///   the user opens any business screen. Surfacing the error here at
  ///   least lets the login screen show a real message.
  /// - **debug** — keep the legacy fallback (reuse SenseCraft tokens on
  ///   `ApiClient`) so we can iterate locally against a backend that hasn't
  ///   shipped the exchange route yet.
  Future<AuthAppLoginResult> _exchangeForBusinessToken({
    required _SenseCraftSession session,
  }) async {
    await SenseCraftAuthTokenStore.saveTokens(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );

    try {
      final resp = await _biz.request<Object>(
        '/api/v1/user/external/sensecraft/login',
        method: 'POST',
        data: <String, dynamic>{
          'sensecraft_access_token': session.accessToken,
          'sensecraft_refresh_token': session.refreshToken,
        },
      );
      final data = resp.data;
      if (data is! Map) {
        return _handleExchangeFailure(
          session: session,
          reason: 'invalid response payload type=${data.runtimeType}',
          statusCode: resp.statusCode,
          payload: data,
        );
      }
      final parsed = AuthAppLoginResponse.fromJson(data.cast<String, dynamic>());
      final r = parsed.result;
      final tok = (r?.token ?? '').trim();
      if (!ServerErrorCodes.isOk(parsed.code) || r == null || tok.isEmpty) {
        return _handleExchangeFailure(
          session: session,
          reason: 'code=${parsed.code} msg=${parsed.message ?? ''} tokenEmpty=${tok.isEmpty}',
          bizCode: parsed.code,
          statusCode: resp.statusCode,
          message: parsed.message,
          payload: data,
        );
      }
      await AuthTokenStore.saveTokens(accessToken: r.token, refreshToken: r.refreshToken);
      return r;
    } on ServerException catch (e) {
      return _handleExchangeFailure(
        session: session,
        reason: 'ServerException status=${e.statusCode} biz=${e.bizCode} ${e.message}',
        bizCode: e.bizCode,
        statusCode: e.statusCode,
        message: e.message,
        payload: e.data,
        rethrowAs: e,
      );
    } catch (e) {
      return _handleExchangeFailure(
        session: session,
        reason: 'error=$e',
      );
    }
  }

  /// Centralised failure handling for [_exchangeForBusinessToken].
  ///
  /// Always throws. Previously we had a debug-only fallback that stuffed the
  /// SenseCraft JWT into [AuthTokenStore], but that JWT is signed by
  /// SenseCraft (HS384, numeric `jti`) and the business backend signs its
  /// own (HS256, string `jti`). Letting the SC JWT leak into [ApiClient]
  /// produced confusing 401s like
  /// `code 2008 — json: cannot unmarshal number into …Claims.jti of type string`
  /// across **every** business request, so we always surface a real error
  /// here instead.
  Future<AuthAppLoginResult> _handleExchangeFailure({
    required _SenseCraftSession session,
    required String reason,
    int? statusCode,
    int? bizCode,
    String? message,
    Object? payload,
    ServerException? rethrowAs,
  }) {
    if (kDebugMode) {
      debugPrint(
        '[SC-AUTH] biz sensecraft/login failed ($reason) — '
        'throwing; SenseCraft JWT is NOT written to AuthTokenStore '
        '(business backend cannot verify it).',
      );
    }
    if (rethrowAs != null) {
      throw rethrowAs;
    }
    throw ServerException(
      message?.trim().isNotEmpty == true
          ? message!
          : 'Business token exchange failed: $reason',
      statusCode: statusCode,
      bizCode: bizCode,
      data: payload,
      messageKey: 'businessTokenExchangeFailed',
    );
  }
}

class _SenseCraftSession {
  final String accessToken;
  final String refreshToken;
  final AuthAppUser user;
  const _SenseCraftSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
  });
}
