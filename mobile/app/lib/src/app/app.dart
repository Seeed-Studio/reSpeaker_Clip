import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/db/account_db_key.dart';
import '../core/db/account_scope_invalidation.dart';
import '../core/legal/privacy_policy_gate.dart';
import '../core/l10n/app_localizations.dart';
import '../core/l10n/app_locale_provider.dart';
import '../core/audio/session_merge_queue.dart';
import '../features/device/presentation/device_controller.dart';
import '../features/recordings/presentation/recordings_controller.dart';
import '../features/recordings/presentation/transcription_task_controller.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

/// Keep navigator / provider state stable when [MaterialApp.locale] changes.
const _materialAppKey = ValueKey<String>('respeaker_material_app');

void _recoverAfterLocaleChange(WidgetRef ref) {
  final dev = ref.read(deviceControllerProvider);
  if (dev.connection == null && dev.lastConnectedDeviceId != null) {
    ref.read(deviceControllerProvider.notifier).kickAutoReconnect();
  }
  bumpRecordingsLists(ref);
}

bool _startupTasksScheduled = false;

void _scheduleStartupTasksOnce(WidgetRef ref) {
  if (_startupTasksScheduled) return;
  _startupTasksScheduled = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref.read(recycleBinPurgeProvider);
    ref.read(validateLocalPathsProvider);
    ref.read(resumeStuckSessionMergesProvider);
    ref.read(reprobeMergedDurationsProvider);
    ref.read(reconcileStuckTranscriptionJobsProvider);
  });
}

class ReSpeakerApp extends ConsumerWidget {
  const ReSpeakerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    ref.listen<Locale>(appLocaleProvider, (prev, next) {
      if (prev == null || prev == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _recoverAfterLocaleChange(ref);
      });
    });

    ref.listen<String?>(accountDbKeyProvider, (prev, next) {
      if (prev == next) return;
      // Leaving an account (logout) or direct A→B hand-off: drop DB + list cache.
      if (prev != null) {
        invalidateAccountScopedData(ref);
      }
      // New account logged in: ensure paged list rebuilds from the new shard.
      if (next != null) {
        ref.invalidate(recordingsListPagedNotifierProvider);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          bumpRecordingsLists(ref);
        });
      }
    });

    // Once after launch: trash cleanup + invalidate stale local_path rows.
    _scheduleStartupTasksOnce(ref);

    return _LocalizedMaterialApp(router: router);
  }
}

class _LocalizedMaterialApp extends ConsumerWidget {
  const _LocalizedMaterialApp({required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(appLocaleProvider);

    return MaterialApp.router(
      key: _materialAppKey,
      title: 'SenseCraft Voice',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Temporary: lock to light theme to keep "white base" UI consistent.
      themeMode: ThemeMode.light,
      routerConfig: router,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: MediaQuery.textScalerOf(context).clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.2,
            ),
          ),
          child: PrivacyPolicyGate(
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', ''), // English
        Locale('zh', ''), // Chinese
      ],
      locale: locale,
    );
  }
}

