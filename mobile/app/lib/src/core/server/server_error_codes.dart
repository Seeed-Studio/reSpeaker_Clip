/// Server business error codes (aligned with backend errors package)
class ServerErrorCodes {
  /// Success
  ///
  /// Note: backend business code may be 0 or 200 for success across services/versions.
  /// Use [isOk] to determine success for both cases.
  static const int ok = 200;
  static const int okLegacy = 0;
  static bool isOk(int code) => code == ok || code == okLegacy;

  // 1000-1999: General errors
  static const int timeout = 1001;
  static const int notImplemented = 1002;
  static const int internalError = 1003;
  static const int busySystem = 1004;
  static const int notAcceptable = 1005;
  static const int badRequest = 1006;
  static const int invalidParams = 1007;

  // 2000-2999: User-related errors
  static const int userNotFound = 2001;
  static const int unauthorized = 2002;
  static const int forbidden = 2003;
  static const int passwordIncorrect = 2004;
  static const int userAlreadyExists = 2005;
  static const int duplicatedPassword = 2006;
  static const int tokenExpired = 2007;
  static const int tokenInvalid = 2008;
  static const int emailAlreadyRegistered = 2009;
  static const int emailNotVerified = 2010;
  static const int verifyCodeInvalid = 2011;

  // 6000-6999: Database-related errors
  static const int recordNotFound = 6001;
  static const int recordNotUpdate = 6002;
  static const int dataNotFound = 6003;
  static const int duplicateRecord = 6004;

  // 7000-7999: External service errors
  static const int clusterNotFound = 7002;

  // 11000-11999: Tenant-related errors
  static const int tenantNotFound = 11001;
  /// Note: collides with [SenseCraftErrorCodes.accountNotFound] (11002).
  /// [serverErrorMessage] maps 11002 to account-not-found for Auth; tenant-exist
  /// falls back to backend message unless disambiguated by caller.
  static const int tenantExist = 11002;

  // 12000-12999: Audit-related errors
  static const int auditNotFound = 12001;
  static const int auditExists = 12002;

  // 13000-13999: RBAC-related errors
  static const int rbacPolicyExists = 13001;
  static const int rbacPolicyNotFound = 13002;
  static const int rbacRoleExists = 13003;
  static const int rbacRoleNotFound = 13004;
  static const int rbacNoPermission = 13005;
  static const int rbacNoUserId = 13006;

  // 14000-14999: ASR-related errors
  static const int asrVendorNotConfigured = 14001;
  static const int asrUnsupportedFormat = 14002;
  static const int asrConfigAlreadyExists = 14003;
  static const int asrConfigNotFound = 14004;
  static const int asrVendorNotFound = 14005;
  static const int asrResultNotFound = 14006;
  static const int asrJobNotFound = 14007;

  // 15000-15999: LLM-related errors
  static const int llmVendorNotConfigured = 15001;
  static const int promptTemplateNotFound = 15002;
  static const int llmConfigAlreadyExists = 15003;
  static const int llmConfigNotFound = 15004;
  static const int promptAlreadyImported = 15005;
  static const int promptTemplateUnsupportedChars = 15006;

  static bool isAuthInvalid(int? code) =>
      code == tokenExpired || code == tokenInvalid || code == unauthorized;
}

