import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence of push switch and token
/// Concrete push scenarios (where to send push) to be configured later on server or business layer
/// Default off: no popup on app launch; only request permission when user enables "Push notifications" in settings
class PushStore {
  static const _kPushEnabled = 'push_enabled';
  static const _kPushToken = 'push_token';

  static bool _cachedEnabled = false;
  static String? _cachedToken;

  static bool get cachedEnabled => _cachedEnabled;
  static String? get cachedToken => _cachedToken;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedEnabled = prefs.getBool(_kPushEnabled) ?? false;
    _cachedToken = prefs.getString(_kPushToken);
  }

  static Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedEnabled = prefs.getBool(_kPushEnabled) ?? false;
    return _cachedEnabled;
  }

  static Future<void> setEnabled(bool enabled) async {
    _cachedEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPushEnabled, enabled);
  }

  static Future<void> saveToken(String? token) async {
    _cachedToken = (token != null && token.trim().isNotEmpty) ? token.trim() : null;
    final prefs = await SharedPreferences.getInstance();
    if (_cachedToken == null) {
      await prefs.remove(_kPushToken);
    } else {
      await prefs.setString(_kPushToken, _cachedToken!);
    }
  }

  static Future<String?> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _cachedToken = prefs.getString(_kPushToken);
    return _cachedToken;
  }
}
