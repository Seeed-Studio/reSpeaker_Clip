/// Base URL resolution for the SenseCraft unified auth service
/// (`authDomain()` per SenseCraft authapi).
///
/// SenseCraft auth lives on a *different* host than the business backend, so
/// it has its own table independent of [serverConfigProvider].
///
/// Pairing with [SenseCraftPaasEnv]: `release` uses international hosts;
/// `dev` / `test` use the test intranet (VPN). Override with
/// `--dart-define=AUTH_BASE_URL=...`.
class SenseCraftAuthEnv {
  /// `--dart-define=AUTH_BASE_URL=https://...` — highest priority override.
  static const String _kOverride =
      String.fromEnvironment('AUTH_BASE_URL', defaultValue: '');

  /// Trailing slash required so [Uri.resolve] keeps the `/authapi` prefix.
  static const String _globalProd = 'https://sensecraft-auth.seeed.cc/authapi/';
  static const String _chinaProd = 'https://sensecraft-auth.seeed.cn/authapi/';
  // Test/dev host is environment-specific; inject with --dart-define=AUTH_BASE_URL.
  static const String _test = 'https://test.example.com/authapi/';

  /// Resolves the auth base URL for the given runtime [env].
  ///
  /// [env] values mirror [ServerEnvStore]: `dev` / `test` / `release`.
  static Uri baseUriFor(String env) {
    final override = _kOverride.trim();
    if (override.isNotEmpty) return _normalize(override);
    final e = env.trim().toLowerCase();
    switch (e) {
      case 'prod':
      case 'production':
      case 'release':
        return _normalize(_globalProd);
      case 'cn':
      case 'china':
        return _normalize(_chinaProd);
      case 'test':
      case 'testing':
      case 'qa':
      case 'uat':
      case 'dev':
      case 'debug':
      case 'local':
      default:
        return _normalize(_test);
    }
  }

  static Uri _normalize(String raw) {
    var b = raw.trim();
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'https://$b';
    }
    if (!b.endsWith('/')) b = '$b/';
    return Uri.parse(b);
  }
}

/// Region label used as the `domain` form/query field on some SenseCraft
/// endpoints (e.g. `getEmailCode` takes `domain: 1=paas | 2=craft`).
///
/// For respeaker we always live in the `craft` realm.
class SenseCraftDomainCode {
  static const int paas = 1;
  static const int craft = 2;
}
