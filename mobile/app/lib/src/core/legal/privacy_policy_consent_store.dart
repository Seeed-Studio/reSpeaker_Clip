import 'package:shared_preferences/shared_preferences.dart';

/// Persists first-launch privacy policy consent (required by Chinese app stores).
class PrivacyPolicyConsentStore {
  static const _kAccepted = 'privacy_policy_consent_accepted_v1';

  static bool? _cached;

  /// Call once from [bootstrap] so the first frame can gate synchronously.
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _cached = prefs.getBool(_kAccepted) ?? false;
  }

  static bool get hasAccepted => _cached == true;

  static Future<void> accept() async {
    _cached = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAccepted, true);
  }
}
