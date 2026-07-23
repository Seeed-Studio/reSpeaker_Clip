import 'dart:async';
import 'dart:io';

import '../at/at_transport.dart';
import '../models/wifi_hotspot_info.dart';
import '../utils/sdk_log.dart';
import '../session/device_status.dart';
import 'hotspot_connector.dart';
import 'transfer_client.dart';

/// One recording session to download while the device hotspot stays on.
class WifiBatchItem {
  const WifiBatchItem({
    required this.recordingId,
    required this.sessionId,
    required this.sessionDir,
    this.expectedBytes,
    this.startFile,
    this.resumeByteOffset = 0,
  });

  /// Host-side recording id or any stable label used by the caller.
  final String recordingId;

  /// Device-side session id passed to `AT+DOWNLOAD`.
  final String sessionId;

  /// Local directory where the UDP transfer writes part files.
  final String sessionDir;

  /// Optional authoritative size for progress / verification.
  final int? expectedBytes;

  /// Optional resume marker such as `0006.opus`.
  final String? startFile;

  /// Bytes already present locally before this batch item starts.
  final int resumeByteOffset;

  WifiBatchItem copyWith({
    String? recordingId,
    String? sessionId,
    String? sessionDir,
    int? expectedBytes,
    String? startFile,
    int? resumeByteOffset,
  }) {
    return WifiBatchItem(
      recordingId: recordingId ?? this.recordingId,
      sessionId: sessionId ?? this.sessionId,
      sessionDir: sessionDir ?? this.sessionDir,
      expectedBytes: expectedBytes ?? this.expectedBytes,
      startFile: startFile ?? this.startFile,
      resumeByteOffset: resumeByteOffset ?? this.resumeByteOffset,
    );
  }
}

typedef WifiBatchResolveStartFile = Future<String?> Function(
  String recordingId,
  String sessionId,
);

enum WifiBleFallbackReason {
  phoneWifiDisconnected,
  phoneOnOtherWifi,
  transferFailed,
}

enum WifiVerifyFailureKind {
  networkUnreachable,
  timedOut,
}

class WifiVerifyFailure implements Exception {
  const WifiVerifyFailure(this.kind, {required this.hotspot});

  final WifiVerifyFailureKind kind;
  final WifiHotspotInfo hotspot;

  @override
  String toString() => 'Wi-Fi setup: ${kind.name}';
}

class WifiFastSyncBatchResult {
  const WifiFastSyncBatchResult({
    this.succeeded = 0,
    this.failed = 0,
    this.userCancelled = false,
    this.abortedForRecording = false,
    this.bleFallbackReason,
    this.fallbackHotspot,
  });

  final int succeeded;
  final int failed;
  final bool userCancelled;
  final bool abortedForRecording;
  final WifiBleFallbackReason? bleFallbackReason;
  final WifiHotspotInfo? fallbackHotspot;

  bool get shouldFallBackToBle => bleFallbackReason != null;
  bool get isOverallSuccess => succeeded > 0 && failed == 0 && !userCancelled;
}

/// Orchestrates BLE hotspot enable → phone join → UDP session download → cleanup.
///
/// For batch downloads, call [prepare] once, use [transferClient] for each
/// session, then [teardown]. For a single session, [downloadSession] wraps
/// the full flow.
class WifiFastSyncSession {
  final AtTransport at;

  WifiHotspotConnector? _connector;
  WifiTransferClient? _client;
  WifiHotspotInfo? _hotspot;

  WifiFastSyncSession({required this.at});

  /// Active hotspot credentials after [prepare]. `null` before prepare or
  /// after [teardown].
  WifiHotspotInfo? get hotspot => _hotspot;

  /// UDP client valid between [prepare] and [teardown].
  WifiTransferClient? get transferClient => _client;

  /// Underlying BLE hotspot connector (e.g. for [WifiHotspotConnector.connectToHotspot] retries).
  WifiHotspotConnector? get connector => _connector;

  bool get isPrepared => _hotspot != null && _client != null;

  Timer? _forceWifiKeepAlive;
  static const Duration _forceWifiKeepAliveInterval = Duration(seconds: 10);

  void _stopForceWifiKeepAlive() {
    _forceWifiKeepAlive?.cancel();
    _forceWifiKeepAlive = null;
  }

  void _startForceWifiKeepAlive() {
    _stopForceWifiKeepAlive();
    unawaited(forceWifiUsage(true));
    _forceWifiKeepAlive = Timer.periodic(_forceWifiKeepAliveInterval, (_) {
      unawaited(forceWifiUsage(true));
    });
  }

  /// Re-bind app traffic to the device AP (see [WifiHotspotConnector.forceWifiUsage]).
  /// No-op if the connector is not yet created.
  Future<void> forceWifiUsage(bool force) async {
    final connector = _connector;
    if (connector == null) return;
    await connector.forceWifiUsage(force);
  }

  /// Enable device AP and create the UDP client. Does not join phone WiFi.
  Future<WifiHotspotInfo> enableHotspot() async {
    _connector ??= WifiHotspotConnector(at: at);
    SdkLog.i('[WiFi] WifiFastSyncSession: enable AP');
    _hotspot = await _connector!.enable();
    _client = WifiTransferClient(_hotspot!);
    return _hotspot!;
  }

  /// Join the phone to the active device AP. Call after [enableHotspot].
  Future<bool> connectPhone() async {
    final hotspot = _hotspot;
    final connector = _connector;
    if (hotspot == null || connector == null) {
      throw StateError('WifiFastSyncSession: call enableHotspot() first');
    }
    SdkLog.i('[WiFi] WifiFastSyncSession: join phone to "${hotspot.ssid}"');
    return connector.connectToHotspot(hotspot);
  }

  Future<({bool ok, bool networkUnreachable})> _wifiReachabilityProbe() async {
    final client = _client;
    if (client == null) return (ok: false, networkUnreachable: false);
    try {
      final r = await client.pingDetailed();
      if (r.ok) return (ok: true, networkUnreachable: false);
      if (r.networkUnreachable) {
        return (ok: false, networkUnreachable: true);
      }
      await forceWifiUsage(true);
      final r2 = await client.pingDetailed();
      if (r2.ok) return (ok: true, networkUnreachable: false);
      return (ok: false, networkUnreachable: r2.networkUnreachable);
    } catch (_) {
      return (ok: false, networkUnreachable: false);
    }
  }

  Future<bool> _deviceIsRecordingOrPaused() async {
    try {
      final r = await at.send('AT+GSTAT', timeout: const Duration(seconds: 4));
      if (r['ok'] != true) return false;
      final st = DeviceStatus.fromAtReply(r);
      return st.isRecording || st.state == 'paused';
    } catch (_) {
      return false;
    }
  }

  /// Enable device AP and optionally join from the phone. Keeps the session
  /// open for one or more [WifiTransferClient.downloadSession] calls.
  ///
  /// When [requirePhoneJoin] is `false`, a failed join is logged but does not
  /// throw — callers may verify with UDP ping (as the host app batch flow does).
  Future<WifiHotspotInfo> prepare({
    bool joinPhone = true,
    bool requirePhoneJoin = false,
  }) async {
    final hotspot = await enableHotspot();

    if (joinPhone) {
      final joined = await connectPhone();
      if (!joined) {
        final msg = 'Phone failed to join device AP "${hotspot.ssid}"';
        if (requirePhoneJoin) {
          throw StateError(
            '$msg. Check WiFi / Local Network permissions.',
          );
        }
        SdkLog.w('[WiFi] $msg — caller may retry UDP anyway');
      }
    }

    return hotspot;
  }

  /// Disconnect phone WiFi and disable device AP (best-effort).
  Future<void> teardown({
    bool disconnectPhone = true,
    bool disableHotspot = true,
  }) async {
    _stopForceWifiKeepAlive();
    final hotspot = _hotspot;
    final connector = _connector;
    _client?.dispose();
    _client = null;

    if (connector != null) {
      if (hotspot != null && disconnectPhone) {
        await connector.disconnectFromHotspot(hotspot);
      }
      if (disableHotspot) {
        await connector.disable();
      }
    }

    _connector = null;
    _hotspot = null;
  }

  /// Batch download one or more sessions while keeping the device hotspot up.
  ///
  /// This is the SDK version of the app's Wi-Fi fast-sync orchestrator, but
  /// without app DB / merge / notification plumbing.
  Future<WifiFastSyncBatchResult> downloadBatch({
    required List<WifiBatchItem> items,
    WifiBatchResolveStartFile? resolveStartFile,
    bool joinPhone = true,
    bool requirePhoneJoin = false,
    bool disconnectPhoneAfter = true,
    bool disableHotspotAfter = true,
  }) async {
    if (items.isEmpty) {
      return const WifiFastSyncBatchResult();
    }

    var succeeded = 0;
    var failed = 0;
    final userCancelled = false;
    var abortedForRecording = false;
    WifiBleFallbackReason? bleFallbackReason;
    WifiHotspotInfo? batchHotspot;

    try {
      batchHotspot = await enableHotspot();
      final hotspot = batchHotspot;

      var joinOk = true;
      if (joinPhone) {
        joinOk = await connectPhone();
        if (!joinOk && requirePhoneJoin) {
          throw StateError(
            'Phone failed to join device AP "${hotspot.ssid}". '
            'Check WiFi / Local Network permissions.',
          );
        }
      }
      _startForceWifiKeepAlive();

      final udpClient = transferClient;
      if (udpClient == null) {
        throw StateError('WifiFastSyncSession: transfer client unavailable');
      }

      final maxPingAttempts =
          joinOk ? (Platform.isIOS ? 18 : 10) : (Platform.isIOS ? 32 : 20);
      final pingGap = Platform.isIOS
          ? const Duration(seconds: 3)
          : const Duration(seconds: 2);
      var pingOk = false;
      var verifyFailedUnreachable = false;
      for (var attempt = 0; attempt < maxPingAttempts; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(pingGap);
          await forceWifiUsage(true);
        }
        final pingResult = await udpClient.pingDetailed();
        pingOk = pingResult.ok;
        if (pingOk) break;
        if (pingResult.networkUnreachable) {
          verifyFailedUnreachable = true;
          break;
        }
      }
      if (!pingOk) {
        throw WifiVerifyFailure(
          verifyFailedUnreachable
              ? WifiVerifyFailureKind.networkUnreachable
              : WifiVerifyFailureKind.timedOut,
          hotspot: hotspot,
        );
      }

      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        if (await _deviceIsRecordingOrPaused()) {
          abortedForRecording = true;
          break;
        }

        var resolved = item;
        if (resolved.startFile == null && resolveStartFile != null) {
          final startFile =
              await resolveStartFile(item.recordingId, item.sessionId);
          resolved = item.copyWith(startFile: startFile);
        }

        try {
          await udpClient.downloadSession(
            sessionId: resolved.sessionId,
            sessionDir: resolved.sessionDir,
            startFile: resolved.startFile,
          );
          succeeded++;
        } catch (e) {
          failed++;
          if (e is WifiVerifyFailure) {
            bleFallbackReason =
                e.kind == WifiVerifyFailureKind.networkUnreachable
                    ? WifiBleFallbackReason.phoneWifiDisconnected
                    : WifiBleFallbackReason.phoneOnOtherWifi;
            break;
          }
          final probe = await _wifiReachabilityProbe();
          if (!probe.ok) {
            bleFallbackReason = probe.networkUnreachable
                ? WifiBleFallbackReason.phoneWifiDisconnected
                : WifiBleFallbackReason.phoneOnOtherWifi;
            break;
          }
        }
      }

      if (bleFallbackReason == null &&
          succeeded == 0 &&
          failed > 0 &&
          !userCancelled &&
          !abortedForRecording) {
        final probe = await _wifiReachabilityProbe();
        bleFallbackReason = probe.ok
            ? WifiBleFallbackReason.transferFailed
            : (probe.networkUnreachable
                ? WifiBleFallbackReason.phoneWifiDisconnected
                : WifiBleFallbackReason.phoneOnOtherWifi);
      }

      return WifiFastSyncBatchResult(
        succeeded: succeeded,
        failed: failed,
        userCancelled: userCancelled,
        abortedForRecording: abortedForRecording,
        bleFallbackReason: bleFallbackReason,
        fallbackHotspot: batchHotspot,
      );
    } catch (e) {
      if (e is WifiVerifyFailure) {
        bleFallbackReason = e.kind == WifiVerifyFailureKind.networkUnreachable
            ? WifiBleFallbackReason.phoneWifiDisconnected
            : WifiBleFallbackReason.phoneOnOtherWifi;
      }
      return WifiFastSyncBatchResult(
        succeeded: succeeded,
        failed: failed + (succeeded == 0 ? 1 : 0),
        userCancelled: userCancelled,
        abortedForRecording: abortedForRecording,
        bleFallbackReason: bleFallbackReason,
        fallbackHotspot: batchHotspot,
      );
    } finally {
      await teardown(
        disconnectPhone: disconnectPhoneAfter,
        disableHotspot: disableHotspotAfter,
      );
    }
  }

  /// One-shot: [prepare] → UDP download → [teardown].
  Future<int> downloadSession({
    required String sessionId,
    required String sessionDir,
    String? startFile,
    WifiTransferProgress? onFileProgress,
    void Function(int fileIndex, int totalFiles, int overallBytes)?
        onOverallProgress,
    bool Function()? shouldCancel,
    bool disableHotspotAfter = true,
    bool disconnectPhoneAfter = true,
  }) async {
    try {
      await prepare(joinPhone: true, requirePhoneJoin: true);
      SdkLog.i('[WiFi] WifiFastSyncSession: UDP download session=$sessionId');
      final bytes = await _client!.downloadSession(
        sessionId: sessionId,
        sessionDir: sessionDir,
        startFile: startFile,
        onFileProgress: onFileProgress,
        onOverallProgress: onOverallProgress,
        shouldCancel: shouldCancel,
      );
      SdkLog.i('[WiFi] WifiFastSyncSession: done bytes=$bytes');
      return bytes;
    } finally {
      await teardown(
        disconnectPhone: disconnectPhoneAfter,
        disableHotspot: disableHotspotAfter,
      );
    }
  }
}
