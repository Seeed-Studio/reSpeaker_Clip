import 'dart:async';
import 'dart:io';

import 'package:sensecraft_voice/sensecraft_voice.dart'
    show isDeviceApNetworkUnreachable, isWifiApReachabilitySocketNoise;

/// Central rules for errors that are expected in normal use and should not
/// inflate Sentry as crashes.
class SentryNoise {
  SentryNoise._();

  static const _wifiUdpStackMarkers = <String>[
    'udp_sync_client.dart',
    'transfer_client.dart',
    'wifi_transfer_controller.dart',
    'hotspot_connector.dart',
    'fast_sync_session.dart',
    'ClipUdpSyncClient._send',
    'ClipUdpSyncClient.ping',
    'ClipUdpSyncClient.downloadSession',
    'ClipUdpSyncClient.sendAtCommand',
    'WifiTransferClient.ping',
    '_wifiStillReachable',
    '_wifiReachabilityProbe',
    '_wifiDownloadAndMergeOneItem',
  ];

  static const _bleTransferStackMarkers = <String>[
    'device_controller.dart',
    'downloadSessionToLocal',
    'AtTransport.send',
    'at_transport.dart',
    'ble_client.dart',
    'recording_session.dart',
  ];

  /// Drop from global handlers / beforeSend when true.
  static bool isExpected(Object error, [StackTrace? stackTrace]) {
    // Unreachable (SDK) + bind-race errno 49 / closed socket errno 9 (app).
    if (isWifiApReachabilitySocketNoise(error, stackTrace: stackTrace)) {
      return true;
    }
    if (_isWifiUdpOperationalSocketNoise(error, stackTrace)) {
      return true;
    }
    if (_isExpectedBleTransferDisconnect(error, stackTrace)) return true;
    if (_isExpectedAtTimeoutDuringTransfer(error, stackTrace)) return true;
    if (_isExpectedDatabaseClosed(error)) return true;
    if (_isExpectedOtaUserError(error)) return true;
    if (_isExpectedAuthUserError(error)) return true;
    return false;
  }

  /// Drop manual [SentryService.captureMessage] payloads.
  static bool isExpectedMessage(String message, {Object? error}) {
    final m = message.trim();
    if (m == 'Session merge refused (incomplete payload)') return true;
    if (m.startsWith('Login failed')) {
      return error == null || _isExpectedAuthUserError(error);
    }
    if (m == 'WiFi Fast Sync batch failed') {
      final s = error?.toString() ?? '';
      if (isDeviceApNetworkUnreachable(s) ||
          isDeviceApNetworkUnreachable(error ?? '') ||
          isWifiUdpTransientSocketError(s) ||
          isWifiUdpTransientSocketError(error ?? '')) {
        return true;
      }
      return s.contains('Wi‑Fi setup:') ||
          s.contains('WifiVerifyFailure') ||
          s.contains('networkUnreachable') ||
          s.contains('timedOut');
    }
    if (m == 'OTA firmware update failed') {
      return error != null && _isExpectedOtaUserError(error);
    }
    return false;
  }

  /// Public for [SentryConfig.beforeSend] frame matching.
  ///
  /// Kept in the app so polish builds work against the pinned SDK ref that
  /// only classifies "network unreachable" (not errno 9 / 49).
  static bool isWifiUdpTransientSocketError(Object error) {
    if (error is SocketException) {
      final code = error.osError?.errorCode;
      // EBADF=9; EADDRNOTAVAIL=49 (Darwin) / 99 (Linux) / 10049 (Windows).
      if (code == 9 || code == 49 || code == 99 || code == 10049) {
        return true;
      }
    }
    final s = error.toString().toLowerCase();
    return s.contains('bad file descriptor') ||
        s.contains("can't assign requested address") ||
        s.contains('cannot assign requested address') ||
        s.contains('errno = 9') ||
        s.contains('errno = 49') ||
        s.contains('errno = 99') ||
        s.contains('errno = 10049');
  }

  static bool _isWifiUdpOperationalSocketNoise(
    Object error,
    StackTrace? stackTrace,
  ) {
    final unreachable = isDeviceApNetworkUnreachable(error);
    final transient = isWifiUdpTransientSocketError(error);
    if (!unreachable && !transient) return false;

    final hasWifiStack = _traceContainsAny(stackTrace, _wifiUdpStackMarkers);
    if (hasWifiStack) return true;

    // No stack: only drop address-assign / unreachable (common Sentry titles).
    // errno 9 alone is too common — require a Wi‑Fi UDP stack marker.
    final socketLike = error is SocketException ||
        error.toString().contains('SocketException');
    if (!socketLike) return false;
    if (unreachable) return true;
    return _isAddressAssignSocketNoise(error);
  }

  static bool _isAddressAssignSocketNoise(Object error) {
    if (error is SocketException) {
      final code = error.osError?.errorCode;
      if (code == 49 || code == 99 || code == 10049) return true;
    }
    final s = error.toString().toLowerCase();
    return s.contains("can't assign requested address") ||
        s.contains('cannot assign requested address') ||
        s.contains('errno = 49') ||
        s.contains('errno = 99') ||
        s.contains('errno = 10049');
  }

  static bool _traceContainsAny(StackTrace? stackTrace, List<String> markers) {
    final trace = stackTrace?.toString() ?? '';
    if (trace.isEmpty) return false;
    for (final marker in markers) {
      if (trace.contains(marker)) return true;
    }
    return false;
  }

  static bool _isExpectedBleTransferDisconnect(
    Object error,
    StackTrace? stackTrace,
  ) {
    final s = error.toString().toLowerCase();
    final disconnectLike = (error is StateError && s.contains('disconnected')) ||
        s.contains('device disconnected') ||
        s.contains('connection lost') ||
        s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('connection terminated') ||
        s.contains('ble disconnected') ||
        s.contains('bluetooth disconnected') ||
        s.contains('gatt') && s.contains('disconnect');
    if (!disconnectLike) return false;
    return _traceContainsAny(stackTrace, _bleTransferStackMarkers) ||
        s.contains('downloadsessiontolocal');
  }

  static bool _isExpectedAtTimeoutDuringTransfer(
    Object error,
    StackTrace? stackTrace,
  ) {
    if (error is! TimeoutException) return false;
    final s = error.toString();
    if (!s.contains('AT command timeout')) return false;
    return _traceContainsAny(stackTrace, _bleTransferStackMarkers);
  }

  static bool _isExpectedDatabaseClosed(Object error) {
    final s = error.toString().toLowerCase();
    return s.contains('database_closed') ||
        s.contains('database has been closed') ||
        s.contains('database is closed');
  }

  static bool _isExpectedOtaUserError(Object error) {
    final s = error.toString();
    if (s.contains('OtaFirmwareException')) return true;
    if (error is StateError && s.contains('widget disposed')) return true;
    final lower = s.toLowerCase();
    return lower.contains('disconnected') ||
        lower.contains('connection lost') ||
        lower.contains('cancelled') ||
        lower.contains('canceled');
  }

  static bool _isExpectedAuthUserError(Object error) {
    final s = error.toString();
    if (s.contains('VERIFY_REQUIRED')) return true;
    if (s.contains('Email login verify returned no session')) return true;
    if (s.contains('invalid email')) return true;
    if (s.contains('invalid code')) return true;
    if (s.contains('messageKey: errorNetworkTimeout')) return true;
    if (s.contains('messageKey: errorNetworkUnavailable')) return true;
    if (s.contains('Network timeout.')) return true;
    if (s.contains('Network unavailable.')) return true;
    if (error is StateError && s.contains('invalid code')) return true;
    return false;
  }
}
