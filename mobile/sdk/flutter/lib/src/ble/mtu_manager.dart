import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/sdk_log.dart';

/// Tracks the negotiated ATT MTU for a BLE link and, on Android, requests a
/// higher MTU after connection.
class MtuManager {
  final BluetoothDevice device;

  int _mtu = 23;
  StreamSubscription<int>? _sub;

  MtuManager(this.device);

  /// Current negotiated MTU (defaults to the LE minimum 23 before the stack
  /// reports a value).
  int get mtu => _mtu;

  /// Maximum ATT payload size (`mtu - 3 bytes` ATT header). Always >= 1.
  int get payloadSize => (_mtu - 3) > 0 ? (_mtu - 3) : 1;

  /// Start listening to MTU change events from the underlying stack.
  /// Cancels automatically when the device disconnects.
  Future<void> startListening() async {
    await _sub?.cancel();
    _sub = device.mtu.listen((m) {
      _mtu = m;
      final payload = (_mtu - 3) > 0 ? (_mtu - 3) : 1;
      SdkLog.i(
        'BLE MTU stream: mtu=$_mtu attPayload~${payload}B '
        '(${Platform.isIOS ? "iOS" : Platform.isAndroid ? "Android" : Platform.operatingSystem})',
      );
    });
    device.cancelWhenDisconnected(_sub!);
  }

  /// Request a higher ATT MTU on Android (no-op on other platforms).
  ///
  /// Some firmwares drop the link shortly after very large MTU
  /// (e.g. 512) negotiation. The default 185 is a safe trade-off; raise to
  /// 247 on stable devices.
  ///
  /// `flutter_blue_plus`'s `BluetoothDevice.requestMtu` is Android-only and
  /// throws on iOS — iOS negotiates the MTU during service discovery; the
  /// `device.mtu` stream still updates (often 500+).
  ///
  /// [timeoutSeconds] caps how long we wait for the MTU response. Default is
  /// 6 s (the fbp default is 15 s, which is too long when the OS BT stack
  /// is congested — e.g. another device on the same controller is still
  /// streaming notify chunks from a previous transfer the firmware never
  /// got an `AT+CANCEL` for). Whether the negotiation succeeds or times out,
  /// the connection is still usable at the LE-default MTU (23) for AT
  /// commands; the caller can decide whether to keep it or reconnect.
  Future<bool> requestHighMtu({int mtu = 185, int timeoutSeconds = 6}) async {
    if (Platform.isIOS) {
      SdkLog.i(
        'BLE MTU: iOS — flutter_blue_plus does not support requestMtu(); '
        'using CoreBluetooth-negotiated MTU',
      );
      return true;
    }
    if (!Platform.isAndroid) {
      SdkLog.i(
        'BLE MTU: requestMtu($mtu) skipped on ${Platform.operatingSystem}',
      );
      return true;
    }
    try {
      SdkLog.i(
          'BLE MTU: requesting $mtu (Android, timeout=${timeoutSeconds}s)');
      await device.requestMtu(mtu, timeout: timeoutSeconds);
      return true;
    } catch (e, st) {
      SdkLog.w('requestMtu failed (continuing at LE default MTU 23)', e, st);
      return false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}
