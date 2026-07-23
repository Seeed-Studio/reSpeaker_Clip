import 'package:shared_preferences/shared_preferences.dart';

class SearchHistoryHelper {
  static const String _key = 'recordings_search_history';

  /// Latest five search history strings
  static Future<List<String>> getRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    return list.take(5).toList();
  }

  static Future<void> addSearch(String query) async {
    final v = query.trim();
    if (v.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    list.removeWhere((e) => e.toLowerCase() == v.toLowerCase());
    list.insert(0, v);
    if (list.length > 5) list.removeRange(5, list.length);
    await prefs.setStringList(_key, list);
  }

  /// Clear persisted search history
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
