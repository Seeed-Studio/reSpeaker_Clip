import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted token pair issued by the **SenseCraft unified auth** service.
///
/// This is intentionally separate from [AuthTokenStore]:
/// - [AuthTokenStore] holds the **business** JWT used by every business API
///   call (recordings / llm / asr / oss). Its lifecycle is owned by the
///   business backend and must not be confused with the SenseCraft token.
/// - [SenseCraftAuthTokenStore] holds the **SenseCraft** access /
///   refresh tokens. Their only consumers are the SenseCraft auth API
///   itself (refresh, change password, sign out, getUserOrgInfo) and the
///   business "external login" exchange endpoint.
///
/// [changeNotifier] bumps on every [saveTokens] / [clear] so the router (or
/// other widgets) can rerun their redirect logic when the SC session is
/// implicitly invalidated by background refresh failures, not only by
/// explicit user actions that already touch [authSessionProvider].
///
/// When [AuthBackend] is `selfHosted`, this store stays empty.
class SenseCraftAuthTokenStore {
  static const _kToken = 'sensecraft_auth_token';
  static const _kRefreshToken = 'sensecraft_auth_refresh_token';

  static String? _cached;
  static String? _cachedRefresh;

  /// Reactive ping; consumers may subscribe via `Listenable.merge` etc.
  static final ValueNotifier<int> changeNotifier = ValueNotifier<int>(0);

  /// Preload during bootstrap so the first network call doesn't await disk.
  static Future<void> init() async {
    _cached = await load();
    _cachedRefresh = await loadRefreshToken();
    // No notify here — bootstrap callers that care can read [cached] directly.
  }

  static String? get cached => _cached;
  static String? get refreshTokenCached => _cachedRefresh;

  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(_kToken);
    return (t == null || t.trim().isEmpty) ? null : t;
  }

  static Future<String?> loadRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString(_kRefreshToken);
    return (t == null || t.trim().isEmpty) ? null : t;
  }

  static Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    final t = accessToken.trim();
    _cached = t.isEmpty ? null : t;
    if (refreshToken != null) {
      final rt = refreshToken.trim();
      _cachedRefresh = rt.isEmpty ? null : rt;
    }
    final prefs = await SharedPreferences.getInstance();
    if (_cached == null) {
      await prefs.remove(_kToken);
    } else {
      await prefs.setString(_kToken, _cached!);
    }
    if (_cachedRefresh == null) {
      await prefs.remove(_kRefreshToken);
    } else {
      await prefs.setString(_kRefreshToken, _cachedRefresh!);
    }
    _bump();
  }

  static Future<void> clear() async {
    _cached = null;
    _cachedRefresh = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kRefreshToken);
    _bump();
  }

  static void _bump() {
    changeNotifier.value++;
  }
}
