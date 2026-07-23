import 'package:shared_preferences/shared_preferences.dart';

import '../domain/auth_session.dart';

/// Persist login state: after login, next launch goes directly to home
class AuthSessionStore {
  static const _kLoggedIn = 'auth_logged_in';
  static const _kEmail = 'auth_email';
  static const _kNeedsSetPassword = 'auth_needs_set_password';

  static AuthSession? _cached;

  /// Call once at app startup: preload cache to avoid showing login then redirecting
  static Future<void> init() async {
    _cached = await load();
  }

  static AuthSession? get cached => _cached;

  static Future<AuthSession> load() async {
    final prefs = await SharedPreferences.getInstance();
    final loggedIn = prefs.getBool(_kLoggedIn) ?? false;
    if (!loggedIn) return AuthSession.loggedOut();
    final email = prefs.getString(_kEmail);
    final needsSetPassword = prefs.getBool(_kNeedsSetPassword) ?? false;
    return AuthSession(isLoggedIn: true, email: email, needsSetPassword: needsSetPassword);
  }

  static Future<void> save(AuthSession session) async {
    _cached = session;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoggedIn, session.isLoggedIn);
    if (session.email == null) {
      await prefs.remove(_kEmail);
    } else {
      await prefs.setString(_kEmail, session.email!);
    }
    await prefs.setBool(_kNeedsSetPassword, session.needsSetPassword);
  }

  static Future<void> clear() async {
    _cached = AuthSession.loggedOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLoggedIn);
    await prefs.remove(_kEmail);
    await prefs.remove(_kNeedsSetPassword);
  }
}

