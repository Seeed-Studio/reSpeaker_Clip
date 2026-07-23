import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted API auth token (JWT).
///
/// Used by [ServerAuthProvider] to attach `Authorization: Bearer <token>` to requests.
class AuthTokenStore {
  static const _kToken = 'auth_api_token';
  static const _kRefreshToken = 'auth_refresh_token';

  static String? _cached;
  static String? _cachedRefresh;

  static Future<void> init() async {
    _cached = await load();
    _cachedRefresh = await loadRefreshToken();
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

  static Future<void> save(String token) async {
    await saveTokens(accessToken: token, refreshToken: _cachedRefresh);
  }

  static Future<void> saveTokens({required String accessToken, String? refreshToken}) async {
    final t = accessToken.trim();
    _cached = t.isEmpty ? null : t;
    final rt = (refreshToken ?? '').trim();
    _cachedRefresh = rt.isEmpty ? null : rt;
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
  }

  static Future<void> clear() async {
    _cached = null;
    _cachedRefresh = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kRefreshToken);
  }

  /// One-shot bootstrap cleanup: if the cached token is a SenseCraft JWT
  /// (numeric `jti` / has `payload` claim) it cannot be verified by the
  /// business backend (signed with a different `jwt_key`, expects string `jti`).
  /// Leaving it in [AuthTokenStore] causes every business request to fail with
  /// `code 2008 — json: cannot unmarshal number into …Claims.jti of type string`.
  /// We just clear it so the SC redirect flow re-runs `external/sensecraft/login`
  /// on next session.
  static Future<void> purgeIfNotBusinessJwt() async {
    final tok = _cached;
    if (tok == null || tok.trim().isEmpty) return;
    if (_looksLikeBusinessJwt(tok)) return;
    await clear();
  }

  /// Heuristic JWT-shape check. Business JWTs (see go-example `pkg/util/token`)
  /// embed `id: <int64>` + `name: <string>` custom claims and use a string
  /// `jti` (UUID). SenseCraft JWTs carry `payload: <string>` and a numeric
  /// `jti`. We treat anything not matching the business shape as **not** a
  /// business JWT so it is purged on bootstrap.
  static bool _looksLikeBusinessJwt(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return false;
    try {
      final raw = base64Url.decode(base64Url.normalize(parts[1]));
      final payload = jsonDecode(utf8.decode(raw));
      if (payload is! Map) return false;
      final m = payload.cast<String, dynamic>();
      if (m.containsKey('payload')) return false;
      final jti = m['jti'];
      if (jti is num) return false;
      return m['id'] is num || m['name'] is String;
    } catch (_) {
      return false;
    }
  }
}

