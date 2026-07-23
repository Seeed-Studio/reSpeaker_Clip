import 'dart:async';
import 'dart:io';

import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;

import '../utils/sdk_log.dart';
import 'firmware_processor.dart';

/// High-level OTA upgrade phase, normalised across iOS/Android mcumgr behaviour.
enum OtaPhase {
  /// Initial state before any work has started.
  idle,

  /// Firmware archive is being parsed / verified.
  preparing,

  /// Uploading image bytes over BLE (SMP) — this is where most time is spent.
  uploading,

  /// Validating / testing the uploaded image on the device.
  validating,

  /// Device is rebooting / swapping the active slot.
  resetting,

  /// Image was confirmed by the bootloader. Upgrade complete.
  success,

  /// The upgrade failed; see [OtaSession.lastError].
  failed,

  /// The upgrade was cancelled.
  cancelled,
}

/// A single OTA progress event emitted by [OtaSession.events].
class OtaProgress {
  /// Current phase of the upgrade.
  final OtaPhase phase;

  /// Aggregated progress in `0.0 .. 1.0` across all images in the archive.
  final double progress;

  /// Bytes flashed so far across all images.
  final int bytesSent;

  /// Total bytes to flash across all images.
  final int totalBytes;

  /// Plain-English status text suitable for UI display.
  final String message;

  const OtaProgress({
    required this.phase,
    required this.progress,
    required this.bytesSent,
    required this.totalBytes,
    required this.message,
  });

  @override
  String toString() =>
      'OtaProgress(phase=$phase, progress=${(progress * 100).toStringAsFixed(1)}%, '
      '$bytesSent/$totalBytes, "$message")';
}

/// Drives a single firmware upgrade end-to-end.
///
/// Typical usage:
///
/// ```dart
/// final session = OtaSession(deviceId: conn.device.remoteId.str);
/// session.events.listen((p) => print(p));
/// final ok = await session.upgrade(File('/path/to/firmware.zip'));
/// ```
///
/// The session is single-use; create a new one per upgrade attempt.
class OtaSession {
  /// Device identifier — same as `BluetoothDevice.remoteId.str` from the BLE
  /// client. mcumgr uses this to (re)connect over SMP, independent of the
  /// AT(JSON) BLE link.
  final String deviceId;

  OtaSession({required this.deviceId});

  final _events = StreamController<OtaProgress>.broadcast();

  /// Live progress + phase events. Listen *before* calling [upgrade] to avoid
  /// missing the earliest events.
  Stream<OtaProgress> get events => _events.stream;

  OtaPhase _phase = OtaPhase.idle;
  Object? _lastError;
  StackTrace? _lastStackTrace;
  bool _cancelled = false;

  mcumgr.FirmwareUpdateManager? _manager;
  StreamSubscription<mcumgr.FirmwareUpgradeState>? _stateSub;
  StreamSubscription<mcumgr.ProgressUpdate>? _progressSub;

  OtaPhase get phase => _phase;
  Object? get lastError => _lastError;
  StackTrace? get lastStackTrace => _lastStackTrace;

  /// Run the upgrade. Returns `true` on success, `false` on failure or
  /// cancellation. Detailed reason is available via [phase] / [lastError].
  Future<bool> upgrade(
    File firmwareFile, {
    mcumgr.FirmwareUpgradeConfiguration? configuration,
  }) async {
    _emit(OtaPhase.preparing, 0, 0, 0, 'Parsing firmware...');
    final List<mcumgr.Image> images;
    try {
      images = await OtaFirmwareProcessor.processFile(firmwareFile);
    } catch (e, st) {
      _fail(e, st, 'Firmware parsing failed: $e');
      return false;
    }
    return _runUpgrade(images, configuration);
  }

  /// Same as [upgrade] but accepts already-parsed mcumgr images.
  Future<bool> upgradeImages(
    List<mcumgr.Image> images, {
    mcumgr.FirmwareUpgradeConfiguration? configuration,
  }) =>
      _runUpgrade(images, configuration);

  Future<bool> _runUpgrade(
    List<mcumgr.Image> images,
    mcumgr.FirmwareUpgradeConfiguration? configuration,
  ) async {
    if (_cancelled) {
      _emit(OtaPhase.cancelled, 0, 0, 0, 'Cancelled before start');
      return false;
    }

    final totalBytes = images.fold<int>(0, (a, e) => a + e.data.length);
    if (totalBytes <= 0) {
      _fail(
        const OtaFirmwareException('No firmware bytes to flash'),
        StackTrace.current,
        'No firmware bytes to flash',
      );
      return false;
    }

    final config = configuration ??
        const mcumgr.FirmwareUpgradeConfiguration(
          estimatedSwapTime: Duration.zero,
          eraseAppSettings: true,
        );

    final done = Completer<bool>();

    try {
      final factory = mcumgr.FirmwareUpdateManagerFactory();
      _manager = await factory.getUpdateManager(deviceId);

      // Progress aggregation: mcumgr reports `bytesSent / imageSize` per
      // **current** image; for multi-image ZIPs the bar would jump to 100% on
      // image 0 then snap to 0 when image 1 starts. We accumulate finished
      // images and add the in-flight progress.
      var completedBytes = 0;
      var lastImageSize = -1;
      var lastBytesSent = 0;

      _emit(OtaPhase.uploading, 0, 0, totalBytes, 'Uploading firmware...');

      _progressSub = _manager!.progressStream.listen((p) {
        final imageSize = p.imageSize;
        final bytesSent = p.bytesSent;
        if (imageSize <= 0) return;

        final transitioned = lastImageSize > 0 &&
            (imageSize != lastImageSize || bytesSent < lastBytesSent);
        if (transitioned) {
          completedBytes += lastImageSize;
        }
        lastImageSize = imageSize;
        lastBytesSent = bytesSent;

        final aggBytes = completedBytes + bytesSent;
        final ratio = totalBytes > 0
            ? (aggBytes / totalBytes).clamp(0.0, 1.0)
            : 0.0;
        _emit(
          OtaPhase.uploading,
          ratio,
          aggBytes,
          totalBytes,
          'Uploading firmware...',
        );
      });

      _stateSub = _manager!.setup().listen(
        (state) {
          final phase = _mapState(state);
          // Once we leave upload, mcumgr no longer reports byte progress; snap
          // to 100% so subsequent phases don't look frozen.
          final snapTotal = phase != OtaPhase.uploading
              ? totalBytes
              : (completedBytes + lastBytesSent).clamp(0, totalBytes);
          _emit(
            phase,
            phase == OtaPhase.uploading ? -1 : 1.0,
            snapTotal,
            totalBytes,
            _stateText(state),
          );
          if (phase == OtaPhase.success && !done.isCompleted) {
            done.complete(true);
          }
        },
        onError: (Object e, StackTrace? st) {
          if (!done.isCompleted) {
            done.completeError(e, st ?? StackTrace.current);
          }
        },
        onDone: () {
          // iOS: the state stream may close without emitting "success".
          if (!done.isCompleted) done.complete(true);
        },
        cancelOnError: false,
      );

      // mcumgr's `update()` returns as soon as DFU is *started*; real
      // completion arrives via the state stream above.
      await _manager!.update(images, configuration: config);
      final ok = await done.future;
      if (ok) {
        _emit(OtaPhase.success, 1.0, totalBytes, totalBytes, 'Upgrade complete');
      }
      return ok;
    } catch (e, st) {
      if (_cancelled) {
        _emit(OtaPhase.cancelled, 0, 0, totalBytes, 'Cancelled');
        return false;
      }
      _fail(e, st, 'Upgrade failed: $e');
      return false;
    } finally {
      await _cleanup();
    }
  }

  /// Abort the active upgrade. Subsequent events will be a single
  /// [OtaPhase.cancelled] entry; [upgrade] returns `false`.
  Future<void> cancel() async {
    _cancelled = true;
    await _releaseManager();
  }

  Future<void> _cleanup() async {
    await _progressSub?.cancel();
    await _stateSub?.cancel();
    _progressSub = null;
    _stateSub = null;
    await _releaseManager();
  }

  /// Release the native mcumgr manager so a subsequent OTA on the same device
  /// does not fail with `updateManagerExists`.
  Future<void> _releaseManager() async {
    final manager = _manager;
    _manager = null;
    if (manager == null) return;
    try {
      await manager.kill();
    } catch (e, st) {
      SdkLog.w('OtaSession: manager.kill failed', e, st);
    }
  }

  /// Closes the event stream. Call after the consumer is done listening.
  Future<void> dispose() async {
    await _cleanup();
    await _events.close();
  }

  void _emit(
    OtaPhase phase,
    double progress,
    int bytesSent,
    int totalBytes,
    String message,
  ) {
    _phase = phase;
    if (_events.isClosed) return;
    _events.add(OtaProgress(
      phase: phase,
      progress: progress,
      bytesSent: bytesSent,
      totalBytes: totalBytes,
      message: message,
    ));
  }

  void _fail(Object error, StackTrace stackTrace, String message) {
    _lastError = error;
    _lastStackTrace = stackTrace;
    _emit(OtaPhase.failed, -1, 0, 0, message);
    SdkLog.w('OtaSession failed', error, stackTrace);
  }

  static OtaPhase _mapState(mcumgr.FirmwareUpgradeState s) {
    switch (s) {
      case mcumgr.FirmwareUpgradeState.upload:
        return OtaPhase.uploading;
      case mcumgr.FirmwareUpgradeState.validate:
      case mcumgr.FirmwareUpgradeState.test:
      case mcumgr.FirmwareUpgradeState.confirm:
        return OtaPhase.validating;
      case mcumgr.FirmwareUpgradeState.reset:
      case mcumgr.FirmwareUpgradeState.eraseAppSettings:
        return OtaPhase.resetting;
      case mcumgr.FirmwareUpgradeState.bootloaderInfo:
      case mcumgr.FirmwareUpgradeState.requestMcuMgrParameters:
        return OtaPhase.preparing;
      case mcumgr.FirmwareUpgradeState.success:
        return OtaPhase.success;
      // ignore: unreachable_switch_default
      default:
        return OtaPhase.preparing;
    }
  }

  static String _stateText(mcumgr.FirmwareUpgradeState s) {
    return switch (s) {
      mcumgr.FirmwareUpgradeState.upload => 'Uploading firmware...',
      mcumgr.FirmwareUpgradeState.validate => 'Validating...',
      mcumgr.FirmwareUpgradeState.test => 'Testing...',
      mcumgr.FirmwareUpgradeState.confirm => 'Confirming...',
      mcumgr.FirmwareUpgradeState.reset => 'Resetting device...',
      mcumgr.FirmwareUpgradeState.eraseAppSettings => 'Erasing settings...',
      mcumgr.FirmwareUpgradeState.bootloaderInfo => 'Reading bootloader info...',
      mcumgr.FirmwareUpgradeState.requestMcuMgrParameters =>
        'Requesting parameters...',
      mcumgr.FirmwareUpgradeState.success => 'Upgrade complete',
      // ignore: unreachable_switch_default
      _ => s.toString(),
    };
  }
}
