/// Base URL resolution for the SenseCAP **PaaS** APIs (device firmware,
/// gateway get_new_version, etc.).
///
/// Hosts (Portal `domain()` vs auth `authDomain()`):
/// - International: `https://sensecap.seeed.cc/portalapi/`
/// - China:         `https://sensecap.seeed.cn/portalapi/`
/// - Test/dev:      inject with `--dart-define=PAAS_BASE_URL=...`
///
/// [ServerEnvStore]: `release` → international; `dev` / `test` → test intranet
/// (tokens must match the same env on [SenseCraftAuthEnv]). Override any time
/// with `--dart-define=PAAS_BASE_URL=...`.
class SenseCraftPaasEnv {
  /// `--dart-define=PAAS_BASE_URL=https://...` — highest priority override.
  static const String _kOverride =
      String.fromEnvironment('PAAS_BASE_URL', defaultValue: '');

  /// Trailing slash required so [Uri.resolve] keeps the `/portalapi` prefix.
  static const String _globalProd = 'https://sensecap.seeed.cc/portalapi/';
  static const String _chinaProd = 'https://sensecap.seeed.cn/portalapi/';
  // Test/dev host is environment-specific; inject with --dart-define=PAAS_BASE_URL.
  static const String _test = 'https://test.example.com/portalapi/';

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
