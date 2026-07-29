import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../utils/crc32.dart';
import '../utils/sdk_log.dart';
import 'wifi_network_errors.dart';

/// CLIP UDP transport on device WiFi AP (aligned with `py_test/clip/wifi.py`).
///
/// Frame types (binary) vs plain text AT commands on the same port:
/// - **Client → device**: `AT+...\n` for commands; `0x03` FILE_ACK; `0x30` HEARTBEAT
/// - **Device → client**: `0x20` AT_RESP (length-prefixed JSON); `0x10/0x01/0x11/0x12` file transfer; `0x30` HEARTBEAT
const int udpFrameData = 0x01;
const int udpFrameFileAck = 0x03;
const int udpFrameFileStart = 0x10;
const int udpFrameFileEnd = 0x11;
const int udpFrameTransferDone = 0x12;
const int udpFrameAtResp = 0x20;
const int udpFrameHeartbeat = 0x30;

const int _udpDataHeaderSize = 9; // type(1)+seq(2)+len(2)+crc32(4)

String _normalizeAtCommand(String cmd) {
  var line = cmd.trim();
  if (line.isEmpty) return line;
  if (!line.toUpperCase().startsWith('AT')) {
    line = 'AT+$line';
  }
  return line;
}

/// UDP sync client: AT over `AT+…\\n`, file transfer over binary frames (port 8089).
class ClipUdpSyncClient {
  ClipUdpSyncClient({this.receiveTimeout = const Duration(seconds: 5)});

  final Duration receiveTimeout;

  RawDatagramSocket? _socket;
  InternetAddress? _host;
  int _port = 8089;
  StreamSubscription<RawSocketEvent>? _sub;

  /// Incoming datagrams (never drop between recv iterations).
  ///
  /// A [StreamController.broadcast] + ephemeral `.first` subscriptions **drops**
  /// `add()` when no listener is attached — under Wi‑Fi bursts that loses low seq.
  final ListQueue<Uint8List> _rxQueue = ListQueue<Uint8List>();
  Completer<void>? _rxSignal;

  /// Frames that arrive while [sendAtCommand] is waiting for `AT_RESP` (e.g. file
  /// data right after `AT+DOWNLOAD`) — must not be dropped.
  final List<Uint8List> _earlyRxReplay = [];

  Timer? _heartbeatTimer;
  bool _connected = false;
  bool _lastFailureUnreachable = false;

  /// Total datagrams pulled off the socket since [connect] — used with the
  /// kernel drop counter to quantify burst packet loss during a download.
  int _rxDatagramCount = 0;

  bool get isConnected => _connected;

  /// Set when [connect] or [_send] failed with a routing error (phone off AP).
  bool get lastFailureUnreachable => _lastFailureUnreachable;

  static bool _isRfc1918Ipv4(InternetAddress a) {
    if (a.type != InternetAddressType.IPv4) return false;
    final b = a.rawAddress;
    if (b.length < 4) return false;
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    return false;
  }

  /// iOS: when Wi‑Fi has "no internet", the OS may route datagrams via cellular unless we bind to the AP interface.
  static Future<InternetAddress?> _iosBindAddressForTargetHost(String hostStr) async {
    if (!Platform.isIOS) return null;
    try {
      final target = InternetAddress(hostStr);
      if (target.type != InternetAddressType.IPv4) return null;
      final t = target.rawAddress;
      if (t.length < 4) return null;

      final ifaces = await NetworkInterface.list(includeLinkLocal: false);
      // Prefer same /24 as device IP (Clip AP is usually 192.168.4.1, phone 192.168.4.x).
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          if (a.type != InternetAddressType.IPv4 || a.isLoopback) continue;
          final b = a.rawAddress;
          if (b.length >= 4 && b[0] == t[0] && b[1] == t[1] && b[2] == t[2]) {
            SdkLog.i(
              'ClipUdpSync: iOS pick bind $a (${iface.name}) same /24 as $hostStr',
            );
            return a;
          }
        }
      }
      // Then any private IPv4 on en0 (Wi‑Fi on iPhone).
      for (final iface in ifaces) {
        if (iface.name != 'en0') continue;
        for (final a in iface.addresses) {
          if (a.type == InternetAddressType.IPv4 && _isRfc1918Ipv4(a)) {
            SdkLog.i('ClipUdpSync: iOS pick bind $a (en0 private)');
            return a;
          }
        }
      }
      // Last: any RFC1918 on any interface (e.g. rare en1 layouts).
      for (final iface in ifaces) {
        for (final a in iface.addresses) {
          if (a.type == InternetAddressType.IPv4 && _isRfc1918Ipv4(a)) {
            SdkLog.i('ClipUdpSync: iOS pick bind $a (${iface.name} private)');
            return a;
          }
        }
      }
    } catch (e, st) {
      SdkLog.w('ClipUdpSync: iOS bind address lookup failed', e, st);
    }
    return null;
  }

  Future<void> connect(String host, int port) async {
    if (_connected) return;
    _lastFailureUnreachable = false;
    // Drop a partial bind from a previous failed wake/send (common when the phone
    // has not joined the device AP yet).
    if (_socket != null) {
      dispose();
    }
    _earlyRxReplay.clear();
    _rxQueue.clear();
    _rxSignal = null;
    _rxDatagramCount = 0;
    _host = InternetAddress(host);
    _port = port;

    if (Platform.isIOS) {
      final picked = await _iosBindAddressForTargetHost(host);
      if (picked != null) {
        try {
          _socket = await RawDatagramSocket.bind(picked, 0);
          SdkLog.i('ClipUdpSync: UDP bound to $picked → $host:$port');
        } catch (e, st) {
          SdkLog.w(
            'ClipUdpSync: bind to $picked failed, using anyIPv4 (UDP may misroute)',
            e,
            st,
          );
          _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        }
      } else {
        SdkLog.w(
          'ClipUdpSync: iOS no suitable bind address for $host — using anyIPv4; '
          'if verify hangs, check Local Network permission and Wi‑Fi "no internet" routing',
        );
        _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }
    } else {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _tryEnlargeUdpReceiveBuffer(_socket!);
    _sub = _socket!.listen((event) {
      try {
        if (event == RawSocketEvent.read) {
          final s = _socket!;
          while (true) {
            final dg = s.receive();
            if (dg == null) break;
            if (dg.data.isNotEmpty) {
              _rxDatagramCount++;
              _enqueueRx(Uint8List.fromList(dg.data));
            }
          }
        }
      } catch (e, st) {
        SdkLog.w('ClipUdpSync: UDP recv error', e, st);
      }
    });
    try {
      _socket!.send(const [0x0a], _host!, _port); // '\n' wake-up, same as Python
    } catch (e, st) {
      _lastFailureUnreachable = isDeviceApNetworkUnreachable(e);
      SdkLog.w(
        'ClipUdpSync: UDP wake send failed ($host:$port — phone may not be on device AP yet)',
        e,
        st,
      );
      dispose();
      return;
    }
    _connected = true;
    _startHeartbeat();
  }

  /// Idle cadence: just enough to prove the session is still alive.
  static const Duration _idleHeartbeatInterval = Duration(seconds: 5);

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_idleHeartbeatInterval, (_) {
      if (!_connected || _socket == null || _host == null) return;
      final ts = DateTime.now().millisecondsSinceEpoch & 0xffffffff;
      final bd = ByteData(5)
        ..setUint8(0, udpFrameHeartbeat)
        ..setUint32(1, ts, Endian.little);
      try {
        _socket!.send(bd.buffer.asUint8List(0, 5), _host!, _port);
      } catch (_) {}
    });
  }

  /// Silence the uplink while a bulk download is in flight: every frame we send
  /// contends with the device's TX on a half-duplex link, and the firmware has
  /// to service the RX path mid-burst.
  void _pauseHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _resumeHeartbeat() {
    if (_connected) _startHeartbeat();
  }

  void dispose() {
    _connected = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    _earlyRxReplay.clear();
    _rxQueue.clear();
    _rxSignal = null;
  }

  void _enqueueRx(Uint8List data) {
    _rxQueue.addLast(data);
    final s = _rxSignal;
    if (s != null && !s.isCompleted) {
      s.complete();
    }
    _rxSignal = null;
  }

  static bool _isFileTransferFrame(Uint8List data) {
    if (data.isEmpty) return false;
    final t = data[0];
    return t == udpFrameData ||
        t == udpFrameFileStart ||
        t == udpFrameFileEnd ||
        t == udpFrameTransferDone;
  }

  /// Best-effort larger kernel RX queue to reduce bursty drops on Wi‑Fi.
  ///
  /// Sets SO_RCVBUF then **reads the granted value back** and logs it. On
  /// Android/Linux the request is silently clamped to `net.core.rmem_max`
  /// (commonly ~208 KB), and an app cannot exceed it without `SO_RCVBUFFORCE`
  /// (needs CAP_NET_ADMIN). A small granted buffer is a prime suspect for the
  /// burst UDP loss seen on some phones, so surface it explicitly.
  static void _tryEnlargeUdpReceiveBuffer(RawDatagramSocket socket) {
    // SO_RCVBUF: 8 on Linux/Android, 0x1002 (SO_RCVBUF) on Darwin.
    final int optRcvBuf = (Platform.isIOS || Platform.isMacOS) ? 0x1002 : 8;
    const requested = 8 * 1024 * 1024;
    try {
      socket.setRawOption(RawSocketOption.fromInt(
        RawSocketOption.levelSocket,
        optRcvBuf,
        requested,
      ));
    } catch (e) {
      SdkLog.w('ClipUdpSync: set SO_RCVBUF failed: $e');
    }
    var granted = 0;
    try {
      final raw = socket.getRawOption(RawSocketOption(
        RawSocketOption.levelSocket,
        optRcvBuf,
        Uint8List(4),
      ));
      if (raw.length >= 4) {
        granted = ByteData.sublistView(raw).getInt32(0, Endian.host);
      }
    } catch (e) {
      SdkLog.w('ClipUdpSync: get SO_RCVBUF failed: $e');
    }
    // Linux/Android report 2× the usable size (kernel bookkeeping overhead).
    final usable =
        (Platform.isAndroid || Platform.isLinux) ? granted ~/ 2 : granted;
    final clamped = granted > 0 && granted < requested;
    SdkLog.i(
      'ClipUdpSync: SO_RCVBUF requested=${requested ~/ 1024}KB '
      'granted=${granted ~/ 1024}KB (~${usable ~/ 1024}KB usable)'
      '${clamped ? ' — CLAMPED by net.core.rmem_max; burst UDP drops likely' : ''}',
    );
  }

  /// Linux desktop only: this socket's kernel UDP drop counter, read from the
  /// last column of `/proc/net/udp[6]` for our bound local port.
  ///
  /// Android apps are blocked from these proc files by SELinux, and probing
  /// them emits noisy `avc: denied` lines, so Android intentionally returns -1.
  ///
  /// A rising counter during a download means datagrams reached the phone but
  /// the kernel discarded them because the receive buffer overflowed (the app
  /// isolate could not drain fast enough) — i.e. NOT over-the-air RF loss.
  int _readKernelUdpDrops() {
    if (!Platform.isLinux) return -1;
    final port = _socket?.port;
    if (port == null) return -1;
    final portHex = port.toRadixString(16).toUpperCase().padLeft(4, '0');
    for (final path in const ['/proc/net/udp', '/proc/net/udp6']) {
      try {
        final f = File(path);
        if (!f.existsSync()) continue;
        for (final line in f.readAsLinesSync()) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length < 13) continue;
          final local = parts[1]; // hex "IP:PORT"
          final colon = local.lastIndexOf(':');
          if (colon < 0) continue;
          if (local.substring(colon + 1) != portHex) continue;
          return int.tryParse(parts.last) ?? -1;
        }
      } catch (_) {}
    }
    return -1;
  }

  Future<Uint8List?> _recvOneUntil(DateTime deadline) async {
    if (_earlyRxReplay.isNotEmpty) {
      return _earlyRxReplay.removeAt(0);
    }
    while (DateTime.now().isBefore(deadline)) {
      if (_rxQueue.isNotEmpty) {
        return _rxQueue.removeFirst();
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final slice = remaining > const Duration(milliseconds: 500)
          ? const Duration(milliseconds: 500)
          : remaining;
      final mySignal = Completer<void>();
      _rxSignal = mySignal;
      try {
        await mySignal.future.timeout(slice);
      } on TimeoutException {
        if (identical(_rxSignal, mySignal)) {
          _rxSignal = null;
        }
      }
    }
    return _rxQueue.isNotEmpty ? _rxQueue.removeFirst() : null;
  }

  bool _send(Uint8List data) {
    final s = _socket;
    final h = _host;
    if (s == null || h == null || !_connected) {
      SdkLog.w('ClipUdpSync: UDP send skipped (not connected)');
      return false;
    }
    try {
      s.send(data, h, _port);
      return true;
    } catch (e, st) {
      if (isDeviceApNetworkUnreachable(e)) {
        _lastFailureUnreachable = true;
        _connected = false;
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
      }
      SdkLog.w(
        'ClipUdpSync: UDP send failed (${h.address}:$_port)',
        e,
        st,
      );
      return false;
    }
  }

  /// Send plain AT command, wait for [udpFrameAtResp] with JSON body.
  Future<Map<String, dynamic>> sendAtCommand(
    String command, {
    Duration? timeout,
    int maxSkips = 64,
  }) async {
    final line = _normalizeAtCommand(command);
    if (!_send(Uint8List.fromList(utf8.encode('$line\n')))) {
      return <String, dynamic>{'ok': false, 'error': 'UDP send failed'};
    }

    final deadline = DateTime.now().add(timeout ?? receiveTimeout);
    var skips = 0;
    while (DateTime.now().isBefore(deadline) && skips < maxSkips) {
      final data = await _recvOneUntil(deadline);
      if (data == null || data.isEmpty) continue;
      final t = data[0];
      if (t == udpFrameHeartbeat) {
        skips++;
        continue;
      }
      if (t == udpFrameAtResp && data.length >= 3) {
        final len = data[1] | (data[2] << 8);
        if (data.length >= 3 + len) {
          final text =
              utf8.decode(data.sublist(3, 3 + len), allowMalformed: true);
          try {
            final obj = jsonDecode(text);
            if (obj is Map<String, dynamic>) return obj;
            return <String, dynamic>{'ok': true, 'raw': obj};
          } catch (_) {
            return <String, dynamic>{'ok': true, 'raw': text};
          }
        }
      }
      if (_isFileTransferFrame(data)) {
        _earlyRxReplay.add(Uint8List.fromList(data));
        skips++;
        continue;
      }
      skips++;
    }
    return <String, dynamic>{'ok': false, 'error': 'No UDP AT response'};
  }

  void _sendFileAck(bool ok) {
    final sent =
        _send(Uint8List.fromList([udpFrameFileAck, ok ? 0x00 : 0x01]));
    SdkLog.i(
      'ClipUdpSync: FILE_ACK ${ok ? 'ACK' : 'NACK'} sent=$sent',
    );
    if (!sent) {
      SdkLog.w('ClipUdpSync: FILE_ACK send failed');
    }
  }

  /// Reachability check after joining AP (same socket as file sync).
  Future<bool> ping() async {
    try {
      final r =
          await sendAtCommand('AT+GSTAT', timeout: const Duration(seconds: 3));
      return r['ok'] == true;
    } catch (e, st) {
      SdkLog.w('ClipUdpSync: ping failed', e, st);
      return false;
    }
  }

  /// Download one session over UDP (aligned with `WiFiSync.download_session`).
  ///
  /// Returns total payload bytes received, or 0 on failure / cancel.
  Future<int> downloadSession({
    required String sessionId,
    required String sessionDir,
    String? startFile,
    bool Function()? shouldCancel,
    void Function(String currentFile, int filesDone, int totalFiles,
            int receivedBytes, int? totalBytes)?
        onProgress,
  }) async {
    final dir = Directory(sessionDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    var totalFiles = 0;
    var totalBytes = 0;
    try {
      final infoResp = await sendAtCommand('AT+LIST=$sessionId',
          timeout: const Duration(seconds: 8));
      if (infoResp['ok'] == true) {
        final data = infoResp['data'];
        if (data is Map) {
          totalFiles = _parseInt(data['files'] ?? data['total']) ?? 0;
          totalBytes = _parseInt(data['size']) ?? 0;
        }
      }
    } catch (_) {}

    final dlCmd = (startFile != null && startFile.trim().isNotEmpty)
        ? 'AT+DOWNLOAD=$sessionId:${startFile.trim()}'
        : 'AT+DOWNLOAD=$sessionId';
    // Log the resume marker explicitly so that BLE/Wi‑Fi handoff regressions
    // (firmware "still sending 0001.opus" after a Wi‑Fi switch) can be diagnosed
    // from the app log without firmware-side traces.
    SdkLog.i('ClipUdpSync: send $dlCmd');
    var dlResp =
        await sendAtCommand(dlCmd, timeout: const Duration(seconds: 15));
    // Self-heal a common race: while we were bringing up the AP, a BLE caller
    // (e.g. an auto-resume queued on `_bleDownloadExclusiveChain`) may have re-armed
    // a BLE `AT+DOWNLOAD`. Firmware then rejects the UDP `AT+DOWNLOAD` with
    // "transfer already in progress" / "busy". Send `AT+CANCEL` once to clear the
    // stale BLE leg and try again before giving up.
    if (dlResp['ok'] != true) {
      final errStr = (dlResp['error'] ?? dlResp['msg'] ?? '')
          .toString()
          .toLowerCase();
      final looksBusy = errStr.contains('already in progress') ||
          errStr.contains('busy') ||
          errStr.contains('in progress') ||
          errStr.contains('transfer already');
      if (looksBusy) {
        SdkLog.w(
          'ClipUdpSync: DOWNLOAD rejected as busy — sending AT+CANCEL and retrying once',
        );
        try {
          await sendAtCommand('AT+CANCEL',
              timeout: const Duration(seconds: 3));
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 600));
        dlResp =
            await sendAtCommand(dlCmd, timeout: const Duration(seconds: 15));
      }
    }
    if (dlResp['ok'] != true) {
      SdkLog.w(
        'ClipUdpSync: DOWNLOAD failed: ${dlResp['error'] ?? dlResp['msg'] ?? 'unknown'}',
      );
      return 0;
    }
    final dData = dlResp['data'];
    if (dData is Map) {
      final df = _parseInt(dData['files'] ?? dData['total']);
      final db = _parseInt(dData['bytes'] ?? dData['size']);
      if (df != null && df > 0) totalFiles = df;
      if (db != null && db > 0) totalBytes = db;
    }
    if (totalFiles == 0) {
      SdkLog.w('ClipUdpSync: session $sessionId has no files');
      return 0;
    }

    // Serialize slice writes. Previously [unawaited(writeAsBytes)] let TRANSFER_DONE exit
    // before the last .opus hit disk — merge saw partial/empty files, DB could stay stuck
    // at transferring / wrong progress while Wi‑Fi batch still reported success.
    var diskWriteChain = Future<void>.value();

    _pauseHeartbeat();
    try {
      String? currentName;
      var declaredFileSize = 0;

      /// Drop DATA with seq above this — stale datagrams from a prior retransmit
      /// would otherwise sit in [pendingDataBySeq] and corrupt assembly.
      var maxDataSeqInclusive = 0;
      var expectedDataFrames = 0;
      final currentData = BytesBuilder(copy: false);
      var fileCrc = 0;
      var nextExpectedSeq = 0;
      final pendingDataBySeq = <int, Uint8List>{};
      var filesReceived = 0;
      var receivedBytes = 0;
      var lastProgressAt = DateTime.now();

      // Fail-fast guard. The firmware auto-retries a failed file by re-sending
      // FILE_START from seq 0. In a lossy/congested RF environment a large file
      // (no byte-offset resume in the protocol) can never complete, so it would
      // otherwise burn ~12 full-file retries (~1 min) before TRANSFER_DONE
      // file_count=0. Bail after a few consecutive same-file NACKs so the caller
      // can fall back to the reliable BLE path instead of stalling.
      // Match the firmware's file-level retry budget. Four attempts was too
      // aggressive for phones with occasional transient UDP loss and caused
      // the app to send AT+CANCEL while firmware still had retries available.
      // Severe-loss devices may still exhaust all ten and fall back to BLE.
      const maxConsecutiveFileNacks = 10;
      var consecutiveFileNacks = 0;
      String? lastNackFile;

      // Per-file reassembly counters. We MUST NOT log per datagram in the hot
      // path: every `SdkLog.d` is bridged to the app's PrettyPrinter logger
      // (multi-line boxed output to logcat). At hundreds of packets/sec that
      // synchronous formatting starves this isolate's receive loop, the kernel
      // UDP buffer overflows and packets are dropped — a single early loss with
      // no retransmit then wedges assembly forever (e.g. stuck at next=17).
      // Tally instead and emit one summary per file.
      var outOfOrderHolds = 0;
      var duplicateSkips = 0;
      var staleDrops = 0;
      var malformedDataDrops = 0;
      var dataCrcDrops = 0;
      // Per-file snapshots to attribute loss: datagrams delivered to us and the
      // kernel drop counter at FILE_START, compared again at FILE_END.
      var fileRxBaseline = 0;
      var fileKdropBaseline = -1;

      void resetFileAssemblyState() {
        nextExpectedSeq = 0;
        pendingDataBySeq.clear();
      }

      String missingSeqSummary() {
        if (expectedDataFrames <= 0) return 'none';
        final ranges = <String>[];
        var missingCount = 0;
        int? rangeStart;
        var previous = -1;
        for (var seq = nextExpectedSeq; seq < expectedDataFrames; seq++) {
          if (pendingDataBySeq.containsKey(seq)) continue;
          missingCount++;
          if (rangeStart == null) {
            rangeStart = seq;
          } else if (seq != previous + 1) {
            if (ranges.length < 8) {
              ranges.add(rangeStart == previous
                  ? '$rangeStart'
                  : '$rangeStart-$previous');
            }
            rangeStart = seq;
          }
          previous = seq;
        }
        if (rangeStart != null && ranges.length < 8) {
          ranges.add(
              rangeStart == previous ? '$rangeStart' : '$rangeStart-$previous');
        }
        return 'count=$missingCount ranges=${ranges.join(',')}'
            '${missingCount > 0 && ranges.length >= 8 ? ',…' : ''}';
      }

      void appendVerifiedPayload(Uint8List payload) {
        currentData.add(payload);
        fileCrc = crc32Ieee(payload, fileCrc);
        receivedBytes += payload.length;
      }

      void ingestDataFrame(Uint8List data) {
        final cn = currentName;
        if (cn == null) return;
        if (data.length < _udpDataHeaderSize) {
          malformedDataDrops++;
          return;
        }
        final dataLen = data[3] | (data[4] << 8);
        if (data.length < _udpDataHeaderSize + dataLen) {
          malformedDataDrops++;
          return;
        }
        final recvCrc =
            ByteData.sublistView(data, 5, 9).getUint32(0, Endian.little);
        final payload =
            data.sublist(_udpDataHeaderSize, _udpDataHeaderSize + dataLen);
        final calc = crc32Ieee(payload);
        if (calc != recvCrc) {
          dataCrcDrops++;
          return;
        }
        final seq = (data[1] | (data[2] << 8)) & 0xffff;
        if (seq > maxDataSeqInclusive) {
          staleDrops++;
          lastProgressAt = DateTime.now();
          return;
        }
        if (seq < nextExpectedSeq) {
          duplicateSkips++;
          lastProgressAt = DateTime.now();
          return;
        }
        if (seq > nextExpectedSeq) {
          pendingDataBySeq[seq] = Uint8List.fromList(payload);
          outOfOrderHolds++;
          lastProgressAt = DateTime.now();
          return;
        }
        appendVerifiedPayload(payload);
        nextExpectedSeq++;
        while (pendingDataBySeq.containsKey(nextExpectedSeq)) {
          final p = pendingDataBySeq.remove(nextExpectedSeq)!;
          appendVerifiedPayload(p);
          nextExpectedSeq++;
        }
        lastProgressAt = DateTime.now();
        onProgress?.call(cn, filesReceived, totalFiles, receivedBytes,
            totalBytes > 0 ? totalBytes : null);
      }

      Future<Uint8List?> nextFrame() async {
        final deadline = DateTime.now().add(receiveTimeout);
        while (DateTime.now().isBefore(deadline)) {
          if (shouldCancel?.call() == true) return null;
          final d = await _recvOneUntil(deadline);
          if (d != null) return d;
        }
        return null;
      }

      while (true) {
        if (shouldCancel?.call() == true) {
          await sendAtCommand('AT+CANCEL', timeout: const Duration(seconds: 2));
          return receivedBytes;
        }

        final data = await nextFrame();
        if (data == null || data.isEmpty) {
          if (DateTime.now().difference(lastProgressAt) >
              const Duration(seconds: 60)) {
            SdkLog.w('ClipUdpSync: stall timeout');
            return receivedBytes;
          }
          continue;
        }

        final frameType = data[0];
        if (frameType == udpFrameHeartbeat) continue;
        if (frameType == udpFrameAtResp) {
          if (data.length >= 3) {
            final len = data[1] | (data[2] << 8);
            if (data.length >= 3 + len) {
              SdkLog.d(
                  'ClipUdpSync AT_RESP: ${utf8.decode(data.sublist(3, 3 + len), allowMalformed: true)}');
            }
          }
          continue;
        }

        if (frameType == udpFrameFileStart) {
          if (data.length < 3) continue;
          final fnLen = data[1];
          if (data.length < 2 + fnLen + 4) continue;
          final name =
              utf8.decode(data.sublist(2, 2 + fnLen), allowMalformed: true);
          currentName = name;
          final bd = ByteData.sublistView(data, 2 + fnLen, 2 + fnLen + 4);
          final fileSize = bd.getUint32(0, Endian.little);
          declaredFileSize = fileSize;
          final chunkSlots = fileSize == 0 ? 0 : (fileSize + 1023) ~/ 1024;
          expectedDataFrames = chunkSlots;
          maxDataSeqInclusive = fileSize == 0 ? 8 : chunkSlots + 47;
          currentData.clear();
          fileCrc = 0;
          resetFileAssemblyState();
          outOfOrderHolds = 0;
          duplicateSkips = 0;
          staleDrops = 0;
          malformedDataDrops = 0;
          dataCrcDrops = 0;
          onProgress?.call(name, filesReceived, totalFiles, receivedBytes,
              totalBytes > 0 ? totalBytes : null);
          SdkLog.i('ClipUdpSync FILE_START $name ($fileSize bytes)');
          fileRxBaseline = _rxDatagramCount;
          fileKdropBaseline = _readKernelUdpDrops();
          lastProgressAt = DateTime.now();
          continue;
        }

        if (frameType == udpFrameData) {
          // Match `py_test/clip/wifi.py`: discard DATA until FILE_START.
          // A bounded orphan FIFO could evict low seq (e.g. 0..N) before FILE_START
          // and leave only high seq, causing perpetual out-of-order (next=0, pending high).
          if (currentName == null) continue;
          ingestDataFrame(data);
          continue;
        }

        if (frameType == udpFrameFileEnd) {
          if (data.length < 5) continue;
          final serverCrc =
              ByteData.sublistView(data, 1, 5).getUint32(0, Endian.little);
          final cn = currentName;
          var crcOk =
              (fileCrc & 0xffffffff) == (serverCrc & 0xffffffff);

          // Some phone Wi-Fi drivers deliver the final DATA datagrams after
          // FILE_END. Do not NACK immediately: only for an incomplete/CRC-bad
          // file, allow a short grace window to consume late DATA. Healthy
          // files take this path zero times and have no added latency.
          if (cn != null &&
              (currentData.length != declaredFileSize || !crcOk)) {
            const grace = Duration(milliseconds: 500);
            final graceDeadline = DateTime.now().add(grace);
            final beforeFrames =
                nextExpectedSeq + pendingDataBySeq.length;
            final beforeMissing = missingSeqSummary();
            final deferred = <Uint8List>[];
            SdkLog.i(
              'ClipUdpSync FILE_END grace start ${grace.inMilliseconds}ms '
              'frames=$beforeFrames/$expectedDataFrames '
              'missing[$beforeMissing]',
            );
            while (DateTime.now().isBefore(graceDeadline)) {
              if (shouldCancel?.call() == true) break;
              final late = await _recvOneUntil(graceDeadline);
              if (late == null) break;
              if (late.isEmpty) continue;
              final lateType = late[0];
              if (lateType == udpFrameData) {
                ingestDataFrame(late);
                crcOk = (fileCrc & 0xffffffff) ==
                    (serverCrc & 0xffffffff);
                if (currentData.length == declaredFileSize && crcOk) {
                  break;
                }
              } else if (lateType != udpFrameHeartbeat &&
                  lateType != udpFrameFileEnd) {
                // Firmware normally waits for FILE_ACK before sending another
                // control frame. Preserve any unexpected frame for the normal
                // loop rather than consuming it inside the grace window.
                deferred.add(late);
              }
            }
            if (deferred.isNotEmpty) {
              _earlyRxReplay.insertAll(0, deferred);
            }
            final afterFrames =
                nextExpectedSeq + pendingDataBySeq.length;
            final afterMissing = missingSeqSummary();
            SdkLog.i(
              'ClipUdpSync FILE_END grace done recovered='
              '${afterFrames - beforeFrames} crcOk=$crcOk '
              'assembled=${currentData.length}/$declaredFileSize '
              'frames=$afterFrames/$expectedDataFrames '
              'missing[$afterMissing]',
            );
          }

          // Loss attribution: how many datagrams we actually pulled off the
          // socket for this file, and how many the kernel dropped (buffer
          // overflow) in the same window. kdrop>0 ⇒ kernel/CPU-side loss, not RF.
          final rxThisFile = _rxDatagramCount - fileRxBaseline;
          final kdropNow = _readKernelUdpDrops();
          final kdropDelta = (fileKdropBaseline >= 0 && kdropNow >= 0)
              ? kdropNow - fileKdropBaseline
              : -1;
          final lossDiag =
              'rx=$rxThisFile kdrop=${kdropDelta >= 0 ? kdropDelta : 'n/a'}';
          final uniqueDataFrames = nextExpectedSeq + pendingDataBySeq.length;
          final missing = missingSeqSummary();
          SdkLog.i(
            'ClipUdpSync FILE_END $cn crcOk=$crcOk assembled=${currentData.length}/'
            '$declaredFileSize reassembly[outOfOrder=$outOfOrderHolds '
            'dup=$duplicateSkips stale=$staleDrops pending=${pendingDataBySeq.length}] '
            'frames=$uniqueDataFrames/$expectedDataFrames '
            'dataCrcDrops=$dataCrcDrops malformed=$malformedDataDrops '
            'missing[$missing] $lossDiag',
          );
          if (crcOk &&
              cn != null &&
              currentData.isNotEmpty &&
              currentData.length == declaredFileSize) {
            consecutiveFileNacks = 0;
            lastNackFile = null;
            _sendFileAck(true);
            final path = '$sessionDir/${p.basename(cn)}';
            final bytes = currentData.toBytes();
            final countOpus = cn.toLowerCase().endsWith('.opus');
            currentName = null;
            currentData.clear();
            fileCrc = 0;
            resetFileAssemblyState();
            if (countOpus) {
              filesReceived++;
            }
            diskWriteChain = diskWriteChain.then((_) async {
              try {
                await File(path).writeAsBytes(bytes, flush: true);
              } catch (e, st) {
                SdkLog.w('ClipUdpSync: write failed $path', e, st);
              }
            });
          } else {
            SdkLog.w(
              'ClipUdpSync FILE_END NACK: crcOk=$crcOk name=$cn assembled=${currentData.length} '
              'declared=$declaredFileSize localCrc=0x${(fileCrc & 0xffffffff).toRadixString(16)} '
              'serverCrc=0x${(serverCrc & 0xffffffff).toRadixString(16)} pending=${pendingDataBySeq.length} '
              'nextSeq=$nextExpectedSeq frames=$uniqueDataFrames/$expectedDataFrames '
              'dataCrcDrops=$dataCrcDrops malformed=$malformedDataDrops '
              'missing[$missing] $lossDiag',
            );
            _sendFileAck(false);
            if (cn != null && cn == lastNackFile) {
              consecutiveFileNacks++;
            } else {
              consecutiveFileNacks = 1;
              lastNackFile = cn;
            }
            currentName = null;
            currentData.clear();
            fileCrc = 0;
            resetFileAssemblyState();
            if (consecutiveFileNacks >= maxConsecutiveFileNacks) {
              SdkLog.w(
                'ClipUdpSync: $lastNackFile failed $consecutiveFileNacks times in a '
                'row (lossy link, no byte-offset resume) — aborting Wi‑Fi transfer '
                'to fall back to BLE',
              );
              try {
                await sendAtCommand('AT+CANCEL',
                    timeout: const Duration(seconds: 2));
              } catch (_) {}
              break;
            }
          }
          lastProgressAt = DateTime.now();
          continue;
        }

        if (frameType == udpFrameTransferDone) {
          // `py_test/clip/wifi.py`: type(1) + sid_len(1) + session_id(N) + file_count(4) LE
          if (data.length < 2) {
            SdkLog.w(
              'ClipUdpSync TRANSFER_DONE short frame len=${data.length}',
            );
            break;
          }
          final sidLen = data[1] & 0xff;
          var doneSid = '';
          var doneFileCount = -1;
          if (data.length >= 2 + sidLen + 4) {
            doneSid = sidLen > 0
                ? utf8.decode(data.sublist(2, 2 + sidLen), allowMalformed: true)
                    .trim()
                : '';
            doneFileCount = ByteData.sublistView(
              data,
              2 + sidLen,
              6 + sidLen,
            ).getUint32(0, Endian.little);
          } else {
            SdkLog.w(
              'ClipUdpSync TRANSFER_DONE truncated len=${data.length} '
              'need>=${2 + sidLen + 4} sidLen=$sidLen',
            );
          }
          if (doneSid.isNotEmpty && doneSid != sessionId.trim()) {
            SdkLog.w(
              'ClipUdpSync TRANSFER_DONE session mismatch '
              'fw="$doneSid" expected="$sessionId"',
            );
          }
          if (doneFileCount >= 0) {
            if (totalFiles > 0 && doneFileCount != totalFiles) {
              SdkLog.w(
                'ClipUdpSync TRANSFER_DONE file_count=$doneFileCount '
                '!= LIST/DL totalFiles=$totalFiles',
              );
            }
            // Resume-from-0002: device file_count is session total; [filesReceived] counts
            // only slices finished in this UDP run (0001 may already exist from BLE).
            if (doneFileCount != filesReceived && startFile == null) {
              SdkLog.w(
                'ClipUdpSync TRANSFER_DONE file_count=$doneFileCount '
                '!= local .opus slices finished=$filesReceived (full download)',
              );
            }
          }
          SdkLog.i(
            'ClipUdpSync TRANSFER_DONE session=$doneSid files=$doneFileCount '
            'payloadBytes=$receivedBytes (expect session=$sessionId)',
          );
          await diskWriteChain;
          break;
        }
      }

      return receivedBytes;
    } finally {
      try {
        await diskWriteChain;
      } catch (_) {}
      _resumeHeartbeat();
    }
  }
}

int? _parseInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
