// TODO(sdk): migrate Android WiFi scan from deprecated `wifi_iot.loadWifiList`
//            to the dedicated `wifi_scan` plugin (WiFiFlutter ecosystem).
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_iot/wifi_iot.dart';

import '../at/at_transport.dart';
import '../models/wifi_hotspot_info.dart';
import '../utils/sdk_log.dart';

/// WiFi hotspot connection lifecycle manager.
///
/// Orchestrates: BLE AT command → enable hotspot → phone connects to AP → verify → cleanup.
/// BLE connection stays alive as the control channel throughout.
///
/// Platform WiFi connection uses `wifi_iot` plugin on Android and
/// `NEHotspotConfiguration` (via wifi_iot) on iOS.
class WifiHotspotConnector {
  final AtTransport at;

  WifiHotspotConnector({required this.at});

  /// After `AT+WIFI=ON`, firmware may be busy; queries need longer timeout + retries.
  static const Duration _wifiQueryAfterOnTimeout = Duration(seconds: 12);
  static const int _wifiQueryAfterOnMaxAttempts = 3;
  static const Duration _wifiQueryAfterOnRetryGap = Duration(milliseconds: 600);
  static const Duration _wifiSettleAfterOn = Duration(milliseconds: 800);

  /// Phone: give device AP time to beacon before scan/connect (Android).
  static const Duration _androidApSettleBeforeConnect = Duration(seconds: 2);

  /// iOS [NEHotspotConfiguration] often fails with "network not found" if applied before the AP beacons.
  static const Duration _iosApSettleBeforeConnect = Duration(seconds: 3);

  /// After NEHotspot apply, wait before UDP — DHCP + iOS routing; also pairs with [forceWifiUsage] local-network prompt.
  static const Duration _iosPostConnectSettle = Duration(seconds: 5);

  /// Stop the `fileData` notify flood so WiFi AT command replies are not stuck
  /// behind inbound file bytes (same fix as AT+STOP/CANCEL on Android/iOS).
  Future<void> _freeLinkBeforeWifiAt() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    try {
      await at.setFileDataNotify(false, timeout: const Duration(seconds: 2));
      SdkLog.i('[WiFi] disabled fileData notify to free BLE link before WiFi AT');
    } catch (e, st) {
      SdkLog.w('[WiFi] disable fileData notify failed (continuing)', e, st);
    }
  }

  /// Query current WiFi hotspot status from device via BLE.
  Future<WifiHotspotInfo> queryStatus() async {
    final resp = await at.send('AT+WIFI?', timeout: const Duration(seconds: 5));
    if (resp['ok'] != true) {
      throw StateError('AT+WIFI? failed: ${_atWifiFailureDetail(resp)}');
    }
    return WifiHotspotInfo.fromJson(resp);
  }

  /// Best-effort `AT+WIFI?` before [enable]; failures are logged and ignored.
  Future<WifiHotspotInfo?> _queryStatusBeforeEnable() async {
    try {
      SdkLog.i('[WiFi] BLE → AT+WIFI? (query before ON)');
      final resp = await at.send('AT+WIFI?', timeout: const Duration(seconds: 5));
      if (resp['ok'] != true) {
        SdkLog.w('[WiFi] AT+WIFI? not ok: ${_atWifiFailureDetail(resp)}');
        return null;
      }
      final info = WifiHotspotInfo.fromJson(resp);
      SdkLog.i(
        '[WiFi] AT+WIFI? ok — enabled=${info.enabled} ssid=${info.ssid} '
        'ip=${info.ip}:${info.port} pwdLen=${info.password.length}',
      );
      return info;
    } catch (e, st) {
      SdkLog.w('[WiFi] AT+WIFI? exception, will try AT+WIFI=ON', e, st);
      return null;
    }
  }

  /// Enable WiFi hotspot on device via BLE; returns hotspot credentials.
  ///
  /// 1. Optional **`AT+WIFI?` first**: if already `enabled` with valid credentials, skips ON.
  /// 2. **`AT+WIFI=ON`** (then `on`): firmware returns status in the response.
  /// 3. **`AT+WIFI?` again** after ON: prefer this for canonical ssid/password/ip/port; fallback to ON parse if `?` fails but ON was valid.
  ///
  /// If the device replies e.g. `Cannot start WiFi in current state` while `AT+GSTAT`
  /// is `WIFI_SYNC`, we send `AT+WIFI=OFF`, wait until GSTAT leaves `WIFI_SYNC`, then retry ON.
  Future<WifiHotspotInfo> enable() async {
    await _freeLinkBeforeWifiAt();
    final prior = await _queryStatusBeforeEnable();
    if (prior != null && prior.enabled && prior.isValid) {
      SdkLog.i('[WiFi] hotspot already on (AT+WIFI?), skip AT+WIFI=ON');
      return prior;
    }

    SdkLog.i('[WiFi] BLE → AT+WIFI=ON (enable device AP)');
    var resp = await _sendWifiOnPair();
    // A timeout is "no BLE ack yet", NOT a failure — the AP may still be coming
    // up. Only an explicit `ok:false` from the firmware (e.g. "Failed to start
    // WiFi AP" / "Cannot start WiFi in current state") counts as a real failure.
    var onTimedOut = resp['__timeout'] == true;
    if (resp['ok'] != true && !onTimedOut) {
      final m = _atWifiFailureDetail(resp);
      SdkLog.w('[WiFi] first ON attempt not ok (explicit): $m');
      if (_wifiOnFailureMayBeStaleState(m)) {
        SdkLog.i('[WiFi] trying recovery: OFF + wait GSTAT≠WIFI_SYNC, then ON again');
        await _turnOffDeviceWifiAp();
        await _waitGstatLeavesWifiSync(const Duration(seconds: 22));
        resp = await _sendWifiOnPair();
        onTimedOut = resp['__timeout'] == true;
      }
    }
    if (resp['ok'] != true && !onTimedOut) {
      final m = _atWifiFailureDetail(resp);
      SdkLog.e('[WiFi] AT+WIFI=ON failed (firmware reported): $m');
      throw StateError('AT+WIFI=ON failed: $m');
    }
    if (onTimedOut) {
      SdkLog.w(
        '[WiFi] AT+WIFI=ON got no BLE ack in time — not failing; verifying '
        'whether the AP came up via AT+WIFI?',
      );
    }

    // On a timeout we have no usable ON payload; [_hotspotInfoAfterOn] then
    // relies on AT+WIFI? to fetch credentials and confirm the AP is actually up.
    // It only throws if AT+WIFI? also fails to show a valid hotspot.
    final info = await _hotspotInfoAfterOn(resp);
    SdkLog.i(
      '[WiFi] Device AP ready — ssid=${info.ssid} ip=${info.ip} port=${info.port} '
      '(password length=${info.password.length})',
    );
    return info;
  }

  /// Parse ON response, then **`AT+WIFI?`** for authoritative credentials (per firmware flow).
  Future<WifiHotspotInfo> _hotspotInfoAfterOn(Map<String, dynamic> onResp) async {
    final topKeys = onResp.keys.toList();
    final data = onResp['data'];
    final dataKeys = data is Map ? data.keys.toList() : const <Object?>[];
    SdkLog.i('[WiFi] AT+WIFI=ON raw keys top=$topKeys dataKeys=$dataKeys');

    final fromOn = WifiHotspotInfo.fromJson(onResp);
    SdkLog.i(
      '[WiFi] AT+WIFI=ON parsed — enabled=${fromOn.enabled} isValid=${fromOn.isValid} '
      'ssid=${fromOn.ssid} ip=${fromOn.ip}:${fromOn.port} pwdLen=${fromOn.password.length}',
    );

    await Future<void>.delayed(_wifiSettleAfterOn);
    SdkLog.i(
      '[WiFi] BLE → AT+WIFI? (after ON, timeout=${_wifiQueryAfterOnTimeout.inSeconds}s, '
      'attempts=$_wifiQueryAfterOnMaxAttempts)',
    );

    for (var attempt = 1; attempt <= _wifiQueryAfterOnMaxAttempts; attempt++) {
      try {
        final q = await at.send('AT+WIFI?', timeout: _wifiQueryAfterOnTimeout);
        if (q['ok'] == true) {
          final queried = WifiHotspotInfo.fromJson(q);
          SdkLog.i(
            '[WiFi] AT+WIFI? after ON (attempt $attempt) — enabled=${queried.enabled} '
            'isValid=${queried.isValid} ssid=${queried.ssid} ip=${queried.ip}:${queried.port} '
            'pwdLen=${queried.password.length}',
          );
          if (queried.isValid) return queried;
          if (fromOn.isValid) {
            SdkLog.w('[WiFi] AT+WIFI? missing fields, fallback to ON response');
            return fromOn;
          }
          throw StateError('Invalid hotspot: AT+WIFI? missing ssid/password/ip');
        }
        SdkLog.w(
          '[WiFi] AT+WIFI? after ON not ok (attempt $attempt): ${_atWifiFailureDetail(q)}',
        );
      } catch (e, st) {
        if (e is StateError) rethrow;
        SdkLog.w(
          '[WiFi] AT+WIFI? after ON exception (attempt $attempt/$_wifiQueryAfterOnMaxAttempts)',
          e,
          st,
        );
        if (attempt == _wifiQueryAfterOnMaxAttempts) {
          if (fromOn.isValid) {
            SdkLog.w(
              '[WiFi] all AT+WIFI? attempts failed; using ON response (isValid=true)',
            );
            return fromOn;
          }
          throw StateError('AT+WIFI? after ON failed: $e');
        }
      }
      await Future<void>.delayed(_wifiQueryAfterOnRetryGap);
    }

    if (fromOn.isValid) return fromOn;
    throw StateError('AT+WIFI? after ON failed: exhausted retries');
  }

  /// `AT+WIFI=ON` then `AT+WIFI=on` if needed.
  ///
  /// A real failure is the firmware replying `{"ok":false,"msg":"Failed to start
  /// WiFi AP"}`. A BLE *timeout* (no reply within the window) is NOT a failure on
  /// its own: starting the AP can take a while and the firmware often de-
  /// prioritises BLE the moment the radio switches to AP, so the ON ack can be
  /// late or never arrive even though the AP came up. We therefore tag a
  /// timeout-only result with `__timeout` so [enable] can verify via AT+WIFI?
  /// instead of declaring the transfer failed prematurely.
  Future<Map<String, dynamic>> _sendWifiOnPair() async {
    var sawTimeout = false;
    Map<String, dynamic> resp;
    try {
      resp = await at.send('AT+WIFI=ON', timeout: const Duration(seconds: 12));
    } on TimeoutException catch (e) {
      SdkLog.w('[WiFi] AT+WIFI=ON timed out (AP may still be starting): $e');
      sawTimeout = true;
      resp = <String, dynamic>{'ok': false};
    } catch (e) {
      SdkLog.w('[WiFi] AT+WIFI=ON transport error: $e');
      resp = <String, dynamic>{'ok': false};
    }
    if (resp['ok'] == true) return resp;
    // Only re-issue ON when the firmware gave an explicit non-ok reply. After a
    // timeout, re-sending can collide with an in-progress AP bringup — let the
    // caller confirm via AT+WIFI? instead.
    if (!sawTimeout) {
      SdkLog.i('[WiFi] BLE → retry AT+WIFI=on');
      try {
        resp = await at.send('AT+WIFI=on', timeout: const Duration(seconds: 12));
      } on TimeoutException catch (e) {
        SdkLog.w('[WiFi] AT+WIFI=on timed out (AP may still be starting): $e');
        sawTimeout = true;
        resp = <String, dynamic>{'ok': false};
      } catch (e) {
        SdkLog.w('[WiFi] AT+WIFI=on transport error: $e');
        resp = <String, dynamic>{'ok': false};
      }
    }
    if (resp['ok'] != true && sawTimeout) {
      return <String, dynamic>{'ok': false, '__timeout': true};
    }
    return resp;
  }

  static bool _wifiOnFailureMayBeStaleState(String detail) {
    final l = detail.toLowerCase();
    return l.contains('cannot start wifi') ||
        l.contains('current state') ||
        l.contains('invalid transition') ||
        l.contains('wifi_sync');
  }

  Future<void> _turnOffDeviceWifiAp() async {
    for (final cmd in ['AT+WIFI=OFF', 'AT+WIFI=off']) {
      try {
        final r = await at.send(cmd, timeout: const Duration(seconds: 8));
        SdkLog.i('[WiFi] $cmd → ok=${r['ok']}');
      } catch (e) {
        SdkLog.w('[WiFi] $cmd error: $e');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// Poll until firmware leaves [WIFI_SYNC] (seen when AP / sync mode is stuck).
  Future<void> _waitGstatLeavesWifiSync(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      try {
        final g = await at.send('AT+GSTAT', timeout: const Duration(seconds: 4));
        final ok = g['ok'] == true;
        var st = '';
        if (ok) {
          final d = g['data'];
          final m = d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
          st = (m['state'] ?? '').toString().trim();
        }
        final upper = st.toUpperCase();
        SdkLog.i('[WiFi] GSTAT poll state="$st"');
        if (ok && upper != 'WIFI_SYNC') {
          SdkLog.i('[WiFi] left WIFI_SYNC (now "$st") — OK to AT+WIFI=ON');
          return;
        }
      } catch (e) {
        SdkLog.w('[WiFi] GSTAT poll error: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    SdkLog.w('[WiFi] GSTAT still WIFI_SYNC or unreachable after ${timeout.inSeconds}s');
  }

  static String _atWifiFailureDetail(Map<String, dynamic> resp) {
    final msg = resp['msg'] ?? resp['message'] ?? resp['error'];
    if (msg != null && '$msg'.isNotEmpty) return msg.toString();
    final data = resp['data'];
    if (data is Map && data['msg'] != null) return data['msg'].toString();
    return resp.toString();
  }

  /// Disable WiFi hotspot on device via BLE.
  Future<void> disable() async {
    await _freeLinkBeforeWifiAt();
    for (final cmd in ['AT+WIFI=OFF', 'AT+WIFI=off']) {
      try {
        final r = await at.send(cmd, timeout: const Duration(seconds: 8));
        SdkLog.i('[WiFi] $cmd → ok=${r['ok']}');
      } catch (e) {
        SdkLog.w('WifiHotspotConnector $cmd: $e');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  /// Connect phone to the device's WiFi hotspot.
  ///
  /// Uses wifi_iot plugin for cross-platform support.
  /// Returns true if connection was successful.
  Future<bool> connectToHotspot(WifiHotspotInfo info) async {
    final os = Platform.isAndroid
        ? 'Android'
        : Platform.isIOS
            ? 'iOS'
            : Platform.operatingSystem;
    SdkLog.i('[WiFi] Phone → join AP "${info.ssid}" ($os)');
    try {
      await _silentlyDisconnectCurrentWifiBeforeJoin();
      if (Platform.isAndroid) {
        final ok = await _connectAndroid(info);
        if (ok) {
          SdkLog.i('[WiFi] SUCCESS: phone associated with "${info.ssid}" ($os, forceWifiUsage applied)');
        } else {
          SdkLog.w('[WiFi] FAILED: could not join "${info.ssid}" ($os, connect=false)');
        }
        return ok;
      } else if (Platform.isIOS) {
        final ok = await _connectIOS(info);
        if (ok) {
          SdkLog.i('[WiFi] SUCCESS: phone associated with "${info.ssid}" (iOS NEHotspotConfiguration)');
        } else {
          SdkLog.w('[WiFi] FAILED: could not join "${info.ssid}" (iOS connect=false)');
        }
        return ok;
      }
      SdkLog.w('[WiFi] Unsupported platform: $os');
      return false;
    } catch (e, st) {
      SdkLog.w('[WiFi] connectToHotspot exception', e, st);
      return false;
    }
  }

  /// Disconnect phone from device hotspot and restore original WiFi.
  Future<void> disconnectFromHotspot(WifiHotspotInfo info) async {
    try {
      if (Platform.isAndroid) {
        await _disconnectAndroid(info);
      } else if (Platform.isIOS) {
        await _disconnectIOS(info);
      }
    } catch (e) {
      SdkLog.w('WifiHotspotConnector.disconnectFromHotspot failed (non-fatal)', e);
    }
  }

  /// Bind (or unbind) app traffic to the current Wi‑Fi network.
  ///
  /// Android: `ConnectivityManager.bindProcessToNetwork` via wifi_iot — keeps
  /// UDP on the no-internet device AP when the OS would otherwise route via
  /// cellular / another saved Wi‑Fi. Call periodically during a long transfer;
  /// some OEMs silently unbind mid-session.
  ///
  /// iOS: triggers local-network access / routing toward the hotspot interface.
  Future<void> forceWifiUsage(bool force) => _wifiIotForceWifiUsage(force);

  // -- Platform-specific implementations --
  // These use wifi_iot plugin. Import is deferred to avoid compile errors
  // when the plugin is not yet added; actual calls go through the plugin API.

  Future<bool> _connectAndroid(WifiHotspotInfo info) async {
    try {
      await _ensureAndroidWifiPermissions();
      final wifiOn = await WiFiForIoTPlugin.isEnabled();
      SdkLog.i('[WiFi] Android phone Wi‑Fi enabled=$wifiOn (if false, user must turn Wi‑Fi on)');

      await Future<void>.delayed(_androidApSettleBeforeConnect);
      SdkLog.i('[WiFi] Android waited ${_androidApSettleBeforeConnect.inSeconds}s for device AP to appear');

      String? ssidBefore;
      try {
        ssidBefore = await WiFiForIoTPlugin.getSSID();
      } catch (e) {
        SdkLog.w('[WiFi] Android getSSID before connect failed (non-fatal): $e');
      }
      SdkLog.i('[WiFi] Android current SSID before connect (may be null): $ssidBefore');

      final scannedBssid = await _androidScanBssidForSsid(info.ssid);

      Future<void> logSsidAfter(String step) async {
        String? ssidAfter;
        try {
          ssidAfter = await WiFiForIoTPlugin.getSSID();
        } catch (e) {
          SdkLog.w('[WiFi] Android getSSID after $step failed (non-fatal): $e');
        }
        SdkLog.i(
          '[WiFi] Android after $step: getSSID=$ssidAfter matchTarget=${ssidAfter == info.ssid}',
        );
      }

      // Join budget is intentionally short. On API 29+ the join uses a
      // WifiNetworkSpecifier request: if the phone refuses to leave its
      // internet-bearing Wi‑Fi (e.g. a saved office AP with auto-join), the
      // request never resolves and the old 45/60/90s waits just made the UI
      // feel stuck for minutes. Failing fast lets the app fall back to BLE and
      // prompt the user to rejoin the recorder's hotspot manually.

      // 1) Direct specifier (SSID + WPA2 PSK, no internet) — usual path on API 29+.
      SdkLog.i('[WiFi] Android step1 wifi_iot.connect (no BSSID, 20s)');
      var connected = await _wifiIotConnect(
        ssid: info.ssid,
        bssid: null,
        password: info.password,
        joinOnce: true,
        withInternet: false,
        timeoutInSeconds: 20,
      );
      await logSsidAfter('step1');
      if (connected) {
        await _wifiIotForceWifiUsage(true);
        return true;
      }

      // 2) Same with BSSID from scan (some OEMs / dual-band behave better).
      if (scannedBssid != null && scannedBssid.isNotEmpty) {
        SdkLog.i('[WiFi] Android step2 wifi_iot.connect with BSSID=$scannedBssid (20s)');
        connected = await _wifiIotConnect(
          ssid: info.ssid,
          bssid: scannedBssid,
          password: info.password,
          joinOnce: true,
          withInternet: false,
          timeoutInSeconds: 20,
        );
        await logSsidAfter('step2');
        if (connected) {
          await _wifiIotForceWifiUsage(true);
          return true;
        }
      }

      // 3) Scan-based: resolves security + BSSID from [ScanResult] then same native connectTo.
      SdkLog.i('[WiFi] Android step3 wifi_iot.findAndConnect (25s)');
      try {
        connected = await WiFiForIoTPlugin.findAndConnect(
          info.ssid,
          password: info.password,
          joinOnce: true,
          withInternet: false,
          timeoutInSeconds: 25,
        );
      } catch (e, st) {
        SdkLog.w('[WiFi] Android findAndConnect threw', e, st);
        connected = false;
      }
      SdkLog.i('[WiFi] Android findAndConnect raw result=$connected');
      await logSsidAfter('step3');
      if (connected) {
        await _wifiIotForceWifiUsage(true);
        return true;
      }

      SdkLog.w(
        '[WiFi] Android all join strategies failed for "${info.ssid}". '
        'Phone likely stayed on its internet Wi‑Fi. Falling back to BLE; the app '
        'should prompt the user to open Wi‑Fi settings, join the recorder AP, and '
        'disable auto-join for the office network.',
      );
      return false;
    } catch (e, st) {
      SdkLog.w('_connectAndroid failed', e, st);
      return false;
    }
  }

  /// Returns BSSID from last scan if [ssid] is seen (Android only).
  Future<String?> _androidScanBssidForSsid(String ssid) async {
    if (!Platform.isAndroid) return null;
    try {
      SdkLog.i('[WiFi] Android loadWifiList() looking for "$ssid"');
      final list = await WiFiForIoTPlugin.loadWifiList().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          SdkLog.w('[WiFi] Android loadWifiList timeout (15s) → empty');
          return <WifiNetwork>[];
        },
      );
      final labels = list.map((e) => e.ssid).whereType<String>().toList();
      SdkLog.i('[WiFi] Android scan: ${list.length} network(s), ssids=$labels');
      for (final n in list) {
        final s = n.ssid;
        if (s != null && s == ssid) {
          final b = n.bssid;
          SdkLog.i('[WiFi] Android matched AP bssid=$b caps=${n.capabilities} level=${n.level}');
          return b;
        }
      }
      SdkLog.w('[WiFi] Android scan: SSID "$ssid" not found (move closer / wait / check device AP is on)');
    } catch (e, st) {
      SdkLog.w('[WiFi] Android loadWifiList failed', e, st);
    }
    return null;
  }

  Future<void> _disconnectAndroid(WifiHotspotInfo info) async {
    await _wifiIotForceWifiUsage(false);
    await _wifiIotDisconnect();
  }

  /// iOS 14+: [WiFiForIoTPlugin.forceWifiUsage] triggers local-network access (see plugin Swift); needed for UDP to device IP.
  Future<void> _iosPrepareUdpRouting() async {
    if (!Platform.isIOS) return;
    try {
      SdkLog.i(
        '[WiFi] iOS forceWifiUsage(true) — accept Local Network if prompted; '
        'ignore nehelper/SSID errors (iOS often hides SSID from apps)',
      );
      await WiFiForIoTPlugin.forceWifiUsage(true);
    } catch (e, st) {
      SdkLog.w('[WiFi] iOS forceWifiUsage(true) failed (non-fatal)', e, st);
    }
    await Future<void>.delayed(_iosPostConnectSettle);
    SdkLog.i(
      '[WiFi] iOS post-connect settle ${_iosPostConnectSettle.inSeconds}s done (ready for UDP)',
    );
  }

  Future<bool> _connectIOS(WifiHotspotInfo info) async {
    SdkLog.i(
      '[WiFi] iOS wait ${_iosApSettleBeforeConnect.inSeconds}s before NEHotspot '
      '(reduces "network not found" if AP was just started)',
    );
    await Future<void>.delayed(_iosApSettleBeforeConnect);
    // iOS: NEHotspotConfiguration — joinOnce false keeps the profile; retry when AP beacons late.
    var anyAttemptSucceeded = false;
    for (var attempt = 1; attempt <= 3; attempt++) {
      if (attempt > 1) {
        SdkLog.i('[WiFi] iOS NEHotspot retry $attempt/3 after 2s (AP may not have been visible yet)');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final ok = await _wifiIotConnect(
        ssid: info.ssid,
        bssid: null,
        password: info.password,
        joinOnce: false,
        withInternet: false,
        timeoutInSeconds: 60,
      );
      if (ok) anyAttemptSucceeded = true;
      if (ok) break;
    }
    // Always prepare routing + settle: plugin often reports false while user is joining, or SSID reads as nil (Unknown Network).
    await _iosPrepareUdpRouting();
    return anyAttemptSucceeded;
  }

  /// Android 10+ often requires location; Android 13+ may use NEARBY_WIFI_DEVICES.
  Future<void> _ensureAndroidWifiPermissions() async {
    if (!Platform.isAndroid) return;
    final nearBefore = await Permission.nearbyWifiDevices.status;
    final locBefore = await Permission.locationWhenInUse.status;
    SdkLog.i(
      '[WiFi] Android permission BEFORE request: nearbyWifiDevices=$nearBefore '
      'locationWhenInUse=$locBefore',
    );
    final nearby = await Permission.nearbyWifiDevices.request();
    SdkLog.i('[WiFi] Android nearbyWifiDevices after request → $nearby');
    final loc = await Permission.locationWhenInUse.request();
    SdkLog.i('[WiFi] Android locationWhenInUse after request → $loc');
    if (!loc.isGranted && !loc.isLimited) {
      SdkLog.w(
        '[WiFi] Location not granted; joining a third‑party AP may fail until '
        'allowed in system Settings → App → Permissions',
      );
    }
    if (!nearby.isGranted && !nearby.isLimited) {
      SdkLog.w(
        '[WiFi] nearbyWifiDevices not granted (common on API < 33); '
        'relying on location for Wi‑Fi join APIs',
      );
    }
  }

  Future<void> _disconnectIOS(WifiHotspotInfo info) async {
    // wifi_iot iOS native `removeWifiNetwork` expects `prefix_ssid` but Dart passes `ssid` → "No prefix SSID was given!".
    // Skipping avoids noisy logs; user can forget the SSID in Settings → Wi‑Fi if needed.
    SdkLog.i(
      '[WiFi] iOS disconnect: skip removeWifiNetwork (plugin arg mismatch); '
      'forget "${info.ssid}" in Settings if the profile causes issues',
    );
    await _wifiIotForceWifiUsage(false);
  }

  // -- wifi_iot plugin wrappers --

  /// Drop the phone's current Wi‑Fi association before joining the device AP.
  /// Best-effort, no UI; failures are logged and ignored.
  Future<void> _silentlyDisconnectCurrentWifiBeforeJoin() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      String? ssidBefore;
      try {
        ssidBefore = await WiFiForIoTPlugin.getSSID();
      } catch (_) {}
      SdkLog.i(
        '[WiFi] pre-join: silently disconnect current Wi‑Fi (ssid=$ssidBefore)',
      );
      await _wifiIotForceWifiUsage(false);
      await _wifiIotDisconnect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } catch (e, st) {
      SdkLog.w('[WiFi] pre-join disconnect failed (non-fatal)', e, st);
    }
  }

  Future<bool> _wifiIotConnect({
    required String ssid,
    String? bssid,
    required String password,
    required bool joinOnce,
    required bool withInternet,
    required int timeoutInSeconds,
  }) async {
    try {
      SdkLog.i(
        '[WiFi] wifi_iot.connect(ssid=$ssid, bssid=$bssid, joinOnce=$joinOnce, '
        'withInternet=$withInternet, timeout=${timeoutInSeconds}s)',
      );
      final result = await WiFiForIoTPlugin.connect(
        ssid,
        bssid: bssid,
        password: password,
        security: NetworkSecurity.WPA,
        joinOnce: joinOnce,
        withInternet: withInternet,
        timeoutInSeconds: timeoutInSeconds,
      );
      SdkLog.i('[WiFi] wifi_iot.connect raw result=$result');
      return result;
    } catch (e) {
      SdkLog.w('_wifiIotConnect failed', e);
      return false;
    }
  }

  Future<void> _wifiIotForceWifiUsage(bool force) async {
    try {
      await WiFiForIoTPlugin.forceWifiUsage(force);
      SdkLog.i('[WiFi] wifi_iot.forceWifiUsage($force) ok');
    } catch (e) {
      SdkLog.w('forceWifiUsage failed (non-fatal)', e);
    }
  }

  Future<void> _wifiIotDisconnect() async {
    try {
      await WiFiForIoTPlugin.disconnect();
      SdkLog.i('WifiHotspotConnector: disconnected');
    } catch (e) {
      SdkLog.w('disconnect failed (non-fatal)', e);
    }
  }
}

