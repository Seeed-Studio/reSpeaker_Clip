import 'dart:io';

import '../../../core/server/api/auth_api.dart';
import '../../../core/server/api/email_auth_api.dart';
import '../../../core/server/api/user_api.dart';

export '../../../core/server/api/auth_api.dart' show AuthAppLoginRequest, AuthAppLoginResult, AuthAppUser;
export '../../../core/server/api/email_auth_api.dart' show EmailCodeScene, EmailCodeSceneX;

/// Abstract authentication contract used by the UI layer.
///
/// Two implementations live behind this interface:
///
/// - [SelfHostedAuthRepository] — calls the project's own backend
///   directly via [EmailAuthApi] / [AuthApi] / [UserApi].
/// - `SenseCraftAuthRepository` — calls SenseCraft unified auth
///   (`authDomain()`), then exchanges the SenseCraft token for a business
///   token via `POST /api/v1/user/external/sensecraft/login` so existing
///   business endpoints stay on the business backend's JWT.
///
/// Concrete impl is selected by `authBackendProvider`. UI must depend only on
/// this interface so the two backends can swap at runtime / build time.
///
/// Result / scene types intentionally reuse the existing `AuthAppLoginResult`
/// / `UserProfile` / `EmailCodeScene` to keep UI code unchanged during the
/// migration. The SenseCraft impl is responsible for translating its
/// `{code, msg, data}` envelope into these types.
abstract class AuthRepository {
  // ---- Email verification code ------------------------------------------

  /// Sends an email verification code for [scene].
  ///
  /// - register: account doesn't exist
  /// - login: account exists, code login
  /// - resetPassword: account exists, prepares password reset
  /// - changeEmail: requires a logged-in session
  Future<void> sendEmailCode({
    required String email,
    required EmailCodeScene scene,
  });

  /// Verifies an email code.
  ///
  /// Returns [AuthAppLoginResult] when [scene] is [EmailCodeScene.login] (the
  /// backend issues a session). For other scenes returns `null` and the caller
  /// proceeds to the next page (e.g. set password).
  Future<AuthAppLoginResult?> verifyEmailCode({
    required String email,
    required String code,
    required EmailCodeScene scene,
  });

  // ---- Email register / login (password) --------------------------------

  /// [registerCode]: 6-digit email code from `getEmailCode` (register scene).
  /// Required for SenseCraft `registerByEmail`; ignored by self-hosted if unused.
  Future<AuthAppLoginResult> register({
    required String email,
    required String password,
    String? username,
    String? registerCode,
  });

  Future<AuthAppLoginResult> loginWithPassword({
    required String email,
    required String password,
  });

  /// Cheap "does this email have an account?" check used by the landing page
  /// to decide between register vs login screens. May be a best-effort guess;
  /// backends without a dedicated endpoint can always return `false` and let
  /// the actual call surface 2005 / `EmailAlreadyRegistered`.
  Future<bool> isRegistered({required String email});

  // ---- Third-party OAuth ------------------------------------------------

  /// Apple / Google / GitHub login. The caller has already obtained the
  /// IdP credential (idToken / accessToken / code) and the repo is
  /// responsible for shipping it to the right endpoint.
  Future<AuthAppLoginResult> appLogin(AuthAppLoginRequest req);

  // ---- Password mgmt ----------------------------------------------------

  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  });

  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  });

  // ---- Profile ----------------------------------------------------------

  Future<UserProfile?> updateEmail({
    required String email,
    required String code,
  });

  Future<UserProfile?> updateProfile({String? name, String? avatarUrl});

  /// Avatar image: presign (`/api/v1/user/presignUpload`) then PUT bytes to storage.
  Future<OssUploadResult> uploadAvatar(File file);

  Future<UserProfile> getMe();

  /// User-center linked account (`GET /api/v1/user/getSecurityInfo`).
  ///
  /// [UserSecurityInfo.accountType] is the source of truth for third-party vs
  /// SenseCraft native binding in **SenseCraft** mode; see
  /// SenseCraft authapi.
  Future<UserSecurityInfo> getSecurityInfo();

  // ---- Session ----------------------------------------------------------

  /// Sign out the current session on the server side.
  Future<void> logout();

  /// Permanently delete the account on the server side.
  Future<void> deactivateAccount();

  // ---- Legacy local-only placeholders -----------------------------------
  //
  // Used by `set_password_page` for the third-party "set password" UX that
  // is not yet wired to a backend endpoint. Both impls treat these as
  // local no-ops; remove once the UX is finalized.

  Future<void> setPassword({required String email, required String password});

  Future<void> markSkipSetPassword({required String email});
}
