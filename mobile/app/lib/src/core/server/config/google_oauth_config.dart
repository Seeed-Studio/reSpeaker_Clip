// Google Sign-In / SenseCraft `oauth/mobile` — Web application client IDs
// (`GoogleSignIn.initialize(serverClientId: …)` → `id_token.aud` matches SenseCraft).
// Provide your own OAuth clients from the Google Cloud console and inject the
// Web client IDs at build time; the Android app OAuth client must be registered
// for your Android package name + signing SHA-1.

import '../server_providers.dart' show kDefaultAppEnv;

/// Production / Global Web client. Inject via
/// `--dart-define=GOOGLE_WEB_CLIENT_ID_PROD=...`.
const String kGoogleWebClientIdProd =
    String.fromEnvironment('GOOGLE_WEB_CLIENT_ID_PROD');

/// Test / dev Web client. Inject via
/// `--dart-define=GOOGLE_WEB_CLIENT_ID_DEV=...`.
const String kGoogleWebClientIdDev =
    String.fromEnvironment('GOOGLE_WEB_CLIENT_ID_DEV');

/// Pick Web client id from persisted / compile-time app env (same buckets as
/// [serverConfigProvider] / login env switch).
///
/// Override anytime with `--dart-define=GOOGLE_SERVER_CLIENT_ID=...`.
String googleWebClientIdForAppEnv(String? env) {
  final e = (env ?? kDefaultAppEnv).trim().toLowerCase();
  switch (e) {
    case 'prod':
    case 'production':
    case 'release':
      return kGoogleWebClientIdProd;
    case 'test':
    case 'testing':
    case 'qa':
    case 'uat':
    case 'dev':
    case 'debug':
    case 'local':
    default:
      return kGoogleWebClientIdDev;
  }
}
