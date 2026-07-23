/// Business codes returned by the SenseCraft unified auth service.
///
/// Aligned with SenseCraft authapi `HttpResponse` definitions.
///
/// NOTE: `code` may be serialised as `string` or `number` — use
/// [parseSenseCraftCode] before comparing.
class SenseCraftErrorCodes {
  static const int ok = 0;
  static const int okLegacy = 200;
  static bool isOk(int code) => code == ok || code == okLegacy;

  // ---- General (10xxx) --------------------------------------------
  static const int serviceError = 10000;
  static const int remoteCalledError = 10002;
  static const int pathNotFound = 10007;
  /// Empty token / missing required parameters.
  static const int missingParams = 10009;
  @Deprecated('Use missingParams')
  static const int noAccessKey = missingParams;

  // ---- Account / email / password (110xx) -------------------------
  static const int accountNotFound = 11002;
  static const int passwordIncorrect = 11005;
  static const int verifyCodeInvalid = 11008;
  static const int verifyCodeExpired = 11010;
  @Deprecated('Use verifyCodeExpired')
  static const int verifyCodeWrong = verifyCodeExpired;
  static const int emailAlreadyUsed = 11013;
  static const int mobileAlreadyUsed = 11014;
  static const int smsCodeInvalid = 11015;
  static const int smsCodeExpired = 11016;
  static const int smsCodeAlreadySent = 11017;
  static const int mobileRequired = 11018;
  static const int mobileFormatInvalid = 11019;
  static const int newPasswordSameAsOld = 11020;
  static const int accountFrozen = 11025;

  // ---- Token (111xx) ----------------------------------------------
  static const int refreshTokenExpired = 11101;
  static const int tokenInvalid = 11102;
  @Deprecated('Use tokenInvalid')
  static const int accessKeyInvalid = tokenInvalid;
  static const int refreshTokenInvalid = 11103;

  // ---- Permission / params / OSS (112xx) --------------------------
  static const int noPermission = 11201;
  static const int paramInvalid = 11202;
  static const int tooManyLoginAttempts = 11229;
  static const int ossUploadNotConfigured = 11233;
  static const int ossPresignFailed = 11234;

  // ---- OAuth / terms / misc (17xxx) -------------------------------
  static const int authorizeCodeInvalid = 17000;
  static const int oauthUserInfoFailed = 17001;
  @Deprecated('Use oauthUserInfoFailed')
  static const int oauthFailed = oauthUserInfoFailed;
  static const int unsupportedOAuthProvider = 17002;
  static const int userInfoError = 17003;
  static const int verifyCodeNotExpired = 17004;
  static const int oauthStateMismatch = 17005;
  static const int oauthCodeMissing = 17006;
  static const int oauthStateMissing = 17007;
  static const int oauthAccountNeedBind = 17008;
  static const int childAccountCannotDelete = 17009;
  static const int termsAcceptanceRequired = 17010;
  static const int oauthForeignIdTaken = 17011;
  static const int oauthOrgAlreadyBound = 17012;
  static const int oauthWechatNoUnionid = 17013;

  /// Session is no longer valid; client should refresh or re-login.
  static bool isAuthInvalid(int? code) =>
      code == refreshTokenExpired ||
      code == refreshTokenInvalid ||
      code == tokenInvalid;
}

int parseSenseCraftCode(Object? raw) {
  if (raw == null) return SenseCraftErrorCodes.ok;
  if (raw is num) return raw.toInt();
  final s = raw.toString().trim();
  return int.tryParse(s) ?? SenseCraftErrorCodes.ok;
}
