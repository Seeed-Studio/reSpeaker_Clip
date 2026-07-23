import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'sentry_config.dart';
import 'sentry_noise.dart';

/// Thin wrapper around Sentry — no-ops unless release build + APP_ENV=release.
class SentryService {
  SentryService._();

  static bool _ready = false;

  /// True after [markReady] in release builds with a configured DSN.
  static bool get active => SentryConfig.enabled && _ready;

  static void markReady() {
    if (SentryConfig.enabled) _ready = true;
  }

  /// Call once during bootstrap after stores init.
  static Future<void> configureReleaseAndTags({
    String? authBackend,
    bool deviceConnected = false,
  }) async {
    if (!active) return;
    try {
      final info = await PackageInfo.fromPlatform();
      await Sentry.configureScope((scope) {
        scope.setTag('release', '${info.version}+${info.buildNumber}');
        scope.setTag('platform', SentryConfig.platformTag());
        scope.setTag('device_connected', deviceConnected.toString());
        if (authBackend != null && authBackend.isNotEmpty) {
          scope.setTag('auth_backend', authBackend);
        }
      });
    } catch (_) {}
  }

  static Future<void> setAuthBackendTag(String backend) async {
    if (!active || backend.isEmpty) return;
    await Sentry.configureScope((scope) {
      scope.setTag('auth_backend', backend);
    });
  }

  static Future<void> setDeviceConnected(bool connected) async {
    if (!active) return;
    await Sentry.configureScope((scope) {
      scope.setTag('device_connected', connected.toString());
    });
  }

  static Future<void> setUser({
    int? userId,
    String? email,
  }) async {
    if (!active) return;
    final id = (userId != null && userId > 0)
        ? userId.toString()
        : _hashedUserId(email);
    if (id == null) return;
    await Sentry.configureScope((scope) {
      scope.setUser(SentryUser(id: id));
    });
  }

  static Future<void> clearUser() async {
    if (!active) return;
    await Sentry.configureScope((scope) {
      scope.setUser(null);
    });
  }

  static String? _hashedUserId(String? email) {
    final normalized = (email ?? '').trim().toLowerCase();
    if (normalized.isEmpty) return null;
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
  }

  static void breadcrumb(
    String message, {
    String category = 'app',
    Map<String, dynamic>? data,
  }) {
    if (!active) return;
    Sentry.addBreadcrumb(
      Breadcrumb(
        message: message,
        category: category,
        level: SentryLevel.info,
        data: SentryConfig.scrubMap(data),
      ),
    );
  }

  static Future<void> captureMessage(
    String message, {
    SentryLevel level = SentryLevel.warning,
    Map<String, dynamic>? extras,
    Object? relatedError,
  }) async {
    if (!active) return;
    final err = relatedError ??
        (extras != null ? extras['error'] : null);
    if (SentryNoise.isExpectedMessage(message, error: err)) return;
    await Sentry.captureMessage(
      message,
      level: level,
      withScope: (scope) {
        if (extras != null && extras.isNotEmpty) {
          scope.setContexts(
            'details',
            SentryConfig.scrubMap(extras) ?? const {},
          );
        }
      },
    );
  }

  static Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    Map<String, dynamic>? extras,
  }) async {
    if (!active || SentryNoise.isExpected(error, stackTrace)) return;
    await Sentry.captureException(
      error,
      stackTrace: stackTrace,
      withScope: (scope) {
        if (extras != null && extras.isNotEmpty) {
          scope.setContexts(
            'details',
            SentryConfig.scrubMap(extras) ?? const {},
          );
        }
      },
    );
  }

  static Future<void> captureLoginFailure(Object error, {String? method}) async {
    if (SentryNoise.isExpected(error)) return;
    await captureMessage(
      'Login failed${method != null ? ' ($method)' : ''}',
      level: SentryLevel.warning,
      extras: {
        if (method != null) 'method': method,
        'error': error.toString(),
      },
      relatedError: error,
    );
  }

  static Future<void> captureWifiBatchFailure({
    required String recordingId,
    required String sessionId,
    required String phase,
    required Object error,
  }) async {
    if (SentryNoise.isExpectedMessage(
      'WiFi Fast Sync batch failed',
      error: error,
    )) {
      return;
    }
    breadcrumb(
      'WiFi batch failed',
      category: 'wifi',
      data: {
        'recording_id': recordingId,
        'session_id': sessionId,
        'phase': phase,
      },
    );
    await captureMessage(
      'WiFi Fast Sync batch failed',
      level: SentryLevel.error,
      extras: {
        'recording_id': recordingId,
        'session_id': sessionId,
        'phase': phase,
        'error': error.toString(),
      },
      relatedError: error,
    );
  }

  static Future<void> captureMergeRefused({
    required String recordingId,
    required int mergedBytes,
    required int? expectedBytes,
    required String source,
  }) async {
    breadcrumb(
      'Merge refused',
      category: 'merge',
      data: {
        'recording_id': recordingId,
        'merged_bytes': mergedBytes,
        'expected_bytes': expectedBytes,
        'source': source,
      },
    );
  }

  static Future<void> captureOtaFailure({
    required String deviceId,
    required Object error,
  }) async {
    if (SentryNoise.isExpectedMessage(
      'OTA firmware update failed',
      error: error,
    )) {
      return;
    }
    breadcrumb(
      'OTA failed',
      category: 'ota',
      data: {'device_id': deviceId},
    );
    await captureMessage(
      'OTA firmware update failed',
      level: SentryLevel.error,
      extras: {
        'device_id': deviceId,
        'error': error.toString(),
      },
      relatedError: error,
    );
  }
}

