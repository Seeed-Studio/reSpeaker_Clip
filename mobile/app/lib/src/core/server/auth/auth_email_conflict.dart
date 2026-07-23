import '../sensecraft_auth/sensecraft_error_codes.dart';
import '../server_error_codes.dart';
import '../server_exception.dart';

/// Whether the server rejected a **register**-scene verification request because
/// the email already has an account. Callers should route to the email-login
/// flow instead of surfacing a hard error.
///
/// - Self-hosted: HTTP 409 or biz `2005` / `2009`
/// - SenseCraft: `11013` email already in use (e.g. `getEmailCode` with register type)
bool emailAlreadyRegisteredForAuthFlow(ServerException e) {
  return e.statusCode == 409 ||
      e.bizCode == ServerErrorCodes.userAlreadyExists ||
      e.bizCode == ServerErrorCodes.emailAlreadyRegistered ||
      e.bizCode == SenseCraftErrorCodes.emailAlreadyUsed ||
      e.bizCode == SenseCraftErrorCodes.mobileAlreadyUsed;
}
