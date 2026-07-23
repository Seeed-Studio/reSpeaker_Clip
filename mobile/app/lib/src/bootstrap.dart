import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart' show SdkLog, SdkLogLevel;

import 'app/app.dart';
import 'core/log/app_log.dart';
import 'core/legal/privacy_policy_consent_store.dart';
import 'core/l10n/app_locale_store.dart';
import 'core/observability/sentry_config.dart';
import 'core/observability/sentry_service.dart';
import 'core/server/auth/auth_backend.dart';
import 'core/server/auth/auth_token_store.dart';
import 'core/server/auth/user_profile_store.dart';
import 'core/server/sensecraft_auth/sensecraft_auth_token_store.dart';
import 'features/ai_config/presentation/guide/ai_config_guide_helper.dart';
import 'features/auth/data/auth_session_store.dart';
import 'features/settings/data/push_store.dart' as push_store;

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Bridge sensecraft_voice SDK logs into the host app logger so every BLE/AT
  // line from the SDK still shows up in our log files.
  SdkLog.bind((level, message, error, stackTrace) {
    switch (level) {
      case SdkLogLevel.debug:
        AppLog.d(message);
        break;
      case SdkLogLevel.info:
        AppLog.i(message);
        break;
      case SdkLogLevel.warning:
        AppLog.w(message, error, stackTrace);
        break;
      case SdkLogLevel.error:
        AppLog.e(message, error, stackTrace);
        break;
    }
  });

  AppLog.i('bootstrap start');

  // Lower BLE stack log noise during transfer (onCharacteristicChanged spam).
  FlutterBluePlus.setLogLevel(LogLevel.warning);

  // Transparent status bar; each Scaffold paints behind (no extra scrim on non-notch devices).
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));

  Future<void> initStep(String name, Future<void> Function() action) async {
    final sw = Stopwatch()..start();
    try {
      await action().timeout(const Duration(seconds: 3));
      AppLog.i('bootstrap $name ok (${sw.elapsedMilliseconds}ms)');
    } on TimeoutException {
      AppLog.w('bootstrap $name timeout, continue');
    } catch (e, st) {
      // Bootstrap failures are non-fatal (each step degrades gracefully) and
      // are surfaced via logs only — intentionally not reported to Sentry.
      AppLog.e('bootstrap $name failed', e, st);
    }
  }

  // Guide completion is keyed to this install (reinstall → show guide again).
  await initStep('ai_config_guide_scope', AiConfigGuideHelper.syncInstallScope);
  // First-launch privacy consent (Chinese app stores require Agree/Refuse before use).
  await initStep('privacy_consent', PrivacyPolicyConsentStore.init);
  // Preload auth session so cold start can go straight home.
  await initStep('auth_session', AuthSessionStore.init);
  // Preload API token for automatic Authorization headers.
  await initStep('auth_token', AuthTokenStore.init);
  // If a previous debug fallback left a SenseCraft JWT here, the business
  // backend will 401 every request with `code 2008 — jti unmarshal` because
  // it tries to verify with its own `jwt_key`. Purge such stale tokens so the
  // SC mode redirect flow re-runs `external/sensecraft/login` on next session.
  await initStep('auth_token_sanitize', AuthTokenStore.purgeIfNotBusinessJwt);
  // Preload SenseCraft token (used when AuthBackend=sensecraft; no-op otherwise).
  await initStep('sensecraft_auth_token', SenseCraftAuthTokenStore.init);
  // Preload AuthBackend selection so first widget build picks the right repo.
  await initStep('auth_backend', AuthBackendStore.init);
  // Preload user profile for settings screen.
  await initStep('user_profile', UserProfileStore.init);
  // Preload locale so first frame uses saved language.
  await initStep('locale', AppLocaleStore.init);
  // Push toggle + token cache (no permission prompt here; only when user enables push in settings).
  await initStep('push_store', push_store.PushStore.init);

  final cachedSession = AuthSessionStore.cached;
  if (cachedSession?.isLoggedIn == true) {
    unawaited(SentryService.setUser(email: cachedSession!.email));
  }
  final authBackend = AuthBackendStore.cached?.storageValue;
  await SentryService.configureReleaseAndTags(authBackend: authBackend);

  FlutterError.onError = (details) {
    AppLog.e('FlutterError', details.exception, details.stack);
    if (SentryService.active &&
        !SentryConfig.isExpectedWifiApReachabilityNoise(
          details.exception,
          details.stack,
        )) {
      unawaited(
        Sentry.captureException(
          details.exception,
          stackTrace: details.stack,
        ),
      );
    }
  };

  runApp(
    const ProviderScope(
      child: ReSpeakerApp(),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppLog.i('first frame rendered');
  });
}

