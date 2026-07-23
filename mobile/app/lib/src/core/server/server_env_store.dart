import 'package:shared_preferences/shared_preferences.dart';

/// Persist server env: dev | test | release (login page; takes effect after restart)
class ServerEnvStore {
  static const _kKey = 'server_env';

  /// Allowed values
  static const String dev = 'dev';
  static const String test = 'test';
  static const String release = 'release';
  static const List<String> values = [dev, test, release];

  static Future<String?> get() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_kKey)?.trim().toLowerCase();
    if (v == null || v.isEmpty) return null;
    if (values.contains(v)) return v;
    return null;
  }

  static Future<void> set(String env) async {
    final e = env.trim().toLowerCase();
    if (!values.contains(e)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, e);
  }
}
