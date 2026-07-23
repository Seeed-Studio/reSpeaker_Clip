import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/user_api.dart';

/// Persisted user profile (from login or `/api/v1/user`).
///
/// [save] / [clear] use an epoch so a slow [save] from a previous account
/// cannot overwrite a newer clear/login. Without this, logout → login can
/// briefly (or permanently after Notifier rebuild) revive the old avatar.
class UserProfileStore {
  static const _kUser = 'auth_user_profile_json';
  static UserProfile? _cached;
  static int _epoch = 0;

  static Future<void> init() async {
    _cached = await load();
  }

  static UserProfile? get cached => _cached;

  static int get epoch => _epoch;

  /// Invalidate in-flight [save] callers (e.g. account switch before clear).
  static void bumpEpoch() {
    _epoch++;
  }

  static Future<UserProfile?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kUser);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return UserProfile.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(UserProfile user) async {
    final e = _epoch;
    _cached = user;
    final prefs = await SharedPreferences.getInstance();
    if (e != _epoch) return;
    await prefs.setString(_kUser, jsonEncode(user.toJson()));
  }

  static Future<void> clear() async {
    _epoch++;
    _cached = null;
    final e = _epoch;
    final prefs = await SharedPreferences.getInstance();
    if (e != _epoch) return;
    await prefs.remove(_kUser);
  }
}
