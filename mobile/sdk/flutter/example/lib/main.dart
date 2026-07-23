import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  SdkLog.bind((level, message, error, stack) {
    final prefix = switch (level) {
      SdkLogLevel.debug => '[D]',
      SdkLogLevel.info => '[I]',
      SdkLogLevel.warning => '[W]',
      SdkLogLevel.error => '[E]',
    };
    // ignore: avoid_print
    print('$prefix $message${error != null ? ' | $error' : ''}');
  });

  runApp(const SenseCraftVoiceDemoApp());
}

class SenseCraftVoiceDemoApp extends StatelessWidget {
  const SenseCraftVoiceDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SenseCraft Voice SDK Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final SenseCraftVoiceClient _sdk = SenseCraftVoiceClient();
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<int>? _batterySub;
  StreamSubscription<DownloadEvent>? _downloadSub;
  StreamSubscription<OtaProgress>? _otaSub;

  final List<ScanResult> _devices = <ScanResult>[];
  bool _scanning = false;
  bool _busy = false;
  SenseCraftVoiceConnection? _conn;
  AtTransport? _at;
  RecordingSession? _session;
  OtaSession? _otaSession;
  String _log = '';
  int? _battery;
  String? _activeSession;
  String? _lastStoppedSession;

  @override
  void initState() {
    super.initState();
    _scanSub = _sdk.scanResults.listen((results) {
      final byId = <String, ScanResult>{};
      for (final r in results) {
        byId[r.device.remoteId.str] = r;
      }
      setState(() {
        _devices
          ..clear()
          ..addAll(byId.values);
      });
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _batterySub?.cancel();
    _downloadSub?.cancel();
    _otaSub?.cancel();
    unawaited(_otaSession?.dispose());
    final conn = _conn;
    if (conn != null) {
      unawaited(_sdk.disconnect(conn));
    }
    super.dispose();
  }

  void _appendLog(String line) {
    setState(() {
      _log = '$line\n$_log';
      if (_log.length > 6000) {
        _log = _log.substring(0, 6000);
      }
    });
  }

  Future<T?> _runBusy<T>(String label, Future<T> Function() fn) async {
    if (_busy) {
      _appendLog('Busy — wait for $label to finish');
      return null;
    }
    setState(() => _busy = true);
    try {
      return await fn();
    } catch (e, st) {
      _appendLog('$label failed: $e');
      SdkLog.e(label, e, st);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startScan() async {
    await _runBusy('scan', () async {
      setState(() {
        _scanning = true;
        _devices.clear();
      });
      try {
        await _sdk.startScan(
          timeout: const Duration(seconds: 12),
          filterByService: false,
        );
      } finally {
        if (mounted) setState(() => _scanning = false);
      }
    });
  }

  Future<void> _connect(ScanResult result) async {
    await _runBusy('connect', () async {
      _appendLog('Connecting to ${result.device.platformName}...');
      await _sdk.stopScan();
      final conn = await _sdk.connect(result);
      final at = AtTransport(
        commandRx: conn.commandRx,
        responseTx: conn.responseTx,
        fileData: conn.fileData,
        mtu: conn.mtu,
      );
      await _batterySub?.cancel();
      _batterySub = conn.batteryLevelStream?.listen((pct) {
        setState(() => _battery = pct);
      });
      final session = RecordingSession(connection: conn, at: at);
      setState(() {
        _conn = conn;
        _at = at;
        _session = session;
      });
      _appendLog('Connected. MTU=${conn.mtu.mtu}');
    });
  }

  Future<void> _sendVersion() async {
    final at = _at;
    if (at == null) return;
    await _runBusy('AT+VERSION', () async {
      final reply = await at.send('AT+VERSION');
      _appendLog('AT+VERSION -> $reply');
    });
  }

  Future<void> _startRecording() async {
    final s = _session;
    if (s == null) return;
    await _runBusy('record start', () async {
      final info = await s.start();
      setState(() => _activeSession = info.sessionId);
      _appendLog('REC START -> session=${info.sessionId} mode=${info.mode}');
    });
  }

  Future<void> _stopRecording() async {
    final s = _session;
    if (s == null) return;
    await _runBusy('record stop', () async {
      final info = await s.stop();
      final sid = info.sessionId ?? _activeSession;
      setState(() {
        _activeSession = null;
        _lastStoppedSession = sid;
      });
      _appendLog(
        'REC STOP -> session=$sid '
        'dur=${info.durationSeconds}s files=${info.fileCount}',
      );
    });
  }

  Future<void> _showStatus() async {
    final s = _session;
    if (s == null) return;
    await _runBusy('GSTAT', () async {
      final st = await s.getStatus();
      _appendLog(
        'STATUS state=${st.state} rec=${st.isRecording} '
        'session=${st.sessionId} battery=${st.batteryPercent}',
      );
    });
  }

  Future<void> _listFiles() async {
    final s = _session;
    if (s == null) return;
    final sid = _lastStoppedSession ?? _activeSession;
    await _runBusy('AT+LIST', () async {
      final files = await s.listFiles(sessionId: sid);
      if (files.isEmpty) {
        _appendLog('LIST -> (empty) session=$sid');
        return;
      }
      _appendLog(
        'LIST ${files.length} file(s): ${files.map((f) => f.name).join(", ")}',
      );
    });
  }

  Future<void> _bleDownload() async {
    final s = _session;
    final sid = _lastStoppedSession;
    if (s == null || sid == null || sid.isEmpty) {
      _appendLog('BLE download: stop a recording first to get session id');
      return;
    }
    await _runBusy('BLE download', () async {
      final dir = await getTemporaryDirectory();
      final outDir = Directory('${dir.path}/sdk_demo/$sid');
      await outDir.create(recursive: true);

      await _downloadSub?.cancel();
      _downloadSub = s.download(sessionId: sid).listen((event) {
        switch (event) {
          case DownloadStarted():
            _appendLog(
              'DOWNLOAD started files=${event.totalFiles} bytes=${event.totalBytes}',
            );
          case DownloadFileStarted():
            _appendLog('FILE ${event.filename} (${event.fileSize} B)');
          case DownloadFileProgress():
            if (event.received % 8192 < event.total) {
              _appendLog(
                '  ${event.filename} ${event.received}/${event.total}',
              );
            }
          case DownloadFileCompleted():
            final file = File('${outDir.path}/${event.filename}');
            file.writeAsBytesSync(event.bytes);
            _appendLog(
              '  saved ${event.filename} (${event.bytes.length} B) crc=0x${event.crc32.toRadixString(16)}',
            );
          case DownloadTransferDone():
            _appendLog(
              'TRANSFER_DONE session=${event.sessionId} files=${event.fileCount} → ${outDir.path}',
            );
        }
      }, onError: (Object e) {
        _appendLog('BLE download error: $e');
      });
    });
  }

  Future<void> _wifiFastSync() async {
    final at = _at;
    final sid = _lastStoppedSession;
    if (at == null || sid == null || sid.isEmpty) {
      _appendLog('WiFi sync: connect + stop a recording first');
      return;
    }
    await _runBusy('WiFi fast sync', () async {
      final dir = await getTemporaryDirectory();
      final outDir = '${dir.path}/sdk_demo_wifi/$sid';
      final sync = WifiFastSyncSession(at: at);
      final bytes = await sync.downloadSession(
        sessionId: sid,
        sessionDir: outDir,
        onFileProgress: (rx, total) {
          if (rx % 65536 < 8192) {
            _appendLog('WiFi file progress $rx/${total < 0 ? "?" : total}');
          }
        },
        onOverallProgress: (idx, total, overall) {
          _appendLog('WiFi overall file $idx/$total bytes=$overall');
        },
      );
      _appendLog('WiFi sync done: $bytes bytes → $outDir');
    });
  }

  Future<void> _pickAndOta() async {
    final conn = _conn;
    if (conn == null) {
      _appendLog('OTA: connect to a device first');
      return;
    }
    final pick = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip', 'bin'],
    );
    if (pick == null || pick.files.single.path == null) return;
    final path = pick.files.single.path!;

    await _runBusy('OTA', () async {
      await _otaSub?.cancel();
      await _otaSession?.dispose();
      _otaSession = OtaSession(deviceId: conn.device.remoteId.str);
      _otaSub = _otaSession!.events.listen((p) {
        final pct = p.progress >= 0
            ? '${(p.progress * 100).toStringAsFixed(0)}%'
            : '—';
        _appendLog('OTA ${p.phase.name} $pct — ${p.message}');
      });
      final ok = await _otaSession!.upgrade(File(path));
      if (ok) {
        _appendLog('OTA success');
      } else {
        _appendLog('OTA failed: ${_otaSession!.lastError}');
      }
    });
  }

  Future<void> _disconnect() async {
    final conn = _conn;
    if (conn == null) return;
    await _downloadSub?.cancel();
    await _otaSub?.cancel();
    await _otaSession?.dispose();
    _otaSession = null;
    await _sdk.disconnect(conn);
    await _batterySub?.cancel();
    setState(() {
      _conn = null;
      _at = null;
      _session = null;
      _battery = null;
      _activeSession = null;
    });
    _appendLog('Disconnected.');
  }

  @override
  Widget build(BuildContext context) {
    final connected = _conn != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SenseCraft Voice SDK Demo'),
        actions: [
          if (_battery != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(child: Text('Battery: $_battery%')),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _scanning || _busy ? null : _startScan,
                  icon: const Icon(Icons.search),
                  label: Text(_scanning ? 'Scanning...' : 'Scan'),
                ),
                OutlinedButton.icon(
                  onPressed: connected && !_busy ? _sendVersion : null,
                  icon: const Icon(Icons.send),
                  label: const Text('Version'),
                ),
                OutlinedButton.icon(
                  onPressed: connected && !_busy ? _showStatus : null,
                  icon: const Icon(Icons.info_outline),
                  label: const Text('Status'),
                ),
                FilledButton.tonalIcon(
                  onPressed: connected && !_busy && _activeSession == null
                      ? _startRecording
                      : null,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Record'),
                ),
                FilledButton.tonalIcon(
                  onPressed: connected && !_busy && _activeSession != null
                      ? _stopRecording
                      : null,
                  icon: const Icon(Icons.stop),
                  label: Text(_activeSession == null
                      ? 'Stop'
                      : 'Stop (${_activeSession!})'),
                ),
                OutlinedButton.icon(
                  onPressed: connected && !_busy ? _listFiles : null,
                  icon: const Icon(Icons.list),
                  label: const Text('List'),
                ),
                OutlinedButton.icon(
                  onPressed: connected && !_busy ? _bleDownload : null,
                  icon: const Icon(Icons.download),
                  label: const Text('BLE DL'),
                ),
                OutlinedButton.icon(
                  onPressed: connected && !_busy ? _wifiFastSync : null,
                  icon: const Icon(Icons.wifi),
                  label: const Text('WiFi sync'),
                ),
                OutlinedButton.icon(
                  onPressed: connected && !_busy ? _pickAndOta : null,
                  icon: const Icon(Icons.system_update),
                  label: const Text('OTA'),
                ),
                OutlinedButton.icon(
                  onPressed: connected && !_busy ? _disconnect : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
              ],
            ),
            if (_lastStoppedSession != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Last session: $_lastStoppedSession',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),
            Expanded(
              flex: 2,
              child: Card(
                child: ListView.separated(
                  itemBuilder: (_, i) {
                    final r = _devices[i];
                    final name = r.device.platformName.isEmpty
                        ? '(unnamed)'
                        : r.device.platformName;
                    return ListTile(
                      title: Text(name),
                      subtitle: Text(
                        '${r.device.remoteId.str}  rssi=${r.rssi}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : () => _connect(r),
                    );
                  },
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemCount: _devices.length,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              flex: 3,
              child: Card(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _log.isEmpty ? '(log)' : _log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
