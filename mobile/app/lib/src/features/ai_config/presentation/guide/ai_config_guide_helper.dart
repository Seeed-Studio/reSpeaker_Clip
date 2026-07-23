import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Loads [AiConfigGuideHelper.isDone] for router redirect after login.
final aiConfigGuideDoneProvider = FutureProvider<bool>((ref) {
  return AiConfigGuideHelper.isDone();
});

/// First-login STT/LLM onboarding; completion is scoped to the current app install.
class AiConfigGuideHelper {
  static const String _legacyDoneKey = 'ai_config_guide_done';
  static const String _doneForInstallKey = 'ai_config_guide_done_for_install';
  static const String _installScopeFileName = '.app_install_scope_id';

  static bool? _cachedDone;

  /// Sync read after [syncInstallScope] / [isDone] / [markDone]; used by router redirect.
  static bool get cachedDone => _cachedDone ?? false;

  /// Call from [bootstrap] before the first frame so router redirect sees the right state.
  static Future<void> syncInstallScope() async {
    final epoch = await _currentInstallEpoch();
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyIfNeeded(prefs, epoch);
    final saved = prefs.getString(_doneForInstallKey);
    _cachedDone = saved != null && saved == epoch;
  }

  static Future<bool> isDone() async {
    if (_cachedDone != null) return _cachedDone!;
    try {
      await syncInstallScope();
    } catch (_) {
      _cachedDone = false;
    }
    return _cachedDone ?? false;
  }

  static Future<void> markDone({WidgetRef? ref}) async {
    final epoch = await _currentInstallEpoch();
    _cachedDone = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_doneForInstallKey, epoch);
    await prefs.remove(_legacyDoneKey);
    ref?.invalidate(aiConfigGuideDoneProvider);
  }

  static Future<void> reset({WidgetRef? ref}) async {
    _cachedDone = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_doneForInstallKey);
    await prefs.remove(_legacyDoneKey);
    ref?.invalidate(aiConfigGuideDoneProvider);
  }

  /// After any successful login/register (all auth methods): guide once, then home.
  static Future<void> navigateAfterAuthReady(BuildContext context) async {
    final done = await isDone();
    if (!context.mounted) return;
    context.go(done ? '/recordings' : '/ai-config/guide');
  }

  /// Same as [navigateAfterAuthReady] but uses [GoRouter] directly.
  ///
  /// GitHub OAuth can finish while the app is still in the browser; [GoRouter]
  /// redirect then disposes the authorize page so [BuildContext.mounted] is false
  /// before navigation runs. Call this after [AuthSessionController.setLoggedIn].
  static Future<void> navigateAfterAuthReadyRouter(GoRouter router) async {
    final done = await isDone();
    router.go(done ? '/recordings' : '/ai-config/guide');
  }

  static Future<void> _migrateLegacyIfNeeded(
    SharedPreferences prefs,
    String epoch,
  ) async {
    if (prefs.getString(_doneForInstallKey) != null) {
      if (prefs.containsKey(_legacyDoneKey)) {
        await prefs.remove(_legacyDoneKey);
      }
      return;
    }
    if (prefs.getBool(_legacyDoneKey) == true) {
      await prefs.setString(_doneForInstallKey, epoch);
      await prefs.remove(_legacyDoneKey);
    }
  }

  /// Android: [PackageInfo.installTime] changes on reinstall (not prefs backup).
  /// iOS / others without installTime: stable id file under Application Support.
  static Future<String> _currentInstallEpoch() async {
    final info = await PackageInfo.fromPlatform();
    final installTime = info.installTime;
    if (installTime != null) {
      return installTime.millisecondsSinceEpoch.toString();
    }
    return _installScopeIdFromFile();
  }

  static Future<String> _installScopeIdFromFile() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_installScopeFileName');
    if (await file.exists()) {
      final id = (await file.readAsString()).trim();
      if (id.isNotEmpty) return id;
    }
    final id = const Uuid().v4();
    await file.writeAsString(id, flush: true);
    return id;
  }
}
