import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble/mtu_manager.dart';
import '../utils/sdk_log.dart';
import 'json_object_framer.dart';

/// AT(JSON) protocol transport over BLE (GATT) for SenseCraft Voice Clip
/// devices.
///
/// Spec summary:
/// - App writes AT commands to the *command* characteristic (Write or
///   WriteWithoutResponse).
/// - Device pushes JSON responses / progress on the *response* characteristic
///   (Notify), possibly chunked across multiple notifications.
/// - Device pushes raw file bytes on the *file-data* characteristic (Notify).
///
/// Higher layers reassemble complete JSON objects via [_JsonObjectFramer] and
/// match each command with its reply through a serial send queue.
class AtTransport {
  final BluetoothCharacteristic commandRx;
  final BluetoothCharacteristic responseTx;
  final BluetoothCharacteristic fileData;
  final MtuManager mtu;

  AtTransport({
    required this.commandRx,
    required this.responseTx,
    required this.fileData,
    required this.mtu,
  });

  /// Raw notify bytes on the response characteristic (chunked JSON).
  Stream<List<int>> get responseNotifyBytes => responseTx.onValueReceived;

  /// Raw notify bytes on the file-data characteristic.
  Stream<List<int>> get fileDataBytes => fileData.onValueReceived;

  Future<void> setFileDataNotify(
    bool enabled, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final sw = Stopwatch()..start();
    try {
      await fileData.setNotifyValue(enabled).timeout(timeout);
      SdkLog.i(
        'BLE fileData notify ${enabled ? "enabled" : "disabled"} '
        'in ${sw.elapsedMilliseconds}ms',
      );
    } catch (e, st) {
      SdkLog.w(
        'BLE fileData notify ${enabled ? "enable" : "disable"} failed '
        'after ${sw.elapsedMilliseconds}ms',
        e,
        st,
      );
      rethrow;
    }
  }

  /// Broadcast stream of complete JSON objects parsed from notify traffic.
  ///
  /// Broadcast because the SDK has both long-lived listeners (UI / state) and
  /// short-lived per-command waiters; a single-subscription stream would throw
  /// `Bad state: Stream has already been listened to.`.
  late final Stream<Map<String, dynamic>> _jsonStream =
      _buildJsonStream().asBroadcastStream();

  Stream<Map<String, dynamic>> get jsonMessages => _jsonStream;

  final _SerialQueue _sendQueue = _SerialQueue();

  /// Send a single AT command and await its JSON reply.
  ///
  /// Commands are serialised; concurrent callers are queued. The reply
  /// matcher disambiguates AT+STOP, AT+START and AT+DOWNLOAD where the
  /// firmware may interleave `state_change` or `AT+GSTAT` notifies.
  Future<Map<String, dynamic>> send(
    String atCommand, {
    Duration timeout = const Duration(seconds: 5),
    bool withoutResponse = false,
    Duration interChunkDelay = const Duration(milliseconds: 16),
  }) {
    return _sendQueue.run(() async {
      final completer = Completer<Map<String, dynamic>>();
      late final StreamSubscription<Map<String, dynamic>> sub;

      // AT+STOP: firmware may emit `state_change` first, then a separate
      // message with `session`. Using the wrong message as the STOP reply
      // causes "Session not found" on the subsequent AT+DOWNLOAD.
      final waitForSession = atCommand.toUpperCase().startsWith('AT+STOP');

      // AT+START: firmware may notify AT+GSTAT while START is still being
      // processed — the first JSON on the wire could be GSTAT, not the
      // START ack.
      final waitForStartAck = atCommand.toUpperCase().startsWith('AT+START');

      // AT+DOWNLOAD ack can be preceded/followed by GSTAT on the same notify
      // stream; taking an "IDLE" GSTAT as the download reply causes timeouts
      // and wrong progress.
      final waitForDownloadAck =
          atCommand.toUpperCase().startsWith('AT+DOWNLOAD');
      final waitForGstatAck = atCommand.toUpperCase().startsWith('AT+GSTAT');

      // AT+PAUSE / AT+RESUME: iOS BLE often delivers a stale AT+GSTAT notify
      // (`ok:true`, `data.state: recording`) before the real pause/resume ack.
      // Treating that as success made the App show "paused" while the device
      // kept capturing for several more seconds (Android timing usually hid it).
      final waitForPauseAck = atCommand.toUpperCase().startsWith('AT+PAUSE');
      final waitForResumeAck = atCommand.toUpperCase().startsWith('AT+RESUME');

      // AT+CANCEL is the *only* command whose reply looks like a cancel ack
      // (`data.canceled` / "No active transfer"). When the firmware is busy
      // streaming a file over the file-data characteristic it cannot answer
      // AT+CANCEL in time, so the App's send() times out and moves on — yet the
      // firmware still delivers that cancel reply seconds later. Without command
      // IDs in the protocol, a *later* command (notably AT+START) would then
      // match that stale cancel reply and report a bogus failure
      // ("START failed (No active transfer)") even though recording actually
      // started. Only AT+CANCEL may consume a cancel-shaped reply; every other
      // in-flight command skips it and keeps waiting for its real ack.
      final isCancelCommand = atCommand.toUpperCase().startsWith('AT+CANCEL');

      sub = jsonMessages.listen((m) {
        // Binary / garbage on the response notify characteristic
        // (iOS stack quirks or mis-routed packets) shows up as
        // `ok:false + JSON decode failed`. Must not complete send().
        if (_isSyntheticFramerFailure(m)) return;
        // Drop stale/late AT+CANCEL replies for any non-cancel command.
        if (!isCancelCommand && _isCancelReply(m)) return;
        // Push notifications (`event:"state"`, `event:"mark"`, etc.) are
        // NEVER an AT-command reply — even though `event:"state"` carries a
        // `session` id that superficially looks like an AT+STOP ack.
        //
        // The previous heuristic ("accept event when it has session, on
        // STOP") fired on the device's own IDLE push that the firmware
        // emits right before the real STOP ack, so `at.send('AT+STOP')`
        // returned a payload with `ok:null` / no `data.frames`, and the
        // App treated stop as failed. UX symptom: a "stop failed" toast right
        // after stop, and the post-stop transfer pipeline launched with
        // `sizeBytes=0`. See log line "stopRecording: AT+STOP reply
        // ok=null keys=[event, state, session, duration]" — the matched
        // payload was the IDLE event, not the ack.
        //
        // A real ack always carries `ok` (true/false) and no `event` field;
        // require that to disambiguate.
        if (_isEventMessage(m)) return;
        if (waitForSession && !_hasSession(m) && !_isStopFailureReply(m)) {
          return;
        }
        if (waitForSession &&
            m['ok'] == true &&
            _hasSession(m) &&
            !isStopAckShape(m)) {
          return;
        }
        if (isCancelCommand && !_isCancelReply(m)) return;
        if (waitForStartAck && looksLikeGstatOkReply(m)) return;
        if (waitForDownloadAck && looksLikeGstatOkReply(m)) return;
        if (waitForPauseAck && looksLikeGstatOkReply(m)) return;
        if (waitForResumeAck && looksLikeGstatOkReply(m)) return;
        if (waitForGstatAck && !looksLikeGstatOkReply(m)) return;
        if (!completer.isCompleted) completer.complete(m);
        sub.cancel();
      }, onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
        sub.cancel();
      });

      final writeSw = Stopwatch()..start();
      try {
        await _writeCommand(
          atCommand,
          withoutResponse: withoutResponse,
          interChunkDelay: interChunkDelay,
        );
        _logAtWriteTiming(atCommand, writeSw.elapsed, withoutResponse);
        final replySw = Stopwatch()..start();
        final reply = await completer.future.timeout(timeout, onTimeout: () {
          throw TimeoutException('AT command timeout: $atCommand', timeout);
        });
        _logAtReplyTiming(atCommand, replySw.elapsed);
        return reply;
      } finally {
        // Safe even if already cancelled.
        unawaited(sub.cancel());
      }
    });
  }

  /// Write an AT command without registering a JSON reply waiter and without
  /// joining the serial send queue.
  ///
  /// This is intentionally narrow: use it for emergency commands where waiting
  /// for an ack can block the next user action behind a busy firmware transfer
  /// (notably `AT+CANCEL` before starting a recording on iOS). Late replies are
  /// still delivered on [jsonMessages]; normal [send] matchers ignore stale
  /// cancel-shaped replies for non-cancel commands.
  Future<void> writeCommandOnly(
    String atCommand, {
    bool withoutResponse = false,
    Duration interChunkDelay = const Duration(milliseconds: 16),
  }) async {
    final sw = Stopwatch()..start();
    await _writeCommand(
      atCommand,
      withoutResponse: withoutResponse,
      interChunkDelay: interChunkDelay,
    );
    _logAtWriteTiming(atCommand, sw.elapsed, withoutResponse);
  }

  static bool _shouldLogAtTiming(String atCommand, Duration elapsed) {
    if (elapsed >= const Duration(milliseconds: 200)) return true;
    final upper = atCommand.toUpperCase();
    return upper.startsWith('AT+CANCEL') ||
        upper.startsWith('AT+START') ||
        upper.startsWith('AT+STOP') ||
        upper.startsWith('AT+PAUSE') ||
        upper.startsWith('AT+RESUME') ||
        upper.startsWith('AT+WIFI') ||
        upper.startsWith('AT+GSTAT');
  }

  static String _commandForLog(String atCommand) {
    final trimmed = atCommand.trim();
    if (trimmed.length <= 48) return trimmed;
    return '${trimmed.substring(0, 48)}...';
  }

  static void _logAtWriteTiming(
    String atCommand,
    Duration elapsed,
    bool withoutResponse,
  ) {
    if (!_shouldLogAtTiming(atCommand, elapsed)) return;
    final msg =
        'AT TX write ${_commandForLog(atCommand)} took ${elapsed.inMilliseconds}ms '
        '(withoutResponse=$withoutResponse)';
    if (elapsed >= const Duration(milliseconds: 500)) {
      SdkLog.w(msg);
    } else {
      SdkLog.i(msg);
    }
  }

  static void _logAtReplyTiming(String atCommand, Duration elapsed) {
    if (!_shouldLogAtTiming(atCommand, elapsed)) return;
    final msg =
        'AT RX reply ${_commandForLog(atCommand)} took ${elapsed.inMilliseconds}ms '
        'after write';
    if (elapsed >= const Duration(seconds: 2)) {
      SdkLog.w(msg);
    } else {
      SdkLog.i(msg);
    }
  }

  static bool _hasSession(Map<String, dynamic> m) {
    if ((m['session'] ?? '').toString().trim().isNotEmpty) return true;
    final data = m['data'];
    if (data is Map && (data['session'] ?? '').toString().trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  /// Distinguish a real AT+STOP ack from stray AT+GSTAT notifies — both may
  /// include `data.session`. Without this, the STOP waiter completes early on
  /// GSTAT and `stopRecording` parses the wrong payload / times out.
  static bool isStopAckShape(Map<String, dynamic> m) {
    if (m['ok'] == false) return true;
    final data = m['data'];
    if (data is! Map) return false;
    final d = Map<String, dynamic>.from(data);
    if (d.containsKey('frames') ||
        d.containsKey('file_count') ||
        d.containsKey('total_size')) {
      return true;
    }
    final cmd = (m['cmd'] ?? d['cmd'] ?? '').toString().toUpperCase();
    if (cmd == 'STOP') return true;
    // GSTAT payloads almost always include `state`; a typical STOP result
    // does not.
    if (!d.containsKey('state') && _hasSession(m)) return true;
    return false;
  }

  /// On STOP failure firmware may return `ok:false` with no `session`
  /// (e.g. "No active session"). The session waiter would then time out and
  /// look like stop did nothing.
  static bool _isStopFailureReply(Map<String, dynamic> m) => m['ok'] == false;

  /// True when [m] is a reply to `AT+CANCEL` — either a success ack
  /// (`{"ok":true,"data":{"canceled":true}}`) or the "nothing to cancel"
  /// failure (`{"ok":false,"msg":"No active transfer"}`). These are *only*
  /// ever produced by AT+CANCEL, so any other command that sees one is looking
  /// at a stale/late reply from a previously timed-out cancel and must skip it.
  static bool _isCancelReply(Map<String, dynamic> m) {
    if (_isEventMessage(m)) return false;
    final data = m['data'];
    if (data is Map && data.containsKey('canceled')) return true;
    if (m['ok'] == false) {
      final msg = (m['msg'] ?? m['error'] ?? m['message'] ?? '')
          .toString()
          .toLowerCase();
      if (msg.contains('no active transfer')) return true;
    }
    return false;
  }

  /// True when this notify is the JSON for an AT+GSTAT response
  /// (not an AT+START ack).
  static bool _isGstatCommandReply(Map<String, dynamic> m) {
    final c = _responseCmdTag(m);
    return c == 'GSTAT';
  }

  static String? _responseCmdTag(Map<String, dynamic> m) {
    final c = (m['cmd'] ?? '').toString().trim().toUpperCase();
    if (c.isNotEmpty) return c;
    final data = m['data'];
    if (data is Map) {
      final dc = (data['cmd'] ?? '').toString().trim().toUpperCase();
      if (dc.isNotEmpty) return dc;
    }
    return null;
  }

  static bool _isEventMessage(Map<String, dynamic> m) {
    if (m['event'] != null) return true;
    final data = m['data'];
    if (data is Map && (data['event'] != null)) return true;
    return false;
  }

  /// [jsonMessages] yields these when notify bytes are not valid JSON
  /// (e.g. a file payload leaked onto the response characteristic).
  /// They are not firmware AT replies.
  static bool _isSyntheticFramerFailure(Map<String, dynamic> m) {
    if (m['ok'] != false) return false;
    final err = (m['error'] ?? '').toString();
    return err == 'JSON decode failed' || err.startsWith('Invalid JSON root');
  }

  /// True when [m] is a successful JSON blob that matches an AT+GSTAT reply
  /// (by `cmd` or common fields). Used by higher layers to sync UI state
  /// from notify traffic without issuing an explicit AT+GSTAT.
  static bool looksLikeGstatOkReply(Map<String, dynamic> m) {
    if (_isEventMessage(m)) return false;
    if (m['ok'] != true) return false;
    if (_isGstatCommandReply(m)) return true;
    final data = m['data'];
    if (data is! Map) return false;
    final d = Map<String, dynamic>.from(data);
    if ((d['state'] ?? '').toString().trim().isEmpty) return false;
    if (d.containsKey('battery') ||
        d.containsKey('free_space') ||
        d.containsKey('bitrate') ||
        d.containsKey('charging')) {
      return true;
    }
    return d.containsKey('recording') &&
        (d.containsKey('session') || d.containsKey('duration'));
  }

  Future<void> _writeCommand(
    String at, {
    required bool withoutResponse,
    required Duration interChunkDelay,
  }) async {
    // Prefer WRITE_WITHOUT_RESPONSE automatically when the characteristic
    // only supports that mode, to avoid "WRITE property is not supported".
    var useWithoutResponse = withoutResponse;
    final props = commandRx.properties;
    if (useWithoutResponse && !props.writeWithoutResponse && props.write) {
      useWithoutResponse = false;
    }
    if (!useWithoutResponse && !props.write && props.writeWithoutResponse) {
      useWithoutResponse = true;
    }

    final bytes = utf8.encode(at);
    final payload = mtu.payloadSize;

    if (bytes.length <= payload) {
      await commandRx.write(bytes, withoutResponse: useWithoutResponse);
      return;
    }

    // Try long write first (platform / device dependent).
    try {
      await commandRx.write(
        bytes,
        withoutResponse: useWithoutResponse,
        allowLongWrite: true,
      );
      return;
    } catch (e, st) {
      SdkLog.w('allowLongWrite failed, fallback to chunking', e, st);
    }

    // Fallback: MTU-aware chunked writes (firmware must reassemble).
    final chunkSize = max(1, min(payload, 512));
    final total = (bytes.length / chunkSize).ceil();
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = min(i + chunkSize, bytes.length);
      final chunk = bytes.sublist(i, end);
      await commandRx.write(chunk, withoutResponse: useWithoutResponse);
      if (end < bytes.length) {
        await Future<void>.delayed(interChunkDelay);
      }
      SdkLog.d(
        'AT chunk ${(i ~/ chunkSize) + 1}/$total (${chunk.length} bytes)',
      );
    }
  }

  Stream<Map<String, dynamic>> _buildJsonStream() async* {
    final framer = JsonObjectFramer();

    await for (final bytes in responseNotifyBytes) {
      final text = _decodeBestEffort(bytes);
      for (final jsonText in framer.feed(text)) {
        final obj = _tryDecodeJsonText(jsonText);
        if (obj is Map<String, dynamic>) {
          yield obj;
        } else if (obj != null) {
          yield <String, dynamic>{
            'ok': false,
            'error': 'Invalid JSON root (not object)',
            'raw': obj,
          };
        } else {
          yield <String, dynamic>{
            'ok': false,
            'error': 'JSON decode failed',
            'raw': jsonText,
          };
        }
      }
    }
  }

  /// Decode one JSON object. Some iOS / BLE corruption truncates the numeric
  /// `"bytes"` field; attempt a one-shot repair when the first parse fails.
  static dynamic _tryDecodeJsonText(String jsonText) {
    try {
      return jsonDecode(jsonText);
    } catch (_) {
      final repaired = _repairCorruptedBytesField(jsonText);
      if (repaired == jsonText) return null;
      try {
        return jsonDecode(repaired);
      } catch (_) {
        return null;
      }
    }
  }

  /// Replace an invalid `"bytes": <garbage>` with `"bytes": 0` so progress /
  /// DOWNLOAD payloads still parse (firmware may resend the size via LIST or
  /// FILE_START anyway).
  static String _repairCorruptedBytesField(String jsonText) {
    return jsonText.replaceFirstMapped(
      RegExp(r'"bytes"\s*:\s*([^,}]+)'),
      (Match m) {
        final rawVal = m.group(1)!.trim();
        if (rawVal.isEmpty) return '"bytes":0';
        if (int.tryParse(rawVal) != null) return m.group(0)!;
        if (rawVal == 'null') return m.group(0)!;
        return '"bytes":0';
      },
    );
  }

  static String _decodeBestEffort(List<int> data) {
    try {
      return utf8.decode(data, allowMalformed: true);
    } catch (_) {
      return data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    }
  }
}

/// Serialise async tasks so AT commands never overlap on the wire.
class _SerialQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}
