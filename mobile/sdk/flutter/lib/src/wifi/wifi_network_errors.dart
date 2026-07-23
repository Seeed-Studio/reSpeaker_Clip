import 'dart:io';

const _wifiUdpStackMarkers = <String>[
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

/// Heuristic: phone cannot route UDP to the device AP (Wi‑Fi off, wrong network, etc.).
/// Used to fail fast instead of retrying ping for ~60s when the path is clearly dead.
bool isDeviceApNetworkUnreachable(Object error) {
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    // ENETUNREACH / ENETDOWN / EHOSTUNREACH (Linux/Android/iOS vary).
    if (code == 51 || code == 65 || code == 100 || code == 101 || code == 113) {
      return true;
    }
    final msg = error.message.toLowerCase();
    if (msg.contains('network is unreachable') ||
        msg.contains('network is down') ||
        msg.contains('no route to host') ||
        msg.contains('host is down') ||
        msg.contains('machine is not on the network')) {
      return true;
    }
  }
  final s = error.toString().toLowerCase();
  return s.contains('network is unreachable') ||
      s.contains('network is down') ||
      s.contains('machine is not on the network') ||
      s.contains('errno = 101') ||
      s.contains('errno = 100') ||
      s.contains('errno = 64');
}

/// Transient local socket failures during Wi‑Fi AP UDP (not product bugs).
///
/// - errno 49 / EADDRNOTAVAIL: bind/send while the AP iface address is gone
///   ("Can't assign requested address") — common on iOS during hotspot handoff.
/// - errno 9 / EBADF: send/recv/close after the datagram socket was already
///   closed (cancel, leave AP, dispose race).
bool isWifiUdpTransientSocketError(Object error) {
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

bool _isWifiUdpExpectedSocketError(Object error) {
  return isDeviceApNetworkUnreachable(error) ||
      isWifiUdpTransientSocketError(error);
}

/// True when a Wi‑Fi AP UDP socket failure is an expected operational outcome
/// (left hotspot, iface gone, socket already closed). Should not be crash reports.
bool isWifiApReachabilitySocketNoise(
  Object error, {
  StackTrace? stackTrace,
}) {
  if (!_isWifiUdpExpectedSocketError(error)) return false;
  final trace = stackTrace?.toString() ?? '';
  if (trace.isEmpty) {
    // Message-only / beforeSend summary paths: only treat SocketException-like
    // strings as noise when they match the expected patterns above.
    return error is SocketException ||
        error.toString().contains('SocketException');
  }
  return _stackLooksLikeWifiUdpProbe(trace);
}

bool _stackLooksLikeWifiUdpProbe(String trace) {
  for (final marker in _wifiUdpStackMarkers) {
    if (trace.contains(marker)) return true;
  }
  return false;
}
