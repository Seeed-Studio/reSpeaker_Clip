import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persist app [Locale] choice.
///
/// Notes:
/// - Call `init()` from `bootstrap()` so the first frame reads the cache.
/// - Before the user picks a language in settings, follows the OS locale.
/// - After the user saves a choice, only `en` / `zh` is stored in prefs.
class AppLocaleStore {
  static const _kLocale = 'app_locale';

  static Locale? _cached;
  static String? _savedCode;

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _savedCode = prefs.getString(_kLocale);
    _cached = resolveLocale(_savedCode);
  }

  static Locale get cached => _cached ?? resolveLocale(_savedCode);

  /// True when the user has explicitly chosen a language in settings.
  static bool get hasUserOverride =>
      _savedCode == 'en' || _savedCode == 'zh';

  static Future<void> save(Locale locale) async {
    final code = locale.languageCode;
    _savedCode = code;
    _cached = _fromCode(code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocale, code);
  }

  static Locale resolveLocale(String? savedCode) {
    switch (savedCode) {
      case 'en':
        return const Locale('en', '');
      case 'zh':
        return const Locale('zh', '');
      default:
        return localeFromSystem();
    }
  }

  /// Maps the device locale to a supported app locale (`en` / `zh`).
  static Locale localeFromSystem() {
    final code = PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    if (code == 'zh' || code.startsWith('zh')) {
      return const Locale('zh', '');
    }
    return const Locale('en', '');
  }

  static Locale _fromCode(String code) {
    switch (code) {
      case 'en':
        return const Locale('en', '');
      case 'zh':
        return const Locale('zh', '');
      default:
        return const Locale('en', '');
    }
  }
}
