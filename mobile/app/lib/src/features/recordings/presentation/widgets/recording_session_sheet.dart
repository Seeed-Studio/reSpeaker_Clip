import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_radii.dart';
import '../../../../core/db/account_db_key.dart';
import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/storage/account_storage_paths.dart';
import '../../../../core/log/app_log.dart';
import '../../../../core/widgets/app_bottom_sheet.dart';
import '../../../../core/widgets/app_pill_button.dart';
import '../../../device/data/device_repository.dart';
import '../../../device/presentation/device_controller.dart';
import '../../../device/presentation/wifi_transfer_controller.dart';
import '../../../device/presentation/bluetooth_connect_gate.dart';
import '../../../device/presentation/widgets/device_connect_sheet.dart';
import '../../data/recordings_repository.dart';
import '../../domain/recording.dart';
import '../../utils/recording_display_name.dart';
import '../recordings_controller.dart';

const bool kBypassDeviceConnectGate = bool.fromEnvironment(
  'BYPASS_DEVICE_CONNECT_GATE',
  defaultValue: false,
);

const bool kPreferDemoAlacIfAvailable = bool.fromEnvironment(
  'PREFER_DEMO_ALAC',
  defaultValue: true,
);

const bool kUseLocalRecorder = bool.fromEnvironment(
  'USE_LOCAL_RECORDER',
  defaultValue: false,
);

/// Prefer persisted [Device.name] so labels match the app after rename; BLE
/// advertising name can lag until AT+NAME / stack refresh.
Future<String> _resolvedRecordingDeviceName(
  ProviderContainer container,
  String deviceId,
  String platformName,
) async {
  final trimmed = platformName.trim();
  try {
    final repo = await container.read(deviceRepositoryProvider.future);
    final d = await repo.getById(deviceId);
    final n = (d?.name ?? '').trim();
    if (n.isNotEmpty) return n;
  } catch (_) {}
  if (trimmed.isNotEmpty) return trimmed;
  return 'SenseCraft Voice Clip';
}

void _showSnackOnRoot(BuildContext root, String message) {
  if (!root.mounted) return;
  ScaffoldMessenger.of(root).showSnackBar(SnackBar(content: Text(message)));
}

class RecordingSessionSheet extends ConsumerStatefulWidget {
  /// Used to navigate after finishing (e.g. back to Files).
  final BuildContext rootContext;
  final int? batteryPercent;

  const RecordingSessionSheet({
    super.key,
    required this.rootContext,
    this.batteryPercent,
  });

  static Future<void> show(BuildContext context, {int? batteryPercent}) {
    return showAppBottomSheet<void>(
      context,
      useRootNavigator: true,
      builder: (_) => RecordingSessionSheet(
          rootContext: context, batteryPercent: batteryPercent),
    );
  }

  @override
  ConsumerState<RecordingSessionSheet> createState() =>
      _RecordingSessionSheetState();
}

enum _SessionView { noDevice, recording, finished }

class _RecordingSessionSheetState extends ConsumerState<RecordingSessionSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  Duration _elapsed = Duration.zero;
  _RecPhase _phase = _RecPhase.idle;
  final List<Duration> _marks = [];
  _SessionView _view = _SessionView.recording;

  // Local recorder (for server API test)
  final AudioRecorder _localRecorder = AudioRecorder();
  final Stopwatch _localStopwatch = Stopwatch();
  Timer? _localTicker;
  String? _localOutPath;
  DateTime? _localStartedAt;

  // Live VU meter (0..1) to drive "real" recording waveform.
  StreamSubscription? _ampSub;
  double _vuLevel = 0.0; // smoothed 0..1
  double _vuPeak = 0.18; // AGC envelope peak

  // Device mode fallback: make waveform "feel real" even without amplitude.
  Timer? _fakeVuTicker;
  StreamSubscription<DeviceEvent>? _deviceEventSub;
  final math.Random _fakeVuRnd = math.Random(20260205);
  double _fakeVu = 0.0;
  double _fakeVuTarget = 0.22;
  DateTime _fakeVuNextTargetAt = DateTime.now();

  /// Avoid multiple simultaneous reconnect attempts when device drops during recording.
  bool _reconnecting = false;

  /// While START/STOP/pause/resume waits on firmware, ignore duplicate taps on record / finish / mark.
  bool _recordingUiBusy = false;

  /// Set immediately when the user taps pause, before AT+PAUSE returns.
  /// Prevents stale RECORDING events / local ticker from making the sheet keep counting.
  bool _pauseRequestedByUi = false;

  /// True while [_startRecording] is stopping an in-flight transfer and waiting
  /// on AT+START. Used to show a "preparing…" hint + spinner so the sheet does
  /// not look frozen while the firmware (busy streaming a file) is slow to ack.
  bool _preparingStart = false;

  /// True after the user confirmed Stop. Device IDLE events that arrive while
  /// AT+STOP is settling belong to this App-driven stop, not a separate device
  /// button stop that should surface its own toast.
  bool _stopRequestedByUi = false;

  /// Freeze the elapsed-time display the instant the user taps save/stop.
  /// The firmware AT+STOP round-trip (BLE) can take a couple of seconds; without
  /// this the ticker would keep counting up (e.g. 13s → 16s) until STOP returns,
  /// even though the saved file is the firmware-reported duration. We freeze the
  /// shown time at tap, then snap to `res.durationSeconds` once STOP replies.
  bool _freezeElapsed = false;

  /// When doing device recording with "real-time sync", this tracks the
  /// recordings table id (`deviceId_devicePath`) we created at START.
  /// It allows STOP to only patch metadata instead of starting a second
  /// DOWNLOAD pipeline.
  String? _deviceRecordingId;

  /// Approximate started-at for the current device recording (App-side clock).
  DateTime? _deviceRecordingStartedAt;

  /// After [AT+START] succeeds (with session), UI for this session follows **AT replies only**
  /// (START / PAUSE / RESUME / STOP), not GSTAT — avoids firmware state strings out of sync with App.
  /// False when opening the sheet without starting from here (then [_syncRecordingSheetFromDeviceGstatOnce] sends **one** GSTAT).
  bool _recordingUiFollowsAtAck = false;

  /// Center action should be Start recording (stop transfer + START), not Pause from a bad GSTAT read.
  bool get _primaryButtonStartsNewRecording =>
      _phase == _RecPhase.idle ||
      (_phase == _RecPhase.recording &&
          !_recordingUiFollowsAtAck &&
          _deviceRecordingId == null);

  static String _recordingDisplayName(
          String deviceOrRecordings, DateTime date) =>
      recordingDisplayNameForDevice(deviceOrRecordings, date);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
    if (!kUseLocalRecorder) {
      _deviceEventSub =
          ref.read(deviceControllerProvider.notifier).deviceEvents.listen(
                _handleDeviceEvent,
                onError: (_) {},
              );
      // Single AT+GSTAT when opening: recording? + duration (no poll loop).
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _syncFromDeviceOnce());
    } else {
      // Local mode: don't poll device at all.
      _view = _SessionView.recording;
      _phase = _RecPhase.idle;
      _elapsed = Duration.zero;
    }
  }

  @override
  void dispose() {
    _fakeVuTicker?.cancel();
    _fakeVuTicker = null;
    _deviceEventSub?.cancel();
    _deviceEventSub = null;
    _ampSub?.cancel();
    _ampSub = null;
    _localTicker?.cancel();
    _localRecorder.dispose();
    _anim.dispose();
    super.dispose();
  }

  /// BLE pull may stop after background/disconnect; if DB still `transferring`, resume from local parts only (no extra GSTAT for this).
  Future<void> _maybeResumeStalledLiveTransfer(RecStatus st) async {
    try {
      final gsid = (st.sessionId ?? '').trim();
      if (gsid.isEmpty) return;
      if (ref.read(wifiTransferControllerProvider).isActive) return;
      final conn = ref.read(deviceControllerProvider).connection;
      if (conn == null) return;
      final deviceId = conn.device.remoteId.toString();
      var rid = _deviceRecordingId;
      final recRepo = await ref.read(recordingsRepositoryProvider.future);
      if (rid != null) {
        final r = await recRepo.getById(rid);
        if (r == null) {
          rid = null;
        } else {
          final p = r.devicePath.contains('/')
              ? r.devicePath.split('/').first
              : r.devicePath;
          if (p.trim() != gsid) {
            rid = null;
          }
        }
      }
      rid ??= '${deviceId}_$gsid';
      final rec = await recRepo.getById(rid);
      if (rec == null ||
          rec.transferState != 'transferring' ||
          rec.endedAt != null) {
        return;
      }
      final ctrl = ref.read(deviceControllerProvider.notifier);
      await ctrl.resumeLiveRecordingTransferIfStalled(
        recordingId: rid,
        sessionId: rec.devicePath.trim(),
      );
      if (mounted && _deviceRecordingId == null) {
        setState(() => _deviceRecordingId = rid);
      }
    } catch (_) {}
  }

  void _handleDeviceEvent(DeviceEvent event) {
    if (!mounted || kUseLocalRecorder) return;
    if (_view == _SessionView.finished) return;
    if (event is! DeviceRecordingStateEvent) return;

    final sid = (event.sessionId ?? '').trim();
    final activeSid =
        (ref.read(deviceControllerProvider.notifier).activeRecordingSessionId ??
                '')
            .trim();
    if (sid.isNotEmpty && activeSid.isNotEmpty && sid != activeSid) return;

    final nextPhase = switch (event.state) {
      DeviceRecordingState.recording => _RecPhase.recording,
      DeviceRecordingState.paused => _RecPhase.paused,
      DeviceRecordingState.idle => _RecPhase.idle,
      _ => null,
    };
    if (nextPhase == null) return;
    if (_pauseRequestedByUi && nextPhase == _RecPhase.recording) return;
    if (nextPhase == _RecPhase.paused || nextPhase == _RecPhase.idle) {
      _pauseRequestedByUi = false;
    }

    final durationSeconds = event.durationSeconds ?? 0;
    final eventElapsed = Duration(
      seconds: durationSeconds.clamp(0, 24 * 3600).toInt(),
    );
    var nextElapsed = _elapsed;
    if (nextPhase == _RecPhase.recording || nextPhase == _RecPhase.paused) {
      if (eventElapsed > nextElapsed) nextElapsed = eventElapsed;
      if (nextPhase == _RecPhase.recording && nextElapsed > Duration.zero) {
        _deviceRecordingStartedAt = DateTime.now().subtract(nextElapsed);
      } else if (nextPhase == _RecPhase.paused) {
        _deviceRecordingStartedAt = null;
      }
    } else {
      _deviceRecordingStartedAt = null;
    }

    setState(() {
      _phase = nextPhase;
      _view = _SessionView.recording;
      _elapsed = nextElapsed;
    });
    _ensureFakeVuTicker();
  }

  void _startAmpMeterIfPossible() {
    // Only meaningful for local recording (mic on phone). Device recording needs device-side VU in future.
    if (!kUseLocalRecorder) return;
    _ampSub?.cancel();
    _ampSub = _localRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((amp) {
      double? db;
      try {
        // record:^6.x -> Amplitude has `current` in dBFS (negative), sometimes -160 for silence.
        db = (amp.current as num?)?.toDouble();
      } catch (_) {
        // Fall back (shouldn't happen, but don't break waveform).
        db = null;
      }
      if (db == null) return;

      // Map dB (-160..0) -> 0..1.
      final raw = _dbToUnit(db);
      // AGC: keep speech visible even when overall level is low.
      _vuPeak = math.max(raw, _vuPeak * 0.92);
      final norm = (raw / (_vuPeak + 1e-4)).clamp(0.0, 1.0);
      // Smooth (EMA).
      _vuLevel = (_vuLevel * 0.78) + (norm * 0.22);
      if (!mounted) return;
      setState(() {});
    }, onError: (_) {});
  }

  void _stopAmpMeter() {
    _ampSub?.cancel();
    _ampSub = null;
  }

  void _ensureFakeVuTicker() {
    if (kUseLocalRecorder) return;
    if (_view == _SessionView.finished || _phase == _RecPhase.idle) {
      _fakeVuTicker?.cancel();
      _fakeVuTicker = null;
      return;
    }
    _fakeVuTicker ??= Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      if (_deviceRecordingStartedAt != null &&
          _phase == _RecPhase.recording &&
          !_freezeElapsed) {
        var d = now.difference(_deviceRecordingStartedAt!);
        if (d.isNegative) d = Duration.zero;
        if (d > const Duration(hours: 24)) d = const Duration(hours: 24);
        _elapsed = d;
      }
      // Pick a new target every ~0.7-1.4s to imitate "phrases".
      if (now.isAfter(_fakeVuNextTargetAt)) {
        final speaking = _phase == _RecPhase.recording;
        final r = _fakeVuRnd.nextDouble();
        // speaking: more mid/high energy; paused: low energy
        if (speaking) {
          // Occasionally a quieter phrase.
          _fakeVuTarget = (r < 0.18)
              ? (0.10 + _fakeVuRnd.nextDouble() * 0.18)
              : (0.24 + _fakeVuRnd.nextDouble() * 0.62);
        } else {
          _fakeVuTarget = 0.06 + _fakeVuRnd.nextDouble() * 0.08;
        }
        final ms = 700 + _fakeVuRnd.nextInt(700);
        _fakeVuNextTargetAt = now.add(Duration(milliseconds: ms));
      }
      // Smooth towards target (slower when speaking looks more natural).
      final k = (_phase == _RecPhase.recording) ? 0.14 : 0.22;
      _fakeVu = (_fakeVu * (1 - k)) + (_fakeVuTarget * k);
      // Add tiny micro-jitter so it never feels "flat".
      _fakeVu =
          (_fakeVu + (_fakeVuRnd.nextDouble() - 0.5) * 0.02).clamp(0.0, 1.0);
      setState(() {});
    });
  }

  static double _dbToUnit(double db) {
    // Typical mic amplitude ranges around -60..0. Record plugin may report -160 for silence.
    if (!db.isFinite) return 0.0;
    final clamped = db.clamp(-60.0, -3.0);
    final x = ((clamped + 60.0) / 57.0).clamp(0.0, 1.0);
    // Curve to make low speech more visible.
    return math.pow(x, 0.80).toDouble();
  }

  Future<void> _syncFromDeviceOnce() async {
    var hasDevice = ref.read(deviceControllerProvider).connection != null;
    if (!hasDevice &&
        ref.read(deviceControllerProvider).lastConnectedDeviceId != null) {
      final ctrl = ref.read(deviceControllerProvider.notifier);
      final ok = await ctrl.kickAutoReconnect();
      if (mounted && ok) hasDevice = true;
    }
    if (!hasDevice) {
      if (!mounted) return;
      setState(() {
        _view = _SessionView.noDevice;
        _phase = _RecPhase.idle;
        _elapsed = Duration.zero;
      });
      return;
    }
    await _syncRecordingSheetFromDeviceGstatOnce();
  }

  /// Fallback when this sheet's own AT+GSTAT fails/drops on iOS: show the
  /// controller's firmware-anchored running duration instead of leaving the
  /// popup at 0. [activeRecordingDurationSeconds] is seeded from the firmware
  /// GSTAT the controller runs at connect and keeps ticking, so it matches the
  /// device clock — this is NOT a local session-id guess (which caused the
  /// earlier "number jitter").
  void _applyControllerRecordingFallback() {
    if (!mounted || _view == _SessionView.finished) return;
    final ctrl = ref.read(deviceControllerProvider.notifier);
    final deviceState = ref.read(deviceControllerProvider);
    final recState = (deviceState.firmwareRecState ?? '').trim();
    final paused = recState == 'paused';
    final sid = (ctrl.activeRecordingSessionId ?? '').trim();
    final isRecording = recState == 'recording' || (!paused && sid.isNotEmpty);
    if (!isRecording && !paused) return;
    final seconds = ctrl.activeRecordingDurationSeconds ?? 0;
    if (seconds <= 0) return;
    final elapsed = Duration(seconds: seconds.clamp(0, 999999));
    setState(() {
      _phase = paused ? _RecPhase.paused : _RecPhase.recording;
      _view = _SessionView.recording;
      if (elapsed > _elapsed) _elapsed = elapsed;
      _deviceRecordingStartedAt =
          paused ? null : DateTime.now().subtract(_elapsed);
    });
    _ensureFakeVuTicker();
  }

  /// **Only** place this sheet actively pulls AT+GSTAT (on open + one short
  /// retry if iOS returns recording state without duration).
  /// Skipped when AT already drives the session to avoid colliding with START/PAUSE/STOP replies.
  Future<void> _syncRecordingSheetFromDeviceGstatOnce() async {
    if (kUseLocalRecorder) return;
    if (!mounted) return;
    if (_view == _SessionView.finished) return;

    final ctrl = ref.read(deviceControllerProvider.notifier);
    final activeTransferId = ctrl.activeTransferRecordingId;

    final hasDevice = ref.read(deviceControllerProvider).connection != null;
    if (!hasDevice && !kBypassDeviceConnectGate) {
      if (_phase == _RecPhase.recording && !_reconnecting) {
        final st = ref.read(deviceControllerProvider);
        if (st.reconnectStatus == 'reconnecting') return;
        if (st.connection != null) return;

        setState(() => _reconnecting = true);
        final c = ref.read(deviceControllerProvider.notifier);
        c.kickAutoReconnect().then((ok) async {
          if (!mounted) return;
          setState(() => _reconnecting = false);
          final nowSt = ref.read(deviceControllerProvider);
          if (nowSt.connection != null) return;
          if (nowSt.reconnectStatus == 'reconnecting') return;
          setState(() {
            _view = _SessionView.noDevice;
            _phase = _RecPhase.idle;
            _recordingUiFollowsAtAck = false;
          });
          // Reconnect failure UX is owned by [DeviceStatusPoller] — avoid duplicate snackbars.
        });
        return;
      }
      if (_reconnecting) return;
      setState(() {
        _view = _SessionView.noDevice;
        _phase = _RecPhase.idle;
        _recordingUiFollowsAtAck = false;
      });
      return;
    }
    if (_reconnecting) setState(() => _reconnecting = false);

    if (_recordingUiFollowsAtAck) return;

    // --- single AT+GSTAT below ---
    // Do NOT seed the clock from local estimates (session-id inference / DB
    // started-at / activeRecordingDurationSeconds) before this GSTAT: that made
    // the displayed time guess first and then snap to the firmware value when the
    // reply arrived ("number jitter"). The elapsed time on entry now comes straight
    // from the firmware GSTAT duration below, and the smooth ticker is anchored
    // to it.
    RecStatus? st;
    final gstatTimeout = Platform.isIOS
        ? const Duration(seconds: 8)
        : const Duration(seconds: 3);

    // While the device is recording AND streaming audio over BLE, the GSTAT
    // response notify is starved behind file-data notifies on iOS — the firmware
    // answers in tens of ms but the reply can reach us several seconds later
    // ("AT RX reply AT+GSTAT took 7259ms after write"). Don't leave the popup at
    // 00:00 that whole time: after a short grace period, surface the
    // controller's firmware-anchored running clock (seeded from the connect-time
    // GSTAT and ticking locally — not a session-id guess). Fast BLE (Android)
    // replies well before this fires, so the grace seed never runs there and the
    // earlier "number jitter" stays fixed.
    Timer? graceSeedTimer;
    if (!_recordingUiFollowsAtAck) {
      graceSeedTimer = Timer(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        if (_elapsed > Duration.zero) return;
        _applyControllerRecordingFallback();
      });
    }

    st = await ctrl.getRecordingStatus(timeout: gstatTimeout);
    graceSeedTimer?.cancel();
    if (!mounted) return;
    if (st == null) {
      // iOS BLE: GSTAT can time out / drop. Retry once, then fall back to the
      // controller's firmware-anchored running duration so the popup never sits
      // at 0 while the device is clearly recording.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      st = await ctrl.getRecordingStatus(timeout: gstatTimeout);
      if (!mounted) return;
      if (st == null) {
        _applyControllerRecordingFallback();
        return;
      }
    }
    // Firmware sometimes reports `recording` with duration 0 on the first read;
    // retry a couple of times to pick up the real elapsed before falling back.
    var status = st;
    if (status.state == 'recording' && status.durationSeconds <= 0) {
      for (var i = 0; i < 2 && status.durationSeconds <= 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted) return;
        final retry = await ctrl.getRecordingStatus(timeout: gstatTimeout);
        if (!mounted) return;
        if (retry != null &&
            retry.state == status.state &&
            ((retry.sessionId ?? '').isEmpty ||
                (status.sessionId ?? '').isEmpty ||
                retry.sessionId == status.sessionId) &&
            retry.durationSeconds > status.durationSeconds) {
          status = retry;
        }
      }
    }
    st = status;
    if (!mounted) return;

    if (!_recordingUiFollowsAtAck && activeTransferId != null) {
      try {
        final recRepo = await ref.read(recordingsRepositoryProvider.future);
        final rec = await recRepo.getById(activeTransferId);
        if (rec != null &&
            rec.endedAt == null &&
            rec.transferState == 'transferring') {
          if (st.state == 'recording') {
            final deviceSession = (st.sessionId ?? '').trim();
            final rowPath = rec.devicePath.trim();
            final rowSessionRoot =
                rowPath.contains('/') ? rowPath.split('/').first : rowPath;
            final sessionMatches = deviceSession.isEmpty ||
                rowSessionRoot.isEmpty ||
                deviceSession == rowSessionRoot;
            if (sessionMatches) {
              // Firmware-reported duration is the source of truth; only fall
              // back to the DB started-at estimate when the firmware did not
              // report a usable duration.
              var elapsed = Duration(
                seconds: st.durationSeconds.clamp(0, 24 * 3600).toInt(),
              );
              if (elapsed <= Duration.zero) {
                // Firmware GSTAT had no usable duration: use the controller's
                // firmware-anchored running clock before guessing from the DB.
                final ctrlSeconds = ctrl.activeRecordingDurationSeconds ?? 0;
                if (ctrlSeconds > 0) {
                  elapsed = Duration(seconds: ctrlSeconds.clamp(0, 24 * 3600));
                }
              }
              if (elapsed <= Duration.zero) {
                final startedAt =
                    rec.startedAt ?? rec.createdAt ?? DateTime.now();
                elapsed = DateTime.now().difference(startedAt);
                if (elapsed.isNegative) elapsed = Duration.zero;
                if (elapsed > const Duration(hours: 24)) {
                  elapsed = const Duration(hours: 24);
                }
              }
              final alignedStartedAt = DateTime.now().subtract(elapsed);
              if (mounted) {
                setState(() {
                  _phase = _RecPhase.recording;
                  _elapsed = elapsed;
                  _deviceRecordingId = activeTransferId;
                  _deviceRecordingStartedAt = alignedStartedAt;
                  _view = _SessionView.recording;
                });
                _ensureFakeVuTicker();
              }
              unawaited(_maybeResumeStalledLiveTransfer(st));
              return;
            }
          }
        }
      } catch (_) {}
    }

    final fallbackSeconds = (st.state == 'recording')
        ? (ctrl.activeRecordingDurationSeconds ?? 0)
        : 0;
    final displaySeconds = math.max(st.durationSeconds, fallbackSeconds);
    var nextElapsed = Duration(seconds: displaySeconds.clamp(0, 999999));
    final nextPhase = switch (st.state) {
      'recording' => _RecPhase.recording,
      'paused' => _RecPhase.paused,
      _ => _RecPhase.idle,
    };
    final nextView = (nextPhase == _RecPhase.idle)
        ? _SessionView.recording
        : _SessionView.recording;

    if (_deviceRecordingStartedAt != null && nextPhase == _RecPhase.recording) {
      var local = DateTime.now().difference(_deviceRecordingStartedAt!);
      if (local.isNegative) local = Duration.zero;
      if (local > const Duration(hours: 24)) local = const Duration(hours: 24);
      if (local < nextElapsed && displaySeconds > 0) {
        _deviceRecordingStartedAt = DateTime.now().subtract(nextElapsed);
      } else {
        nextElapsed = local;
      }
    } else if (_deviceRecordingStartedAt == null &&
        nextPhase == _RecPhase.recording &&
        displaySeconds > 0) {
      _deviceRecordingStartedAt = DateTime.now().subtract(nextElapsed);
    } else if (nextPhase != _RecPhase.recording) {
      _deviceRecordingStartedAt = null;
    }

    if (nextPhase != _phase || nextElapsed != _elapsed || nextView != _view) {
      setState(() {
        _phase = nextPhase;
        _elapsed = nextElapsed;
        _view = nextView;
      });
    }
    if (nextPhase == _RecPhase.recording &&
        ref.read(deviceControllerProvider).connection != null) {
      unawaited(_maybeResumeStalledLiveTransfer(st));
    }
  }

  Future<void> _startRecording() async {
    if (_recordingUiBusy) return;
    setState(() {
      _recordingUiBusy = true;
      _preparingStart = !kUseLocalRecorder;
    });
    try {
      if (kUseLocalRecorder) {
        await _startLocalRecording();
        return;
      }
      final hasDevice = ref.read(deviceControllerProvider).connection != null;
      if (!hasDevice && !kBypassDeviceConnectGate) {
        setState(() => _view = _SessionView.noDevice);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text(AppLocalizations.of(context)!.connectDeviceToRecord)),
          );
        }
        return;
      }
      final ctrl = ref.read(deviceControllerProvider.notifier);
      final conn = ref.read(deviceControllerProvider).connection;
      final mode = (conn != null)
          ? (await ref
                  .read(deviceRepositoryProvider.future)
                  .then((r) => r.getById(conn.device.remoteId.toString())))
              ?.recordingMode
          : null;
      final modeStr = (mode == RecordingMode.enhanced) ? 'enhanced' : 'normal';

      // Before start: end Wi‑Fi fast transfer; DeviceController stops BLE live pull. If AT+START fails, dismiss sheet then turn off device AP.
      final wifiNotifier = ref.read(wifiTransferControllerProvider.notifier);
      await wifiNotifier.cancel();
      final wifiDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (mounted && DateTime.now().isBefore(wifiDeadline)) {
        if (!ref.read(wifiTransferControllerProvider).isActive) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      if (ref.read(wifiTransferControllerProvider).isActive) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.fastSyncStillRunningCannotRecord)),
        );
        return;
      }

      final startResult = await ctrl.startRecording(mode: modeStr);
      if (!mounted) return;
      // Reconcile: AT+START may report a failure even though the firmware
      // actually started — its real ack can be lost behind a busy file
      // transfer, with the device pushing `event:"state":"RECORDING"` a beat
      // later (the controller adopts it into [activeRecordingSessionId]).
      // Treat that as success so the sheet enters the ticking recording state
      // instead of showing a spurious "start failed" dialog.
      final startedOk =
          startResult.ok || await _deviceRecordingBecameActive(ctrl);
      if (!mounted) return;
      if (!startedOk) {
        final l10n = AppLocalizations.of(context)!;
        final body = (startResult.atErrorMessage != null &&
                startResult.atErrorMessage!.trim().isNotEmpty)
            ? startResult.atErrorMessage!.trim()
            : l10n.recordingStartFailed;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.recordingStartFailed),
            content: SingleChildScrollView(child: SelectableText(body)),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  unawaited(ctrl.forceDisableDeviceWifiAp());
                },
                child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
              ),
            ],
          ),
        );
        return;
      }

      // AT+START or "accept already recording" ok → recording UI now.
      final adoptedDur = ctrl.consumeAdoptedRecordingDurationFromLastStart();
      final sessionId = (ctrl.activeRecordingSessionId ?? '').trim();
      if (sessionId.isEmpty) {
        AppLog.w(
            'RecordingSessionSheet: startRecording ok but activeRecordingSessionId is empty');
        ctrl.clearRecordingStartBleGuard();
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.recordingStartFailed)));
        return;
      }
      final now = DateTime.now();
      if (mounted) {
        setState(() {
          _recordingUiFollowsAtAck = true;
          _phase = _RecPhase.recording;
          _view = _SessionView.recording;
          if (adoptedDur != null) {
            final sec = adoptedDur.clamp(0, 999999);
            _elapsed = Duration(seconds: sec);
            _deviceRecordingStartedAt = now.subtract(Duration(seconds: sec));
          } else {
            _elapsed = Duration.zero;
            _deviceRecordingStartedAt = now;
          }
        });
      }

      try {
        final st = ref.read(deviceControllerProvider);
        final conn = st.connection;
        if (conn != null && _deviceRecordingId == null) {
          final deviceId = conn.device.remoteId.toString();
          final deviceName = await _resolvedRecordingDeviceName(
            ProviderScope.containerOf(context),
            deviceId,
            conn.device.platformName,
          );
          final recRepo = await ref.read(recordingsRepositoryProvider.future);

          final recordingId = await recRepo.createPendingDeviceRecording(
            deviceId: deviceId,
            devicePath: sessionId,
            name: _recordingDisplayName(
              deviceName,
              parseSessionTimestamp(sessionId) ?? now,
            ),
            durationSeconds: 0,
            createdAt: now,
            startedAt: now,
            endedAt: null,
            format: 'opus',
            container: 'opus',
            mtu: st.mtu,
          );
          _deviceRecordingId = recordingId;
          _deviceRecordingStartedAt = now;
          bumpRecordingsLists(ref);
          if (!ctrl.liveRecordingBleSyncEnabled) {
            await recRepo.updateTransfer(
              id: recordingId,
              state: 'transferring',
              error: '',
              errorCode: 'device_recording_resume_later',
              recordingState: 'transferring',
            );
            bumpRecordingsLists(ref);
            AppLog.i(
              'RecordingSessionSheet: iOS recording-exclusive BLE mode — '
              'defer live download for $recordingId until STOP',
            );
          } else if (!ctrl.isTransferRunningFor(recordingId)) {
            unawaited(
              ctrl.downloadSessionToLocal(
                recordingId: recordingId,
                sessionId: sessionId,
                expectedBytes: null,
                continuous: true,
                allowDuringRecordingStartGuard: true,
              ),
            );
          }
        } else if (conn != null) {
          // Already have a row (e.g. reopen / adopt). Android can release the
          // short START guard because live transfer owns the slot; iOS keeps
          // the guard until STOP so recording controls stay responsive.
          if (ctrl.liveRecordingBleSyncEnabled) {
            ctrl.clearRecordingStartBleGuard();
          }
        }
      } catch (_) {
        if (ctrl.liveRecordingBleSyncEnabled) {
          ctrl.clearRecordingStartBleGuard();
        }
      }

      _ensureFakeVuTicker();
    } finally {
      if (mounted) {
        setState(() {
          _recordingUiBusy = false;
          _preparingStart = false;
        });
      }
    }
  }

  /// True if the firmware is recording now, or becomes recording within a short
  /// grace window. AT+START's real ack can arrive (or the device can push
  /// `event:"state":"RECORDING"`) a beat after [startRecording] returns when the
  /// firmware was busy streaming a file, so poll briefly before giving up.
  Future<bool> _deviceRecordingBecameActive(DeviceController ctrl) async {
    bool active() {
      final sid = (ctrl.activeRecordingSessionId ?? '').trim();
      if (sid.isEmpty) return false;
      final fr = ref.read(deviceControllerProvider).firmwareRecState;
      return fr == 'recording' || fr == 'paused';
    }

    if (active()) return true;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (mounted && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (active()) return true;
    }
    return active();
  }

  Future<void> _togglePauseOrResume() async {
    if (kUseLocalRecorder) {
      _toggleLocalPauseOrResume();
      return;
    }
    final ctrl = ref.read(deviceControllerProvider.notifier);
    if (_phase == _RecPhase.recording) {
      if (_deviceRecordingNoLongerActive(ctrl)) {
        _closeAfterDeviceRecordingEnded();
        return;
      }
      final pauseFn = _deviceRecordingId != null
          ? () => ctrl.pauseRecordingWithSync(_deviceRecordingId!)
          : () => ctrl.pauseRecording();
      var frozenElapsed = _elapsed;
      final startedAt = _deviceRecordingStartedAt;
      if (startedAt != null) {
        var local = DateTime.now().difference(startedAt);
        if (local.isNegative) local = Duration.zero;
        if (local > const Duration(hours: 24)) {
          local = const Duration(hours: 24);
        }
        if (local > frozenElapsed) frozenElapsed = local;
      }
      _stopAmpMeter();
      _recordingUiFollowsAtAck = true;
      _pauseRequestedByUi = true;
      setState(() {
        _phase = _RecPhase.paused;
        _elapsed = frozenElapsed;
        _deviceRecordingStartedAt = null;
      });
      final ok = await pauseFn();
      if (!mounted) return;
      if (ok) {
        _pauseRequestedByUi = false;
        setState(() {
          _phase = _RecPhase.paused;
          _elapsed = frozenElapsed;
          _deviceRecordingStartedAt = null;
        });
      } else if (_deviceRecordingNoLongerActive(ctrl)) {
        _pauseRequestedByUi = false;
        _closeAfterDeviceRecordingEnded();
      } else if (await _deviceRecordingNoLongerActiveAfterSettling(ctrl)) {
        if (!mounted) return;
        _pauseRequestedByUi = false;
        _closeAfterDeviceRecordingEnded();
      } else {
        if (!mounted) return;
        _pauseRequestedByUi = false;
        _deviceRecordingStartedAt = DateTime.now().subtract(frozenElapsed);
        setState(() => _phase = _RecPhase.recording);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.pauseFailed)),
        );
      }
      return;
    }
    if (_phase == _RecPhase.paused) {
      final resumeFn = _deviceRecordingId != null
          ? () => ctrl.resumeRecordingWithSync(_deviceRecordingId!)
          : () => ctrl.resumeRecording();
      final ok = await resumeFn();
      if (!mounted) return;
      if (ok) {
        _recordingUiFollowsAtAck = true;
        _deviceRecordingStartedAt = DateTime.now().subtract(_elapsed);
        _startAmpMeterIfPossible();
        setState(() => _phase = _RecPhase.recording);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.resumeFailed)),
        );
      }
    }
  }

  bool _deviceRecordingNoLongerActive(DeviceController ctrl) {
    final sid = (ctrl.activeRecordingSessionId ?? '').trim();
    final firmwareState = ref.read(deviceControllerProvider).firmwareRecState;
    return sid.isEmpty &&
        (firmwareState == 'idle' || firmwareState == 'transmitting');
  }

  Future<bool> _deviceRecordingNoLongerActiveAfterSettling(
      DeviceController ctrl) async {
    if (_deviceRecordingNoLongerActive(ctrl)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return false;
    if (_deviceRecordingNoLongerActive(ctrl)) return true;
    final timeout = Platform.isIOS
        ? const Duration(seconds: 4)
        : const Duration(seconds: 2);
    final st = await ctrl.getRecordingStatus(timeout: timeout);
    if (!mounted || st == null) return false;
    return st.state == 'idle' || st.state == 'transmitting';
  }

  void _closeAfterDeviceRecordingEnded() {
    if (!mounted) return;
    _recordingUiFollowsAtAck = false;
    setState(() {
      _phase = _RecPhase.idle;
      _deviceRecordingStartedAt = null;
    });
    _dismissRecordingSheet();
  }

  /// Returns `true` when the mark was newly added (i.e. not a duplicate of an
  /// existing second), so callers can decide whether to surface a toast.
  bool _addMarkIfNew(Duration markAt) {
    final exists = _marks.any((m) => m.inSeconds == markAt.inSeconds);
    if (exists) return false;
    setState(() => _marks.add(markAt));
    return true;
  }

  void _mark() {
    if (_recordingUiBusy) return;
    if (kUseLocalRecorder) {
      if (!mounted) return;
      if (_phase == _RecPhase.idle) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.markFailedNotRecording)));
        return;
      }
      _addMarkIfNew(_elapsed);
      return;
    }
    final ctrl = ref.read(deviceControllerProvider.notifier);
    ctrl.markRecording().then((ok) {
      if (!mounted) return;
      if (!ok) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.markFailedDeviceNotReady)));
        return;
      }
      _addMarkIfNew(_elapsed);
    });
  }

  Future<void> _connectNow() async {
    // UX requirement: tap "Connect Now" -> close recording sheet -> go bind device
    // Bind success -> open a fresh recording sheet (timer starts from 0).
    final root = widget.rootContext;
    if (!await ensureBluetoothReadyForConnect(root)) return;
    if (!root.mounted) return;
    Navigator.of(context).pop();
    final ok = await DeviceConnectSheet.show(root);
    if (!ok) return;
    // Open again as a fresh session UI.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!root.mounted) return;
    await RecordingSessionSheet.show(root);
  }

  Future<void> _requestFinish() async {
    if (_recordingUiBusy) return;
    final result = await showAppBottomSheet<String>(
      context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppLocalizations.of(ctx)!.endRecording,
              style: Theme.of(ctx)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(ctx)!.endRecordingMessage,
              style: Theme.of(ctx)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            AppBlackPillButton(
              label: AppLocalizations.of(ctx)!.stopAndSave,
              onPressed: () => Navigator.of(ctx).pop('stop'),
            ),
            const SizedBox(height: 10),
            AppOutlinedPillButton(
              label: AppLocalizations.of(ctx)!.continueRecording,
              onPressed: () => Navigator.of(ctx).pop('continue'),
              height: 56,
              borderColor: AppColors.borderLight,
              foregroundColor: AppColors.textPrimary,
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (result == 'stop') {
      await _stopAndSave();
    } else if (result == 'continue') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.continueRecordingSnack),
            duration: const Duration(milliseconds: 1200),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _stopAndSave() async {
    if (_recordingUiBusy) return;
    if (kUseLocalRecorder) {
      setState(() {
        _recordingUiBusy = true;
        _freezeElapsed = true;
      });
      try {
        await _stopLocalAndSave();
      } finally {
        if (mounted) {
          setState(() {
            _recordingUiBusy = false;
            _freezeElapsed = false;
          });
        }
      }
      return;
    }
    final hasDevice = ref.read(deviceControllerProvider).connection != null;
    if (!hasDevice && !kBypassDeviceConnectGate) {
      setState(() => _view = _SessionView.noDevice);
      return;
    }
    // Close the sheet as soon as the user confirms Stop; AT+STOP and sync
    // continue in the background (list banner shows transfer progress).
    final root = widget.rootContext;
    final container = ProviderScope.containerOf(root);
    final deviceRecordingId = _deviceRecordingId;
    final deviceRecordingStartedAt = _deviceRecordingStartedAt;
    setState(() {
      _recordingUiBusy = true;
      _freezeElapsed = true;
      _recordingUiFollowsAtAck = false;
      _stopRequestedByUi = true;
    });
    _dismissRecordingSheet();
    unawaited(_finishDeviceStopAfterSheetDismissed(
      container: container,
      root: root,
      deviceRecordingId: deviceRecordingId,
      deviceRecordingStartedAt: deviceRecordingStartedAt,
    ));
  }

  Future<void> _finishDeviceStopAfterSheetDismissed({
    required ProviderContainer container,
    required BuildContext root,
    required String? deviceRecordingId,
    required DateTime? deviceRecordingStartedAt,
  }) async {
    try {
      final ctrl = container.read(deviceControllerProvider.notifier);
      final res = await ctrl.stopRecording();
      if (res == null) {
        AppLog.w(
          'RecordingSessionSheet: stopRecording returned null '
          '(no error toast — deferred resume / device events may still sync)',
        );
        return;
      }
      unawaited(_runPostStopDeviceTransferPipeline(
        container: container,
        root: root,
        res: res,
        deviceRecordingId: deviceRecordingId,
        deviceRecordingStartedAt: deviceRecordingStartedAt,
      ));
    } catch (e, st) {
      AppLog.e(
        'RecordingSessionSheet: stop after dismiss failed (no error toast)',
        e,
        st,
      );
    }
  }

  Future<void> _runPostStopDeviceTransferPipeline({
    required ProviderContainer container,
    required BuildContext root,
    required RecStopResult res,
    required String? deviceRecordingId,
    required DateTime? deviceRecordingStartedAt,
  }) async {
    var sessionId = (res.file ?? '').trim();
    if (sessionId.isEmpty) {
      // Align with Python: after STOP, wait a bit for firmware to finalize session metadata.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      // Some firmwares don't return session in AT+STOP; align with Python by reading latest session from AT+LIST.
      final latest = await container
          .read(deviceControllerProvider.notifier)
          .getLatestSessionId();
      sessionId = (latest ?? '').trim();
    }
    if (sessionId.isEmpty) {
      if (root.mounted) {
        final l10n = AppLocalizations.of(root)!;
        _showSnackOnRoot(root, l10n.sessionMissingCannotSync);
      }
      return;
    }

    final st = container.read(deviceControllerProvider);
    final conn = st.connection;
    if (conn == null && !kBypassDeviceConnectGate) {
      return;
    }

    final deviceId = conn?.device.remoteId.toString() ?? 'unknown_device';
    final deviceName = await _resolvedRecordingDeviceName(
      container,
      deviceId,
      conn?.device.platformName ?? '',
    );

    final now = DateTime.now();
    final startedAtFromRes =
        now.subtract(Duration(seconds: res.durationSeconds.clamp(0, 999999)));
    final ctrl = container.read(deviceControllerProvider.notifier);

    try {
      await withFreshRecordingsRepoContainer(container, (recRepo) async {
        Future<void> ensureTransferRunning(String recordingId) async {
          if (ctrl.isTransferRunningFor(recordingId)) {
            final rec = await recRepo.getById(recordingId);
            // Live pull stuck at 0 B after STOP (firmware "Empty file" / files=0) — cancel and retry.
            if (rec != null &&
                rec.endedAt != null &&
                (rec.receivedBytes ?? 0) == 0 &&
                rec.transferState == 'transferring') {
              AppLog.w(
                'RecordingSessionSheet: post-stop transfer running but 0 bytes — '
                'cancel and retry $recordingId',
              );
              await ctrl.cancelTransfer(recordingId);
              await Future<void>.delayed(const Duration(milliseconds: 300));
            } else {
              AppLog.i(
                'RecordingSessionSheet: post-stop transfer already running for $recordingId',
              );
              return;
            }
          }
          final rec = await recRepo.getById(recordingId);
          if (rec == null) return;
          final hasMergedLocal = (rec.localPath ?? '').trim().isNotEmpty &&
              rec.transferState == 'done';
          if (hasMergedLocal) return;
          final shouldRetry = rec.transferState == 'transferring' ||
              rec.transferState == 'failed' ||
              rec.transferState == 'not_started' ||
              ((rec.receivedBytes ?? 0) > 0 &&
                  (rec.localPath ?? '').trim().isEmpty);
          if (!shouldRetry) return;
          if (await ctrl
              .tryCompleteTransferFromLocalPartsIfReady(recordingId)) {
            AppLog.i(
              'RecordingSessionSheet: post-stop merged from local parts '
              'recordingId=$recordingId',
            );
            return;
          }
          final sessionForResume = (rec.devicePath).trim();
          final resumeStart = sessionForResume.isNotEmpty
              ? await ctrl.getResumeStartFileForSession(sessionForResume)
              : null;
          final retry = await ctrl.retryTransfer(recordingId);
          AppLog.i(
            'RecordingSessionSheet: post-stop ensureTransferRunning '
            'recordingId=$recordingId retry=$retry startFile=$resumeStart '
            'state=${rec.transferState} received=${rec.receivedBytes ?? 0}',
          );
        }

        if (deviceRecordingId != null) {
          final startedAt = deviceRecordingStartedAt ?? startedAtFromRes;
          await recRepo.updateDeviceRecordingMeta(
            id: deviceRecordingId,
            durationSeconds: res.durationSeconds,
            startedAt: startedAt,
            endedAt: now,
          );
          final rec = await recRepo.getById(deviceRecordingId);
          final mergedExpected = mergeStopTransferExpectedBytes(
            stopSizeBytes: res.sizeBytes,
            receivedBytes: rec?.receivedBytes ?? 0,
            previousExpectedBytes: rec?.expectedBytes,
            previousSizeBytes: rec?.sizeBytes,
          );
          if (mergedExpected != null && mergedExpected > 0) {
            final received = rec?.receivedBytes ?? 0;
            await recRepo.updateTransfer(
              id: deviceRecordingId,
              state: 'transferring',
              expectedBytes: mergedExpected,
              sizeBytes: mergedExpected,
              progress: received > 0
                  ? (received / mergedExpected).clamp(0.0, 0.995)
                  : null,
            );
          }
          bumpRecordingsLists(container);
          container.invalidate(recordingByIdProvider(deviceRecordingId));
          await ensureTransferRunning(deviceRecordingId);
          return;
        }
        // Avoid duplicate work: if resume already transfers this session, skip createPendingDeviceRecording (resets progress to 0)
        final fallbackRecordingId = '${deviceId}_$sessionId';
        if (ctrl.activeTransferRecordingId == fallbackRecordingId) {
          final rec = await recRepo.getById(fallbackRecordingId);
          if (rec != null) {
            await recRepo.updateDeviceRecordingMeta(
              id: fallbackRecordingId,
              durationSeconds: res.durationSeconds,
              startedAt: startedAtFromRes,
              endedAt: now,
            );
            if (res.sizeBytes > 0) {
              final mergedExpected = mergeStopTransferExpectedBytes(
                stopSizeBytes: res.sizeBytes,
                receivedBytes: rec.receivedBytes ?? 0,
                previousExpectedBytes: rec.expectedBytes,
                previousSizeBytes: rec.sizeBytes,
              );
              if (mergedExpected != null && mergedExpected > 0) {
                final received = rec.receivedBytes ?? 0;
                await recRepo.updateTransfer(
                  id: fallbackRecordingId,
                  state: 'transferring',
                  expectedBytes: mergedExpected,
                  sizeBytes: mergedExpected,
                  progress: received > 0
                      ? (received / mergedExpected).clamp(0.0, 0.995)
                      : null,
                );
              }
            }
            bumpRecordingsLists(container);
            container.invalidate(recordingByIdProvider(fallbackRecordingId));
            await ensureTransferRunning(fallbackRecordingId);
            return;
          }
        }
        final existing = await recRepo.getById(fallbackRecordingId);
        if (existing != null &&
            (existing.transferState == 'transferring' ||
                (existing.receivedBytes ?? 0) > 0)) {
          await recRepo.updateDeviceRecordingMeta(
            id: fallbackRecordingId,
            durationSeconds: res.durationSeconds,
            startedAt: startedAtFromRes,
            endedAt: now,
          );
          bumpRecordingsLists(container);
          container.invalidate(recordingByIdProvider(fallbackRecordingId));
          await ensureTransferRunning(fallbackRecordingId);
          return;
        }
        final nowForFallback = now;
        final startedAt = startedAtFromRes;
        final recordingId = await recRepo.createPendingDeviceRecording(
          deviceId: deviceId,
          devicePath: sessionId,
          name: _recordingDisplayName(
            deviceName,
            parseSessionTimestamp(sessionId) ?? nowForFallback,
          ),
          durationSeconds: res.durationSeconds,
          createdAt: nowForFallback,
          startedAt: startedAt,
          endedAt: nowForFallback,
          format: 'opus',
          container: 'opus',
          mtu: st.mtu,
        );
        bumpRecordingsLists(container);

        final recAfterCreate = await recRepo.getById(recordingId);
        final resumeStartFile =
            await ctrl.getResumeStartFileForSession(sessionId);
        if (ctrl.isTransferRunningFor(recordingId)) {
          AppLog.i(
            'RecordingSessionSheet: post-stop live BLE pull still running for '
            '$recordingId — skip second AT+DOWNLOAD',
          );
          return;
        }
        final ok = await container
            .read(deviceControllerProvider.notifier)
            .downloadSessionToLocal(
              recordingId: recordingId,
              sessionId: sessionId,
              startFile: resumeStartFile,
              expectedBytes: mergeStopTransferExpectedBytes(
                stopSizeBytes: res.sizeBytes,
                receivedBytes: recAfterCreate?.receivedBytes ?? 0,
                previousExpectedBytes: recAfterCreate?.expectedBytes,
                previousSizeBytes: recAfterCreate?.sizeBytes,
              ),
              notifyOnComplete: false,
              continuous: true,
            );

        bumpRecordingsLists(container);
        // Only toast when the row is actually merged locally (not a partial live leg).
        if (ok && root.mounted) {
          final merged = await recRepo.getById(recordingId);
          if (merged?.transferState == 'done' &&
              (merged?.localPath ?? '').trim().isNotEmpty) {
            final l10n = AppLocalizations.of(root)!;
            _showSnackOnRoot(root, l10n.syncComplete);
          }
        }
      });
    } catch (e, st) {
      if (isRecordingsDatabaseClosedError(e)) {
        AppLog.w(
          'RecordingSessionSheet: post-stop transfer skipped '
          '(account DB not ready)',
          e,
          st,
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _startLocalRecording() async {
    // Permission (will request if needed)
    final okPerm = await _localRecorder.hasPermission();
    if (!mounted) return;
    if (!okPerm) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.microphonePermissionDenied)));
      return;
    }

    final opusSupported =
        await _localRecorder.isEncoderSupported(AudioEncoder.opus);
    if (!mounted) return;
    if (!opusSupported) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.opusNotSupported)));
      return;
    }

    final String accountKey;
    try {
      accountKey = requireAccountDbKey(ref);
    } catch (_) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorLoginFailed)),
      );
      return;
    }
    final outDir = Directory(
      await AccountStoragePaths.localRecordingsDirectory(accountKey),
    );
    outDir.createSync(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = Platform.isIOS ? 'caf' : 'opus';
    final outPath = p.join(outDir.path, 'local_$ts.$ext');
    _localOutPath = outPath;
    _localStartedAt = DateTime.now();

    final cfg = const RecordConfig(
      encoder: AudioEncoder.opus,
      sampleRate: 16000,
      numChannels: 1,
      bitRate: 24000, // speech-friendly bitrate
      // Keep defaults for echo/noise; can be tuned later if needed.
    );

    await _localRecorder.start(cfg, path: outPath);
    if (!mounted) return;

    _localStopwatch
      ..reset()
      ..start();
    _localTicker?.cancel();
    _localTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed = _localStopwatch.elapsed);
    });

    setState(() {
      _phase = _RecPhase.recording;
      _view = _SessionView.recording;
      _elapsed = Duration.zero;
      _marks.clear();
    });

    // Start real mic-driven VU meter (after state flips to recording).
    _startAmpMeterIfPossible();
  }

  void _toggleLocalPauseOrResume() {
    if (_phase == _RecPhase.recording) {
      _localRecorder.pause().then((_) {
        _localStopwatch.stop();
        if (!mounted) return;
        _stopAmpMeter();
        _vuLevel = 0.0;
        setState(() => _phase = _RecPhase.paused);
      });
      return;
    }
    if (_phase == _RecPhase.paused) {
      _localRecorder.resume().then((_) {
        _localStopwatch.start();
        if (!mounted) return;
        setState(() => _phase = _RecPhase.recording);
        _startAmpMeterIfPossible();
      });
    }
  }

  Future<void> _stopLocalAndSave() async {
    // Stop ticker first to freeze elapsed time
    _localTicker?.cancel();
    _localTicker = null;
    _localStopwatch.stop();
    _stopAmpMeter();
    _vuLevel = 0.0;

    final outPath = await _localRecorder.stop();
    if (!mounted) return;
    final path = outPath ?? _localOutPath;
    if (path == null) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.recordingStopFailed)));
      return;
    }

    final f = File(path);
    final size = await f.length();
    final durationSeconds = math.max(1, _localStopwatch.elapsed.inSeconds);

    final repo = await ref.read(recordingsRepositoryProvider.future);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final name = _recordingDisplayName('recordings', DateTime.now());
    final startedAt = _localStartedAt;
    final endedAt = DateTime.now();
    final container = Platform.isIOS ? 'caf' : 'opus';
    await repo.createLocalRecording(
      name: name,
      localPath: path,
      durationSeconds: durationSeconds,
      sizeBytes: size,
      createdAt: endedAt,
      startedAt: startedAt,
      endedAt: endedAt,
      format: 'opus',
      container: container,
      sampleRate: 16000,
      channels: 1,
    );

    setState(() {
      _phase = _RecPhase.idle;
      _elapsed = Duration(seconds: durationSeconds);
    });
    bumpRecordingsLists(ref);

    _dismissRecordingSheet(snackMessage: l10n.recordingSavedLocally);
  }

  void _backToFiles() {
    // Ensure we land on Files page.
    GoRouter.of(widget.rootContext).go('/recordings');
    Navigator.of(context).pop();
  }

  /// Close the recording sheet. Optional [snackMessage] is shown on
  /// [rootContext] so feedback survives after the sheet is dismissed.
  void _dismissRecordingSheet({String? snackMessage}) {
    final root = widget.rootContext;
    Navigator.of(context).pop();
    if (snackMessage != null) {
      _showSnackOnRoot(root, snackMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primary = cs.primary;
    final l10n = AppLocalizations.of(context)!;
    // Do not watch full [DeviceUiState]: every BLE JSON notify updates [lastResponse] and would rebuild here
    // every ~300–500ms, re-scheduling [_syncFromDeviceOnce] when [_view]==noDevice → AT+GSTAT storm.
    final hasDevice =
        ref.watch(deviceControllerProvider.select((s) => s.connection != null));
    // Bookmark notifications coming from the device button (Appendix E.2 of
    // `protocol.md`). Keep the marker list and snackbar in sync regardless
    // of whether the bookmark was triggered by the App or the physical
    // short-press on the device.
    ref.listen(
      deviceControllerProvider.select((s) => s.lastBookmark),
      (prev, next) {
        if (kUseLocalRecorder) return;
        if (next == null) return;
        // Only fire when seq advances — protects against a state.copyWith
        // that re-triggers the listener with the same notice instance.
        if (prev != null && prev.seq == next.seq) return;
        if (!mounted) return;
        // Use the App-side elapsed clock when the firmware does not provide
        // an absolute offset (the legacy event shape).
        final markAt = next.offsetSeconds != null
            ? Duration(seconds: next.offsetSeconds!.clamp(0, 24 * 3600))
            : _elapsed;
        // The firmware notify is the source of truth for both device-button
        // presses AND App-initiated AT+MARK. On iOS, an App mark can land on
        // the device but have its ack starved by a concurrent record-while-
        // transfer flood, so [markRecording] returns false and [_mark] never
        // records it. Adding here (dedup-safe) guarantees the mark still
        // appears once the device confirms it.
        _addMarkIfNew(markAt);
      },
    );

    ref.listen(
      deviceControllerProvider.select(
        (s) => (
          s.connection?.device.remoteId.toString(),
          s.reconnectStatus,
          s.firmwareRecState,
        ),
      ),
      (prev, next) {
        if (kUseLocalRecorder) return;
        final (prevId, _, prevFr) = prev ?? (null, null, null);
        final (nextId, nextRs, nextFr) = next;

        if (prevId != null &&
            nextId == null &&
            _phase == _RecPhase.recording &&
            !_reconnecting &&
            _view != _SessionView.finished) {
          setState(() => _reconnecting = true);
        }
        if (prevId == null && nextId != null && _reconnecting) {
          setState(() => _reconnecting = false);
        }
        if (nextRs == 'failed' && _reconnecting) {
          setState(() {
            _reconnecting = false;
            _view = _SessionView.noDevice;
            _phase = _RecPhase.idle;
            _recordingUiFollowsAtAck = false;
          });
        }
        // Reconnect from offline while on empty-device page: sync once like initState (not every build postFrame).
        if (prevId == null &&
            nextId != null &&
            _view == _SessionView.noDevice &&
            !kUseLocalRecorder) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _syncFromDeviceOnce();
          });
        }
        // Device STOP push or in-app stop cleared session: GSTAT idle + empty session → leave recording UI.
        if (_view != _SessionView.finished &&
            (_phase == _RecPhase.recording || _phase == _RecPhase.paused)) {
          final ctrl = ref.read(deviceControllerProvider.notifier);
          final sid = (ctrl.activeRecordingSessionId ?? '').trim();
          final prevRecOrPause = prevFr == 'recording' || prevFr == 'paused';
          if (sid.isEmpty && nextFr == 'idle' && prevRecOrPause) {
            final appStopInProgress = _stopRequestedByUi;
            _recordingUiFollowsAtAck = false;
            // Prefer the recording id we adopted at START (which is keyed off
            // the *current* device-button session, never the unrelated
            // `activeTransferRecordingId` that may belong to a leftover
            // resume from an older session). If absent (e.g. sheet opened
            // mid-recording), we fall back to leaving `_deviceRecordingId`
            // null and the finished panel will simply hide the sync widget.
            final adoptedTransferId = _deviceRecordingId;
            final shouldShowFinished = adoptedTransferId != null &&
                adoptedTransferId.trim().isNotEmpty;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _phase = _RecPhase.idle;
                _deviceRecordingStartedAt = null;
                if (!shouldShowFinished) {
                  _elapsed = Duration.zero;
                }
              });
              _dismissRecordingSheet();
            });
            // Surface a one-line toast so the user understands that the
            // device button (long press) ended the recording. AT-driven
            // stop has its own success path in [_stopAndSave].
            if (!appStopInProgress) {
              final l10n = AppLocalizations.of(context)!;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.deviceButtonStoppedRecording),
                  duration: const Duration(milliseconds: 1500),
                ),
              );
            }
          }
        }
        // Device button started recording while the sheet was idle: adopt
        // the in-flight session so the timer / waveform / mark UI come
        // alive without requiring the user to tap the record button.
        if (!_recordingUiBusy &&
            _view != _SessionView.finished &&
            _phase == _RecPhase.idle &&
            nextFr == 'recording' &&
            (prevFr == null || prevFr == 'idle')) {
          final ctrl = ref.read(deviceControllerProvider.notifier);
          final st = ref.read(deviceControllerProvider);
          final sid = (ctrl.activeRecordingSessionId ?? '').trim();
          // Derive the *current* recording id from the active session id, not
          // from `activeTransferRecordingId` (that may still be the previous
          // session's resume transfer — see _startLiveDownloadForDeviceInitiatedRecording).
          // [DeviceController._startLiveDownloadForDeviceInitiatedRecording]
          // always inserts a row keyed by `${deviceId}_${sid}`, even when
          // the live download itself is deferred behind another transfer.
          final deviceId = st.connection?.device.remoteId.toString();
          final adoptedId =
              (sid.isNotEmpty && deviceId != null) ? '${deviceId}_$sid' : null;
          if (sid.isNotEmpty) {
            final now = DateTime.now();
            final adoptedElapsed = Duration(
              seconds:
                  (ctrl.activeRecordingDurationSeconds ?? 0).clamp(0, 999999),
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _phase = _RecPhase.recording;
                _view = _SessionView.recording;
                _elapsed = adoptedElapsed;
                _deviceRecordingStartedAt = now.subtract(adoptedElapsed);
                _deviceRecordingId = adoptedId;
                _recordingUiFollowsAtAck = true;
              });
              _ensureFakeVuTicker();
            });
            final l10n = AppLocalizations.of(context)!;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.deviceButtonStartedRecording),
                duration: const Duration(milliseconds: 1500),
              ),
            );
          }
        }
      },
    );
    final hasDeviceForUi =
        kUseLocalRecorder ? true : (hasDevice || kBypassDeviceConnectGate);
    final battery = widget.batteryPercent;

    // If device disconnected while not finished, show no-device empty state.
    final effectiveView =
        (!_view.isFinished && !hasDeviceForUi) ? _SessionView.noDevice : _view;
    _ensureFakeVuTicker();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (effectiveView == _SessionView.noDevice) ...[
            const SizedBox(height: 24),
            const Icon(Icons.bluetooth_disabled,
                size: 120, color: AppColors.gray200),
            const SizedBox(height: 18),
            Text(
              l10n.noDeviceConnected,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              l10n.connectDeviceToRecord,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            AppBlackPillButton(
              label: l10n.connectNow,
              onPressed: _connectNow,
            ),
            const SizedBox(height: 32),
          ] else if (effectiveView == _SessionView.finished) ...[
            const SizedBox(height: 32),
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(55),
              ),
              child: Center(
                child: Container(
                  width: 66,
                  height: 66,
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: BorderRadius.circular(33),
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 36),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              l10n.recordingFinished,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              kUseLocalRecorder
                  ? l10n.recordingFinishedLocal
                  : l10n.recordingFinishedDevice,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: const Color(0xFF6B7280)),
              textAlign: TextAlign.center,
            ),
            if (!kUseLocalRecorder &&
                _deviceRecordingId != null &&
                hasDeviceForUi) ...[
              const SizedBox(height: 16),
              _RecordingSyncProgress(
                  recordingId: _deviceRecordingId!,
                  primary: primary,
                  l10n: l10n,
                  hasDevice: hasDeviceForUi),
            ],
            const SizedBox(height: 18),
            AppBlackPillButton(
              label: l10n.backToFiles,
              onPressed: _backToFiles,
            ),
            const SizedBox(height: 10),
          ] else ...[
            Row(
              children: [
                _RecordingStatusLabel(
                  phase: _phase,
                  color: primary,
                  isLocal: kUseLocalRecorder,
                  preparing: _preparingStart,
                ),
                const Spacer(),
                if (battery != null)
                  _BatteryPill(percent: battery, color: primary),
              ],
            ),
            const SizedBox(height: 26),

            // Center waveform (animated)
            SizedBox(
              height: 140,
              child: Center(
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (_, __) {
                    final isActive = _phase == _RecPhase.recording;
                    final level = kUseLocalRecorder ? _vuLevel : _fakeVu;
                    return _LiveWaveformIcon(
                      color: primary,
                      t: _anim.value,
                      isActive: isActive,
                      level: level,
                    );
                  },
                ),
              ),
            ),

            const SizedBox(height: 12),
            Text(
              _fmtHms(_elapsed),
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
            ),
            const SizedBox(height: 18),

            if (!kUseLocalRecorder &&
                _deviceRecordingId != null &&
                hasDeviceForUi &&
                (_phase == _RecPhase.recording ||
                    _phase == _RecPhase.paused)) ...[
              _RecordingSyncProgress(
                recordingId: _deviceRecordingId!,
                primary: primary,
                l10n: l10n,
                hasDevice: hasDeviceForUi,
                liveWhileRecording: true,
              ),
              const SizedBox(height: 14),
            ],

            if (_marks.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _marks.reversed.take(4).map((d) {
                  return _MarkerChip(
                      label: l10n.keyAt(_fmtMs(d)), color: primary);
                }).toList(),
              ),
              const SizedBox(height: 14),
            ],

            // control bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surfaceSubtle,
                borderRadius: BorderRadius.circular(AppRadii.r28),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _SmallCircleAction(
                      icon: Icons.star_border_rounded,
                      label: l10n.mark,
                      enabled: _phase != _RecPhase.idle && !_recordingUiBusy,
                      backgroundColor: Colors.white,
                      iconColor: AppColors.textPrimary,
                      labelColor: AppColors.textSecondary,
                      onTap: _mark,
                    ),
                  ),
                  const SizedBox(width: 10),
                  _BigCenterAction(
                    icon: _primaryButtonStartsNewRecording
                        ? Icons.mic_rounded
                        : (_phase == _RecPhase.recording
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                    label: _primaryButtonStartsNewRecording
                        ? l10n.record
                        : (_phase == _RecPhase.recording
                            ? l10n.pause
                            : l10n.resume),
                    enabled: !_recordingUiBusy,
                    busy: _recordingUiBusy,
                    onTap: () async {
                      if (_recordingUiBusy) return;
                      if (!hasDeviceForUi) {
                        setState(() => _view = _SessionView.noDevice);
                        return;
                      }
                      if (_primaryButtonStartsNewRecording) {
                        await _startRecording();
                        return;
                      }
                      setState(() => _recordingUiBusy = true);
                      try {
                        if (kUseLocalRecorder) {
                          _toggleLocalPauseOrResume();
                        } else {
                          await _togglePauseOrResume();
                        }
                      } finally {
                        if (mounted) setState(() => _recordingUiBusy = false);
                      }
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _SmallCircleAction(
                      icon: Icons.stop_rounded,
                      label: l10n.finish,
                      enabled: !(_elapsed == Duration.zero &&
                              _phase == _RecPhase.idle) &&
                          !_recordingUiBusy,
                      backgroundColor: const Color(0xFFE53935),
                      iconColor: Colors.white,
                      labelColor: AppColors.textSecondary,
                      onTap: _requestFinish,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

extension on _SessionView {
  bool get isFinished => this == _SessionView.finished;
}

enum _RecPhase { idle, recording, paused }

class _RecordingStatusLabel extends StatelessWidget {
  final _RecPhase phase;
  final Color color;
  final bool isLocal;
  final bool preparing;

  const _RecordingStatusLabel(
      {required this.phase,
      required this.color,
      required this.isLocal,
      this.preparing = false});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isRecording = phase == _RecPhase.recording;
    if (preparing) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.preparingRecording,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.1,
                ),
          ),
        ],
      );
    }
    final label = switch (phase) {
      _RecPhase.idle => l10n.ready,
      _RecPhase.paused => l10n.paused,
      _RecPhase.recording =>
        isLocal ? l10n.localRecording : l10n.deviceRecording,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: isRecording ? color : AppColors.textTertiary,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: isRecording ? color : AppColors.textSecondary,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.1,
              ),
        ),
      ],
    );
  }
}

class _BatteryPill extends StatelessWidget {
  final int percent;
  final Color color;

  const _BatteryPill({required this.percent, required this.color});

  @override
  Widget build(BuildContext context) {
    final p = percent.clamp(0, 100);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.battery_full, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            '$p%',
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _LiveWaveformIcon extends StatelessWidget {
  final Color color;
  final double t;
  final bool isActive;
  final double level; // 0..1

  const _LiveWaveformIcon({
    required this.color,
    required this.t,
    required this.isActive,
    required this.level,
  });

  @override
  Widget build(BuildContext context) {
    // 17 bars, center is tallest; sides fade to match design.
    const n = 17;
    final mid = (n - 1) / 2.0;
    final maxDist = mid;
    final basePhase = t * math.pi * 2;

    // Idle still shows a subtle "breathing" so it doesn't feel dead.
    final l =
        (isActive ? level : 0.10 + 0.04 * math.sin(basePhase)).clamp(0.0, 1.0);

    final bars = List.generate(n, (i) {
      final dist = (i - mid).abs();
      final w = (1.0 - (dist / maxDist)).clamp(0.0, 1.0);
      final weight = math.pow(w, 1.6).toDouble(); // emphasize center

      // "Real-feel" motion:
      // - main amplitude follows VU level
      // - each bar gets small phase offsets so it doesn't move in perfect sync
      final micro =
          isActive ? (0.90 + 0.10 * math.sin(basePhase + i * 0.62)) : 1.0;
      final jitter =
          isActive ? (0.96 + 0.04 * math.sin(basePhase * 1.7 + i * 0.93)) : 1.0;

      // Center reacts stronger; sides weaker.
      final shaped = (0.20 + 0.80 * weight) * l;
      final amp = (0.18 + 0.82 * shaped) * micro * jitter;

      // Prototype-like: sides lighter.
      final alpha = (0.22 + 0.78 * weight).clamp(0.0, 1.0);
      return _Bar(h: 110 * amp, w: 7, color: color.withValues(alpha: alpha));
    });

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < bars.length; i++) ...[
          bars[i],
          if (i != bars.length - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  final double h;
  final double w;
  final Color color;

  const _Bar({required this.h, required this.w, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: w,
      height: h.clamp(16, 110),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
    );
  }
}

class _MarkerChip extends StatelessWidget {
  final String label;
  final Color color;

  const _MarkerChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }
}

class _SmallCircleAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final Color backgroundColor;
  final Color iconColor;
  final Color labelColor;

  const _SmallCircleAction({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.enabled,
    required this.backgroundColor,
    required this.iconColor,
    required this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadii.r18),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: enabled ? backgroundColor : AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadii.pill),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Icon(
                icon,
                color: enabled ? iconColor : AppColors.textTertiary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: labelColor,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BigCenterAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final bool busy;

  const _BigCenterAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: enabled ? Colors.black : AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 16,
                        offset: const Offset(0, 10),
                      ),
                    ]
                  : null,
            ),
            child: busy
                ? const Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: Colors.white,
                      ),
                    ),
                  )
                : Icon(
                    icon,
                    color: enabled ? Colors.white : AppColors.textTertiary,
                    size: 34,
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color:
                      enabled ? AppColors.textPrimary : AppColors.textTertiary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.4,
                ),
          ),
        ],
      ),
    );
  }
}

/// Sync progress shown on completion page after STOP, so user sees transfer still in progress (aligned with Python record.py "Waiting for sync..." feedback).
class _RecordingSyncProgress extends ConsumerWidget {
  final String recordingId;
  final Color primary;
  final AppLocalizations l10n;
  final bool liveWhileRecording;
  final bool hasDevice;

  const _RecordingSyncProgress({
    required this.recordingId,
    required this.primary,
    required this.l10n,
    this.liveWhileRecording = false,
    this.hasDevice = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hasDevice) return const SizedBox.shrink();
    final asyncRec = ref.watch(recordingByIdProvider(recordingId));
    return asyncRec.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      data: (rec) {
        if (rec == null) return const SizedBox.shrink();
        // In-flight BLE leg for this row: suppress the byte-based merge inference
        // so a transient `received` overshoot during a resume re-pull keeps the
        // progress bar visible instead of flipping to "merging".
        final transferActiveForRec =
            (ref.watch(deviceControllerProvider).activeTransferRecordingId ?? '')
                    .trim() ==
                recordingId.trim();
        final state = rec.transferState;
        final sessionStillLive = liveWhileRecording ||
            (rec.source == 'device' && rec.endedAt == null && state == 'done');
        if (state == 'done' && !sessionStillLive) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: primary, size: 18),
              const SizedBox(width: 6),
              Text(
                l10n.syncComplete,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: primary,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          );
        }
        if (state == 'failed') {
          return const SizedBox.shrink();
        }
        if ((rec.transferProgress ?? 0) >= 1.0 &&
            !liveWhileRecording &&
            !transferActiveForRec &&
            !transferUiLocalMergePhase(
              recording: rec,
              liveRecordWhileBleTransfer: liveWhileRecording,
              transferActiveForRecording: transferActiveForRec,
            )) {
          return const SizedBox.shrink();
        }
        // transferring
        if (liveWhileRecording) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    backgroundColor: primary.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation<Color>(primary),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _syncingReceivedText(l10n, rec.receivedBytes),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: primary,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          );
        }
        final rawP = transferProgressForDisplay(
          recording: rec,
          liveRecordWhileBleTransfer: liveWhileRecording,
          transferActiveForRecording: transferActiveForRec,
        );
        final p = rawP;
        final localMerging = transferUiLocalMergePhase(
          recording: rec,
          liveRecordWhileBleTransfer: liveWhileRecording,
          transferActiveForRecording: transferActiveForRec,
        );
        final hasDeterminateProgress = p != null && p > 0 && !localMerging;
        final barWidth = 200.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: barWidth,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: hasDeterminateProgress ? p : null,
                  minHeight: 6,
                  backgroundColor: primary.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(primary),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              localMerging
                  ? l10n.fastSyncMerging
                  : hasDeterminateProgress
                      ? l10n.syncingPercent(
                          p >= 1.0 ? 100 : (p * 100).round().clamp(0, 100),
                        )
                      : _syncingReceivedText(l10n, rec.receivedBytes),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: primary,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

String _syncingReceivedText(AppLocalizations l10n, int? receivedBytes) {
  if (receivedBytes == null || receivedBytes <= 0) return l10n.syncing;
  return '${l10n.syncing} (${formatTransferReceivedBytesUi(receivedBytes)})';
}

String _fmtHms(Duration d) {
  final total = d.inSeconds.clamp(0, 999999);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

String _fmtMs(Duration d) {
  final total = d.inSeconds.clamp(0, 999999);
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}
