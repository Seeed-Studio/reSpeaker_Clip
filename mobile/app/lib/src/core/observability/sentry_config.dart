import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart'
    show isDeviceApNetworkUnreachable;

import '../server/server_providers.dart' show kDefaultAppEnv;
import 'sentry_noise.dart';

/// Optional Sentry reporting. The DSN is injected at build time via
/// `--dart-define=SENTRY_DSN=...` and defaults to empty, so builds never
/// report to Sentry unless a DSN is explicitly provided.
class SentryConfig {
  SentryConfig._();

  static const dsn = String.fromEnvironment('SENTRY_DSN');

  /// Release **build** + release **APP_ENV** only (`--dart-define=APP_ENV=release`).
  /// Debug/profile builds and test/dev/local envs never report.
  static bool get enabled =>
      kReleaseMode && _isReleaseAppEnv && dsn.isNotEmpty;

  static bool get _isReleaseAppEnv {
    switch (kDefaultAppEnv.trim().toLowerCase()) {
      case 'release':
      case 'prod':
      case 'production':
        return true;
      default:
        return false;
    }
  }

  static void configure(SentryFlutterOptions options) {
    options.dsn = enabled ? dsn : '';
    options.environment = kDefaultAppEnv.trim().isEmpty
        ? 'unknown'
        : kDefaultAppEnv.trim().toLowerCase();
    options.attachStacktrace = true;
    options.sendDefaultPii = false;
    options.tracesSampleRate = 0.0;
    options.enableAutoSessionTracking = enabled;
    // Drop high-volume auto breadcrumbs. We keep only the manual breadcrumbs we
    // add ourselves (wifi/ota/merge) which carry the useful transfer context.
    // - print: AppLog (logger pkg) routes through debugPrint, so every log line
    //   would otherwise become a breadcrumb in release builds.
    // - user interaction / native system events add little to crash triage here.
    options.enablePrintBreadcrumbs = false;
    options.enableUserInteractionBreadcrumbs = false;
    options.enableUserInteractionTracing = false;
    options.enableAutoNativeBreadcrumbs = false;
    options.beforeSend = _beforeSend;
  }

  /// Public helper for early drop before enqueueing a Sentry event.
  static bool isExpectedWifiApReachabilityNoise(
    Object error,
    StackTrace? stackTrace,
  ) {
    return SentryNoise.isExpected(error, stackTrace);
  }

  static FutureOr<SentryEvent?> _beforeSend(SentryEvent event, Hint hint) {
    if (!enabled) return null;

    final message = event.message?.formatted ?? '';
    if (message.isNotEmpty &&
        SentryNoise.isExpectedMessage(message, error: hint.get('error'))) {
      return null;
    }

    if (_isExpectedExceptionEvent(event)) return null;
    return event;
  }

  static bool _isExpectedExceptionEvent(SentryEvent event) {
    final exceptions = event.exceptions;
    if (exceptions == null || exceptions.isEmpty) return false;

    const wifiStackMarkers = <String>[
      'udp_sync_client.dart',
      'transfer_client.dart',
      'wifi_transfer_controller.dart',
      'hotspot_connector.dart',
      'fast_sync_session.dart',
      'ClipUdpSyncClient._send',
      'ClipUdpSyncClient.ping',
      'ClipUdpSyncClient.downloadSession',
      'WifiTransferClient.ping',
      '_wifiStillReachable',
      '_wifiReachabilityProbe',
      '_wifiDownloadAndMergeOneItem',
    ];

    for (final ex in exceptions) {
      final summary = '${ex.type ?? ''} ${ex.value ?? ''}';
      final frames = ex.stackTrace?.frames ?? const [];
      final traceText = frames
          .map((f) => '${f.function ?? ''} ${f.absPath ?? ''} ${f.fileName ?? ''}')
          .join('\n');

      if (SentryNoise.isExpected(summary, StackTrace.fromString(traceText))) {
        return true;
      }

      final wifiUdpNoise = isDeviceApNetworkUnreachable(summary) ||
          SentryNoise.isWifiUdpTransientSocketError(summary);
      if (!summary.contains('SocketException') || !wifiUdpNoise) {
        continue;
      }

      // Truncated events: only drop address-assign / unreachable (errno 49-ish).
      // errno 9 needs a Wi‑Fi UDP stack marker to avoid unrelated closed sockets.
      if (frames.isEmpty) {
        final lower = summary.toLowerCase();
        return isDeviceApNetworkUnreachable(summary) ||
            lower.contains("can't assign requested address") ||
            lower.contains('cannot assign requested address') ||
            lower.contains('errno = 49') ||
            lower.contains('errno = 99') ||
            lower.contains('errno = 10049');
      }

      for (final frame in frames) {
        final fn = frame.function ?? '';
        final file = '${frame.absPath ?? ''} ${frame.fileName ?? ''}';
        for (final marker in wifiStackMarkers) {
          if (fn.contains(marker) || file.contains(marker)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  static String platformTag() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return Platform.operatingSystem;
  }

  /// Strip sensitive keys from manual [SentryService] extras/breadcrumbs.
  static Map<String, dynamic>? scrubMap(Map<String, dynamic>? input) {
    if (input == null || input.isEmpty) return input;
    final out = <String, dynamic>{};
    for (final entry in input.entries) {
      final key = entry.key.toLowerCase();
      if (_sensitiveKey(key)) {
        out[entry.key] = '[Filtered]';
        continue;
      }
      final value = entry.value;
      if (value is Map) {
        out[entry.key] = scrubMap(Map<String, dynamic>.from(value));
      } else {
        out[entry.key] = value;
      }
    }
    return out;
  }

  static bool _sensitiveKey(String lowerKey) {
    return lowerKey.contains('password') ||
        lowerKey.contains('token') ||
        lowerKey.contains('authorization') ||
        lowerKey.contains('secret') ||
        lowerKey.contains('api_key') ||
        lowerKey.contains('logincode') ||
        lowerKey.contains('pwd') ||
        lowerKey == 'email';
  }
}
