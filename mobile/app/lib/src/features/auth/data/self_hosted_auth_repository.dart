import 'dart:io';

import '../../../core/server/api/auth_api.dart';
import '../../../core/server/api/email_auth_api.dart';
import '../../../core/server/api/user_api.dart';
import 'auth_repository.dart';

/// [AuthRepository] backed by the project's own Go backend.
///
/// All calls are thin pass-throughs to the existing [EmailAuthApi] /
/// [AuthApi] / [UserApi] — this class exists so the UI can depend on the
/// neutral [AuthRepository] contract while the SenseCraft impl is being
/// rolled out.
class SelfHostedAuthRepository implements AuthRepository {
  final EmailAuthApi _emailAuthApi;
  final AuthApi _authApi;
  final UserApi _userApi;

  SelfHostedAuthRepository({
    required EmailAuthApi emailAuthApi,
    required AuthApi authApi,
    required UserApi userApi,
  })  : _emailAuthApi = emailAuthApi,
        _authApi = authApi,
        _userApi = userApi;

  @override
  Future<void> sendEmailCode({
    required String email,
    required EmailCodeScene scene,
  }) =>
      _emailAuthApi.sendCode(email: email, scene: scene);

  @override
  Future<AuthAppLoginResult?> verifyEmailCode({
    required String email,
    required String code,
    required EmailCodeScene scene,
  }) =>
      _emailAuthApi.verifyCode(email: email, code: code, scene: scene);

  @override
  Future<AuthAppLoginResult> register({
    required String email,
    required String password,
    String? username,
    String? registerCode,
  }) =>
      _emailAuthApi.register(email: email, password: password, username: username);

  @override
  Future<AuthAppLoginResult> loginWithPassword({
    required String email,
    required String password,
  }) =>
      _emailAuthApi.loginWithPassword(email: email, password: password);

  @override
  Future<bool> isRegistered({required String email}) =>
      _emailAuthApi.isRegistered(email: email);

  @override
  Future<AuthAppLoginResult> appLogin(AuthAppLoginRequest req) =>
      _authApi.appLogin(req);

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) =>
      _userApi.resetPassword(email: email, code: code, newPassword: newPassword);

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) =>
      _userApi.changePassword(oldPassword: oldPassword, newPassword: newPassword);

  @override
  Future<UserProfile?> updateEmail({
    required String email,
    required String code,
  }) =>
      _userApi.updateEmail(email: email, code: code);

  @override
  Future<UserProfile?> updateProfile({String? name, String? avatarUrl}) =>
      _userApi.updateProfile(name: name, avatarUrl: avatarUrl);

  @override
  Future<OssUploadResult> uploadAvatar(File file) =>
      _userApi.uploadToOss(file: file, type: 'avatar');

  @override
  Future<UserProfile> getMe() => _userApi.getMe();

  @override
  Future<UserSecurityInfo> getSecurityInfo() => _userApi.getSecurityInfo();

  @override
  Future<void> logout() => _userApi.logout();

  @override
  Future<void> deactivateAccount() => _userApi.deactivate();

  // ---- Local-only placeholders ----

  @override
  Future<void> setPassword({required String email, required String password}) async {
    // No backend endpoint yet; set_password_page persists nothing.
    // TODO: wire to a real endpoint once available.
  }

  @override
  Future<void> markSkipSetPassword({required String email}) async {
    // Local UX flag only; nothing to send.
  }
}
