/// Compile-time switch for domestic China builds.
///
/// Hide Google / GitHub / Apple login on the login page by packaging with:
/// `--dart-define=HIDE_THIRD_PARTY_LOGIN=true`
///
/// App API envs stay `release` (prod) / `test` only — do **not** use a separate
/// `china` APP_ENV for packaging; hide third-party login via this define.
const bool kHideThirdPartyLoginDefine =
    bool.fromEnvironment('HIDE_THIRD_PARTY_LOGIN', defaultValue: false);

/// Whether third-party login (Google / GitHub / Apple) is shown on the login
/// page. Controlled purely at build time — domestic packages set the define to
/// hide it; all other builds show it.
class ThirdPartyLoginStore {
  const ThirdPartyLoginStore._();

  static bool get showThirdPartyLogin => !kHideThirdPartyLoginDefine;
}
