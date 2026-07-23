import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
// The app keeps its own copies of these session helpers under core/audio/;
// hide the SDK's identically-named exports so both can coexist.
import 'package:sensecraft_voice/sensecraft_voice.dart'
    hide
        SessionResumeMarkers,
        resumeFileIndexFromStartFile,
        resolveResumeByteFloor,
        resolveSessionResumeMarkers,
        compareSessionOpusPartFilename,
        partNumberFromSessionOpusFilename,
        isCanonicalCompleteSessionOpusSlice,
        SessionOpusSliceInventory,
        inventorySessionOpusParts;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException;

import '../../../core/db/account_db_key.dart';
import '../../../core/storage/account_storage_paths.dart';
import '../../../core/audio/session_merge_queue.dart';
import '../../../core/audio/session_opus_part_names.dart';
import '../../../core/audio/session_resume_markers.dart';
import '../../../core/audio/raw_opus_utils.dart';
import '../../../core/log/app_log.dart';
import '../../../core/observability/sentry_service.dart';
import '../data/device_repository.dart';
import '../../recordings/data/recordings_repository.dart';
import '../../recordings/domain/recording.dart';
import '../../recordings/presentation/recordings_controller.dart';
import '../../recordings/utils/recording_display_name.dart';
import 'wifi_transfer_controller.dart';

final bleClientProvider =
    Provider<SenseCraftVoiceClient>((ref) => SenseCraftVoiceClient());

bool isBluetoothAdapterDisabled(BluetoothAdapterState state) =>
    state == BluetoothAdapterState.off ||
    state == BluetoothAdapterState.unavailable ||
    state == BluetoothAdapterState.turningOff;

final deviceControllerProvider =
    NotifierProvider<DeviceController, DeviceUiState>(DeviceController.new);

({Future<void> future, void Function() cancel}) debouncedDisconnectFuture(
  BluetoothDevice device, {
  Duration debounce = const Duration(milliseconds: 500),
}) {
  final completer = Completer<void>();
  Timer? debounceTimer;
  StreamSubscription<BluetoothConnectionState>? sub;
  sub = device.connectionState.listen((s) {
    if (s == BluetoothConnectionState.disconnected) {
      debounceTimer?.cancel();
      debounceTimer = Timer(debounce, () {
        if (!completer.isCompleted) {
          // Normal completion — [Future.any] treats this as disconnect without
          // leaving a rejected future that triggers PlatformDispatcher if the
          // leg already finished first.
          completer.complete();
        }
        sub?.cancel();
      });
    } else {
      debounceTimer?.cancel();
      debounceTimer = null;
    }
  });
  void cancel() {
    debounceTimer?.cancel();
    sub?.cancel();
  }

  return (future: completer.future, cancel: cancel);
}

/// Android-only: drop the OS BLE bond so the phone forgets this device.
///
/// Works while GATT is up (preferred) or after the Clip reboots from
/// `AT+PAIR=reset` (native unbond may complete even when fbp throws on wait).
Future<bool> _removeAndroidBondForDevice(BluetoothDevice device) async {
  if (!Platform.isAndroid) return false;

  Future<BluetoothBondState> readBond() async {
    try {
      return await device.bondState.first.timeout(const Duration(seconds: 3));
    } catch (_) {
      return BluetoothBondState.none;
    }
  }

  var bond = await readBond();
  if (bond == BluetoothBondState.none) {
    AppLog.i(
      'DeviceController.removeAndroidBond: already unbonded remoteId=${device.remoteId}',
    );
    return true;
  }

  for (var attempt = 1; attempt <= 2; attempt++) {
    AppLog.i(
      'DeviceController.removeAndroidBond: removeBond remoteId=${device.remoteId} '
      'connected=${device.isConnected} attempt=$attempt',
    );
    try {
      await device.removeBond(timeout: 30);
    } catch (e, st) {
      AppLog.w(
        'DeviceController.removeAndroidBond: removeBond threw remoteId=${device.remoteId}',
        e,
        st,
      );
    }

    await Future<void>.delayed(const Duration(milliseconds: 400));
    bond = await readBond();
    if (bond == BluetoothBondState.none) {
      AppLog.i(
        'DeviceController.removeAndroidBond: done remoteId=${device.remoteId}',
      );
      return true;
    }
  }

  AppLog.w(
    'DeviceController.removeAndroidBond: bond still $bond remoteId=${device.remoteId}',
  );
  return false;
}

const _kIosPairingResetTombstonePrefix = 'device.ios_pairing_reset.';
const _kIosPairingResetTombstoneTtl = Duration(hours: 24);
const _kIosPeerRemovedPairingInfoErrorCode = 'ios_peer_removed_pairing_info';
const _kIosStaleBluetoothPairingErrorCode = 'ios_stale_bluetooth_pairing';

bool _isIosPeerRemovedPairingInfo(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('peer removed pairing information') ||
      (msg.contains('apple-code: 14') && msg.contains('pair'));
}

bool _looksLikeIosStaleBondError(Object error) {
  if (_isIosPeerRemovedPairingInfo(error)) return false;
  final msg = error.toString().toLowerCase();
  return msg.contains('insufficient authentication') ||
      msg.contains('insufficient encryption') ||
      msg.contains('auth_fail') ||
      msg.contains('authentication') ||
      msg.contains('encryption') ||
      msg.contains('pair') ||
      msg.contains('bond') ||
      msg.contains('not authorized') ||
      msg.contains('permission') ||
      msg.contains('status 5') ||
      msg.contains('status 15') ||
      msg.contains('status 137') ||
      msg.contains('characteristics not found') ||
      msg.contains('did not respond');
}

/// Narrower than [_looksLikeIosStaleBondError]: only crypto/bond failures that
/// warrant telling the user to Forget the device in iOS Settings.
bool _isIosDefiniteStaleBondError(Object error) {
  if (_isIosPeerRemovedPairingInfo(error)) return true;
  final msg = error.toString().toLowerCase();
  return msg.contains('insufficient authentication') ||
      msg.contains('insufficient encryption') ||
      msg.contains('auth_fail') ||
      msg.contains('authentication failure') ||
      msg.contains('encryption failure') ||
      msg.contains('status 5') ||
      msg.contains('status 15') ||
      msg.contains('status 137');
}

/// Per receive-leg completion inside [DeviceController.downloadSessionToLocal] (CRC resync vs normal end).
enum _BleTransferLegEnd { unknown, crcResync, spuriousTdResume }

/// While recording and transferring, total size is unknown: do not return an estimated ratio; the UI shows
/// "X MB received" plus an indeterminate bar to avoid a sudden percentage jump after Stop.
double? _transferProgressOrNull(int received, int? expectedBytes) {
  if (expectedBytes != null && expectedBytes > 0) {
    return (received / expectedBytes).clamp(0.0, 0.995);
  }
  return null;
}

/// Seed [receivedBytes] on resume without dropping user-visible progress, but
/// never above the known session size (Wi‑Fi peak can double-count and falsely
/// trigger the "merging" UI while local slices are still incomplete).
int _reconcileTransferReceivedBytes({
  required int preserved,
  required int local,
  required int expected,
}) {
  if (expected > 0 && preserved > (expected * 1.05).round()) {
    return local > 0 ? local : 0;
  }
  var p = preserved;
  if (expected > 0 && p > expected) p = expected;
  return math.max(p, local);
}

bool _isSqfliteDatabaseClosed(Object e) =>
    e is DatabaseException && e.isDatabaseClosedError();

/// BLE progress aligned with Wi‑Fi (see [WifiTransferState.progress], [WifiTransferController] DB updates):
/// - With [expectedSession]: `receivedSession / expectedSession` (same as Wi‑Fi `cum/expectedBytes`).
/// - Else if firmware reports `files` + `size`/`bytes`:
///   `filesDone/totalFiles + (received/sessionBytes)/totalFiles`.
/// - If only `files`: `filesDone/totalFiles` (same as Wi‑Fi without expected: `fileIdx/totalFiles`).
/// - Else slice mode: current slice `bytesThisFile / currentFileDeclaredSize`.
double? _wifiAlignedBleTransferProgress({
  required bool framedMode,
  required int currentFileDeclaredSize,
  required int bytesThisFile,
  required int receivedSession,
  required int? expectedSession,
  required int filesCompleted,
  required int deviceTotalFiles,
  required int deviceSessionBytes,
}) {
  final r = TransferProgress.wifiAligned(
    framedMode: framedMode,
    currentFileDeclaredSize: currentFileDeclaredSize,
    bytesThisFile: bytesThisFile,
    receivedSession: receivedSession,
    expectedSession: expectedSession,
    filesCompleted: filesCompleted,
    deviceTotalFiles: deviceTotalFiles,
    deviceSessionBytes: deviceSessionBytes,
  );
  if (r != null && r >= 0.99) {
    AppLog.d(
      'BLE transferProgress near 0.995 cap: branch=${TransferProgress.branchLabel(
        framedMode: framedMode,
        currentFileDeclaredSize: currentFileDeclaredSize,
        bytesThisFile: bytesThisFile,
        receivedSession: receivedSession,
        expectedSession: expectedSession,
        filesCompleted: filesCompleted,
        deviceTotalFiles: deviceTotalFiles,
        deviceSessionBytes: deviceSessionBytes,
      )} rawRatio≈${TransferProgress.uncappedRatio(
        framedMode: framedMode,
        currentFileDeclaredSize: currentFileDeclaredSize,
        bytesThisFile: bytesThisFile,
        receivedSession: receivedSession,
        expectedSession: expectedSession,
        filesCompleted: filesCompleted,
        deviceTotalFiles: deviceTotalFiles,
        deviceSessionBytes: deviceSessionBytes,
      ).toStringAsFixed(4)} stored=${r.toStringAsFixed(4)} '
      'recvSess=$receivedSession exp=$expectedSession files=$filesCompleted/$deviceTotalFiles '
      'devSessBytes=$deviceSessionBytes slice=$bytesThisFile/$currentFileDeclaredSize framed=$framedMode',
    );
  }
  return r;
}

/// Firmware [TRANSFER_DONE] / JSON `transfer_complete` [files] equals AT+DOWNLOAD session file count
/// (or we have completed that many slices). Then transfer bytes are done; [mergeAllParts] may run for a while.
bool _bleTransferDoneMeansSessionComplete({
  required int eventFileCount,
  required int fileCompleteCount,
  required int deviceTotalFilesFromDownload,
}) =>
    TransferProgress.sessionTransferBytesComplete(
      eventFileCount: eventFileCount,
      fileCompleteCount: fileCompleteCount,
      deviceTotalFilesFromDownload: deviceTotalFilesFromDownload,
    );

bool _isDisconnectError(Object e) {
  final s = e.toString().toLowerCase();
  return (e is StateError && s.contains('disconnected')) ||
      s.contains('device disconnected') ||
      s.contains('connection lost') ||
      s.contains('connection closed') ||
      s.contains('connection reset') ||
      s.contains('connection terminated') ||
      s.contains('ble disconnected') ||
      s.contains('bluetooth disconnected');
}

/// One session root for comparisons: trim, first `/` segment only.
/// Aligns DB `device_path` (`20260401/foo`), GSTAT `session`, and `AT+DOWNLOAD` args.
String _normalizeRecordingSessionRoot(String? raw) {
  var s = (raw ?? '').trim();
  if (s.isEmpty) return '';
  final i = s.indexOf('/');
  if (i >= 0) {
    s = s.substring(0, i).trim();
  }
  return s;
}

/// AT+LIST page may return fewer names than [info.files] / [info.synced].
int _effectiveSessionFileTotal({
  required int totalFiles,
  required int synced,
  required List<String> deviceFiles,
}) {
  var total = totalFiles;
  if (deviceFiles.isNotEmpty) {
    total = math.max(total, deviceFiles.length);
  }
  if (synced > 0) {
    total = math.max(total, synced);
  }
  return total;
}

String? _recordingStartErrorMessageFromResponse(Map<String, dynamic> resp) {
  for (final key in ['msg', 'error', 'message']) {
    final o = resp[key];
    if (o != null && o.toString().trim().isNotEmpty) return o.toString().trim();
  }
  final data = resp['data'];
  if (data is Map) {
    final m = Map<String, dynamic>.from(data);
    for (final key in ['msg', 'error', 'message']) {
      final o = m[key];
      if (o != null && o.toString().trim().isNotEmpty) {
        return o.toString().trim();
      }
    }
  }
  return null;
}

bool _isNoActiveSessionStopResponse(Map<String, dynamic> resp) {
  // Firmware protocol AT+STOP error code 4005 = "Not currently recording".
  // (`py_test/docs/protocol.md` §AT+STOP → Error Cases.)
  // Treat code 4005 as a signal that the device is already idle no matter
  // which language/wording the firmware uses for the human-readable msg.
  int? parseInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  final rootCode = parseInt(resp['code']);
  if (rootCode == 4005) return true;
  final data = resp['data'];
  if (data is Map) {
    final dataCode = parseInt(data['code']);
    if (dataCode == 4005) return true;
  }

  final parts = <String>[
    (resp['error'] ?? '').toString(),
    (resp['msg'] ?? '').toString(),
    (resp['message'] ?? '').toString(),
  ];
  if (data is Map) {
    final m = Map<String, dynamic>.from(data);
    parts.addAll([
      (m['error'] ?? '').toString(),
      (m['msg'] ?? '').toString(),
      (m['message'] ?? '').toString(),
    ]);
  }
  final s = parts.join(' ').toLowerCase();
  return s.contains('no active session') ||
      s.contains('no active recording') ||
      s.contains('not currently recording') ||
      s.contains('not recording') ||
      s.contains('already stopped') ||
      s.contains('already idle');
}

/// Result of retryTransfer for UI to show correct prompt.
enum RetryTransferResult {
  ok,
  notConnected,

  /// Device is recording/paused on another session; cannot preempt that BLE transfer.
  deviceRecordingOtherSession,

  /// [downloadSessionToLocal] returned without starting (e.g. Wi‑Fi handoff, recording-start guard, BLE mutex).
  couldNotStart,
  failed,
}

/// Outcome of [DeviceController.startRecording]. On AT failure, UI may show [atErrorMessage] and call [DeviceController.forceDisableDeviceWifiAp] after user confirms.
class RecordingStartResult {
  const RecordingStartResult._({required this.ok, this.atErrorMessage});
  const RecordingStartResult.success() : this._(ok: true);

  final bool ok;
  final String? atErrorMessage;

  factory RecordingStartResult.failure({String? atErrorMessage}) {
    return RecordingStartResult._(ok: false, atErrorMessage: atErrorMessage);
  }
}

/// Outcome of [DeviceController.applyDeviceName].
///
/// `errorCode` values:
/// - `name_invalid` — App-side validation rejected the input (length /
///   control chars). UI should show an inline form error.
/// - `device_offline` — `requireDevice=true` but no live BLE link.
/// - `device_rejected` — firmware returned `ok:false` (typically "Name too
///   long" once UTF-8 byte length is included). UI should suggest a shorter
///   name.
/// - `at_failed` — write timed out or BLE error. Local DB is unchanged.
class DeviceNameApplyResult {
  final bool ok;

  /// `true` only when AT+NAME was successfully written. `false` for offline
  /// local-only saves (so the UI can show "will sync on next connect").
  final bool savedOnDeviceToo;

  /// `null` when [ok] is true.
  final String? errorCode;

  /// Best-effort firmware error message when `errorCode == 'device_rejected'`
  /// or `'at_failed'`.
  final String? atErrorMessage;

  const DeviceNameApplyResult._({
    required this.ok,
    required this.savedOnDeviceToo,
    this.errorCode,
    this.atErrorMessage,
  });

  const DeviceNameApplyResult.success({required bool savedOnDeviceToo})
      : this._(ok: true, savedOnDeviceToo: savedOnDeviceToo);

  const DeviceNameApplyResult.failure({
    required String errorCode,
    String? atErrorMessage,
  }) : this._(
          ok: false,
          savedOnDeviceToo: false,
          errorCode: errorCode,
          atErrorMessage: atErrorMessage,
        );
}

/// A simple revision counter to make "device DB readers" refresh when we persist
/// new device info (battery/firmware/mode/online).
final deviceDbRevisionProvider = StateProvider<int>((ref) => 0);

/// Bound devices from local DB; refreshes after rename / persist / bind.
final devicesListProvider = FutureProvider<List<Device>>((ref) async {
  ref.watch(deviceDbRevisionProvider);
  final repo = await ref.watch(deviceRepositoryProvider.future);
  return repo.listAll();
});

/// DB [Device.isOnline] can lag behind a live BLE link (startup race with
/// [DeviceRepository.markAllOffline], or [pollGstatAndPersist] skipped mid-transfer).
///
/// Multi-device aware: returns true when the device is either the active
/// foreground connection OR currently kept alive as a background link
/// (see [DeviceController] background-pool docs).
bool isDeviceEffectivelyOnline(Device device, DeviceUiState deviceState) {
  final connId = deviceState.connection?.device.remoteId.toString();
  if (connId != null && connId == device.id) return true;
  if (deviceState.backgroundConnectedIds.contains(device.id)) return true;
  return device.isOnline;
}

class DeviceUiState {
  final bool isScanning;
  final BluetoothAdapterState adapterState;
  final List<ScanResult> results;
  final SenseCraftVoiceConnection? connection;
  final String? lastResponse;
  final int mtu;
  final String? error;

  /// Optional error code for i18n (e.g. device_disconnected_resume).
  final String? errorCode;

  /// Device ID of last connected device; kept on disconnect for auto-reconnect.
  final String? lastConnectedDeviceId;

  /// 'idle' | 'reconnecting' | 'success' | 'failed'
  final String reconnectStatus;

  /// BLE file transfer in progress for this recording id (mirrors [DeviceController._activeTransferRecordingId]).
  final String? activeTransferRecordingId;

  /// Last known `AT+GSTAT` session state: `idle` | `recording` | `paused`. Null when unknown / disconnected.
  /// Used to hide Fast Sync while the device is recording (Wi‑Fi sync is not allowed then).
  final String? firmwareRecState;

  /// Most recent bookmark notification reported by the device (via
  /// `event:"mark"`, see `protocol.md` 7.1.2 / Appendix E.5).
  ///
  /// Populated on both AT+MARK ack (when the firmware echoes the unsolicited
  /// event) and physical short-press on the device button. UI listens to
  /// this in [RecordingSessionSheet] to show "device added a bookmark"
  /// feedback even when the phone is asleep / sheet is in the background.
  final DeviceBookmarkNotice? lastBookmark;

  /// Device IDs of background-pool BLE links. These are devices the user
  /// previously connected to and switched away from — the GATT link is kept
  /// alive (battery notify still updates DB, disconnect is detected) so the
  /// UI shows them as "online" and switching back is instant. AT/file/recording
  /// subscriptions are NOT active for these devices; only the foreground
  /// [connection] gets full controller plumbing.
  final Set<String> backgroundConnectedIds;

  const DeviceUiState({
    required this.isScanning,
    this.adapterState = BluetoothAdapterState.unknown,
    required this.results,
    required this.connection,
    required this.lastResponse,
    required this.mtu,
    required this.error,
    this.errorCode,
    this.lastConnectedDeviceId,
    this.reconnectStatus = 'idle',
    this.activeTransferRecordingId,
    this.firmwareRecState,
    this.lastBookmark,
    this.backgroundConnectedIds = const <String>{},
  });

  bool get firmwareAppearsRecordingOrPaused =>
      firmwareRecState == 'recording' || firmwareRecState == 'paused';

  factory DeviceUiState.initial() => const DeviceUiState(
        isScanning: false,
        adapterState: BluetoothAdapterState.unknown,
        results: [],
        connection: null,
        lastResponse: null,
        mtu: 23,
        error: null,
        lastConnectedDeviceId: null,
        reconnectStatus: 'idle',
        activeTransferRecordingId: null,
        firmwareRecState: null,
        lastBookmark: null,
        backgroundConnectedIds: <String>{},
      );

  DeviceUiState copyWith({
    bool? isScanning,
    BluetoothAdapterState? adapterState,
    List<ScanResult>? results,
    SenseCraftVoiceConnection? connection,
    bool clearConnection = false,
    String? lastResponse,
    int? mtu,
    String? error,
    String? errorCode,
    bool clearErrorCode = false,
    String? lastConnectedDeviceId,
    bool clearLastConnectedDeviceId = false,
    String? reconnectStatus,
    String? activeTransferRecordingId,
    bool clearActiveTransferRecordingId = false,
    String? firmwareRecState,
    bool clearFirmwareRecState = false,
    DeviceBookmarkNotice? lastBookmark,
    bool clearLastBookmark = false,
    Set<String>? backgroundConnectedIds,
  }) {
    return DeviceUiState(
      isScanning: isScanning ?? this.isScanning,
      adapterState: adapterState ?? this.adapterState,
      results: results ?? this.results,
      // `connection: null` does NOT clear via `??` (Dart can't distinguish
      // "not passed" from "passed null" in optional parameters). Callers must
      // pass `clearConnection: true` to explicitly null the link — disconnect,
      // GATT-drop handlers and `_demoteCurrentToBackground` rely on this.
      connection: clearConnection ? null : (connection ?? this.connection),
      lastResponse: lastResponse ?? this.lastResponse,
      mtu: mtu ?? this.mtu,
      error: error,
      errorCode: clearErrorCode
          ? null
          : (errorCode ?? (error != null ? null : this.errorCode)),
      lastConnectedDeviceId: clearLastConnectedDeviceId
          ? null
          : (lastConnectedDeviceId ?? this.lastConnectedDeviceId),
      reconnectStatus: reconnectStatus ?? this.reconnectStatus,
      activeTransferRecordingId: clearActiveTransferRecordingId
          ? null
          : (activeTransferRecordingId ?? this.activeTransferRecordingId),
      firmwareRecState: clearFirmwareRecState
          ? null
          : (firmwareRecState ?? this.firmwareRecState),
      lastBookmark:
          clearLastBookmark ? null : (lastBookmark ?? this.lastBookmark),
      backgroundConnectedIds:
          backgroundConnectedIds ?? this.backgroundConnectedIds,
    );
  }
}

/// Background-pool BLE link for a device the user is not currently viewing.
///
/// The GATT connection stays alive so [DeviceController] can promote it back
/// to foreground instantly (no scan / GATT discover / MTU negotiation). Only
/// the lightweight subscriptions are kept:
/// - [connSub] detects GATT disconnect (link dropped → remove from pool, mark
///   the DB row offline).
/// - [batterySub] keeps the device row's `battery_percent` fresh in the DB so
///   the device dropdown shows up-to-date battery without switching to it.
/// - [at] is the existing [AtTransport] for this connection. We keep it alive
///   and reuse it on promote — building a fresh transport would call
///   `listen()` on the characteristic notify streams a second time and
///   flutter_blue_plus's `lastValueStream` chain is **single-subscription**
///   (closed on first cancel), so a fresh listen would crash with
///   `Bad state: Stream has already been listened to.`.
///
/// JSON message subscription is NOT carried (recreated on promote against
/// [at]'s broadcast `jsonMessages` stream so the listener closure can
/// reference the current foreground state).
/// Per-device transfer context (Phase 2 — multi-device decoupling).
///
/// One instance per *running* BLE file transfer, keyed by [deviceId] in
/// [DeviceController._transfersByDevice]. The owning `downloadSessionToLocal`
/// captures a local reference at entry and uses it for *all* its coordination
/// — cancel signaling, wait completer, identity check — instead of the legacy
/// single-instance fields. The legacy fields remain as a foreground "mirror"
/// (see [DeviceController._activeTransferRecordingId]) so existing UI/guards
/// keep working unchanged: the mirror always reflects the transfer of the
/// *currently foreground* device only, and is updated synchronously by
/// [DeviceController._registerTransfer] / [DeviceController._unregisterTransfer].
///
/// The key insight: a transfer is bound to the device it runs on, not to
/// "foreground". When the user switches devices we *demote* the foreground
/// link but leave [_ActiveTransfer] running on it; its chunks keep flowing
/// (`fileDataBytes` / `jsonMessages` are broadcast streams, the demoted
/// link still receives notify packets), the loop keeps writing to the temp
/// file and finally commits `transfer_state='done'` to the DB. No race with
/// any new transfer the user starts on the newly-foreground device.
class _ActiveTransfer {
  final String deviceId;
  final String recordingId;

  /// `await`ed by `cancelTransfer` so callers can wait for the download loop
  /// to exit its current AT-level retry leg cleanly (instead of hard-aborting
  /// from the outside). Set per *leg* by the download loop itself.
  Completer<void>? waitCompleter;

  /// Set by callers (cancel buttons, `_demoteCurrentToBackground` in the rare
  /// "force cancel" path) to ask the download loop to exit at its next
  /// awaitable cleanup point. The download loop only owns this flag for
  /// *this* device — a cancel of one device's transfer cannot affect another.
  bool cancelRequested = false;

  /// Error code propagated to the recording's `transfer_state='failed'` row
  /// when the cancel resolves (e.g. `user_cancelled`, `wifi_handoff`,
  /// `device_switch_demote`). Per-transfer so a cancel of one device's row
  /// can't accidentally stamp another device's row with the wrong code.
  String? cancelErrorCode;

  /// Set when the device reports IDLE / AT+STOP for this session while the
  /// download loop is still running. Used to finish continuous live-record
  /// legs even if the IDLE notify arrived before [jsonSub] subscribed.
  bool sessionEndedOnDevice = false;

  /// Set when the app disabled this link's shared `fileData` CCCD (iOS
  /// STOP/PAUSE/CANCEL flush) while this leg was still streaming. No more file
  /// bytes can arrive on the dead leg, so the watchdog must pause for resync
  /// within seconds instead of waiting the full 180s no-data window. Cleared
  /// when a fresh leg re-enables the notify before its AT+DOWNLOAD.
  bool fileNotifyDisabledWhileActive = false;

  /// One-shot signal to immediately wrap up this leg as a resumable
  /// `stalled_no_data_3min` pause (no merge, no cancel) so the post-stop resume
  /// re-issues AT+DOWNLOAD right away. Set when the session ends while the leg's
  /// fileData notify is already dead — avoids waiting for the 10s watchdog tick.
  bool resyncRequested = false;

  /// Mirrored from the download loop's `lastDataAt` so app-resume can detect
  /// an iOS background freeze (notify stalled mid-file) without waiting 3 min.
  DateTime lastDataAt = DateTime.now();

  _ActiveTransfer({required this.deviceId, required this.recordingId});
}

class _BackgroundLink {
  final SenseCraftVoiceConnection conn;
  final AtTransport at;
  StreamSubscription<BluetoothConnectionState>? connSub;
  StreamSubscription<int>? batterySub;

  /// Periodic AT+GSTAT keepalive on this dormant link. Android may silently
  /// allow a no-traffic LE connection to degrade so the next AT after promote
  /// times out even though the OS still reports "connected" — that surfaces
  /// to the user as "switched over, shows online but commands can't be sent". Pinging every few seconds
  /// keeps the radio active and also gives us an early signal when the peer
  /// has gone (so the pool entry can be evicted before the user tries to
  /// switch).
  Timer? keepaliveTimer;

  /// Consecutive keepalive failures. After [DeviceController._kBackgroundKeepaliveMaxFailures]
  /// the link is evicted so the UI no longer claims this device is online.
  int consecutiveKeepaliveFailures = 0;

  _BackgroundLink({
    required this.conn,
    required this.at,
    required this.connSub,
    required this.batterySub,
  });

  String get deviceId => conn.device.remoteId.toString();
}

/// Snapshot of the latest `event:"mark"` notification (per protocol 7.1.2).
///
/// Each instance is uniquely identifiable by its [seq] counter — UI widgets
/// use `seq` to detect that a new device-side bookmark arrived even when
/// `markCount` is unchanged (e.g. legacy firmware that always returns 0).
class DeviceBookmarkNotice {
  /// Monotonic counter incremented each time the controller receives an
  /// `event:"mark"`. Always strictly greater than the previous value.
  final int seq;

  /// Session ID reported by the firmware. Empty when not provided.
  final String sessionId;

  /// `mark_count` field from the event when reported (`null` for legacy
  /// firmwares that omit it).
  final int? markCount;

  /// Optional second-offset from session start.
  final int? offsetSeconds;

  /// `true` when the bookmark almost certainly came from the device button
  /// rather than an AT+MARK we just sent. The controller marks AT-driven
  /// bookmarks with `false` so the sheet does not double-toast.
  final bool fromDeviceButton;

  /// When the controller observed the event (App-side clock).
  final DateTime receivedAt;

  const DeviceBookmarkNotice({
    required this.seq,
    required this.sessionId,
    required this.markCount,
    required this.offsetSeconds,
    required this.fromDeviceButton,
    required this.receivedAt,
  });
}

/// True when [code] marks an intentional pause (device switch / foreground priority),
/// not a user-visible transfer failure.
bool isBenignTransferPauseCode(String? code) {
  final c = (code ?? '').trim();
  return c == 'device_switch_demote' ||
      c == 'foreground_priority' ||
      c == 'already_synced';
}

/// Disconnect/resume pause codes — benign while the link is back up; still shown when offline.
///
/// [transfer_incomplete_resume] is included: when the device is connected the
/// transfer resumes automatically, so the "transfer incomplete, will resume"
/// subtitle is just noise (every post-stop sync briefly hits it). It still shows
/// when the device is offline, where "will resume after reconnect" is useful.
bool isDisconnectResumePauseCode(String? code) {
  final c = (code ?? '').trim();
  return c == 'device_disconnected_resume' ||
      c == 'device_disconnected_resume_after_reconnect' ||
      c == 'transfer_incomplete_resume';
}

/// Live record while transferring: BLE is pulling this [Recording] and firmware still reports recording/paused
/// (total length still changing; do not use snapshot `expected_bytes` as denominator up to ~99%).
bool deviceLiveRecordWhileBleTransfer(
  Recording r,
  DeviceUiState s, {
  String? activeRecordingSessionId,
}) {
  if (r.source != 'device') return false;
  if (r.transferState != 'transferring') return false;
  if (!s.firmwareAppearsRecordingOrPaused) return false;
  final sid = (activeRecordingSessionId ?? '').trim();
  if (sid.isNotEmpty) {
    return recordingMatchesFirmwareSession(r, sid);
  }
  final aid = (s.activeTransferRecordingId ?? '').trim();
  return aid.isNotEmpty && aid == r.id.trim();
}

/// True when [sessionId] and [Recording.devicePath] refer to the same firmware session root.
bool recordingMatchesFirmwareSession(Recording r, String? sessionId) {
  final sid = (sessionId ?? '').trim();
  if (sid.isEmpty) return false;
  final ourRoot = _normalizeRecordingSessionRoot(r.devicePath);
  final liveRoot = _normalizeRecordingSessionRoot(sid);
  return ourRoot.isNotEmpty && liveRoot.isNotEmpty && ourRoot == liveRoot;
}

/// Manual resync steals BLE bandwidth; hide while the foreground device is recording/paused.
bool shouldSuppressResyncWhileDeviceRecording(Recording r, DeviceUiState s) {
  if (!s.firmwareAppearsRecordingOrPaused) return false;
  if (r.transferState == 'failed') return false;
  final connId = s.connection?.device.remoteId.toString();
  if (connId == null || (r.deviceId ?? '') != connId) return false;
  return true;
}

/// Top transfer banner reflects the foreground BLE link only — not background-pool transfers.
bool transferRecordingBelongsToForegroundDevice(
  Recording r,
  String? foregroundDeviceId,
) {
  final fg = (foregroundDeviceId ?? '').trim();
  if (fg.isEmpty) return true;
  final dev = (r.deviceId ?? '').trim();
  if (dev.isEmpty) return true;
  return dev == fg;
}

/// When `true`, send `AT+DELETE=$sessionId` only **after background merge** succeeds
/// ([SessionMergeQueue] → [schedulePostMergeBleCleanup]), never when UDP/BLE bytes finish.
/// Set to `false` for local testing (files stay on device).
const _deleteFirmwareSessionAfterBleWifiSync = true;

class _PostMergeBleTask {
  const _PostMergeBleTask({
    required this.recordingId,
    required this.sessionId,
    required this.mergedPath,
    this.expectedBytes,
    this.verifiedBytes,
    this.deleteAfterSync = true,
    this.fetchBookmarks = true,
  });

  final String recordingId;
  final String sessionId;
  final String mergedPath;
  final int? expectedBytes;
  final int? verifiedBytes;
  final bool deleteAfterSync;
  final bool fetchBookmarks;
}

class _RecordingClockSnapshot {
  const _RecordingClockSnapshot({
    required this.sessionId,
    required this.firmwareRecState,
    required this.startedAt,
    required this.offsetSeconds,
  });

  final String? sessionId;
  final String? firmwareRecState;
  final DateTime? startedAt;
  final int offsetSeconds;
}

class DeviceController extends Notifier<DeviceUiState> {
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<Map<String, dynamic>>? _jsonSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<int>? _batterySub;
  AtTransport? _at;
  bool _disposed = false;

  /// Background-pool BLE links (multi-device "keep alive" support, see
  /// [_BackgroundLink]). When the user switches the active device, the
  /// previous foreground link is demoted here instead of being torn down;
  /// switching back is then instant. Keyed by device remoteId string.
  final Map<String, _BackgroundLink> _backgrounds = <String, _BackgroundLink>{};

  /// True iff [deviceId] is either the active foreground connection or sits
  /// in the background pool. Used by UI callers to detect "fast-switch"
  /// availability (no GATT round-trip needed).
  bool isLinked(String deviceId) {
    if (deviceId.isEmpty) return false;
    if (state.connection?.device.remoteId.toString() == deviceId) return true;
    return _backgrounds.containsKey(deviceId);
  }

  Future<String> _deviceSessionDirectory(String deviceId, String sessionId) {
    return AccountStoragePaths.deviceSessionDirectory(
      accountKey: requireAccountDbKey(ref),
      deviceId: deviceId,
      sessionId: sessionId,
    );
  }

  Future<String> _deviceSessionOpusPath(String deviceId, String sessionId) {
    return AccountStoragePaths.deviceSessionOpusFile(
      accountKey: requireAccountDbKey(ref),
      deviceId: deviceId,
      sessionId: sessionId,
    );
  }

  /// Account-scoped SQLite; reopens the shard if it was closed mid-BLE/sync.
  Future<T> _withRecRepo<T>(
          Future<T> Function(RecordingsRepository repo) action) =>
      withFreshRecordingsRepo(ref, action);

  /// Incremental `AT+LIST`: first page on connect / auto-sync; further pages from list scroll.
  String? _deviceListCursorDeviceId;
  int _deviceListCursorNextPage = 2;
  int? _deviceListCursorTotal;
  final Set<String> _deviceListCursorRemoteSessionIds = <String>{};
  bool _deviceListCursorHasMorePages = false;
  bool _deviceListContinueInFlight = false;

  void _resetDeviceListPaging() {
    _deviceListCursorDeviceId = null;
    _deviceListCursorNextPage = 2;
    _deviceListCursorTotal = null;
    _deviceListCursorRemoteSessionIds.clear();
    _deviceListCursorHasMorePages = false;
  }

  /// Mark [sessionRoot] as definitely present on [deviceId].
  ///
  /// The device-session cache ([_deviceListCursorRemoteSessionIds]) is built by
  /// [syncDeviceFileIndex] on connect/auto-sync and is NOT refreshed when a new
  /// recording is started or stopped on the device. [_resumeIncompleteTransfers]
  /// SANITY-checks DB rows against this cache and DELETES rows whose session is
  /// "not on device". Without this, a session recorded *after* the last sync
  /// (e.g. a fresh device-button recording) is absent from the cache and the
  /// freshly-recorded row is wrongly deleted, so the app abandons it and resumes
  /// an older session instead. Whenever we positively know the device holds a
  /// session (recording adopted / pending row created / stop meta persisted),
  /// fold it into the cache so the SANITY pass cannot drop it. A later full
  /// [syncDeviceFileIndex] rebuilds the set from scratch, so genuinely deleted
  /// sessions are still pruned.
  void _noteDeviceSessionRootPresent(String deviceId, String? sessionRoot) {
    final root = _normalizeRecordingSessionRoot((sessionRoot ?? '').trim());
    if (root.isEmpty) return;
    if (_deviceListCursorDeviceId != deviceId) return;
    _deviceListCursorRemoteSessionIds.add(root);
  }

  /// Track which device IDs we've already logged during the current scan,
  /// so we don't spam logs for the same device on every scan batch.
  final Set<String> _loggedScanDeviceIds = {};

  /// Incremented on each new scan subscription so stale [scanResults] replays
  /// from flutter_blue_plus cannot repopulate the UI after cancel / rescan.
  int _scanGeneration = 0;

  /// False until [SenseCraftVoiceClient.startScan] succeeds — blocks the
  /// immediate cached replay emitted when subscribing to [scanResults].
  bool _acceptScanResults = false;

  /// iOS can't remove a stale system bond. After `AT+PAIR=reset`, remember the
  /// device briefly and try one scan-based repair on the next failed connect.
  final Set<String> _iosStaleBondRepairTried = <String>{};

  DateTime? _recordingStartedAt;
  int _recordingStartOffsetSeconds = 0;
  String? _activeRecordingSessionId;
  String? _pauseCommandInFlightSessionId;

  /// Long session id for the current device recording (from AT+START),
  /// e.g. `20250227_120000`. This matches Python tools' session id.
  String? get activeRecordingSessionId => _activeRecordingSessionId;

  /// Best-effort App-side view of the active recording duration. Used by UI
  /// when iOS BLE delivers a GSTAT notify without a usable `duration` field.
  int? get activeRecordingDurationSeconds {
    final sid = (_activeRecordingSessionId ?? '').trim();
    if (sid.isEmpty) return null;
    final now = DateTime.now();
    var seconds = _recordingStartOffsetSeconds;
    final startedAt = _recordingStartedAt;
    if (startedAt != null && state.firmwareRecState == 'recording') {
      seconds += now.difference(startedAt).inSeconds;
    }
    if (seconds <= 0 && state.firmwareRecState != 'paused') {
      final sessionStart = _parseSessionTimestamp(sid);
      if (sessionStart != null) {
        final inferred = now.difference(sessionStart).inSeconds;
        if (inferred >= 0 && inferred <= 24 * 3600) {
          seconds = inferred;
        }
      }
    }
    return seconds.clamp(0, 24 * 3600).toInt();
  }

  String _iosPairingResetTombstoneKey(String deviceId) =>
      '$_kIosPairingResetTombstonePrefix$deviceId';

  Future<void> _rememberIosPairingResetTombstone(String deviceId) async {
    if (!Platform.isIOS || deviceId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _iosPairingResetTombstoneKey(deviceId),
        DateTime.now().millisecondsSinceEpoch,
      );
      _iosStaleBondRepairTried.remove(deviceId);
      AppLog.i(
        'DeviceController: remembered iOS pairing-reset tombstone for $deviceId',
      );
    } catch (e, st) {
      AppLog.w('DeviceController: remember iOS tombstone failed', e, st);
    }
  }

  Future<bool> _hasRecentIosPairingResetTombstone(String deviceId) async {
    if (!Platform.isIOS || deviceId.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_iosPairingResetTombstoneKey(deviceId));
      if (ts == null) return false;
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(ts),
      );
      if (age <= _kIosPairingResetTombstoneTtl) return true;
      await prefs.remove(_iosPairingResetTombstoneKey(deviceId));
    } catch (e, st) {
      AppLog.w('DeviceController: read iOS tombstone failed', e, st);
    }
    return false;
  }

  Future<void> _clearIosPairingResetTombstone(String deviceId) async {
    if (!Platform.isIOS || deviceId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_iosPairingResetTombstoneKey(deviceId));
      _iosStaleBondRepairTried.remove(deviceId);
    } catch (e, st) {
      AppLog.w('DeviceController: clear iOS tombstone failed', e, st);
    }
  }

  int _currentRecordingClockSeconds({String? sessionId, int? reportedSeconds}) {
    final reported = reportedSeconds ?? 0;
    if (reported > 0) return reported.clamp(0, 24 * 3600).toInt();

    final now = DateTime.now();
    var seconds = _recordingStartOffsetSeconds;
    final startedAt = _recordingStartedAt;
    if (startedAt != null) {
      seconds += now.difference(startedAt).inSeconds;
    }
    if (seconds <= 0) {
      final sessionStart =
          _parseSessionTimestamp(sessionId ?? _activeRecordingSessionId ?? '');
      if (sessionStart != null) {
        final inferred = now.difference(sessionStart).inSeconds;
        if (inferred >= 0 && inferred <= 24 * 3600) {
          seconds = inferred;
        }
      }
    }
    return seconds.clamp(0, 24 * 3600).toInt();
  }

  void _freezeRecordingClock({String? sessionId, int? reportedSeconds}) {
    _recordingStartOffsetSeconds = _currentRecordingClockSeconds(
      sessionId: sessionId,
      reportedSeconds: reportedSeconds,
    );
    _recordingStartedAt = null;
  }

  void _resumeRecordingClock({String? sessionId, int? reportedSeconds}) {
    _recordingStartOffsetSeconds = _currentRecordingClockSeconds(
      sessionId: sessionId,
      reportedSeconds: reportedSeconds,
    );
    _recordingStartedAt = DateTime.now();
  }

  _RecordingClockSnapshot? _beginOptimisticPauseClock() {
    final sid = (_activeRecordingSessionId ?? '').trim();
    final firmwareState = state.firmwareRecState;
    if (sid.isEmpty && firmwareState != 'recording') return null;

    final snapshot = _RecordingClockSnapshot(
      sessionId: sid.isEmpty ? null : sid,
      firmwareRecState: firmwareState,
      startedAt: _recordingStartedAt,
      offsetSeconds: _recordingStartOffsetSeconds,
    );
    _pauseCommandInFlightSessionId = sid.isEmpty ? null : sid;
    _freezeRecordingClock(sessionId: sid.isEmpty ? null : sid);
    _setFirmwareRecState('paused');
    return snapshot;
  }

  bool _pauseCommandMatchesSession(String? sessionId) {
    final pending = (_pauseCommandInFlightSessionId ?? '').trim();
    if (pending.isEmpty) return false;
    final sid = (sessionId ?? '').trim();
    return sid.isEmpty || sid == pending;
  }

  bool _ignoreStaleRecordingWhilePauseInFlight(
    String? sessionId,
    String source,
  ) {
    if (!_pauseCommandMatchesSession(sessionId)) return false;
    AppLog.d(
      'DeviceController: ignore stale RECORDING from $source while '
      'AT+PAUSE is in-flight (session=${sessionId ?? "(empty)"})',
    );
    return true;
  }

  void _clearPauseCommandInFlightIfMatched(String? sessionId) {
    if (_pauseCommandMatchesSession(sessionId)) {
      _pauseCommandInFlightSessionId = null;
    }
  }

  void _restoreOptimisticPauseClock(_RecordingClockSnapshot? snapshot) {
    if (snapshot == null) return;
    final snapSid = (snapshot.sessionId ?? '').trim();
    final currentSid = (_activeRecordingSessionId ?? '').trim();
    if (snapSid.isNotEmpty && currentSid.isNotEmpty && currentSid != snapSid) {
      return;
    }
    if (snapSid.isNotEmpty && !_pauseCommandMatchesSession(snapSid)) {
      return;
    }
    if (_pauseCommandMatchesSession(snapSid)) {
      _pauseCommandInFlightSessionId = null;
    }
    if (state.firmwareRecState != 'paused') return;
    _recordingStartedAt = snapshot.startedAt;
    _recordingStartOffsetSeconds = snapshot.offsetSeconds;
    _setFirmwareRecState(
        snapshot.firmwareRecState ?? (snapSid.isNotEmpty ? 'recording' : null));
  }

  /// Last GSTAT-derived recording state; used to run [_resumeIncompleteTransfers] when device returns to idle
  /// so `device_recording_resume_later` rows retry without requiring reconnect.
  String? _prevDerivedRecStateForDeferredResume;

  void _onDerivedRecordingStateForDeferredResume(String state) {
    if (_disposed) return;
    final prev = _prevDerivedRecStateForDeferredResume;
    _prevDerivedRecStateForDeferredResume = state;
    if (prev != null && prev != 'idle' && state == 'idle') {
      // Firmware may report IDLE during AT+DOWNLOAD or under BLE load; do not resume other sessions then.
      if (_bleTransferGuardForRecordingStart) {
        AppLog.d(
          'DeviceController: skip deferred resume on idle (recording-start BLE guard)',
        );
        return;
      }
      if ((_activeRecordingSessionId ?? '').trim().isNotEmpty) {
        AppLog.d(
          'DeviceController: skip deferred resume on idle (app has activeRecordingSessionId — GSTAT idle may be stale)',
        );
        return;
      }
      if (_activeTransferRecordingId != null) {
        AppLog.d(
          'DeviceController: skip deferred resume on idle (BLE transfer still tracked: $_activeTransferRecordingId)',
        );
        return;
      }
      AppLog.i(
        'DeviceController: device recording state $prev -> idle (GSTAT), resuming deferred BLE transfers',
      );
      unawaited(_resumeIncompleteTransfers());
    }
  }

  DateTime? _lastDeferredResumeIfIdlePoke;

  /// Optional manual poke (e.g. debug): if device is idle, run deferred BLE resume. List UI no longer polls this.
  Future<void> retryDeferredTransfersIfDeviceIdle() async {
    if (_disposed) return;
    if (_wifiHandoffActive) return;
    if (state.connection == null || _at == null) return;
    if (_activeTransferRecordingId != null) return;
    final now = DateTime.now();
    if (_lastDeferredResumeIfIdlePoke != null &&
        now.difference(_lastDeferredResumeIfIdlePoke!) <
            const Duration(seconds: 2)) {
      return;
    }
    _lastDeferredResumeIfIdlePoke = now;
    final st = await getRecordingStatus();
    if (st?.state != 'idle') return;
    if ((_activeRecordingSessionId ?? '').trim().isNotEmpty) return;
    await _resumeIncompleteTransfers();
  }

  String _deriveRecStateFromGstatMap(Map<String, dynamic> dataMap) {
    final rawState = (dataMap['state'] ?? '').toString().toUpperCase().trim();
    // During AT+DOWNLOAD / BLE file pull, firmware often reports recording:false while
    // state is TRANSMITTING. Right after AT+START it may also briefly report
    // state=RECORDING with recording=false. Prefer the explicit state when it
    // names a real foreground/transfer state; use recording:false only as the
    // fallback for idle-shaped payloads.
    if (rawState == 'TRANSMITTING' ||
        rawState == 'TRANSFER' ||
        rawState == 'TRANSFERING' ||
        rawState == 'TRANSFERRING' ||
        rawState == 'WIFI_SYNC') {
      return 'transmitting';
    }
    if (rawState == 'RECORDING' || rawState == 'REC') return 'recording';
    if (rawState == 'PAUSED') return 'paused';
    final recordingFlag = _parseTriBool(dataMap['recording']);
    if (recordingFlag == true) return 'recording';
    if (recordingFlag == false) return 'idle';
    return 'idle';
  }

  /// Set when [startRecording] succeeds on the adopt path (firmware already recording); consumed by UI once.
  int? _adoptedRecordingDurationSecondsFromLastStart;

  /// Non-null once after an adopt-path [startRecording]; cleared on read.
  int? consumeAdoptedRecordingDurationFromLastStart() {
    final d = _adoptedRecordingDurationSecondsFromLastStart;
    _adoptedRecordingDurationSecondsFromLastStart = null;
    return d;
  }

  /// Recording ID currently being transferred *on the foreground device*.
  ///
  /// Legacy "single transfer" mirror — kept so the existing UI / guards keep
  /// working. The true per-device transfer state lives in
  /// [_transfersByDevice]; this field is just a synchronous shadow of
  /// "whatever transfer the foreground device is running, if any". Updated
  /// by [_registerTransfer] / [_unregisterTransfer] / `_demoteCurrentToBackground`
  /// / `_promoteFromBackground` to stay aligned with `state.connection`.
  String? _activeTransferRecordingId;

  /// Exposed for UI to avoid starting duplicate transfer when Stop is clicked.
  /// Reflects the foreground device's transfer only — background transfers
  /// surface via the recordings list (each row's own `transfer_state`).
  String? get activeTransferRecordingId => _activeTransferRecordingId;

  /// True when any device (foreground or background) has an in-flight BLE pull
  /// for [recordingId]. Prefer this over [activeTransferRecordingId] alone —
  /// the mirror only reflects the foreground device.
  bool isTransferRunningFor(String recordingId) =>
      _transferForRecording(recordingId) != null;

  /// Live record-while-transfer on every platform, including iOS.
  ///
  /// iOS was previously record-exclusive because the command RX characteristic
  /// is WRITE-WITHOUT-RESPONSE only, and CoreBluetooth will not flush a
  /// write-without-response while the firmware floods `fileData` notifications
  /// (`canSendWriteWithoutResponse` stays false) — so AT+CANCEL was queued but
  /// never transmitted and the in-flight BLE pull could not be stopped in time
  /// to START a new recording. [cancelTransfer] now disables the `fileData` CCCD
  /// first (a reliable write-WITH-response descriptor write) to stop the flood
  /// and free the link before AT+CANCEL, so the same live pull path as Android
  /// works on iOS. Notify is re-enabled at the start of the next download leg in
  /// [downloadSessionToLocal].
  bool get liveRecordingBleSyncEnabled => true;

  /// All in-flight BLE file transfers, keyed by `deviceId` (the device that
  /// runs that transfer). Phase 2 core data structure — see [_ActiveTransfer].
  ///
  /// Invariants:
  /// - At most one entry per device (firmware allows one active stream).
  /// - Removed by `_unregisterTransfer` on download loop exit (success or
  ///   failure), by `_demoteCurrentToBackground` ONLY in the legacy
  ///   force-cancel path (currently unused — demote keeps transfers alive),
  ///   and by `disconnect()` / `_evictBackgroundLink()`.
  final Map<String, _ActiveTransfer> _transfersByDevice = {};

  /// Returns the active transfer running on [deviceId], or `null`.
  _ActiveTransfer? _transferForDevice(String? deviceId) {
    if (deviceId == null || deviceId.isEmpty) return null;
    return _transfersByDevice[deviceId];
  }

  /// Returns the (device, transfer) pair that owns [recordingId], or `null`.
  /// Used by [cancelTransfer] so a UI cancel can find the right device's
  /// transfer even when it belongs to a backgrounded link.
  _ActiveTransfer? _transferForRecording(String? recordingId) {
    if (recordingId == null || recordingId.isEmpty) return null;
    for (final t in _transfersByDevice.values) {
      if (t.recordingId == recordingId) return t;
    }
    return null;
  }

  /// Register a new transfer for [deviceId]; also update the foreground
  /// mirror if [deviceId] is the current foreground.
  _ActiveTransfer _registerTransfer({
    required String deviceId,
    required String recordingId,
  }) {
    final t = _ActiveTransfer(deviceId: deviceId, recordingId: recordingId);
    _transfersByDevice[deviceId] = t;
    if (state.connection?.device.remoteId.toString() == deviceId) {
      _activeTransferRecordingId = recordingId;
      state = state.copyWith(activeTransferRecordingId: recordingId);
    }
    return t;
  }

  /// Remove a transfer (download loop exit); clear the foreground mirror
  /// when relevant.
  void _unregisterTransfer(_ActiveTransfer t) {
    final current = _transfersByDevice[t.deviceId];
    if (current == t) {
      _transfersByDevice.remove(t.deviceId);
    }
    if (_activeTransferRecordingId == t.recordingId &&
        state.connection?.device.remoteId.toString() == t.deviceId) {
      _activeTransferRecordingId = null;
      state = state.copyWith(clearActiveTransferRecordingId: true);
    }
  }

  /// Re-sync the foreground mirror after demote/promote. The promoted device's
  /// in-flight transfer (if any) becomes visible to the foreground UI.
  void _syncForegroundTransferMirror() {
    final fg = state.connection?.device.remoteId.toString();
    final t = _transferForDevice(fg);
    final newId = t?.recordingId;
    if (newId == _activeTransferRecordingId) return;
    _activeTransferRecordingId = newId;
    if (newId == null) {
      state = state.copyWith(clearActiveTransferRecordingId: true);
    } else {
      state = state.copyWith(activeTransferRecordingId: newId);
    }
  }

  /// Pause BLE pulls on background-pooled devices so foreground sync / resync
  /// wins. Live-record pulls on a peer still recording/paused use
  /// [cancelTransfer] with `skipAtCancel: true` to avoid the firmware xfer crash.
  Future<void> _yieldBackgroundTransfersToForeground() async {
    final fg = state.connection?.device.remoteId.toString();
    if (fg == null || fg.isEmpty) return;
    final toPause = _transfersByDevice.entries
        .where((e) => e.key != fg && _backgrounds.containsKey(e.key))
        .toList();
    if (toPause.isEmpty) return;
    for (final entry in toPause) {
      final deviceId = entry.key;
      final transfer = entry.value;
      final bgAt = _backgrounds[deviceId]?.at;
      if (bgAt == null) continue;
      var skipAtCancel = false;
      try {
        final st = await getRecordingStatusForAt(bgAt);
        skipAtCancel =
            st != null && (st.state == 'recording' || st.state == 'paused');
      } catch (_) {}
      AppLog.i(
        '_yieldBackgroundTransfersToForeground: pausing ${transfer.recordingId} '
        'on background device $deviceId (skipAtCancel=$skipAtCancel)',
      );
      await cancelTransfer(
        transfer.recordingId,
        errorCode: 'foreground_priority',
        skipAtCancel: skipAtCancel,
      );
    }
  }

  /// Serializes [_resumeIncompleteTransfers] so only one BLE download chain runs at a time.
  bool _resumeIncompleteTransfersBusy = false;
  bool _resumeIncompleteTransfersRerunRequested = false;

  /// Schedules [_resumeIncompleteTransfers] after the current synchronous stack unwinds.
  ///
  /// [downloadSessionToLocal] used to call `unawaited(_resumeIncompleteTransfers())` right before
  /// `return true`; the async body runs synchronously until its first `await`, so it still saw
  /// [_activeTransferRecordingId] set and bailed with "BLE transfer in progress". Deferring to a
  /// microtask runs resume after this download's `finally` clears the active id.
  void _scheduleResumeIncompleteTransfersAfterBleTransfer() {
    scheduleMicrotask(() => unawaited(_resumeIncompleteTransfers()));
  }

  int _resumeAfterBleIdleGeneration = 0;

  /// Consecutive `transfer_incomplete_resume` attempts per recording id. Guards
  /// against an unbreakable resume loop when a session can never reach `total`
  /// slices (slice truly missing/corrupt on device, or persistent total
  /// mismatch). After [_maxIncompleteResumeAttempts] we stop re-downloading and
  /// salvage-merge what we have (or mark failed) to drain the queue.
  final Map<String, int> _incompleteResumeAttempts = <String, int>{};
  static const int _maxIncompleteResumeAttempts = 3;

  /// Give-up cycles for sessions where the device still holds slices we lack.
  ///
  /// When we exhaust [_maxIncompleteResumeAttempts] but the device clearly still
  /// has more slices than we hold locally (e.g. the tail slice keeps timing out
  /// during BLE congestion), salvaging now would mark a SHORT recording as
  /// "done" and silently drop the tail. Instead we keep the transfer resumable
  /// and let a later, less-congested sync finish it — only escalating to
  /// "failed" (never a short "done") after [_maxIncompleteGiveupCycles] cycles.
  final Map<String, int> _incompleteGiveupCycles = <String, int>{};
  static const int _maxIncompleteGiveupCycles = 5;

  void _scheduleResumeIncompleteTransfersWhenBleIdle({
    required String reason,
    String? waitForRecordingId,
    Duration initialDelay = const Duration(milliseconds: 500),
    Duration timeout = const Duration(minutes: 5),
  }) {
    final generation = ++_resumeAfterBleIdleGeneration;
    final target = (waitForRecordingId ?? '').trim();
    unawaited(() async {
      await Future<void>.delayed(initialDelay);
      final deadline = DateTime.now().add(timeout);
      while (!_disposed && DateTime.now().isBefore(deadline)) {
        final conn = state.connection;
        if (conn == null || _at == null) return;
        final deviceId = conn.device.remoteId.toString();
        final targetBusy =
            target.isNotEmpty && _transferForRecording(target) != null;
        final deviceBusy = _transferForDevice(deviceId) != null ||
            _activeTransferRecordingId != null ||
            _bleDownloadBusyForDevice(deviceId);
        if (!targetBusy && !deviceBusy && !_postMergeDraining) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (_disposed || generation != _resumeAfterBleIdleGeneration) return;
      AppLog.i(
        'DeviceController: BLE idle resume trigger ($reason'
        '${target.isNotEmpty ? ', target=$target' : ''})',
      );
      _scheduleResumeIncompleteTransfersAfterBleTransfer();
    }());
  }

  /// While true, blocks [_resumeIncompleteTransfers] and [downloadSessionToLocal] except when
  /// [downloadSessionToLocal.allowDuringRecordingStartGuard] is true (live record-while-transfer pipeline).
  bool _bleTransferGuardForRecordingStart = false;
  String? _bleTransferGuardRecordingId;

  /// While Fast Sync runs, **all** BLE [downloadSessionToLocal] and [_resumeIncompleteTransfers] are skipped
  /// so no other `transferring` row (e.g. another session) steals AT+DOWNLOAD while we AT+WIFI=ON / UDP.
  String? _wifiHandoffRecordingId;
  String? _preferredBleResumeRecordingIdAfterWifiHandoff;
  DateTime? _wifiHandoffExpiresAt;
  Timer? _wifiHandoffTtlTimer;

  /// Default TTL so a crashed / dismissed Fast Sync sheet cannot block BLE forever.
  static const Duration _kWifiHandoffTtl = Duration(minutes: 20);

  /// Recording ids that just finished via Wi‑Fi UDP+merge. [resumeBleTransfersAfterFastSyncDismiss] runs
  /// ~450ms later; if SQLite still briefly shows `transferring` or the inject path races, BLE resume would
  /// start [downloadSessionToLocal] again and stick the top banner — skip BLE for these ids briefly.
  final Map<String, DateTime> _suppressBleResumeUntil = {};

  /// Bookmarks + AT+DELETE deferred until BLE is idle (background merge must not block next download).
  final List<_PostMergeBleTask> _postMergeBleTasks = [];

  /// Throttle [resumeLiveRecordingTransferIfStalled] (recording sheet may poll often).
  DateTime? _lastLiveResumeBleAt;
  String? _lastLiveResumeBleRecordingId;

  bool get _wifiHandoffActive {
    if (_wifiHandoffRecordingId == null) return false;
    final exp = _wifiHandoffExpiresAt;
    if (exp != null && DateTime.now().isAfter(exp)) {
      endWifiHandoff(reason: 'ttl_lazy');
      return false;
    }
    return true;
  }

  void startWifiHandoff(
    String recordingId, {
    Duration ttl = _kWifiHandoffTtl,
  }) {
    _wifiHandoffRecordingId = recordingId;
    _preferredBleResumeRecordingIdAfterWifiHandoff = recordingId;
    _armWifiHandoffTtl(recordingId, ttl);
    AppLog.i(
        'DeviceController.startWifiHandoff: $recordingId (blocks all BLE downloads until endWifiHandoff, ttl=${ttl.inMinutes}m)');
    SentryService.breadcrumb(
      'WiFi handoff started',
      category: 'wifi',
      data: {'recording_id': recordingId, 'ttl_min': ttl.inMinutes},
    );
    _logXferState('afterStartWifiHandoff');
  }

  /// Extend the handoff TTL while Wi‑Fi transfer is still legitimately active.
  void touchWifiHandoff({Duration ttl = _kWifiHandoffTtl}) {
    final id = _wifiHandoffRecordingId;
    if (id == null || _disposed) return;
    _armWifiHandoffTtl(id, ttl);
  }

  void _armWifiHandoffTtl(String recordingId, Duration ttl) {
    _wifiHandoffExpiresAt = DateTime.now().add(ttl);
    _wifiHandoffTtlTimer?.cancel();
    _wifiHandoffTtlTimer = Timer(ttl, () {
      if (_disposed) return;
      if (_wifiHandoffRecordingId == recordingId) {
        AppLog.w(
          'DeviceController: Wi‑Fi handoff TTL expired for $recordingId '
          '(${ttl.inMinutes}m) — clearing so BLE resume can run',
        );
        endWifiHandoff(reason: 'ttl');
      }
    });
  }

  void endWifiHandoff({String? reason}) {
    _wifiHandoffTtlTimer?.cancel();
    _wifiHandoffTtlTimer = null;
    _wifiHandoffExpiresAt = null;
    final was = _wifiHandoffRecordingId;
    _wifiHandoffRecordingId = null;
    if (was != null) {
      AppLog.i(
        'DeviceController.endWifiHandoff (was $was'
        '${reason != null ? ', reason=$reason' : ''})',
      );
      SentryService.breadcrumb(
        'WiFi handoff ended',
        category: 'wifi',
        data: {
          'recording_id': was,
          if (reason != null) 'reason': reason,
        },
      );
      _logXferState('afterEndWifiHandoff');
    }
  }

  /// Call right after Wi‑Fi fast sync writes `transfer_state: done` for [recordingId].
  void suppressBleResumeAfterWifiFastSync(
    String recordingId, {
    Duration ttl = const Duration(seconds: 12),
  }) {
    if (_disposed) return;
    final id = recordingId.trim();
    if (id.isEmpty) return;
    _suppressBleResumeUntil[id] = DateTime.now().add(ttl);
  }

  bool _shouldSuppressBleResume(String recordingId) {
    final until = _suppressBleResumeUntil[recordingId];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _suppressBleResumeUntil.remove(recordingId);
      return false;
    }
    return true;
  }

  /// After AT+STOP / unsolicited STOP, defer BLE resume so live record-while-transfer can
  /// finish its leg, merge, and post-merge cleanup without a second AT+DOWNLOAD on the
  /// same session (stale `transferring` rows in an in-flight resume loop).
  void _deferBleResumeAfterRecordingStop({String? sessionId}) {
    if (_disposed) return;
    final conn = state.connection;
    if (conn == null) return;
    final deviceId = conn.device.remoteId.toString();
    final sid = (sessionId ?? '').trim();
    final liveRecordingId = sid.isNotEmpty ? '${deviceId}_$sid' : null;

    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (_disposed) return;
      if (state.connection?.device.remoteId.toString() != deviceId) return;
      if (liveRecordingId != null &&
          _transferForRecording(liveRecordingId) != null) {
        AppLog.i(
          'DeviceController: defer post-stop BLE resume waiting '
          '(live download still active: $liveRecordingId)',
        );
        _scheduleResumeIncompleteTransfersWhenBleIdle(
          reason: 'post-stop live download finished',
          waitForRecordingId: liveRecordingId,
        );
        return;
      }
      if (liveRecordingId != null &&
          _shouldSuppressBleResume(liveRecordingId)) {
        AppLog.d(
          'DeviceController: post-stop live row suppressed; '
          'resuming other deferred BLE transfers (live=$liveRecordingId)',
        );
      }
      try {
        await _withRecRepo((recRepo) async {
          if (liveRecordingId == null) return;
          final row = await recRepo.getById(liveRecordingId);
          if (row != null &&
              (row.transferState == 'done' || row.transferState == 'merging')) {
            AppLog.i(
              'DeviceController: post-stop live row already '
              '${row.transferState}; resuming other deferred BLE transfers '
              '(live=$liveRecordingId)',
            );
          }
        });
      } catch (e, st) {
        if (isRecordingsDatabaseClosedError(e)) {
          AppLog.w(
            'DeviceController: defer post-stop BLE resume pre-check skipped '
            '(account DB not ready)',
            e,
            st,
          );
          return;
        }
        AppLog.w(
          'DeviceController: defer post-stop BLE resume pre-check failed',
          e,
          st,
        );
      }
      try {
        await _resumeIncompleteTransfers();
      } catch (e, st) {
        AppLog.w(
          'DeviceController: defer post-stop BLE resume failed',
          e,
          st,
        );
      }
    }());
  }

  /// Fast Sync / BLE handoff timeline: grep `xfer|` in logs.
  void _logXferState(String tag) {
    // Snapshot per-device transfer state for the log: which device, which
    // recording, and whether any cancel is pending. With Phase 2 there can
    // be at most one transfer per device (firmware constraint) but multiple
    // devices may have transfers running simultaneously after a fast switch.
    final transfers = _transfersByDevice.values
        .map((t) => '${t.deviceId}:${t.recordingId}'
            '${t.cancelRequested ? '(cancelPending)' : ''}')
        .join(',');
    AppLog.i(
      'xfer|$tag handoffRec=$_wifiHandoffRecordingId '
      'activeTransferForeground=$_activeTransferRecordingId '
      'transfersByDevice=[$transfers] '
      'handoffActive=$_wifiHandoffActive '
      'preferredAfterHandoff=$_preferredBleResumeRecordingIdAfterWifiHandoff',
    );
  }

  /// After the Fast Sync sheet closes without auto-hiding for UDP transfer (see [FastSyncWifiSheet]),
  /// resume BLE pulls for recordings left `transferring` / `failed` (e.g. `wifi_handoff` cancel or Wi‑Fi join failure).
  ///
  /// Delayed so [cancelTransfer] / Wi‑Fi teardown can finish before [downloadSessionToLocal] starts.
  Future<void> resumeBleTransfersAfterFastSyncDismiss({
    String? preferredRecordingId,
    /// When true (Wi‑Fi fallback dialog **Continue**), cancel a stuck BLE leg for
    /// [preferredRecordingId] so [_resumeIncompleteTransfers] can start fresh.
    bool forceRestart = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    _logXferState('resumeFastSyncDismiss.after450ms');
    if (_disposed) return;
    if (state.connection == null || _at == null) {
      AppLog.i(
        'resumeBleTransfersAfterFastSyncDismiss: skip (no connection/at)',
      );
      return;
    }
    if (_wifiHandoffActive) {
      AppLog.i(
        'resumeBleTransfersAfterFastSyncDismiss: handoff still active, skip',
      );
      return;
    }
    var effectivePreferred = (preferredRecordingId ?? '').trim();
    if (effectivePreferred.isEmpty) {
      effectivePreferred =
          (_preferredBleResumeRecordingIdAfterWifiHandoff ?? '').trim();
    }
    if (_activeTransferRecordingId != null) {
      if (forceRestart &&
          effectivePreferred.isNotEmpty &&
          _activeTransferRecordingId == effectivePreferred) {
        AppLog.i(
          'resumeBleTransfersAfterFastSyncDismiss: forceRestart — cancelling '
          'stuck BLE leg for $effectivePreferred',
        );
        await cancelTransfer(
          effectivePreferred,
          errorCode: 'wifi_fast_sync_fallback',
          keepPendingOnTimeout: true,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (_activeTransferRecordingId == effectivePreferred &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      } else {
        AppLog.i(
          'resumeBleTransfersAfterFastSyncDismiss: BLE transfer already active, skip '
          '(wait for slot or retry)',
        );
        return;
      }
    }
    if (effectivePreferred.isNotEmpty) {
      try {
        final recRepo = await ref.read(recordingsRepositoryProvider.future);
        final pr = await recRepo.getById(effectivePreferred);
        if (pr != null && pr.transferState == 'done') {
          AppLog.i(
            'resumeBleTransfersAfterFastSyncDismiss: preferred $effectivePreferred already done in DB, '
            'clearing handoff preferred (skip stale BLE resume)',
          );
          _preferredBleResumeRecordingIdAfterWifiHandoff = null;
          effectivePreferred = '';
        }
      } catch (_) {}
    }
    AppLog.i(
      'resumeBleTransfersAfterFastSyncDismiss: calling _resumeIncompleteTransfers '
      'preferredRecordingId=${effectivePreferred.isNotEmpty ? effectivePreferred : '(none)'}',
    );
    await _disableFileDataNotifyToFreeBleLink(
      logContext: 'resumeBleTransfersAfterFastSyncDismiss',
      markActiveLegs: false,
    );
    try {
      await _resumeIncompleteTransfers(
        preferredRecordingId:
            effectivePreferred.isNotEmpty ? effectivePreferred : null,
      );
    } catch (e, st) {
      AppLog.w('resumeBleTransfersAfterFastSyncDismiss failed', e, st);
    }
  }

  /// Trust firmware completion (like Python); after merge, flag DB + log if merged size is far below [expectedBytes].
  static (String message, String code)? undersizedMergedTransferNote({
    required int mergedBytes,
    required int? expectedBytes,
    required String recordingId,
  }) {
    final exp = expectedBytes ?? 0;
    if (exp <= 0 || mergedBytes >= (exp * 0.9).round()) return null;
    AppLog.e(
      'POSSIBLY INCOMPLETE TRANSFER (recordingId=$recordingId): merged=$mergedBytes bytes < 90%% of expected=$exp. '
      'Device reported transfer done but payload is short — verify playback or re-sync.',
    );
    return (
      'Merged file smaller than expected; recording may be incomplete.',
      'possibly_incomplete_transfer',
    );
  }

  /// Best-effort: turn off device Wi‑Fi AP so recording can start (after Fast Sync or stuck state).
  Future<void> forceDisableDeviceWifiAp() async {
    final at = _at;
    if (at == null) return;
    try {
      AppLog.i('DeviceController.forceDisableDeviceWifiAp: AT+WIFI=OFF');
      await WifiHotspotConnector(at: at).disable();
    } catch (e, st) {
      AppLog.w('DeviceController.forceDisableDeviceWifiAp failed', e, st);
    }
  }

  void _setFirmwareRecState(String? s) {
    if (_disposed) return;
    if (s == null) {
      state = state.copyWith(clearFirmwareRecState: true);
    } else {
      state = state.copyWith(firmwareRecState: s);
    }
  }

  /// Firmware `state` / `state_change` notify (same shape as during
  /// AT+DOWNLOAD) — keep [firmwareRecState] fresh without AT+GSTAT.
  ///
  /// Per `py_test/docs/protocol.md` 7.1.1 and Appendix E.5, the device emits
  /// `{"event":"state", "state":"RECORDING|IDLE|PAUSED", "session":"...",
  /// "duration":N?}` on **both** AT-driven and physical-button-driven
  /// recording transitions. Some legacy builds still ship the older
  /// `{"event":"state_change","new":"RECORDING",...}` shape — we accept
  /// either to stay compatible during the firmware rollout.
  void _maybeApplyBleEventForFirmwareState(Map<String, dynamic> msg) {
    if (_disposed) return;
    final data = msg['data'];
    final dataMap =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final event =
        (msg['event'] ?? dataMap['event'] ?? '').toString().toLowerCase();
    if (event != 'state' && event != 'state_change') return;
    // Protocol spec uses `state`; legacy shipped `new`.
    final newState =
        (dataMap['state'] ?? msg['state'] ?? dataMap['new'] ?? msg['new'] ?? '')
            .toString()
            .toUpperCase()
            .trim();
    final derived = switch (newState) {
      'IDLE' => 'idle',
      'RECORDING' => 'recording',
      'REC' => 'recording',
      'PAUSED' => 'paused',
      'TRANSMITTING' ||
      'TRANSFER' ||
      'TRANSFERING' ||
      'TRANSFERRING' ||
      'WIFI_SYNC' =>
        'transmitting',
      _ => null,
    };
    if (derived == null) return;

    // Device-button-driven recording lifecycle (Appendix E.3): adopt the
    // session id / start time so [downloadSessionToLocal] and the recording
    // sheet behave the same as if the App had issued AT+START / AT+STOP.
    final sid = (dataMap['session'] ?? msg['session'] ?? '').toString().trim();
    final durationSec = _parseInt(dataMap['duration'] ?? msg['duration']) ?? 0;
    if (derived == 'recording' &&
        _ignoreStaleRecordingWhilePauseInFlight(sid, 'event:$event')) {
      return;
    }
    if (derived == 'paused' || derived == 'idle') {
      _clearPauseCommandInFlightIfMatched(sid);
    }

    // IMPORTANT: update [_activeRecordingSessionId] **before**
    // [_setFirmwareRecState]. [ref.listen] on [firmwareRecState] runs
    // synchronously when we assign [state]; the recording sheet tests
    // `activeRecordingSessionId.isEmpty && nextFr == 'idle'` to detect a
    // device-button STOP. If we published `idle` first, listeners still saw
    // the old non-empty session id and skipped leaving the recording UI.
    if (derived == 'idle') {
      // Device stopped recording (long press or AT+STOP we missed).
      final activeBefore = (_activeRecordingSessionId ?? '').trim();
      if (activeBefore.isNotEmpty && (sid.isEmpty || sid == activeBefore)) {
        AppLog.i(
          'DeviceController: cleared active session $activeBefore on '
          'event:"$event" → IDLE (duration=${durationSec}s)',
        );
        final endedAt = DateTime.now();
        final stoppedSession = sid.isNotEmpty ? sid : activeBefore;
        _activeRecordingSessionId = null;
        _recordingStartedAt = null;
        _recordingStartOffsetSeconds = 0;
        // Persist the row's [endedAt] / final duration so the sync banner can
        // offer cancel/resync (depends on endedAt != null) and the recordings
        // list shows the correct duration even before merge completes.
        // Mirrors what [_startDeviceTransferPipeline] does for App-driven STOP.
        unawaited(_persistDeviceInitiatedStopMeta(
          sessionId: stoppedSession,
          durationSec: durationSec,
          endedAt: endedAt,
        ));
        _signalTransferSessionEnded(stoppedSession);
      }
      _setFirmwareRecState('idle');
      // Session is already cleared — do not treat this IDLE as a stale GSTAT
      // during an in-flight adopt; deferred BLE resume may proceed.
      _onDerivedRecordingStateForDeferredResume('idle');
      return;
    }

    if (derived == 'recording' && sid.isNotEmpty) {
      final activeBefore = (_activeRecordingSessionId ?? '').trim();
      if (activeBefore != sid) {
        _activeRecordingSessionId = sid;
        // Estimated start time: if firmware reports a non-zero duration
        // we are adopting an in-flight recording; subtract the elapsed
        // window so the App-side clock stays aligned.
        _recordingStartedAt = DateTime.now().subtract(
          Duration(seconds: durationSec.clamp(0, 24 * 3600)),
        );
        _recordingStartOffsetSeconds = 0;
        AppLog.i(
          'DeviceController: adopted device-side recording session '
          '$sid from event:"$event" (duration=${durationSec}s)',
        );
        final adoptDeviceId = state.connection?.device.remoteId.toString();
        if (adoptDeviceId != null) {
          _noteDeviceSessionRootPresent(adoptDeviceId, sid);
        }
        // Trigger the same live-download path the App uses after a
        // user-initiated AT+START so the recording is actually pulled.
        unawaited(_startLiveDownloadForDeviceInitiatedRecording(
          sessionId: sid,
        ));
      } else if (state.firmwareRecState == 'paused' ||
          _recordingStartedAt == null) {
        _resumeRecordingClock(
          sessionId: sid,
          reportedSeconds: durationSec > 0 ? durationSec : null,
        );
      }
    }

    if (derived == 'paused') {
      if (sid.isNotEmpty && (_activeRecordingSessionId ?? '').trim().isEmpty) {
        _activeRecordingSessionId = sid;
      }
      _freezeRecordingClock(
        sessionId: sid.isNotEmpty ? sid : null,
        reportedSeconds: durationSec > 0 ? durationSec : null,
      );
    }

    _setFirmwareRecState(derived);
    _onDerivedRecordingStateForDeferredResume(derived);
  }

  /// Apply a typed `event:"mark"` notification (protocol 7.1.2).
  ///
  /// Called for every bookmark — AT+MARK acks **and** physical short-press
  /// during recording (Appendix E.2). [fromDeviceButton] is set when the
  /// controller has no in-flight AT+MARK request (a heuristic: the App-side
  /// AT+MARK call always sees the ack inline via [AtTransport.send] so the
  /// notify generally arrives as well; UI uses [DeviceBookmarkNotice.seq] to
  /// detect new entries regardless).
  void _maybeApplyBleEventForBookmark(Map<String, dynamic> msg) {
    if (_disposed) return;
    final data = msg['data'];
    final dataMap =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final event =
        (msg['event'] ?? dataMap['event'] ?? '').toString().toLowerCase();
    if (event != 'mark' && event != 'bookmark') return;

    final sid = (dataMap['session'] ?? msg['session'] ?? '').toString().trim();
    final markCount = _parseInt(dataMap['mark_count'] ??
        msg['mark_count'] ??
        dataMap['count'] ??
        msg['count']);
    final offset = _parseInt(dataMap['offset'] ?? msg['offset']);
    final seq = ++_bookmarkEventSeq;
    final now = DateTime.now();

    final fromButton = !_appInitiatedMarkPending;
    if (_appInitiatedMarkPending) {
      // Consume the App-driven mark hint; subsequent marks default to
      // device-button source.
      _appInitiatedMarkPending = false;
    }

    AppLog.i(
      'DeviceController: bookmark event session=$sid count=$markCount '
      'offset=${offset}s fromButton=$fromButton',
    );

    state = state.copyWith(
      lastBookmark: DeviceBookmarkNotice(
        seq: seq,
        sessionId: sid,
        markCount: markCount,
        offsetSeconds: offset,
        fromDeviceButton: fromButton,
        receivedAt: now,
      ),
    );
  }

  /// Internal counter for bookmark events; bumps on every notify so listeners
  /// can detect new arrivals via reference (== seq) comparison even when
  /// `markCount` repeats / is omitted.
  int _bookmarkEventSeq = 0;

  /// Set by [markRecording] just before sending AT+MARK so the inbound
  /// notify is attributed to the App rather than the device button.
  bool _appInitiatedMarkPending = false;

  /// Broadcast bus for typed device events (button-driven start/stop, marks,
  /// battery_low, storage_low, error, …) parsed from the AT notify stream.
  ///
  /// Exposed for UI widgets that want to react to one specific event type
  /// without re-implementing the JSON parsing — see [DeviceEvent] subclasses
  /// in `package:sensecraft_voice/sensecraft_voice.dart`.
  Stream<DeviceEvent> get deviceEvents => _deviceEvents.stream;
  final StreamController<DeviceEvent> _deviceEvents =
      StreamController<DeviceEvent>.broadcast();

  /// Push a parsed [event] onto [deviceEvents]. Safe to call from anywhere
  /// (no-op when the controller is disposed).
  void _publishDeviceEvent(DeviceEvent event) {
    if (_disposed || _deviceEvents.isClosed) return;
    _deviceEvents.add(event);
  }

  /// Apply battery_low / storage_low / error events from `protocol.md` 7.1.3
  /// – 7.1.5. The controller stashes the data in [DeviceUiState.error] /
  /// [errorCode] so existing snackbar plumbing surfaces it, and re-emits the
  /// parsed [DeviceEvent] on [deviceEvents] for richer UI handlers.
  void _maybeApplyBleEventForBatteryStorageError(Map<String, dynamic> msg) {
    if (_disposed) return;
    final parsed = parseDeviceEvent(msg);
    if (parsed == null) return;

    // Always relay to listeners (typed). The first three handlers above
    // already mutate `state` for state/mark; this one only sets `state.error`
    // for the warning families. We still publish the recording state / mark
    // events here so subscribers don't need to consume two streams.
    _publishDeviceEvent(parsed);

    switch (parsed) {
      case DeviceBatteryLowEvent(:final level):
        AppLog.w(
          'DeviceController: battery_low notify (level=${level ?? '?'}%)',
        );
        state = state.copyWith(
          error: 'Device battery low (${level ?? '<10'}%)',
          errorCode: 'device_battery_low',
        );
        break;
      case DeviceStorageLowEvent(:final freeMb):
        AppLog.w(
          'DeviceController: storage_low notify (free=${freeMb ?? '?'}MB)',
        );
        state = state.copyWith(
          error: 'Device storage low (${freeMb ?? '<100'}MB free)',
          errorCode: 'device_storage_low',
        );
        break;
      case DeviceErrorEvent(:final code, :final message):
        AppLog.w('DeviceController: device error event '
            'code=${code ?? '?'} message="${message ?? ''}"');
        state = state.copyWith(
          error: message ?? 'Device error ${code ?? ''}'.trim(),
          errorCode: 'device_error_${code ?? 'unknown'}',
        );
        break;
      case DeviceConnectedEvent():
      case DeviceDisconnectedEvent():
      case DeviceRecordingStateEvent():
      case DeviceBookmarkEvent():
      case DeviceUnknownEvent():
        // Non-warning events: nothing extra here. Recording state / marks
        // are mutated by their dedicated handlers above; connected /
        // disconnected events are informational.
        break;
    }
  }

  /// Kick off a live BLE download for a recording the **device** started
  /// (button long press). Mirrors what [RecordingSessionSheet._startRecording]
  /// does after a user-initiated AT+START so files are pulled in real time.
  ///
  /// Best-effort: any failure logs and returns silently — the next
  /// [_resumeIncompleteTransfers] sweep will retry once the row exists.
  Future<void> _startLiveDownloadForDeviceInitiatedRecording({
    required String sessionId,
  }) async {
    if (_disposed) return;
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;
    if (sessionId.trim().isEmpty) return;
    final deviceId = conn.device.remoteId.toString();
    final recordingId = '${deviceId}_$sessionId';
    // STEP 1 — always create / refresh the DB row first. This is independent
    // of whether we can start the download immediately: without the row,
    // [_persistDeviceInitiatedStopMeta] has nothing to update on STOP, the
    // sheet's "device started recording" toast can't adopt a recording id,
    // and the resume loop has nothing to pick up after the in-flight transfer
    // finishes.
    try {
      await _withRecRepo((recRepo) async {
        final existing = await recRepo.getById(recordingId);
        final now = DateTime.now();
        if (existing == null) {
          final deviceName = await _resolvedDeviceDisplayName(
            deviceId,
            conn.device.platformName,
            emptyFallback: 'Device',
          );
          final displayDate = parseSessionTimestamp(sessionId) ?? now;
          await recRepo.createPendingDeviceRecording(
            deviceId: deviceId,
            devicePath: sessionId,
            name: recordingDisplayNameForDevice(deviceName, displayDate),
            durationSeconds: 0,
            createdAt: now,
            startedAt: now,
            format: 'opus',
            container: 'opus',
            mtu: state.mtu,
          );
          _noteDeviceSessionRootPresent(deviceId, sessionId);
          AppLog.i(
            'DeviceController: created pending row $recordingId for device-button '
            'start (download may be deferred)',
          );
        } else if (existing.transferState != 'transferring') {
          await recRepo.updateTransfer(
            id: recordingId,
            state: 'transferring',
            recordingState: 'transferring',
            error: null,
            errorCode: null,
          );
        }
        bumpRecordingsLists(ref);
      });
    } catch (e, st) {
      AppLog.w(
        'DeviceController: pending-row write for device-button start failed '
        '(non-fatal)',
        e,
        st,
      );
      return;
    }

    if (!liveRecordingBleSyncEnabled) {
      _holdRecordingExclusiveBleGuard(sessionId);
      try {
        await _withRecRepo((recRepo) => recRepo.updateTransfer(
              id: recordingId,
              state: 'transferring',
              error: '',
              errorCode: 'device_recording_resume_later',
              recordingState: 'transferring',
            ));
      } catch (_) {}
      AppLog.i(
        'DeviceController: iOS recording-exclusive BLE mode — '
        'defer live download for $recordingId until STOP',
      );
      return;
    }

    // STEP 2 — try to start a continuous live download immediately. If a
    // Wi-Fi handoff or another BLE transfer is already running, skip and let
    // [_resumeIncompleteTransfers] (called at the end of the active download)
    // pick up the row we just inserted. Either way, the row exists so STOP
    // can finalize [endedAt] / [durationSeconds].
    if (_wifiHandoffActive) {
      AppLog.d(
        'DeviceController: defer live-download for $sessionId '
        '(Wi-Fi handoff active)',
      );
      return;
    }
    if (_activeTransferRecordingId != null &&
        _activeTransferRecordingId != recordingId) {
      AppLog.d(
        'DeviceController: defer live-download for $sessionId '
        '(active transfer $_activeTransferRecordingId) — resume loop will '
        'pick it up',
      );
      return;
    }
    // Mirror RecordingSessionSheet: ignore failures, the resume loop will
    // retry on disconnect / reconnect.
    unawaited(
      downloadSessionToLocal(
        recordingId: recordingId,
        sessionId: sessionId,
        expectedBytes: null,
        continuous: true,
        allowDuringRecordingStartGuard: true,
      ).catchError((Object e, StackTrace st) {
        AppLog.w(
          'DeviceController: live download failed (resume loop will retry)',
          e,
          st,
        );
        return false;
      }),
    );
  }

  /// Mirror [_startDeviceTransferPipeline]'s post-stop metadata write but for
  /// device-button STOP (we never see [RecStopResult] in that path because the
  /// firmware emits an unsolicited `event:"state","state":"IDLE",...,"duration":N`
  /// instead of an [AT+STOP] response). Without this, the recording row keeps
  /// `ended_at = null` forever, which:
  ///   * blocks cancel/resync in [transfer_progress_banner] (gated on
  ///     `recording.endedAt != null`);
  ///   * leaves [duration_seconds] at 0 in the recordings list until merge
  ///     completes (and even then, only if probing the merged file succeeds).
  /// Idempotent so the App-driven STOP path remains safe to keep updating
  /// the same fields.
  Future<void> _persistDeviceInitiatedStopMeta({
    required String sessionId,
    required int durationSec,
    required DateTime endedAt,
  }) async {
    if (_disposed) return;
    if (sessionId.isEmpty) return;
    final conn = state.connection;
    if (conn == null) return;
    try {
      final deviceId = conn.device.remoteId.toString();
      final recordingId = '${deviceId}_$sessionId';
      await _withRecRepo((recRepo) async {
        final rec = await recRepo.getById(recordingId);
        if (rec == null) {
          // Live download path didn't create a row (e.g. the App joined the
          // session after start). Nothing to backfill — the resume loop will
          // create one when it next sees a session on disk.
          AppLog.d(
            'DeviceController: persistDeviceInitiatedStopMeta — no DB row '
            'for $recordingId, skipping',
          );
          return;
        }
        // Already finalized by [_startDeviceTransferPipeline] (App tapped Stop
        // before the unsolicited event arrived). Don't overwrite a good value
        // with a stale firmware-reported duration.
        if (rec.endedAt != null && (rec.durationSeconds ?? 0) > 0) {
          return;
        }
        await recRepo.updateDeviceRecordingMeta(
          id: recordingId,
          durationSeconds: durationSec > 0 ? durationSec : null,
          endedAt: endedAt,
        );
        bumpRecordingsLists(ref);
        ref.invalidate(recordingByIdProvider(recordingId));
        _noteDeviceSessionRootPresent(deviceId, sessionId);
        AppLog.i(
          'DeviceController: persisted device-stop meta for $recordingId '
          '(duration=${durationSec}s, endedAt=$endedAt)',
        );
      });
    } catch (e, st) {
      AppLog.w(
        'DeviceController: persistDeviceInitiatedStopMeta failed (non-fatal)',
        e,
        st,
      );
    }
  }

  /// GSTAT-shaped JSON on the notify stream (reply to AT+GSTAT or same payload from firmware).
  void _maybeApplyGstatNotifyToFirmwareState(Map<String, dynamic> msg) {
    if (_disposed) return;
    if (!AtTransport.looksLikeGstatOkReply(msg)) return;
    final data = msg['data'];
    if (data is! Map) return;
    final dataMap = Map<String, dynamic>.from(data);
    final derived = _deriveRecStateFromGstatMap(dataMap);
    final sid =
        (dataMap['session_id'] ?? dataMap['session'] ?? '').toString().trim();
    if (derived == 'recording' &&
        _ignoreStaleRecordingWhilePauseInFlight(sid, 'GSTAT notify')) {
      return;
    }
    if (derived == 'paused' || derived == 'idle') {
      _clearPauseCommandInFlightIfMatched(sid);
    }
    _adoptForegroundRecordingFromGstatMap(dataMap);

    final durationSec =
        _parseInt(dataMap['duration']) ?? _parseInt(dataMap['duration_s']);
    final stateEvent = switch (derived) {
      'recording' => DeviceRecordingState.recording,
      'paused' => DeviceRecordingState.paused,
      'idle' => DeviceRecordingState.idle,
      'transmitting' => DeviceRecordingState.transmitting,
      _ => DeviceRecordingState.unknown,
    };
    if (stateEvent != DeviceRecordingState.unknown) {
      _publishDeviceEvent(DeviceRecordingStateEvent(
        state: stateEvent,
        sessionId: sid.isEmpty ? null : sid,
        durationSeconds: durationSec,
        mode: null,
        raw: msg,
      ));
    }
  }

  /// After connect / promote / GSTAT notify: restore foreground recording
  /// mirrors cleared by [_resetActiveDeviceCachesForSwitch] and kick live BLE
  /// pull so transfer banner + list progress appear without opening the sheet.
  void _adoptForegroundRecordingFromGstatMap(Map<String, dynamic> dataMap) {
    if (_disposed) return;
    final derived = _deriveRecStateFromGstatMap(dataMap);
    final sid =
        (dataMap['session_id'] ?? dataMap['session'] ?? '').toString().trim();
    final durationSec =
        _parseInt(dataMap['duration']) ?? _parseInt(dataMap['duration_s']) ?? 0;

    if ((derived == 'recording' || derived == 'paused') && sid.isNotEmpty) {
      final active = (_activeRecordingSessionId ?? '').trim();
      if (active.isEmpty || active == sid) {
        _activeRecordingSessionId = sid;
        if (durationSec > 0) {
          _recordingStartOffsetSeconds =
              durationSec.clamp(0, 24 * 3600).toInt();
          _recordingStartedAt = derived == 'paused' ? null : DateTime.now();
        } else if (derived == 'paused') {
          _freezeRecordingClock(sessionId: sid);
        } else {
          _recordingStartedAt ??= DateTime.now();
        }
        AppLog.i(
          'DeviceController: synced active session=$sid from GSTAT '
          '(state=$derived, duration=${durationSec}s)',
        );
      }
    }

    _setFirmwareRecState(derived);
    _onDerivedRecordingStateForDeferredResume(derived);

    if ((derived == 'recording' || derived == 'paused') && sid.isNotEmpty) {
      _holdRecordingExclusiveBleGuard(sid);
      bumpRecordingsLists(ref);
      unawaited(_ensureLiveRecordingPullAfterForegroundAdopt(sessionId: sid));
    }
  }

  /// Start (or resume) continuous BLE pull for an already-recording foreground device.
  Future<void> _ensureLiveRecordingPullAfterForegroundAdopt({
    required String sessionId,
  }) async {
    if (_disposed) return;
    final conn = state.connection;
    if (conn == null) return;
    final deviceId = conn.device.remoteId.toString();
    final recordingId = '${deviceId}_$sessionId';
    if (!liveRecordingBleSyncEnabled) {
      await _startLiveDownloadForDeviceInitiatedRecording(
        sessionId: sessionId,
      );
      return;
    }
    if (_transferForRecording(recordingId) != null) {
      _syncForegroundTransferMirror();
      return;
    }

    try {
      final recRepo = await ref.read(recordingsRepositoryProvider.future);
      final existing = await recRepo.getById(recordingId);
      if (existing != null &&
          existing.transferState == 'transferring' &&
          existing.endedAt == null) {
        final path = existing.devicePath.trim();
        await resumeLiveRecordingTransferIfStalled(
          recordingId: recordingId,
          sessionId: path.isNotEmpty ? path : sessionId,
        );
        return;
      }
    } catch (e, st) {
      AppLog.w(
        'DeviceController: live-pull resume after adopt failed (non-fatal)',
        e,
        st,
      );
    }

    await _startLiveDownloadForDeviceInitiatedRecording(sessionId: sessionId);
  }

  /// Hardware STOP (or STOP notify arriving outside [AtTransport.send]): clear session so UI can exit recording.
  void _maybeApplyUnsolicitedStopAck(Map<String, dynamic> msg) {
    if (_disposed) return;
    final active = (_activeRecordingSessionId ?? '').trim();
    if (active.isEmpty) return;
    if (!_looksLikeConcreteStopSuccess(msg)) return;
    final data = msg['data'];
    final dataMap =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final sid = (dataMap['session'] ?? msg['session'] ?? '').toString().trim();
    if (sid.isNotEmpty && sid != active) return;
    AppLog.i(
        'DeviceController: unsolicited STOP-shaped notify, clearing active session');
    _activeRecordingSessionId = null;
    _recordingStartedAt = null;
    _recordingStartOffsetSeconds = 0;
    _setFirmwareRecState('idle');
    // STOP does not go through [getRecordingStatus]; sync deferred-resume tracker and retry BLE transfers
    // so `device_recording_resume_later` / progress UI update without waiting for the next GSTAT poll.
    _prevDerivedRecStateForDeferredResume = 'idle';
    _onRecordingStoppedForTransfer(sid.isNotEmpty ? sid : active);
    _deferBleResumeAfterRecordingStop(sessionId: sid.isNotEmpty ? sid : active);
  }

  bool _looksLikeConcreteStopSuccess(Map<String, dynamic> msg) {
    if (msg['ok'] != true) return false;
    final data = msg['data'];
    final dataMap =
        data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
    final cmd =
        (msg['cmd'] ?? dataMap['cmd'] ?? '').toString().trim().toUpperCase();
    if (cmd == 'STOP') return true;
    if (dataMap.containsKey('frames') ||
        dataMap.containsKey('file_count') ||
        dataMap.containsKey('total_size')) {
      return true;
    }

    return false;
  }

  /// Wait until [_resumeIncompleteTransfers] is not holding the busy lock (no gap between two queued downloads).
  Future<void> _waitForResumeLoopIdle(
      {Duration timeout = const Duration(seconds: 12)}) async {
    final deadline = DateTime.now().add(timeout);
    while (
        _resumeIncompleteTransfersBusy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_resumeIncompleteTransfersBusy) {
      AppLog.w(
        'DeviceController._waitForResumeLoopIdle: timeout after ${timeout.inSeconds}s '
        '(resume loop still busy — proceeding with caution)',
      );
    }
  }

  /// End BLE file pull before `AT+START` (Wi‑Fi fast sync must be cancelled by caller). Does not send `AT+WIFI=OFF`; UI turns AP off after user confirms if START fails.
  Future<bool> _stopBleTransferAndDeviceWifiForRecording() async {
    endWifiHandoff();
    var sentCancelBeforeStart = false;
    // Cancel BLE pull **before** [_waitForResumeLoopIdle]: auto-resume holds
    // [_resumeIncompleteTransfersBusy] while awaiting [downloadSessionToLocal]. Waiting
    // first blocked for up to 12s with no AT+CANCEL — firmware kept sending files (felt
    // like "tap record → CANCEL very late").
    final deviceId = state.connection?.device.remoteId.toString();
    final activeId =
        _activeTransferRecordingId ?? _transferForDevice(deviceId)?.recordingId;
    if (activeId != null) {
      sentCancelBeforeStart = true;
      // iOS: fire-and-forget so AT+CANCEL does not block ~12s (serial-queue +
      // 5s ack wait) on the transfer-saturated link before AT+START.
      await cancelTransfer(
        activeId,
        errorCode: 'device_recording_resume_later',
        keepPendingOnTimeout: true,
        fireAndForgetAtCancel: Platform.isIOS,
        atCancelTimeout: Platform.isIOS
            ? const Duration(milliseconds: 900)
            : const Duration(seconds: 5),
        maxStopWait: Platform.isIOS
            ? const Duration(milliseconds: 1200)
            : const Duration(milliseconds: 2500),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (_activeTransferRecordingId != null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_activeTransferRecordingId != null) {
        AppLog.w(
          'DeviceController._stopBleTransferAndDeviceWifiForRecording: '
          'activeTransfer still set after cancel wait (id=$_activeTransferRecordingId)',
        );
        return false;
      }
    } else if (_resumeIncompleteTransfersBusy) {
      // Race: user tapped record while the resume loop is mid-leg but before the
      // download registered a foreground transfer. Without this, we'd block in
      // [_waitForResumeLoopIdle] for the full 12s with NO AT+CANCEL on the wire
      // while the firmware keeps streaming a file over a (possibly weak) link.
      // Poke the firmware up-front so the in-flight leg ends and the resume loop
      // releases quickly. A "No active transfer" / late reply is harmless now.
      final at = _at;
      if (at != null) {
        try {
          AppLog.i(
            'DeviceController: AT+CANCEL up-front '
            '(resume loop busy, no registered transfer yet)',
          );
          sentCancelBeforeStart = true;
          await _disableFileDataNotifyToFreeBleLink(
            logContext: 'DeviceController AT+CANCEL up-front',
            markActiveLegs: false,
          );
          if (Platform.isIOS) {
            // Write-without-response bypasses the serial queue / ack wait so a
            // busy transfer link can't stall the next AT+START by ~seconds.
            await at
                .writeCommandOnly('AT+CANCEL', withoutResponse: true)
                .timeout(const Duration(milliseconds: 900));
          } else {
            await at.send('AT+CANCEL',
                timeout: const Duration(milliseconds: 1500));
          }
        } catch (e, st) {
          AppLog.w('DeviceController: AT+CANCEL up-front (non-fatal)', e, st);
        }
      }
    }
    await _waitForResumeLoopIdle();
    // Always send AT+CANCEL once before START: firmware may still be draining a file after [cancelTransfer]
    // cleared app-side state, or stack may have missed the first cancel.
    //
    // Keep this timeout short: while the firmware is still streaming a file it
    // cannot answer AT commands, so a long wait here just stacks on top of
    // [cancelTransfer]'s own AT+CANCEL (felt like a multi-second frozen sheet).
    // A late reply to this cancel is now harmless — [AtTransport.send] only lets
    // an AT+CANCEL waiter consume a cancel-shaped reply, so the following
    // AT+START can no longer mis-match it.
    final at = _at;
    if (at != null && sentCancelBeforeStart && !Platform.isIOS) {
      try {
        AppLog.i('DeviceController: AT+CANCEL before recording (best-effort)');
        await at.send('AT+CANCEL', timeout: const Duration(milliseconds: 1500));
      } catch (e, st) {
        AppLog.w(
            'DeviceController: AT+CANCEL before record (non-fatal)', e, st);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } else if (sentCancelBeforeStart && Platform.isIOS) {
      AppLog.i(
        'DeviceController: skip duplicate AT+CANCEL before recording on iOS',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } else {
      AppLog.d(
        'DeviceController: skip AT+CANCEL before recording '
        '(no active BLE transfer to cancel)',
      );
    }
    return true;
  }

  /// Clears the recording-start BLE guard if something prevented the live [downloadSessionToLocal] from running.
  void clearRecordingStartBleGuard() {
    if (_bleTransferGuardForRecordingStart) {
      AppLog.d('DeviceController.clearRecordingStartBleGuard');
    }
    _bleTransferGuardForRecordingStart = false;
    _bleTransferGuardRecordingId = null;
  }

  void _holdRecordingExclusiveBleGuard(String sessionId) {
    if (liveRecordingBleSyncEnabled) return;
    final conn = state.connection;
    final sid = sessionId.trim();
    if (conn == null || sid.isEmpty) return;
    _bleTransferGuardForRecordingStart = true;
    _bleTransferGuardRecordingId = '${conn.device.remoteId.toString()}_$sid';
  }

  /// After AT+STOP / device IDLE, tell any live [downloadSessionToLocal] loop
  /// for this session to finish the leg and merge instead of waiting 3 minutes.
  void _signalTransferSessionEnded(String sessionId) {
    final sid = sessionId.trim();
    if (sid.isEmpty) return;
    final suffix = '_$sid';
    for (final t in _transfersByDevice.values) {
      if (t.recordingId.endsWith(suffix)) {
        t.sessionEndedOnDevice = true;
        // The leg's fileData notify was dropped by the STOP link flush, so no
        // more bytes can arrive. Wake it now to pause for resync instead of
        // waiting up to a full 10s watchdog tick — the post-stop resume then
        // re-issues AT+DOWNLOAD and continues from received bytes immediately.
        if (t.fileNotifyDisabledWhileActive && !t.resyncRequested) {
          t.resyncRequested = true;
          final c = t.waitCompleter;
          if (c != null && !c.isCompleted) c.complete();
        }
        AppLog.i(
          'DeviceController: session ended — finish live transfer for ${t.recordingId}',
        );
      }
    }
  }

  /// iOS often freezes GATT file notifies while backgrounded. On foreground
  /// resume, pause any mid-file leg that has been quiet so
  /// [_resumeIncompleteTransfers] can re-issue AT+DOWNLOAD instead of sitting
  /// at ~90% until the 3‑minute stall watchdog.
  void nudgeStalledBleTransfersAfterAppResume() {
    final now = DateTime.now();
    var nudged = 0;
    for (final t in _transfersByDevice.values) {
      if (t.cancelRequested || t.resyncRequested) continue;
      final idleFor = now.difference(t.lastDataAt);
      if (idleFor < const Duration(seconds: 8)) continue;
      t.resyncRequested = true;
      final c = t.waitCompleter;
      if (c != null && !c.isCompleted) c.complete();
      nudged++;
      AppLog.w(
        'DeviceController: app resume — nudge stalled BLE transfer '
        '${t.recordingId} (idle=${idleFor.inSeconds}s) for resync',
      );
    }
    if (nudged > 0) {
      unawaited(_resumeIncompleteTransfers());
    }
  }

  /// iOS disables the shared `fileData` CCCD before AT+STOP/PAUSE/CANCEL to
  /// flush the write-without-response command. That also starves any live
  /// record-while-transfer leg on the same link. Flag those legs so the
  /// watchdog pauses them for resync within seconds (the post-stop resume then
  /// re-issues AT+DOWNLOAD and re-enables the notify) instead of sitting idle
  /// for the full 180s no-data window.
  void _markFileNotifyDisabledForActiveLegs(String deviceId) {
    for (final t in _transfersByDevice.values) {
      if (t.deviceId == deviceId) {
        t.fileNotifyDisabledWhileActive = true;
      }
    }
  }

  /// Disable the `fileData` CCCD so AT command replies are not stuck behind a
  /// notify flood (iOS write-without-response stall; Android inbound backlog).
  /// Re-enabled at the next download leg in [downloadSessionToLocal].
  Future<void> _disableFileDataNotifyToFreeBleLink({
    required String logContext,
    bool markActiveLegs = true,
  }) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    final conn = state.connection;
    final at = _at;
    if (at == null) return;
    if (markActiveLegs && conn != null) {
      _markFileNotifyDisabledForActiveLegs(conn.device.remoteId.toString());
    }
    try {
      await at.setFileDataNotify(false, timeout: const Duration(seconds: 2));
      AppLog.i('$logContext: disabled fileData notify to free BLE link');
    } catch (e, st) {
      AppLog.w(
        '$logContext: disable fileData notify failed (continuing)',
        e,
        st,
      );
    }
  }

  bool _recordingLikelyAfterWifiSetupFailure(Recording rec) {
    final ec = (rec.transferErrorCode ?? '').trim();
    return ec == 'wifi_fast_sync_unreachable' ||
        ec == 'wifi_fast_sync_disconnected' ||
        ec == 'wifi_handoff' ||
        ec == 'wifi_transfer_failed';
  }

  void _onRecordingStoppedForTransfer(String sessionId) {
    _clearRecordingStartBleGuardForStoppedSession(sessionId);
    _signalTransferSessionEnded(sessionId);
  }

  void _clearRecordingStartBleGuardForStoppedSession(String sessionId) {
    if (!_bleTransferGuardForRecordingStart) return;
    final target = (_bleTransferGuardRecordingId ?? '').trim();
    final sid = sessionId.trim();
    if (target.isEmpty) {
      AppLog.d(
        'DeviceController: keep recording-start guard on STOP '
        '(target pending, stoppedSession=${sid.isNotEmpty ? sid : "(empty)"})',
      );
      return;
    }
    if (sid.isNotEmpty && target.endsWith('_$sid')) {
      _bleTransferGuardForRecordingStart = false;
      _bleTransferGuardRecordingId = null;
      AppLog.d(
        'DeviceController: recording-start guard cleared by STOP for $sid',
      );
      return;
    }
    AppLog.d(
      'DeviceController: keep recording-start guard on STOP '
      '(target=$target stoppedSession=${sid.isNotEmpty ? sid : "(empty)"})',
    );
  }

  void _clearRecordingStartBleGuardIfLivePullAborted(
    bool allowDuringRecordingStartGuard, {
    String? recordingId,
  }) {
    if (allowDuringRecordingStartGuard &&
        _bleTransferGuardForRecordingStart &&
        _isRecordingStartGuardTarget(recordingId)) {
      _bleTransferGuardForRecordingStart = false;
      _bleTransferGuardRecordingId = null;
      AppLog.d(
          'DeviceController: recording-start guard cleared (live pull aborted before slot)');
    }
  }

  Future<bool> _clearRecordingStartGuardIfDeviceIdle({
    required String source,
  }) async {
    if (!_bleTransferGuardForRecordingStart) return true;
    final target = (_bleTransferGuardRecordingId ?? '').trim();
    if (target.isEmpty) {
      AppLog.d(
        'DeviceController: keep recording-start guard for $source '
        '(target pending)',
      );
      return false;
    }

    final localActive = (_activeRecordingSessionId ?? '').trim();
    final localState = state.firmwareRecState;
    if (localActive.isEmpty &&
        localState != 'recording' &&
        localState != 'paused') {
      AppLog.i(
        'DeviceController: recording-start guard cleared by $source '
        '(local state=${localState ?? "unknown"})',
      );
      clearRecordingStartBleGuard();
      return true;
    }

    final at = _at;
    if (at == null) return false;
    try {
      final st = await getRecordingStatus(
        timeout: Platform.isIOS
            ? const Duration(milliseconds: 900)
            : const Duration(seconds: 2),
      );
      if (st == null) return false;
      if (st.state == 'recording' || st.state == 'paused') return false;
      AppLog.i(
        'DeviceController: recording-start guard cleared by $source '
        '(device state=${st.state}, session=${st.sessionId ?? "(empty)"})',
      );
      clearRecordingStartBleGuard();
      return true;
    } catch (e, st) {
      AppLog.w(
        'DeviceController: recording-start guard idle probe failed ($source)',
        e,
        st,
      );
      return false;
    }
  }

  bool _isRecordingStartGuardTarget(String? recordingId) {
    final target = (_bleTransferGuardRecordingId ?? '').trim();
    final rid = (recordingId ?? '').trim();
    return target.isNotEmpty && rid == target;
  }

  bool _recordingStartGuardAllows({
    required String recordingId,
    required bool allowDuringRecordingStartGuard,
  }) {
    if (!_bleTransferGuardForRecordingStart) return true;
    if (!allowDuringRecordingStartGuard) return false;
    return _isRecordingStartGuardTarget(recordingId);
  }

  /// Serializes [downloadSessionToLocal] **per device**: the firmware allows one
  /// active transfer stream per peer, but independent devices on separate BLE
  /// links can pull in parallel. A global chain incorrectly blocked the
  /// foreground device while a background device kept a live-record download open.
  final Map<String, Future<void>> _bleDownloadExclusiveChainByDevice = {};

  /// Prevents duplicate concurrent reconnects (recording sheet and controller disconnect callback may fire together).
  bool _reconnectInProgress = false;

  /// Shared in-flight reconnect; concurrent callers await this instead of failing early.
  Future<bool>? _ongoingReconnect;

  /// While non-null, suppress auto-reconnect for this device (unbind / pair reset).
  String? _unbindInProgressFor;

  /// Last successful connection time, for auto-reconnect in the "recently connected" case (also when idle, not only during recording/transfer).
  DateTime? _lastConnectedAt;

  /// Per-device last successful `AT+TIME=`; used to throttle idle re-syncs.
  final Map<String, DateTime> _lastDeviceTimeSyncAt = {};

  /// Last time the user opened device details (foreground connected device).
  DateTime? _lastDeviceDetailsVisitAt;

  /// Earliest next eligibility check for [maybeSyncDeviceTimeWhenIdle]
  /// (does not mean sync every 30 min — actual sync still requires ≥1 h idle).
  DateTime _nextIdleTimeSyncCheckAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _kDeviceTimeSyncMinInterval = Duration(hours: 1);
  static const Duration _kIdleTimeSyncCheckInterval = Duration(minutes: 30);

  /// Debounce: avoid bumping deviceDbRevision too often in short time, which would cause device detail page etc. to refresh excessively.
  Timer? _bumpRevisionTimer;
  static const _bumpRevisionDebounce = Duration(milliseconds: 300);

  /// How often the multi-device background pool pings dormant peers with
  /// AT+GSTAT to keep the BLE link warm. See [_BackgroundLink.keepaliveTimer].
  /// Tuned to be short enough that Android doesn't let the radio go idle, long
  /// enough to be effectively free in terms of battery / airtime.
  static const Duration _kBackgroundKeepaliveInterval = Duration(seconds: 12);

  /// Per-ping timeout. Must comfortably exceed a healthy AT round-trip
  /// (~30-150ms in practice) but stay well under the keepalive interval so a
  /// slow ping doesn't bleed into the next one.
  static const Duration _kBackgroundKeepaliveTimeout = Duration(seconds: 3);

  /// Consecutive keepalive failures tolerated before we evict the background
  /// link. 3 means we give the peer ~36 s to come back before declaring it
  /// dead — generous enough to tolerate transient RF dropouts while still
  /// preventing the dropdown from showing stale "online" devices.
  static const int _kBackgroundKeepaliveMaxFailures = 3;

  Future<Map<String, dynamic>> _sendAtWithDisconnect(
    SenseCraftVoiceConnection conn,
    AtTransport at,
    String cmd, {
    required Duration timeout,
    bool disconnectMeansSuccess = false,
  }) async {
    final disconnectFuture = conn.device.connectionState
        .where((s) => s == BluetoothConnectionState.disconnected)
        .first;
    final winner = await Future.any([
      at.send(cmd, timeout: timeout).then((r) => ('send', r)),
      disconnectFuture.then((_) => ('disconnect', null)),
    ]);
    if (winner.$1 == 'disconnect') {
      if (disconnectMeansSuccess) {
        return const {'ok': true, 'rebooting': true};
      }
      throw StateError('device disconnected');
    }
    return winner.$2 as Map<String, dynamic>;
  }

  /// After GATT connects, confirm the Clip AT channel works before reporting success to UI / starting resume.
  /// Avoids false "connected" when the stack reports linked but writes/notifies are not ready yet.
  Future<bool> _verifyAtLinkReady() async {
    final at = _at;
    if (at == null) return false;
    try {
      final resp =
          await at.send('AT+GSTAT', timeout: const Duration(seconds: 4));
      final ok = resp['ok'] == true;
      if (!ok) {
        AppLog.w('_verifyAtLinkReady: AT+GSTAT ok=false');
      }
      return ok;
    } catch (e, st) {
      AppLog.w('_verifyAtLinkReady: ping failed', e, st);
      return false;
    }
  }

  /// GATT can come up before AT notify/write is ready; retry briefly before declaring failure.
  Future<bool> _verifyAtLinkReadyWithRetry({
    int attempts = 3,
    Duration gap = const Duration(milliseconds: 450),
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (_disposed) return false;
      if (await _verifyAtLinkReady()) return true;
      if (i < attempts - 1) {
        await Future<void>.delayed(gap);
      }
    }
    return false;
  }

  void _markReconnectOutcome(bool success) {
    if (_disposed) return;
    state = state.copyWith(
      reconnectStatus: success ? 'success' : 'failed',
      error: success ? null : state.error,
      clearErrorCode: success,
    );
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!_disposed && state.reconnectStatus != 'reconnecting') {
        state = state.copyWith(reconnectStatus: 'idle');
      }
    });
  }

  /// Snapshot the keys of [_backgrounds] into [DeviceUiState.backgroundConnectedIds]
  /// so UI consumers (e.g. [DeviceSelectorDropdown]) refresh.
  void _publishBackgroundIds() {
    if (_disposed) return;
    state = state.copyWith(
      backgroundConnectedIds:
          Set<String>.unmodifiable(_backgrounds.keys.toSet()),
    );
  }

  /// Active-device caches that only make sense for the currently-foreground
  /// connection. Cleared on demote so the next promote starts fresh.
  void _resetActiveDeviceCachesForSwitch() {
    _resetDeviceListPaging();
    _recordingStartedAt = null;
    _recordingStartOffsetSeconds = 0;
    _activeRecordingSessionId = null;
    _activeTransferRecordingId = null;
    _wifiHandoffTtlTimer?.cancel();
    _wifiHandoffTtlTimer = null;
    _wifiHandoffExpiresAt = null;
    _wifiHandoffRecordingId = null;
    _preferredBleResumeRecordingIdAfterWifiHandoff = null;
    _suppressBleResumeUntil.clear();
    _lastLiveResumeBleAt = null;
    _lastLiveResumeBleRecordingId = null;
    _prevDerivedRecStateForDeferredResume = null;
    _lastDeferredResumeIfIdlePoke = null;
    _adoptedRecordingDurationSecondsFromLastStart = null;
    _bleTransferGuardForRecordingStart = false;
  }

  /// Start the per-link keepalive timer for [link]. Safe to call multiple
  /// times — any previous timer on [link] is cancelled first.
  ///
  /// Each tick fires an AT+GSTAT against the dormant peer; on success the
  /// failure counter resets, on failure we increment and (after
  /// [_kBackgroundKeepaliveMaxFailures]) evict the link so the dropdown stops
  /// claiming it's online.
  void _startBackgroundKeepalive(_BackgroundLink link) {
    link.keepaliveTimer?.cancel();
    final deviceId = link.deviceId;
    link.keepaliveTimer =
        Timer.periodic(_kBackgroundKeepaliveInterval, (_) async {
      if (_disposed) return;
      // Re-fetch from the map every tick: the link object we captured may
      // have been promoted / evicted between ticks; we must not keep pinging
      // a foreground (active) device through its background AtTransport (the
      // foreground path owns send semantics now).
      final current = _backgrounds[deviceId];
      if (current == null || !identical(current, link)) {
        link.keepaliveTimer?.cancel();
        link.keepaliveTimer = null;
        return;
      }
      try {
        await link.at.send(
          'AT+GSTAT',
          timeout: _kBackgroundKeepaliveTimeout,
        );
        if (link.consecutiveKeepaliveFailures != 0) {
          AppLog.i(
              'DeviceController: background keepalive recovered for $deviceId');
        }
        link.consecutiveKeepaliveFailures = 0;
      } catch (e) {
        link.consecutiveKeepaliveFailures++;
        AppLog.w('DeviceController: background keepalive failed for $deviceId '
            '(consecutive=${link.consecutiveKeepaliveFailures}/$_kBackgroundKeepaliveMaxFailures): $e');
        if (link.consecutiveKeepaliveFailures >=
            _kBackgroundKeepaliveMaxFailures) {
          await _evictBackgroundLink(deviceId,
              reason:
                  'keepalive failed $_kBackgroundKeepaliveMaxFailures times');
        }
      }
    });
  }

  /// Drop a background-pool entry, cancel all of its subscriptions / timer,
  /// mark the device offline and tear down the underlying GATT connection.
  /// No-op when [deviceId] is not in the pool.
  ///
  /// Used by both the keepalive failure path and the GATT-drop watcher set
  /// up in [_demoteCurrentToBackground].
  Future<void> _evictBackgroundLink(String deviceId,
      {required String reason}) async {
    final link = _backgrounds.remove(deviceId);
    if (link == null) return;
    AppLog.w('DeviceController: evicting background link $deviceId ($reason)');

    // Phase 2 — if a transfer was running on this background link, it loses
    // its AT transport now; mark it cancelled and drop the per-device entry
    // so the download loop unwinds without dangling cancel state.
    final stuckTransfer = _transfersByDevice.remove(deviceId);
    if (stuckTransfer != null) {
      AppLog.w(
          'DeviceController._evictBackgroundLink: dropping active transfer ${stuckTransfer.recordingId} (background link evicted)');
      stuckTransfer.cancelRequested = true;
      stuckTransfer.waitCompleter?.complete();
    }

    // STEP 1 — Synchronous state + UI sync. Stop the keepalive immediately
    // and publish the new background-id set so `isDeviceEffectivelyOnline`
    // stops returning true for this device on the very next frame. Without
    // this, the dropdown row kept showing "online" until the GATT disconnect
    // round-trip finished (several seconds on Android).
    link.keepaliveTimer?.cancel();
    link.keepaliveTimer = null;
    _publishBackgroundIds();

    // STEP 2 — Cancel sub *before* DB flip so a late-arriving battery notify
    // (handler runs `updateStatus(isOnline: true)`) cannot race us. The
    // handler also has a stale-link guard, but cancelling first removes the
    // window entirely.
    try {
      await link.connSub?.cancel();
    } catch (_) {}
    try {
      await link.batterySub?.cancel();
    } catch (_) {}

    // STEP 3 — Persist offline + force-bump so the device list provider
    // (debounced bump can be starved by another device's frequent notifies).
    try {
      final repo = await ref.read(deviceRepositoryProvider.future);
      await repo.updateStatus(id: deviceId, isOnline: false);
    } catch (_) {}
    _forceBumpDeviceDbRevision();

    // STEP 4 — Slow GATT teardown. UI already shows offline.
    try {
      await ref.read(bleClientProvider).disconnect(link.conn);
    } catch (_) {}
  }

  /// Demote the current foreground connection to the background pool.
  ///
  /// Keeps the GATT link alive (battery notify and disconnect detection stay
  /// subscribed) so the user can switch back instantly. Silently cancels any
  /// in-flight BLE file transfer — the DB row stays in `transferring` state
  /// so the auto-resume kicks in when the user switches back.
  ///
  /// Returns true if a connection was actually demoted; false when there was
  /// nothing to demote.
  Future<bool> _demoteCurrentToBackground() async {
    final conn = state.connection;
    if (conn == null) return false;
    final deviceId = conn.device.remoteId.toString();
    AppLog.i(
        'DeviceController._demoteCurrentToBackground: $deviceId (transfer=$_activeTransferRecordingId recording=$_activeRecordingSessionId)');

    // Phase 2 — per-device transfer ownership:
    // Foreground-first: pause ordinary file sync when demoting so the newly
    // foreground device can resync without competing with this link. Keep a
    // live record-while-transfer pull running (skip AT+CANCEL — firmware crash).
    final ownTransfer = _transferForDevice(deviceId);
    final fr = state.firmwareRecState;
    final liveRecPull =
        ownTransfer != null && (fr == 'recording' || fr == 'paused');
    if (ownTransfer != null) {
      if (liveRecPull) {
        AppLog.i(
            '_demoteCurrentToBackground: $deviceId has live recording transfer '
            '${ownTransfer.recordingId} — keeping it running in background');
      } else {
        AppLog.i(
            '_demoteCurrentToBackground: pausing file sync ${ownTransfer.recordingId} '
            'on $deviceId (foreground-first)');
        await cancelTransfer(
          ownTransfer.recordingId,
          errorCode: 'device_switch_demote',
        );
      }
    }

    // Cancel only the foreground JSON listener and the foreground connSub
    // (its handler captures "current foreground" semantics — reconnect
    // kick, Wi-Fi cancel, etc.). DO NOT touch `_batterySub`, `_at`, or any
    // of the per-device transfer subscriptions:
    //   • `_batterySub` is on `conn.batteryLevelStream`, a single-
    //     subscription stream. Cancelling closes the controller and
    //     re-`listen()` on promote would throw. Transferred into the
    //     `_BackgroundLink` below.
    //   • `_at` is reused on promote (a new AtTransport would re-`listen()`
    //     on the same notify characteristics — same crash risk).
    //   • `downloadSessionToLocal`'s local `fileSub` / `jsonSub` are on
    //     broadcast streams (`at.fileDataBytes` / `at.jsonMessages`) so
    //     they keep receiving notify packets independent of `_jsonSub`.
    await _jsonSub?.cancel();
    _jsonSub = null;
    await _connSub?.cancel();
    _connSub = null;
    final preservedBatterySub = _batterySub;
    _batterySub = null;
    final preservedAt = _at;
    _at = null;
    _resetActiveDeviceCachesForSwitch();

    // Background-variant disconnect watcher: if the OS drops the link, just
    // evict from the pool and mark the row offline. No reconnect kick — the
    // user will see "offline" in the dropdown and can re-tap to reconnect.
    final bgConnSub = conn.device.connectionState.listen((s) async {
      if (s != BluetoothConnectionState.disconnected) return;
      if (!_backgrounds.containsKey(deviceId)) return;
      await _evictBackgroundLink(deviceId, reason: 'GATT disconnected');
    });

    if (preservedAt == null) {
      // Should never happen — having `state.connection` without `_at` means
      // _applyConnection didn't finish. Bail out of the demote so we don't
      // leave an unusable link in the pool.
      AppLog.w(
          '_demoteCurrentToBackground: no AtTransport for $deviceId, aborting demote and fully disconnecting');
      await bgConnSub.cancel();
      try {
        await preservedBatterySub?.cancel();
      } catch (_) {}
      try {
        await ref.read(bleClientProvider).disconnect(conn);
      } catch (_) {}
      return false;
    }
    final link = _BackgroundLink(
      conn: conn,
      at: preservedAt,
      connSub: bgConnSub,
      batterySub: preservedBatterySub,
    );
    _backgrounds[deviceId] = link;
    _startBackgroundKeepalive(link);

    // Drop the foreground reference. lastConnectedDeviceId is intentionally
    // preserved here — the next `_applyConnection` will overwrite it with the
    // promoted device's id.
    state = state.copyWith(
      clearConnection: true,
      lastResponse: null,
      mtu: 23,
      clearActiveTransferRecordingId: true,
      clearFirmwareRecState: true,
    );
    // Mirror is "foreground transfer" — after demote there IS no foreground,
    // so the mirror must clear. Per-device entries for live-record background
    // pulls (if any) stay in [_transfersByDevice].
    _activeTransferRecordingId = null;
    _publishBackgroundIds();
    AppLog.i(
        'DeviceController._demoteCurrentToBackground: $deviceId moved to background pool (size=${_backgrounds.length}, ongoing transfers=${_transfersByDevice.length})');
    return true;
  }

  /// Promote a background-pool link back to the foreground.
  ///
  /// Re-initializes AT transport / JSON listener / battery handler / active
  /// connSub by reusing the shared [_applyConnection] path. Returns true if
  /// the device was found in the pool and successfully wired up (AT ping
  /// included). Returns false when the device wasn't in the pool, or when
  /// the AT verify failed (in which case the link is fully torn down so the
  /// caller can fall back to a fresh connect).
  Future<bool> _promoteFromBackground(String deviceId,
      {String? displayName}) async {
    final link = _backgrounds.remove(deviceId);
    if (link == null) return false;
    AppLog.i(
        'DeviceController._promoteFromBackground: $deviceId (pool size now ${_backgrounds.length})');

    // Stop the background keepalive timer immediately so it doesn't race the
    // foreground caller's first AT command through the same AtTransport's
    // serial queue.
    link.keepaliveTimer?.cancel();
    link.keepaliveTimer = null;

    // Cancel only the background-variant connSub (its closure does pool
    // eviction). DO NOT cancel `link.batterySub` — that subscription is on a
    // single-subscription stream (`conn.batteryLevelStream`); cancelling
    // would close the underlying controller and subsequent re-`listen()`
    // would crash. Transfer ownership directly into `_batterySub`.
    try {
      await link.connSub?.cancel();
    } catch (_) {}
    _publishBackgroundIds();

    // PRE-FLIGHT health check on `link.at` *before* we flip `state.connection`
    // to this device. The 12 s keepalive can miss windows where the Android
    // BT stack silently freezes a backgrounded GATT link without firing
    // `onConnectionStateChange` (seen in the wild: AT+GSTAT promote times out
    // at 4 s, then `AT+VERSION` from `syncConnectedDeviceInfo` racks up
    // another 5 s, then GATT teardown ~5 s — the user sees a "connected"
    // header for 14+ s while every command fails). Doing the verify here,
    // before `_applyConnection`, keeps the UI honest: either we promote
    // successfully and the link is genuinely usable, or we discard the stale
    // link and the caller falls through to a fresh GATT connect.
    bool linkHealthy;
    try {
      final pong =
          await link.at.send('AT+GSTAT', timeout: const Duration(seconds: 2));
      linkHealthy = pong['ok'] == true;
    } catch (e, st) {
      AppLog.w(
          'DeviceController._promoteFromBackground: pre-flight AT+GSTAT failed',
          e,
          st);
      linkHealthy = false;
    }

    if (!linkHealthy) {
      AppLog.w(
          'DeviceController._promoteFromBackground: $deviceId link is stale, discarding (fresh connect required)');
      // Mark offline immediately so dropdown / details reflect it; the slow
      // GATT close that follows happens in the background.
      try {
        final repo = await ref.read(deviceRepositoryProvider.future);
        await repo.updateStatus(id: deviceId, isOnline: false);
      } catch (_) {}
      _forceBumpDeviceDbRevision();
      try {
        await link.batterySub?.cancel();
      } catch (_) {}
      try {
        await ref.read(bleClientProvider).disconnect(link.conn);
      } catch (_) {}
      return false;
    }

    // Reuse the previously-established transport + battery subscription so we
    // never touch the single-subscription notify streams a second time.
    _at = link.at;
    _batterySub = link.batterySub;

    state =
        state.copyWith(error: null, clearErrorCode: true, lastResponse: null);
    await _applyConnection(link.conn,
        deviceNameOverride: displayName, reuseExisting: true);
    return true;
  }

  /// Drop a specific device's link — works for both the active foreground
  /// connection and any background-pool entry. Used by the unbind flow so
  /// "remove this paired device" cleanly tears down whichever pool it lives
  /// in.
  Future<void> disconnectDevice(String deviceId) async {
    if (deviceId.isEmpty) return;
    final activeId = state.connection?.device.remoteId.toString();
    if (activeId == deviceId) {
      await disconnect();
      return;
    }
    if (!_backgrounds.containsKey(deviceId)) return;
    await _evictBackgroundLink(deviceId, reason: 'user disconnect');
  }

  /// Tear down BLE without clearing [lastConnectedDeviceId] (auto-reconnect may retry).
  Future<void> _tearDownBleWithoutClearingLastDevice(
      SenseCraftVoiceConnection conn) async {
    await _connSub?.cancel();
    _connSub = null;
    await _jsonSub?.cancel();
    _jsonSub = null;
    await _batterySub?.cancel();
    _batterySub = null;
    _at = null;
    _resetDeviceListPaging();
    final id = conn.device.remoteId.toString();
    try {
      final repo = await ref.read(deviceRepositoryProvider.future);
      await repo.updateStatus(id: id, isOnline: false);
      _bumpDeviceDbRevision();
    } catch (_) {}
    try {
      await ref.read(bleClientProvider).disconnect(conn);
    } catch (_) {}
    if (!_disposed &&
        state.connection?.device.remoteId == conn.device.remoteId) {
      state = state.copyWith(
        clearConnection: true,
        lastResponse: null,
        mtu: 23,
        clearFirmwareRecState: true,
      );
    }
  }

  @override
  DeviceUiState build() {
    // [DeviceRepository] marks every device offline on init. If BLE reconnect
    // wins that race, restore online for the live link so UI matches reality.
    ref.listen<AsyncValue<DeviceRepository>>(
      deviceRepositoryProvider,
      (_, next) {
        next.whenData((_) => unawaited(_persistConnectedOnline()));
      },
      fireImmediately: true,
    );
    final client = ref.read(bleClientProvider);
    _adapterSub?.cancel();
    _adapterSub = client.adapterState.listen((adapterState) {
      if (_disposed) return;
      if (isBluetoothAdapterDisabled(adapterState)) {
        unawaited(_handleBluetoothAdapterOff(adapterState));
      } else {
        state = state.copyWith(adapterState: adapterState);
      }
    });

    ref.onDispose(() async {
      _disposed = true;
      _wifiHandoffTtlTimer?.cancel();
      _wifiHandoffTtlTimer = null;
      _bumpRevisionTimer?.cancel();
      _bumpRevisionTimer = null;
      await _adapterSub?.cancel();
      await _scanSub?.cancel();
      await _jsonSub?.cancel();
      await _connSub?.cancel();
      await _batterySub?.cancel();
      if (!_deviceEvents.isClosed) {
        await _deviceEvents.close();
      }
      final conn = state.connection;
      if (conn != null) {
        try {
          await ref.read(bleClientProvider).disconnect(conn);
        } catch (_) {}
      }
      // Tear down every background-pool link too — otherwise the GATT
      // connections would survive a controller dispose (e.g. hot-restart in
      // dev or provider invalidation) and the OS would refuse a fresh connect
      // the next time the user opens the device sheet.
      final pool = List<_BackgroundLink>.from(_backgrounds.values);
      _backgrounds.clear();
      for (final link in pool) {
        link.keepaliveTimer?.cancel();
        link.keepaliveTimer = null;
        try {
          await link.connSub?.cancel();
        } catch (_) {}
        try {
          await link.batterySub?.cancel();
        } catch (_) {}
        try {
          await ref.read(bleClientProvider).disconnect(link.conn);
        } catch (_) {}
      }
    });
    return DeviceUiState.initial();
  }

  void _bumpDeviceDbRevision() {
    _bumpRevisionTimer?.cancel();
    _bumpRevisionTimer = Timer(_bumpRevisionDebounce, () {
      _bumpRevisionTimer = null;
      if (_disposed) return;
      final n = ref.read(deviceDbRevisionProvider.notifier);
      n.state = n.state + 1;
    });
  }

  /// Same as [_bumpDeviceDbRevision] but bypasses the 300 ms debounce.
  ///
  /// Use on user-initiated disconnect / background-pool eviction so the
  /// device dropdown's `isOnline` flag flips to false on the very next
  /// frame instead of waiting for the next debounced bump (which can be
  /// indefinitely delayed by frequent battery notifies from *another*
  /// device — every notify resets the debounce timer).
  void _forceBumpDeviceDbRevision() {
    _bumpRevisionTimer?.cancel();
    _bumpRevisionTimer = null;
    if (_disposed) return;
    final n = ref.read(deviceDbRevisionProvider.notifier);
    n.state = n.state + 1;
  }

  Future<BluetoothAdapterState> _fetchAdapterState() async {
    return ref.read(bleClientProvider).getCurrentAdapterState();
  }

  Future<void> _stopScanInternal() async {
    _scanGeneration++;
    _acceptScanResults = false;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await ref.read(bleClientProvider).stopScan();
    } catch (_) {}
  }

  Future<void> _handleBluetoothAdapterOff(
    BluetoothAdapterState adapterState,
  ) async {
    if (_disposed) return;
    AppLog.i(
      'DeviceController: Bluetooth adapter disabled ($adapterState) — clearing scan state',
    );
    await _stopScanInternal();
    _loggedScanDeviceIds.clear();
    state = state.copyWith(
      adapterState: adapterState,
      results: const [],
      isScanning: false,
      clearErrorCode: true,
    );
  }

  /// User tapped "Rescan" — always tear down the previous scan and ignore
  /// flutter_blue_plus cached [scanResults] before starting again.
  Future<void> rescan() async {
    if (_disposed) return;
    await _stopScanInternal();
    _loggedScanDeviceIds.clear();
    state = state.copyWith(isScanning: false, results: const []);
    await startScan();
  }

  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
    bool forReconnect = false,
  }) async {
    if (state.isScanning) {
      AppLog.d('DeviceController.startScan: already scanning, skip duplicate');
      return;
    }
    final client = ref.read(bleClientProvider);
    final adapter = await _fetchAdapterState();
    if (isBluetoothAdapterDisabled(adapter)) {
      AppLog.i('DeviceController.startScan: Bluetooth adapter disabled');
      await _stopScanInternal();
      _loggedScanDeviceIds.clear();
      state = state.copyWith(
        adapterState: adapter,
        isScanning: false,
        results: const [],
      );
      return;
    }

    await _stopScanInternal();
    _loggedScanDeviceIds.clear();
    final scanGen = ++_scanGeneration;
    _acceptScanResults = false;

    state = state.copyWith(
      adapterState: adapter,
      isScanning: true,
      results: const [],
      error: null,
    );

    AppLog.i('DeviceController.startScan: subscribing to scanResults');
    _scanSub = client.scanResults.listen((results) {
      if (_disposed || scanGen != _scanGeneration || !_acceptScanResults) {
        return;
      }
      if (isBluetoothAdapterDisabled(state.adapterState)) {
        return;
      }
      AppLog.i(
          'DeviceController.startScan: received scan batch count=${results.length}');
      // Keep unique by remoteId
      final map = <String, ScanResult>{};
      for (final r in results) {
        final id = r.device.remoteId.toString();

        final platformName = r.device.platformName.trim();
        final advName = r.advertisementData.advName.trim();
        final effectiveName = platformName.isNotEmpty ? platformName : advName;
        final isClipName = effectiveName.toLowerCase().contains('clip');

        // Log sparingly for target devices: same device only once per scan cycle.
        // Note: this only controls which logs are printed, not filtering UI / result list,
        // so we don't hide devices that appear "not found" when name changes.
        if (isClipName && !_loggedScanDeviceIds.contains(id)) {
          _loggedScanDeviceIds.add(id);
          AppLog.i(
            'BLE scan result (Clip): id=${r.device.remoteId} '
            'platformName="$platformName" advName="$advName" '
            'effectiveName="$effectiveName" rssi=${r.rssi}',
          );
        }

        // Always put scanned devices in the list so we can reconnect by saved deviceId even when name is not "Clip".
        map[id] = r;
      }
      state = state.copyWith(results: map.values.toList());
    });

    try {
      AppLog.i(
          'DeviceController.startScan: startScan timeout=${timeout.inSeconds}s forReconnect=$forReconnect');
      await client.startScan(timeout: timeout, filterByService: false);
      if (_disposed || scanGen != _scanGeneration) return;
      _acceptScanResults = true;
    } catch (e) {
      AppLog.e('DeviceController.startScan error', e as Object?);
      _acceptScanResults = false;
      state = state.copyWith(
        error: e.toString(),
        isScanning: false,
        results: const [],
      );
      return;
    }

    // scan auto-stops by timeout; reflect state after a short delay
    Future.delayed(timeout + const Duration(seconds: 1), () {
      state = state.copyWith(isScanning: false);
    });
  }

  /// Apply connection state after connect (from scan or direct connect). Shared by connect() and reconnect direct-connect path.
  ///
  /// When [reuseExisting] is true (promote-from-background path), the caller
  /// has already populated [_at] and [_batterySub] with the existing
  /// background-pool instances. We skip recreating those — see
  /// `_BackgroundLink` docs for why a fresh subscribe on the same notify
  /// characteristics would crash with "Stream has already been listened to.".
  Future<void> _applyConnection(SenseCraftVoiceConnection conn,
      {String? deviceNameOverride, bool reuseExisting = false}) async {
    AppLog.i(
        'DeviceController: applying connection id=${conn.device.remoteId} name=${conn.device.platformName} reuseExisting=$reuseExisting');
    _lastConnectedAt = DateTime.now();
    state = state.copyWith(
      connection: conn,
      mtu: conn.mtu.mtu,
      lastConnectedDeviceId: conn.device.remoteId.toString(),
      error: null,
      clearErrorCode: true,
    );

    // Stale Wi‑Fi handoff guard. `endWifiHandoff()` is normally called from the Fast Sync
    // sheet's `finally` block. When BLE drops mid-merge and the sheet is disposed (or the
    // app is force-killed) before the controller naturally winds down, the flag stays on
    // and `_resumeIncompleteTransfers` on the next reconnect short-circuits with
    // "skip all (Wi‑Fi handoff active …)" — i.e. BLE auto-resume looks dead even though
    // the device is back. If the controller is no longer active there is nothing to wait
    // for: clear the flag and reset the controller so BLE resume can take the row.
    try {
      final wifiState = ref.read(wifiTransferControllerProvider);
      if (_wifiHandoffActive && !wifiState.isActive) {
        AppLog.w(
          'DeviceController: stale Wi‑Fi handoff flag detected on reconnect '
          '(rec=$_wifiHandoffRecordingId, wifiPhase=${wifiState.phase}) — clearing',
        );
        endWifiHandoff();
        try {
          ref.read(wifiTransferControllerProvider.notifier).clearEndedState();
        } catch (_) {}
      }
    } catch (_) {}

    final deviceRepo = await ref.read(deviceRepositoryProvider.future);
    final deviceId = conn.device.remoteId.toString();
    final deviceName = (deviceNameOverride ?? conn.device.platformName).trim();
    final model = deviceName.isNotEmpty ? deviceName : 'SenseCraft Voice Lav';

    // Check if device exists
    final existing = await deviceRepo.getById(deviceId);
    final now = DateTime.now();
    if (existing != null) {
      await deviceRepo.updateStatus(
        id: deviceId,
        isOnline: true,
        batteryPercent: null,
      );
    } else {
      await deviceRepo.upsert(Device(
        id: deviceId,
        name: model,
        model: model,
        batteryPercent: null,
        isOnline: true,
        lastSeen: now,
        createdAt: now,
        updatedAt: now,
      ));
    }
    _bumpDeviceDbRevision();

    // AT transport: fresh on a brand-new connect, reused on promote (see
    // `_BackgroundLink` docs — flutter_blue_plus's notify streams cannot be
    // re-`listen()`-ed after cancel).
    final AtTransport at;
    if (reuseExisting && _at != null) {
      at = _at!;
    } else {
      at = AtTransport(
        commandRx: conn.commandRx,
        responseTx: conn.responseTx,
        fileData: conn.fileData,
        mtu: conn.mtu,
      );
      _at = at;
    }
    // jsonMessages is a broadcast stream on the AtTransport — re-`listen()`
    // after the previous _jsonSub was cancelled is always safe.
    await _jsonSub?.cancel();
    _jsonSub = at.jsonMessages.listen((msg) {
      final text = jsonEncode(msg);
      AppLog.i('AT RX: $text');
      _maybeApplyBleEventForFirmwareState(msg);
      _maybeApplyBleEventForBookmark(msg);
      _maybeApplyBleEventForBatteryStorageError(msg);
      _maybeApplyGstatNotifyToFirmwareState(msg);
      _maybeApplyUnsolicitedStopAck(msg);
      state = state.copyWith(lastResponse: text, mtu: conn.mtu.mtu);
    });
    if (!reuseExisting) {
      await _batterySub?.cancel();
      final batteryStream = conn.batteryLevelStream;
      if (batteryStream != null) {
        _batterySub = batteryStream.listen((percent) async {
          // Stale-link guard: this same closure is preserved on demote (its
          // subscription is transferred to a [_BackgroundLink]), so it keeps
          // firing for as long as the GATT link is alive — INCLUDING the brief
          // window after the user has explicitly disconnected this device or
          // we've evicted the background link, but before the OS has finished
          // closing GATT. Without this guard the handler races our cleanup
          // and re-writes `isOnline: true`, leaving the dropdown showing the
          // device as online for several seconds after disconnect (see
          // [DeviceController.disconnect] / [_evictBackgroundLink]).
          final id = conn.device.remoteId.toString();
          final stillForeground =
              state.connection?.device.remoteId.toString() == id;
          final stillBackground = _backgrounds.containsKey(id);
          if (!stillForeground && !stillBackground) return;
          try {
            final repo = await ref.read(deviceRepositoryProvider.future);
            await repo.updateStatus(
              id: id,
              isOnline: true,
              batteryPercent: percent,
            );
            _bumpDeviceDbRevision();
          } catch (_) {}
        });
      }
    }
    await _connSub?.cancel();
    _connSub = conn.device.connectionState.listen((s) async {
      AppLog.i(
          'DeviceController: connectionState for ${conn.device.remoteId} changed to $s');
      if (s == BluetoothConnectionState.disconnected) {
        final current = state.connection;
        if (current != null &&
            current.device.remoteId == conn.device.remoteId) {
          AppLog.w(
              'DeviceController: GATT disconnected for ${current.device.remoteId} - recording/transfer will auto-resume after reconnect');
          final discDeviceId = current.device.remoteId.toString();
          final hadRecording = _activeRecordingSessionId != null;
          var hadTransfer = _activeTransferRecordingId != null;
          if (!hadTransfer) {
            try {
              final recRepo =
                  await ref.read(recordingsRepositoryProvider.future);
              final toResume =
                  await recRepo.listTransfersToResume(discDeviceId);
              hadTransfer = toResume.isNotEmpty;
            } catch (_) {}
          }
          final recentlyConnected = _lastConnectedAt != null &&
              DateTime.now().difference(_lastConnectedAt!) <
                  const Duration(seconds: 90);
          final unbinding = _unbindInProgressFor == discDeviceId;
          final willReconnect = !unbinding &&
              (hadRecording || hadTransfer || recentlyConnected) &&
              state.lastConnectedDeviceId != null &&
              !_disposed;
          AppLog.i(
            'DeviceController: willReconnect=$willReconnect unbinding=$unbinding '
            '(hadRecording=$hadRecording hadTransfer=$hadTransfer recentlyConnected=$recentlyConnected)',
          );

          // STEP 1 — Synchronous UI sync first so the dropdown / details
          // page flip to "offline" on the very next frame. Wi-Fi Fast Sync
          // cleanup below relies on `state.connection == null` being visible
          // immediately (see comment further down).
          state = state.copyWith(
            clearConnection: true,
            lastResponse: null,
            mtu: 23,
            error: null,
            errorCode: 'device_disconnected_resume',
            reconnectStatus: willReconnect ? 'reconnecting' : null,
            clearFirmwareRecState: true,
          );

          // STEP 2 — Cancel subs before DB flip so the battery handler can't
          // race-write `isOnline: true` after our `isOnline: false` (the
          // handler also has a stale-link guard but cancelling first is
          // belt-and-braces).
          await _jsonSub?.cancel();
          _jsonSub = null;
          await _batterySub?.cancel();
          _batterySub = null;
          _at = null;
          _resetDeviceListPaging();

          try {
            final repo = await ref.read(deviceRepositoryProvider.future);
            await repo.updateStatus(id: discDeviceId, isOnline: false);
          } catch (_) {}
          _forceBumpDeviceDbRevision();
          AppLog.i(
              'DeviceController: cleaned up after GATT disconnect for ${current.device.remoteId}');
          unawaited(SentryService.setDeviceConnected(false));
          SentryService.breadcrumb(
            'Device GATT disconnected',
            category: 'ble',
            data: {'device_id': discDeviceId, 'will_reconnect': willReconnect},
          );

          // If a Wi‑Fi Fast Sync run is mid-flight, signal it to wind down ASAP.
          // Must run AFTER `state.connection = null` so [WifiTransferController._cleanup]
          // observes the dead link and skips its 16 s `AT+WIFI=OFF` round-trip — otherwise
          // the banner sits at the merge-phase label (~99%) for ≈60 s UDP stall + 16 s cleanup. With
          // cancel set, the UDP loop exits on its next frame check (≤ a few seconds) and
          // proceeds straight to merge → DB `state: done` → banner unmounts.
          try {
            final wifiState = ref.read(wifiTransferControllerProvider);
            if (wifiState.isActive) {
              AppLog.i(
                'DeviceController: BLE down → signal Wi‑Fi controller cancel '
                '(phase=${wifiState.phase}, recording=${wifiState.recordingId})',
              );
              unawaited(
                  ref.read(wifiTransferControllerProvider.notifier).cancel());
            }
          } catch (e, st) {
            AppLog.w(
                'DeviceController: Wi‑Fi cancel-on-disconnect failed (non-fatal)',
                e,
                st);
          }

          if (willReconnect) {
            // ignore: unawaited_futures
            kickAutoReconnect();
          }
        }
      }
    });

    // Phase 2 — if this device already had an in-flight transfer running
    // (e.g. it was just promoted back from background and its
    // `downloadSessionToLocal` is still feeding chunks into its temp file),
    // restore the foreground UI mirror so the recordings banner / sheet
    // correctly attribute the in-flight transfer to the now-foreground
    // device. No-op when there's no transfer for this device.
    _syncForegroundTransferMirror();

    final isNewDevice = existing == null;

    // Auto-sync device info (best-effort, non-blocking). On the promote path
    // (`reuseExisting=true`) we skip the global auto-resume sweep (avoids racing
    // a background device's live pull) but still resume *this* device's paused
    // file sync after demote — see [_resumeForegroundDeviceTransfersAfterPromote].
    // ignore: unawaited_futures
    Future.microtask(() => syncConnectedDeviceInfo(
          skipAutoResume: reuseExisting,
          isNewDevice: isNewDevice,
        ));
    unawaited(SentryService.setDeviceConnected(true));
    SentryService.breadcrumb(
      'Device connected',
      category: 'ble',
      data: {'device_id': deviceId},
    );
  }

  Future<bool> _shouldAttemptIosStaleBondRepair(
    ScanResult r,
    Object error,
  ) async {
    if (!Platform.isIOS) return false;
    if (_isIosPeerRemovedPairingInfo(error)) return false;
    final deviceId = r.device.remoteId.toString();
    if (deviceId.isEmpty) return false;
    if (!_iosStaleBondRepairTried.add(deviceId)) {
      AppLog.i(
        'DeviceController.iOS stale-bond repair: already tried for $deviceId',
      );
      return false;
    }

    final hasTombstone = await _hasRecentIosPairingResetTombstone(deviceId);
    if (hasTombstone) return true;
    return _looksLikeIosStaleBondError(error);
  }

  Future<ScanResult?> _scanForRepairTarget(ScanResult original) async {
    final targetId = original.device.remoteId.toString();

    await _stopScanInternal();
    try {
      await ref.read(bleClientProvider).stopScan();
    } catch (_) {}
    try {
      await BluetoothDevice.fromId(targetId).disconnect();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    await startScan(timeout: const Duration(seconds: 8), forReconnect: true);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline) && !_disposed) {
      for (final r in state.results) {
        final id = r.device.remoteId.toString();
        if (id == targetId) return r;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  Future<bool> _tryIosStaleBondRepairFromScan(
    ScanResult original,
    Object triggerError,
  ) async {
    if (!await _shouldAttemptIosStaleBondRepair(original, triggerError)) {
      return false;
    }

    final originalId = original.device.remoteId.toString();
    AppLog.w(
      'DeviceController.iOS stale-bond repair: starting for $originalId',
      triggerError,
      StackTrace.current,
    );

    try {
      final found = await _scanForRepairTarget(original);
      if (found == null) {
        AppLog.w(
          'DeviceController.iOS stale-bond repair: target not found for $originalId',
        );
        return false;
      }

      final client = ref.read(bleClientProvider);
      final conn = await client.connect(found);
      AppLog.i(
        'DeviceController.iOS stale-bond repair: GATT connected id=${conn.device.remoteId}',
      );
      await _applyConnection(
        conn,
        deviceNameOverride: found.device.platformName,
      );
      if (!await _verifyAtLinkReadyWithRetry(attempts: 3)) {
        AppLog.w(
          'DeviceController.iOS stale-bond repair: AT ping still failed for $originalId',
        );
        await _tearDownBleWithoutClearingLastDevice(conn);
        return false;
      }

      await _clearIosPairingResetTombstone(originalId);
      final newId = conn.device.remoteId.toString();
      if (newId != originalId) {
        await _clearIosPairingResetTombstone(newId);
      }
      AppLog.i(
        'DeviceController.iOS stale-bond repair: succeeded original=$originalId new=$newId',
      );
      return true;
    } catch (e, st) {
      AppLog.w('DeviceController.iOS stale-bond repair failed', e, st);
      return false;
    }
  }

  void _setIosPeerRemovedPairingInfoError() {
    state = state.copyWith(
      errorCode: _kIosPeerRemovedPairingInfoErrorCode,
      error: _kIosPeerRemovedPairingInfoErrorCode,
    );
  }

  void _setIosStaleBluetoothPairingError() {
    state = state.copyWith(
      errorCode: _kIosStaleBluetoothPairingErrorCode,
      error: _kIosStaleBluetoothPairingErrorCode,
    );
  }

  /// After a failed iOS connect/repair, surface the Settings → Forget guidance
  /// for bond/key mismatch. Prefer definitive signals only — do not treat
  /// generic AT timeouts as stale bonds.
  Future<bool> _trySetIosForgetDeviceError(
    String deviceId,
    Object error,
  ) async {
    if (!Platform.isIOS) return false;
    if (_isIosPeerRemovedPairingInfo(error)) {
      _setIosPeerRemovedPairingInfoError();
      return true;
    }
    if (_isIosDefiniteStaleBondError(error) ||
        await _hasRecentIosPairingResetTombstone(deviceId)) {
      _setIosStaleBluetoothPairingError();
      return true;
    }
    return false;
  }

  /// After promote-from-background: resume file sync rows paused by demote /
  /// foreground priority. Live recording pulls are handled by GSTAT adopt.
  Future<void> _resumeForegroundDeviceTransfersAfterPromote() async {
    if (_disposed) return;
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;
    final deviceId = conn.device.remoteId.toString();
    if (_transferForDevice(deviceId) != null) {
      AppLog.i(
        '_resumeForegroundDeviceTransfersAfterPromote: skip (transfer active on $deviceId)',
      );
      return;
    }
    if (_wifiHandoffActive || _bleTransferGuardForRecordingStart) return;
    final fr = state.firmwareRecState;
    if (fr == 'recording' || fr == 'paused') {
      AppLog.i(
        '_resumeForegroundDeviceTransfersAfterPromote: skip (device $deviceId recording/paused — live adopt handles pull)',
      );
      return;
    }
    if (!await _verifyAtLinkReady()) return;
    AppLog.i(
      '_resumeForegroundDeviceTransfersAfterPromote: resuming incomplete transfers for $deviceId',
    );
    await _resumeIncompleteTransfers();
  }

  Future<void> connect(ScanResult r) async {
    final client = ref.read(bleClientProvider);
    final newId = r.device.remoteId.toString();

    // Multi-device pool: if currently connected to a different device, demote
    // it to the background pool (keeps GATT alive so a switch-back is instant).
    // Ordinary file sync on the demoted device is paused; live record pulls keep running.
    final existing = state.connection;
    if (existing != null && existing.device.remoteId.toString() != newId) {
      AppLog.i(
          'DeviceController.connect: switching active device from ${existing.device.remoteId} to $newId, demoting current to background');
      await _demoteCurrentToBackground();
    }

    // Fast path: target lives in the background pool — reuse the warm link.
    if (_backgrounds.containsKey(newId)) {
      AppLog.i(
          'DeviceController.connect: $newId already in background pool, promoting (no fresh GATT connect)');
      final promoted = await _promoteFromBackground(newId,
          displayName: r.device.platformName);
      if (promoted) return;
      AppLog.w(
          'DeviceController.connect: promote of $newId failed AT verify, falling back to fresh connect');
    }

    state =
        state.copyWith(error: null, clearErrorCode: true, lastResponse: null);
    try {
      final conn = await client.connect(r);
      AppLog.i(
          'DeviceController.connect: GATT connected, id=${conn.device.remoteId}, name=${conn.device.platformName}');
      await _applyConnection(conn, deviceNameOverride: r.device.platformName);
      if (!await _verifyAtLinkReady()) {
        AppLog.w(
            'DeviceController.connect: AT+GSTAT ping failed after GATT connect');
        await _tearDownBleWithoutClearingLastDevice(conn);
        final atError =
            StateError('Bluetooth connected but AT+GSTAT did not respond');
        if (await _tryIosStaleBondRepairFromScan(r, atError)) {
          return;
        }
        if (await _trySetIosForgetDeviceError(newId, atError)) {
          return;
        }
        state = state.copyWith(
          error:
              'Bluetooth connected but device did not respond. Move closer and try again.',
        );
        return;
      }
      await _clearIosPairingResetTombstone(newId);
    } catch (e) {
      if (Platform.isIOS && _isIosPeerRemovedPairingInfo(e)) {
        AppLog.w(
          'DeviceController.connect: iOS peer removed pairing info for $newId',
          e,
          StackTrace.current,
        );
        _setIosPeerRemovedPairingInfoError();
        return;
      }
      if (await _tryIosStaleBondRepairFromScan(r, e)) {
        return;
      }
      if (await _trySetIosForgetDeviceError(newId, e)) {
        return;
      }
      state = state.copyWith(error: e.toString());
    }
  }

  /// Fast-switch path: connect to a previously paired device by remoteId
  /// without scanning. Used when the target's MAC is already known (e.g. user
  /// taps a saved device in [DeviceSelectorDropdown]).
  ///
  /// Returns `true` on a fully-verified link (GATT up AND AT+GSTAT replies),
  /// `false` otherwise. Callers should fall back to a scan + [connect] when
  /// this returns `false` — direct connect can fail when the device is out of
  /// range, the OS has lost the bond, or the platform requires a fresh scan.
  ///
  /// Behavior with the multi-device background pool:
  /// - If already foreground on this id and AT replies, no-op returning `true`.
  /// - If this id is in the background pool, promote it (instant — no GATT
  ///   round-trip). Any previously-active device is demoted to background.
  /// - Otherwise: demote any existing active device, then do a fresh direct
  ///   connect via [SenseCraftVoiceClient.connectByDeviceId].
  Future<bool> connectById(String deviceId, {String? displayName}) async {
    if (deviceId.isEmpty) return false;
    final client = ref.read(bleClientProvider);

    final existing = state.connection;
    if (existing != null && existing.device.remoteId.toString() == deviceId) {
      if (await _verifyAtLinkReady()) {
        AppLog.i(
            'DeviceController.connectById: already connected to $deviceId and AT ok, no-op');
        return true;
      }
      AppLog.w(
          'DeviceController.connectById: existing connection to $deviceId is stale, tearing down');
      await _tearDownBleWithoutClearingLastDevice(existing);
    } else if (existing != null &&
        existing.device.remoteId.toString() != deviceId) {
      AppLog.i(
          'DeviceController.connectById: switching active device from ${existing.device.remoteId} to $deviceId, demoting current to background');
      await _demoteCurrentToBackground();
    }

    // Fast path: target is already warm in the background pool — promote it.
    if (_backgrounds.containsKey(deviceId)) {
      AppLog.i(
          'DeviceController.connectById: $deviceId in background pool, promoting (no GATT round-trip)');
      final promoted =
          await _promoteFromBackground(deviceId, displayName: displayName);
      if (promoted) return true;
      AppLog.w(
          'DeviceController.connectById: promote of $deviceId failed AT verify, falling back to fresh direct connect');
    }

    // Stopping any in-flight scan helps the OS bring up a fresh GATT link reliably.
    try {
      await client.stopScan();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));

    state =
        state.copyWith(error: null, clearErrorCode: true, lastResponse: null);

    AppLog.i(
        'DeviceController.connectById: attempting direct connect to $deviceId');
    SenseCraftVoiceConnection? conn;
    try {
      conn = await client.connectByDeviceId(deviceId);
    } catch (e) {
      if (Platform.isIOS && _isIosPeerRemovedPairingInfo(e)) {
        AppLog.w(
          'DeviceController.connectById: iOS peer removed pairing info for $deviceId',
          e,
          StackTrace.current,
        );
        _setIosPeerRemovedPairingInfoError();
        return false;
      }
      rethrow;
    }
    if (conn == null) {
      // Try once more after an explicit GATT teardown + back-off. The first
      // direct connect typically fails when the OS still holds a half-stale
      // GATT for the same id (e.g. just disconnected from a stale background
      // promote, or another device on the same controller is congesting
      // requestMtu). Letting the stack settle for ~800 ms and retrying once
      // recovers much faster than the upstream fall-back-to-scan path
      // (12 s scan + connect).
      AppLog.w(
          'DeviceController.connectById: first direct connect returned null for $deviceId, '
          'forcing GATT teardown + retry once before fall-back-to-scan');
      try {
        // Best-effort: kill any lingering GATT for this id so the OS rebuilds
        // the connection from scratch on retry. `BluetoothDevice.fromId` is
        // safe even when the device is fully disconnected.
        await BluetoothDevice.fromId(deviceId).disconnect();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        conn = await client.connectByDeviceId(deviceId);
      } catch (e) {
        if (Platform.isIOS && _isIosPeerRemovedPairingInfo(e)) {
          AppLog.w(
            'DeviceController.connectById: iOS peer removed pairing info on retry for $deviceId',
            e,
            StackTrace.current,
          );
          _setIosPeerRemovedPairingInfoError();
          return false;
        }
        rethrow;
      }
      if (conn == null) {
        AppLog.w(
            'DeviceController.connectById: retry also returned null for $deviceId (will fall back to scan)');
        return false;
      }
      AppLog.i(
          'DeviceController.connectById: direct connect retry succeeded for $deviceId');
    }

    await _applyConnection(conn, deviceNameOverride: displayName);
    if (!await _verifyAtLinkReady()) {
      AppLog.w(
          'DeviceController.connectById: AT+GSTAT ping failed after direct connect to $deviceId, tearing down');
      await _tearDownBleWithoutClearingLastDevice(conn);
      final atError =
          StateError('Bluetooth connected but AT+GSTAT did not respond');
      if (await _trySetIosForgetDeviceError(deviceId, atError)) {
        return false;
      }
      state = state.copyWith(
        error:
            'Bluetooth connected but device did not respond. Move closer and try again.',
      );
      return false;
    }
    await _clearIosPairingResetTombstone(deviceId);
    AppLog.i('DeviceController.connectById: connected to $deviceId (AT ok)');
    return true;
  }

  Future<void> disconnect() async {
    final conn = state.connection;
    if (conn == null) return;
    final id = conn.device.remoteId.toString();

    AppLog.i('DeviceController.disconnect: request for id=$id');
    unawaited(SentryService.setDeviceConnected(false));
    SentryService.breadcrumb(
      'Device disconnect requested',
      category: 'ble',
      data: {'device_id': id},
    );

    // STEP 1 — UI-visible state cleared synchronously *first*. Anything that
    // depends on `state.connection` (header / dropdown / details page) sees
    // "disconnected" on the very next frame, regardless of how long the
    // async cleanup below takes. Without this the device kept showing as
    // online for several seconds after the user tapped "Disconnect" because
    // we awaited stopScan + DB + sub cancels before flipping state.
    state = state.copyWith(
      clearConnection: true,
      lastResponse: null,
      mtu: 23,
      clearLastConnectedDeviceId: true,
      clearActiveTransferRecordingId: true,
      clearFirmwareRecState: true,
    );

    // STEP 2 — Cancel subscriptions BEFORE flipping the DB row offline so no
    // late-arriving battery notify can race our `updateStatus(isOnline: false)`
    // (the foreground battery handler `updateStatus(isOnline: true, ...)` on
    // every notify, every few seconds). The handler itself has a stale-link
    // guard but cancelling first removes the window entirely.
    await _jsonSub?.cancel();
    _jsonSub = null;
    await _connSub?.cancel();
    _connSub = null;
    await _batterySub?.cancel();
    _batterySub = null;
    _at = null;
    // Phase 2 — full disconnect on THIS device: any in-flight transfer for
    // this device cannot continue without `at`, so flag it cancelled and
    // drop it from the per-device map. The download loop will see
    // `cancelRequested` (or hit a disconnect error on its captured `at`),
    // unregister, and exit; we proactively remove the map entry here so a
    // racing reconnect doesn't see a stale slot.
    final stuckTransfer = _transfersByDevice.remove(id);
    if (stuckTransfer != null) {
      AppLog.i(
          'DeviceController.disconnect: dropping active transfer ${stuckTransfer.recordingId} for $id (full disconnect)');
      stuckTransfer.cancelRequested = true;
      stuckTransfer.waitCompleter?.complete();
    }
    _resetDeviceListPaging();
    _recordingStartedAt = null;
    _recordingStartOffsetSeconds = 0;
    _activeRecordingSessionId = null;
    _activeTransferRecordingId = null;
    _wifiHandoffTtlTimer?.cancel();
    _wifiHandoffTtlTimer = null;
    _wifiHandoffExpiresAt = null;
    _wifiHandoffRecordingId = null;

    // STEP 3 — Persist offline to DB and force-bump the device list revision
    // immediately (the debounced bump can be starved indefinitely by frequent
    // battery notifies from a *different* background device, leaving the
    // dropdown row showing online).
    try {
      final deviceRepo = await ref.read(deviceRepositoryProvider.future);
      await deviceRepo.updateStatus(id: id, isOnline: false);
    } catch (_) {}
    _forceBumpDeviceDbRevision();

    // STEP 4 — Best-effort BLE stack cleanup. These can take seconds on
    // Android; UI already reflects "disconnected" so the latency is invisible.
    try {
      await ref.read(bleClientProvider).stopScan();
    } catch (_) {}
    await ref.read(bleClientProvider).disconnect(conn);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// On reconnect failure, retry up to 3 times with 1.5s between attempts to improve success on brief drops.
  static const int _reconnectMaxRetries = 3;
  static const Duration _reconnectRetryDelay = Duration(milliseconds: 1500);

  /// Drives the global "reconnect" UX: flips [DeviceUiState.reconnectStatus] so the
  /// app-level snackbar shows "reconnecting → success/failed", waits [initialDelay]
  /// (use a longer value for OTA reset where the device needs to reboot first), then
  /// attempts a real reconnect. Safe to call repeatedly; concurrent attempts are
  /// guarded by [_reconnectInProgress].
  Future<bool> kickAutoReconnect({
    Duration initialDelay = const Duration(milliseconds: 800),
  }) async {
    if (_disposed) return false;
    if (_unbindInProgressFor != null) {
      AppLog.i(
        'DeviceController.kickAutoReconnect: skipped (unbind in progress for $_unbindInProgressFor)',
      );
      return false;
    }
    if (state.lastConnectedDeviceId == null) return false;

    // Already linked — refresh status without alarming the user.
    if (state.connection != null) {
      final ok = await _verifyAtLinkReadyWithRetry();
      if (ok) {
        _markReconnectOutcome(true);
        return true;
      }
    }

    // Join an in-flight reconnect instead of racing a second attempt.
    final inflight = _ongoingReconnect;
    if (inflight != null) {
      AppLog.i(
          'DeviceController.kickAutoReconnect: awaiting in-flight reconnect');
      state = state.copyWith(reconnectStatus: 'reconnecting');
      try {
        final ok = await inflight;
        if (_disposed) return ok;
        var actuallyConnected = ok && state.connection != null;
        if (actuallyConnected) {
          actuallyConnected = await _verifyAtLinkReadyWithRetry();
        }
        _markReconnectOutcome(actuallyConnected);
        return actuallyConnected;
      } catch (e, st) {
        AppLog.w('DeviceController.kickAutoReconnect join error', e, st);
        if (!_disposed) _markReconnectOutcome(false);
        return false;
      }
    }

    state = state.copyWith(reconnectStatus: 'reconnecting');
    if (initialDelay > Duration.zero) {
      await Future<void>.delayed(initialDelay);
    }
    if (_disposed) return false;

    try {
      final ok = await reconnectToLastDevice();
      if (_disposed) return ok;
      var actuallyConnected = ok && state.connection != null;
      if (actuallyConnected) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        if (_disposed) return actuallyConnected;
        actuallyConnected = await _verifyAtLinkReadyWithRetry();
        if (!actuallyConnected && state.connection != null) {
          AppLog.w(
              'DeviceController.kickAutoReconnect: link did not stabilize after retries, tearing down stale GATT');
          final stale = state.connection;
          if (stale != null) {
            await _tearDownBleWithoutClearingLastDevice(stale);
          }
        }
      }
      _markReconnectOutcome(actuallyConnected);
      return actuallyConnected;
    } catch (e, st) {
      AppLog.w('DeviceController.kickAutoReconnect error', e, st);
      if (!_disposed) {
        _markReconnectOutcome(false);
      }
      return false;
    }
  }

  Future<bool> reconnectToLastDevice() async {
    final deviceId = state.lastConnectedDeviceId;
    if (deviceId == null || deviceId.isEmpty) return false;
    if (state.connection != null) {
      if (await _verifyAtLinkReadyWithRetry()) return true;
      final stale = state.connection;
      if (stale != null) {
        AppLog.w(
            'DeviceController.reconnectToLastDevice: stale connection in state, tearing down');
        await _tearDownBleWithoutClearingLastDevice(stale);
      }
    }

    final inflight = _ongoingReconnect;
    if (inflight != null) {
      AppLog.i(
          'DeviceController.reconnectToLastDevice: awaiting in-flight reconnect');
      return inflight;
    }

    final future = _reconnectToLastDeviceImpl();
    _ongoingReconnect = future;
    try {
      return await future;
    } finally {
      if (identical(_ongoingReconnect, future)) {
        _ongoingReconnect = null;
      }
    }
  }

  Future<bool> _reconnectToLastDeviceImpl() async {
    final deviceId = state.lastConnectedDeviceId;
    if (deviceId == null || deviceId.isEmpty) return false;
    if (_reconnectInProgress) {
      AppLog.w(
          'DeviceController._reconnectToLastDeviceImpl: unexpected nested reconnect');
      return false;
    }

    _reconnectInProgress = true;
    AppLog.i(
        'DeviceController.reconnectToLastDevice: attempting reconnect to $deviceId (max $_reconnectMaxRetries retries)');
    try {
      for (var attempt = 1;
          attempt <= _reconnectMaxRetries && !_disposed;
          attempt++) {
        if (attempt > 1) {
          AppLog.i(
              'DeviceController.reconnectToLastDevice: retry #$attempt/$_reconnectMaxRetries after $_reconnectRetryDelay');
          await Future<void>.delayed(_reconnectRetryDelay);
        }
        if (_disposed) return false;
        if (state.connection != null &&
            await _verifyAtLinkReadyWithRetry(attempts: 2)) {
          return true;
        }

        // Fast path: try direct connect by device ID (no scan); works on Android when device was recently connected.
        if (attempt == 1) {
          try {
            await ref.read(bleClientProvider).stopScan();
          } catch (_) {}
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final conn =
              await ref.read(bleClientProvider).connectByDeviceId(deviceId);
          if (conn != null && !_disposed) {
            await _applyConnection(conn);
            if (await _verifyAtLinkReadyWithRetry()) {
              AppLog.i(
                  'DeviceController.reconnectToLastDevice: reconnected via direct connect (AT ok)');
              return true;
            }
            AppLog.w(
                'DeviceController.reconnectToLastDevice: direct GATT ok but AT ping failed, tearing down');
            await _tearDownBleWithoutClearingLastDevice(conn);
          }
        }

        // Fallback: scan then connect
        try {
          await ref.read(bleClientProvider).stopScan();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 600));

        await startScan(
            timeout: const Duration(seconds: 12), forReconnect: true);
        final deadline = DateTime.now().add(const Duration(seconds: 14));
        while (DateTime.now().isBefore(deadline) && !_disposed) {
          ScanResult? found;
          for (final r in state.results) {
            if (r.device.remoteId.toString() == deviceId) {
              found = r;
              break;
            }
          }
          if (found != null) {
            await connect(found);
            // connect() already runs AT+GSTAT before returning with a live [state.connection].
            if (state.connection != null) {
              AppLog.i(
                  'DeviceController.reconnectToLastDevice: reconnected to $deviceId (attempt $attempt)');
              return true;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    } catch (e) {
      AppLog.w('DeviceController.reconnectToLastDevice error', e,
          StackTrace.current);
    } finally {
      _reconnectInProgress = false;
    }
    return false;
  }

  Future<Map<String, dynamic>?> sendAt(String cmd) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return null;
    try {
      final resp = await _sendAtWithDisconnect(conn, at, cmd,
          timeout: const Duration(seconds: 5));
      return resp;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// Prefer on-device / transferred totals when DB [expectedBytes] is a stale STOP snapshot
  /// (e.g. live record grew after a partial BLE pull — Wi‑Fi sync got the smaller LIST size).
  static int? canonicalTransferExpectedBytes({
    int? dbExpected,
    required int transferredTotal,
  }) {
    if (transferredTotal <= 0) return dbExpected;
    if (dbExpected == null || dbExpected <= 0) return transferredTotal;
    if (dbExpected > (transferredTotal * 1.05).round()) return transferredTotal;
    return dbExpected;
  }

  /// True when [mergedPath] is complete enough to erase the session on firmware.
  ///
  /// [verifiedBytes] must be a **firmware/session** total (e.g. AT+DOWNLOAD `bytes`),
  /// not the merged file size. When [expectedBytes] is known, it takes precedence.
  static bool localMergedFileCompleteForDelete({
    required int actualSize,
    int? expectedBytes,
    int? verifiedBytes,
  }) {
    if (actualSize <= 0) return false;
    final exp = expectedBytes ?? 0;
    if (exp > 0) {
      return actualSize >= (exp * 0.95).round();
    }
    final verified = verifiedBytes ?? 0;
    if (verified > 0) {
      return actualSize >= (verified * 0.95).round();
    }
    // Unknown expected size — keep device copy for re-sync.
    return false;
  }

  /// Send `AT+DELETE=$sessionId` after **local merge** is verified (not when transfer bytes finish):
  /// safety guards used by the BLE download path:
  ///  - merged local file must exist and be ≥ 95% of [expectedBytes] or [verifiedBytes]
  ///    ([verifiedBytes] = firmware session total, not merged file size)
  ///  - skip when the firmware is still recording this same session root
  ///
  /// Returns true when AT+DELETE was sent and acknowledged; false on any skip
  /// or error (non‑fatal — caller should just log).
  Future<bool> deleteDeviceSessionAfterSync({
    required String sessionId,
    required String mergedPath,
    int? expectedBytes,
    int? verifiedBytes,
    String logTag = 'deleteDeviceSessionAfterSync',
  }) async {
    if (!_deleteFirmwareSessionAfterBleWifiSync) {
      AppLog.i(
          '$logTag: SKIP AT+DELETE (_deleteFirmwareSessionAfterBleWifiSync=false, testing)');
      return false;
    }
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) {
      AppLog.w('$logTag: skip AT+DELETE (no BLE connection)');
      return false;
    }
    try {
      final mergedFile = File(mergedPath);
      final exists = await mergedFile.exists();
      final actualSize = exists ? await mergedFile.length() : 0;
      final exp = expectedBytes ?? 0;
      final sizeOk = localMergedFileCompleteForDelete(
        actualSize: actualSize,
        expectedBytes: expectedBytes,
        verifiedBytes: verifiedBytes,
      );
      if (!(exists && sizeOk && actualSize > 0)) {
        AppLog.w(
            '$logTag: skip AT+DELETE (local incomplete: exists=$exists size=$actualSize expected=$exp verified=${verifiedBytes ?? actualSize})');
        return false;
      }
      final recStatus = await getRecordingStatus();
      final activeRoot = _normalizeRecordingSessionRoot(recStatus?.sessionId);
      final ourRoot = _normalizeRecordingSessionRoot(sessionId);
      if (recStatus?.state == 'recording' &&
          activeRoot.isNotEmpty &&
          ourRoot == activeRoot) {
        AppLog.i(
            '$logTag: skip AT+DELETE (device still recording sessionRoot=$ourRoot)');
        return false;
      }
      await _sendAtWithDisconnect(conn, at, 'AT+DELETE=$sessionId',
          timeout: const Duration(seconds: 8));
      AppLog.i(
          '$logTag: AT+DELETE=$sessionId done (local verified: $actualSize bytes)');
      return true;
    } catch (e, st) {
      AppLog.w('$logTag: AT+DELETE failed', e, st);
      return false;
    }
  }

  /// Queue AT+MARKS / AT+DELETE after a background merge; runs when BLE download slot is idle.
  void schedulePostMergeBleCleanup({
    required String recordingId,
    required String sessionId,
    required String mergedPath,
    int? expectedBytes,
    int? verifiedBytes,
    bool deleteAfterSync = true,
    bool fetchBookmarks = true,
  }) {
    if (_disposed) return;
    _postMergeBleTasks.add(_PostMergeBleTask(
      recordingId: recordingId,
      sessionId: sessionId,
      mergedPath: mergedPath,
      expectedBytes: expectedBytes,
      verifiedBytes: verifiedBytes,
      deleteAfterSync: deleteAfterSync,
      fetchBookmarks: fetchBookmarks,
    ));
    unawaited(drainPostMergeBleCleanupQueue());
  }

  bool _bleDownloadBusyForDevice(String deviceId) =>
      _transfersByDevice.containsKey(deviceId);

  /// Serializes [drainPostMergeBleCleanupQueue]: it is called from several
  /// places (merge-queue done, [downloadSessionToLocal] finally, resume loop
  /// finally). Two concurrent drains both grabbed `_postMergeBleTasks.first`
  /// → double AT+DELETE (2nd "Session not found") and `removeAt(0)` on an
  /// already-emptied list (RangeError).
  bool _postMergeDraining = false;

  Future<void> drainPostMergeBleCleanupQueue() async {
    if (_disposed) return;
    if (_wifiHandoffActive) return;
    if (_postMergeDraining) return;
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;
    if (_activeTransferRecordingId != null) return;
    final deviceId = conn.device.remoteId.toString();
    if (_bleDownloadBusyForDevice(deviceId)) return;

    _postMergeDraining = true;
    var ranAnyTask = false;
    try {
      while (_postMergeBleTasks.isNotEmpty) {
        if (_disposed || _wifiHandoffActive) return;
        if (_activeTransferRecordingId != null) return;
        if (_bleDownloadBusyForDevice(deviceId)) return;
        final task = _postMergeBleTasks.first;
        final ran = await _runPostMergeBleTask(task);
        if (!ran) break;
        ranAnyTask = true;
        // Task may have been removed by another path while we awaited; guard
        // the index before removing so we never RangeError on an empty list.
        if (_postMergeBleTasks.isNotEmpty &&
            identical(_postMergeBleTasks.first, task)) {
          _postMergeBleTasks.removeAt(0);
        }
      }
    } finally {
      _postMergeDraining = false;
      if (ranAnyTask) {
        AppLog.i(
          'DeviceController: post-merge cleanup ran; resume deferred BLE transfers',
        );
        _scheduleResumeIncompleteTransfersAfterBleTransfer();
      }
    }
  }

  Future<bool> _runPostMergeBleTask(_PostMergeBleTask task) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;
    if (_activeTransferRecordingId != null) return false;
    try {
      if (task.fetchBookmarks) {
        await _fetchAndSaveBookmarks(
          conn,
          at,
          task.sessionId,
          task.mergedPath,
        );
      }
      if (task.deleteAfterSync && _deleteFirmwareSessionAfterBleWifiSync) {
        await deleteDeviceSessionAfterSync(
          sessionId: task.sessionId,
          mergedPath: task.mergedPath,
          expectedBytes: task.expectedBytes,
          verifiedBytes: task.verifiedBytes,
          logTag: 'postMergeBleCleanup',
        );
      }
      return true;
    } catch (e, st) {
      AppLog.w(
        'postMergeBleCleanup failed recording=${task.recordingId}',
        e,
        st,
      );
      return true;
    }
  }

  Future<bool> purgeAllSessions() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;
    try {
      await _sendAtWithDisconnect(conn, at, 'AT+PURGE',
          timeout: const Duration(seconds: 10));
      AppLog.i('DeviceController.purgeAllSessions: AT+PURGE done');
      await syncConnectedDeviceInfo();
      bumpRecordingsLists(ref);
      return true;
    } catch (e, st) {
      AppLog.w('DeviceController.purgeAllSessions failed', e, st);
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Prepare controller state before unbind: stop auto-reconnect and in-flight
  /// transfers so `removeBond` / `AT+PAIR=reset` are not raced by resume logic.
  Future<void> beginUnbind(String deviceId) async {
    if (deviceId.isEmpty) return;
    _unbindInProgressFor = deviceId;
    _ongoingReconnect = null;
    state = state.copyWith(reconnectStatus: 'idle');

    final stuckTransfer = _transfersByDevice.remove(deviceId);
    if (stuckTransfer != null) {
      AppLog.i(
        'DeviceController.beginUnbind: cancelling active transfer '
        '${stuckTransfer.recordingId} on $deviceId',
      );
      stuckTransfer.cancelRequested = true;
      stuckTransfer.waitCompleter?.complete();
    }
    if (state.activeTransferRecordingId != null &&
        _transferForDevice(deviceId)?.recordingId ==
            state.activeTransferRecordingId) {
      state = state.copyWith(clearActiveTransferRecordingId: true);
    }
  }

  /// Clears pairing on the device via `AT+PAIR=reset` when [deviceId] has a
  /// live foreground or background-pool BLE link. Returns `false` when not
  /// linked or the command failed.
  Future<bool> resetPairingForDevice(String deviceId) async {
    if (deviceId.isEmpty) return false;

    final activeId = state.connection?.device.remoteId.toString();
    if (activeId == deviceId) {
      final conn = state.connection;
      final at = _at;
      if (conn == null || at == null) return false;
      var deviceResetOk = false;
      var phoneBondCleared = false;
      try {
        // Device first: removeBond drops GATT on Android and prevents AT+PAIR=reset.
        await _sendAtWithDisconnect(
          conn,
          at,
          'AT+PAIR=reset',
          timeout: const Duration(seconds: 8),
          disconnectMeansSuccess: true,
        );
        AppLog.i(
            'DeviceController.resetPairingForDevice: AT+PAIR=reset sent (foreground) for $deviceId');
        deviceResetOk = true;
        await _rememberIosPairingResetTombstone(deviceId);
      } catch (e, st) {
        AppLog.w('DeviceController.resetPairingForDevice failed (foreground)',
            e, st);
        state = state.copyWith(error: e.toString());
      } finally {
        phoneBondCleared = await _removeAndroidBondForDevice(conn.device);
        if (state.connection?.device.remoteId.toString() == deviceId) {
          await disconnect();
        }
      }
      return deviceResetOk || phoneBondCleared;
    }

    final link = _backgrounds[deviceId];
    if (link != null) {
      var deviceResetOk = false;
      var phoneBondCleared = false;
      try {
        await _sendAtWithDisconnect(
          link.conn,
          link.at,
          'AT+PAIR=reset',
          timeout: const Duration(seconds: 8),
          disconnectMeansSuccess: true,
        );
        AppLog.i(
            'DeviceController.resetPairingForDevice: AT+PAIR=reset sent (background) for $deviceId');
        deviceResetOk = true;
        await _rememberIosPairingResetTombstone(deviceId);
      } catch (e, st) {
        AppLog.w('DeviceController.resetPairingForDevice failed (background)',
            e, st);
        state = state.copyWith(error: e.toString());
      } finally {
        phoneBondCleared = await _removeAndroidBondForDevice(link.conn.device);
        if (_backgrounds.containsKey(deviceId)) {
          await _evictBackgroundLink(deviceId, reason: 'reset pairing');
        }
      }
      return deviceResetOk || phoneBondCleared;
    }

    return false;
  }

  Future<bool> resetPairing() async {
    final id = state.connection?.device.remoteId.toString();
    if (id == null) return false;
    return resetPairingForDevice(id);
  }

  /// App-side teardown during unbind: drop foreground/background links, clear
  /// auto-reconnect target, and ask the OS to release GATT for [deviceId].
  ///
  /// Pairing reset (`AT+PAIR=reset`) is separate and best-effort while linked;
  /// this always runs so a failed unpair does not leave stale controller/OS
  /// state that blocks the next scan connect.
  Future<void> teardownForUnbind(String deviceId) async {
    if (deviceId.isEmpty) return;
    _unbindInProgressFor ??= deviceId;
    try {
      if (Platform.isAndroid) {
        await _removeAndroidBondForDevice(BluetoothDevice.fromId(deviceId));
      }
      await disconnectDevice(deviceId);
      if (state.lastConnectedDeviceId == deviceId) {
        state = state.copyWith(clearLastConnectedDeviceId: true);
      }
      try {
        await ref.read(bleClientProvider).stopScan();
      } catch (_) {}
      try {
        await BluetoothDevice.fromId(deviceId).disconnect();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      if (_unbindInProgressFor == deviceId) {
        _unbindInProgressFor = null;
      }
      state = state.copyWith(reconnectStatus: 'idle');
    }
  }

  /// Sync VERSION / GSTAT / NAME / LIST / transfer-repair from a freshly
  /// active foreground connection.
  ///
  /// [skipAutoResume] is passed `true` by the promote-from-background path:
  /// on a fast device swap we must NOT auto-trigger `_resumeIncompleteTransfers`,
  /// because the previously-foreground device may still be silently streaming
  /// its in-flight transfer chunks (we did not send `AT+CANCEL` to avoid the
  /// firmware crash). Auto-resuming on promote would race that traffic and,
  /// in pathological cases, fire an `AT+DOWNLOAD` for the wrong session
  /// against a busy AT serial queue — that is the chain that took both
  /// devices offline in the 14:40:16 → 14:41:36 user log. The user can
  /// still trigger a manual retry from the recordings list.
  Future<void> syncConnectedDeviceInfo({
    bool skipAutoResume = false,
    bool isNewDevice = false,
  }) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;

    final deviceId = conn.device.remoteId.toString();
    final repo = await ref.read(deviceRepositoryProvider.future);

    // Align RTC on every connect / promote / first pair (non-fatal).
    await syncDeviceTime(force: true);
    if (isNewDevice) {
      AppLog.i('syncConnectedDeviceInfo: time synced for newly paired $deviceId');
    }

    // 1) VERSION
    try {
      final resp =
          await at.send('AT+VERSION', timeout: const Duration(seconds: 5));
      final ok = resp['ok'] == true;
      if (ok) {
        // Some firmwares may return fields at root, others may wrap into `data`.
        final rootFirmware = (resp['firmware'] ?? '').toString().trim();
        final data = resp['data'];
        final dataMap = data is Map
            ? Map<String, dynamic>.from(data)
            : const <String, dynamic>{};
        final dataFirmware = (dataMap['firmware'] ?? '').toString().trim();
        final firmware =
            (dataFirmware.isNotEmpty ? dataFirmware : rootFirmware);
        if (firmware.isNotEmpty) {
          await repo.updateFirmwareInfo(
              id: deviceId, firmwareVersion: firmware);
          _bumpDeviceDbRevision();
        }
      }
    } catch (e, st) {
      AppLog.w('AT+VERSION failed', e, st);
    }

    // 2) GSTAT (battery/mode/state/free space)
    try {
      final resp =
          await at.send('AT+GSTAT', timeout: const Duration(seconds: 5));
      final ok = resp['ok'] == true;
      if (ok) {
        final data = resp['data'];
        final dataMap = data is Map
            ? Map<String, dynamic>.from(data)
            : const <String, dynamic>{};

        final battery = _parseInt(dataMap['battery']);
        await repo.updateStatus(
            id: deviceId, isOnline: true, batteryPercent: battery);
        _bumpDeviceDbRevision();

        final mode = (dataMap['mode'] ?? '').toString().trim().toLowerCase();
        final rm = switch (mode) {
          'enhanced' => RecordingMode.enhanced,
          'normal' => RecordingMode.normal,
          _ => null,
        };
        if (rm != null) {
          await repo.updateRecordingMode(deviceId, rm);
          _bumpDeviceDbRevision();
        }
        _adoptForegroundRecordingFromGstatMap(dataMap);
      }
    } catch (e, st) {
      AppLog.w('AT+GSTAT failed', e, st);
    }

    // 3) NAME — flush any pending offline rename, then adopt
    // device-persisted name when present (`protocol.md` 3.3.7). Best-effort.
    await _reconcileDeviceNameAfterConnect();

    unawaited(() async {
      await syncDeviceFileIndex();
      await _ensurePendingTransfersForNewSessions();
      bumpRecordingsLists(ref);
      if (skipAutoResume) {
        AppLog.i(
            'syncConnectedDeviceInfo: promote path — resuming paused foreground file sync');
        await _resumeForegroundDeviceTransfersAfterPromote();
        return;
      }
      await _verifyAndResumeTransfers();
    }());
  }

  Future<void> _ensurePendingTransfersForNewSessions() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;
    final deviceId = conn.device.remoteId.toString();
    final deviceName = await _resolvedDeviceDisplayName(
      deviceId,
      conn.device.platformName,
    );
    try {
      await _withRecRepo((recRepo) async {
        final local = await recRepo.listByDeviceId(deviceId);
        for (final r in local) {
          if ((r.localPath ?? '').trim().isNotEmpty) continue;
          if (r.transferState == 'transferring' || r.transferState == 'done') {
            continue;
          }
          final sessionId = r.devicePath.contains('/')
              ? r.devicePath.split('/').first
              : r.devicePath;
          final now = DateTime.now();
          final createdAt = r.createdAt ?? r.startedAt ?? now;
          final displayDate = parseSessionTimestamp(sessionId) ?? createdAt;
          await recRepo.createPendingDeviceRecording(
            deviceId: deviceId,
            devicePath: sessionId,
            name: recordingDisplayNameForDevice(deviceName, displayDate),
            durationSeconds: 0,
            createdAt: createdAt,
            startedAt: r.startedAt ?? createdAt,
            format: 'opus',
            container: 'opus',
            mtu: state.mtu,
          );
        }
      });
    } catch (e, st) {
      if (isRecordingsDatabaseClosedError(e)) {
        AppLog.w(
          '_ensurePendingTransfersForNewSessions: account DB not ready',
          e,
          st,
        );
        return;
      }
      rethrow;
    }
  }

  Future<void> _verifyAndResumeTransfers() async {
    if (state.connection == null || _at == null) return;
    // Link can drop between syncConnectedDeviceInfo and this unawaited chain; avoid starting resume on a dead session.
    if (!await _verifyAtLinkReady()) {
      AppLog.w(
          '_verifyAndResumeTransfers: skip resume/repair (AT ping failed)');
      return;
    }
    await _verifyAndRepairDoneTransfers();
    if (state.connection == null || _at == null) return;
    await _resumeIncompleteTransfers();
  }

  Future<void> _verifyAndRepairDoneTransfers() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;
    final deviceId = conn.device.remoteId.toString();
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final allByDevice = await recRepo.listByDeviceId(deviceId);
    final doneWithDevice = allByDevice
        .where((r) =>
            r.transferState == 'done' &&
            r.devicePresent &&
            r.source == 'device' &&
            (r.devicePath).trim().isNotEmpty)
        .toList();
    if (doneWithDevice.isEmpty) return;

    for (final rec in doneWithDevice) {
      final sessionId = (rec.devicePath).trim();
      final mergedPath = rec.localPath?.trim();
      if (mergedPath != null && mergedPath.isNotEmpty) {
        try {
          final mergedFile = File(mergedPath);
          if (await mergedFile.exists()) {
            final size = await mergedFile.length();
            if (size > 0) {
              final exp = rec.expectedBytes ?? 0;
              if (exp > 0 && size < exp * 0.9) {
                AppLog.w(
                    'verifyAndRepairDoneTransfers: session=$sessionId size=$size < expected*0.9 ($exp), resetting to transferring');
                try {
                  await mergedFile.delete();
                } catch (_) {}
                await _resetToTransferring(
                    recRepo, rec.id, null, 0.0, 'transfer_incomplete_size');
                continue;
              }
              continue;
            }
          }
        } catch (_) {}
      }

      final deviceFiles = await _listSessionFiles(sessionId);
      if (deviceFiles.isEmpty) continue;

      final localParts = await _listLocalPartsWithStatus(deviceId, sessionId);
      if (localParts.isEmpty) {
        // No local part and no valid merged file; need to download from scratch
        AppLog.w(
            'verifyAndRepairDoneTransfers: session=$sessionId no local file, resetting to transferring');
        await _resetToTransferring(
            recRepo, rec.id, null, 0.0, 'local_file_deleted');
        continue;
      }

      String? firstIncomplete;
      for (final part in localParts) {
        final filename = part.filename;
        if (!deviceFiles.contains(filename)) continue;
        if (!part.isComplete) {
          firstIncomplete ??= filename;
          break;
        }
      }
      if (firstIncomplete != null) {
        final idx = deviceFiles.indexOf(firstIncomplete);
        final progress =
            idx > 0 ? (idx / deviceFiles.length).clamp(0.0, 0.99) : 0.0;
        AppLog.w(
            'verifyAndRepairDoneTransfers: session=$sessionId firstIncomplete=$firstIncomplete, resetting to transferring');
        await _resetToTransferring(recRepo, rec.id, firstIncomplete, progress,
            'local_file_incomplete');
      }
    }
  }

  Future<void> _resetToTransferring(
    RecordingsRepository recRepo,
    String recId,
    String? startFile,
    double progress,
    String errorCode,
  ) async {
    await recRepo.updateTransfer(
      id: recId,
      state: 'transferring',
      progress: progress,
      errorCode: errorCode,
      localPath: null,
      recordingState: 'transferring',
    );
    bumpRecordingsLists(ref);
    ref.invalidate(recordingByIdProvider(recId));
  }

  /// Filenames within a session; paging is handled in [_getSessionInfoAndFileList] (matches py_test [list_session_files]).
  Future<List<String>> _listSessionFiles(String sessionId) async {
    final snap = await _getSessionInfoAndFileList(sessionId);
    return snap?.files ?? [];
  }

  /// Session stats + filenames from `AT+LIST=<id>`.
  Future<({Map<String, int> info, List<String> files})?>
      _getSessionInfoAndFileList(String sessionId) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return null;

    List<String> parseFileList(Object? d) {
      if (d is List) {
        return d
            .map((e) => (e?.toString() ?? '').trim())
            .where((s) => s.isNotEmpty)
            .map((s) => s.contains('/') ? s.split('/').last : s)
            .toList();
      }
      return [];
    }

    /// One-shot parse (unpaginated `AT+LIST=id` or legacy payload).
    ({Map<String, int> info, List<String> files})? parseSingleData(
        Object? data) {
      if (data == null) return null;
      if (data is List) {
        final files = parseFileList(data);
        return (
          info: {'files': data.length, 'size': 0, 'synced': 0},
          files: files,
        );
      }
      if (data is Map) {
        final m = Map<String, dynamic>.from(data);
        var fileCount = _parseInt(m['total']) ?? _parseInt(m['files']) ?? 0;
        List<String> files = [];
        final filesField = m['files'];
        if (filesField is List) {
          files = parseFileList(filesField);
          if (fileCount <= 0) fileCount = files.length;
        } else {
          final list = m['list'];
          if (list is List) {
            files = parseFileList(list);
          } else if (fileCount > 0) {
            files = List.generate(
              fileCount,
              (i) => '${(i + 1).toString().padLeft(4, '0')}.opus',
            );
          }
        }
        return (
          info: {
            'files': fileCount,
            'size': _parseInt(m['size']) ?? 0,
            'synced': _parseInt(m['synced']) ?? 0,
          },
          files: files,
        );
      }
      return null;
    }

    try {
      final resp = await _sendAtWithDisconnect(
        conn,
        at,
        'AT+LIST=$sessionId',
        timeout: const Duration(seconds: 8),
      );
      if (resp['ok'] != true) return null;
      return parseSingleData(resp['data']);
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// When resuming, if [startFile] is not present on device (e.g. SD lost one slice),
  /// pick the smallest `NNNN.opus` on device with index ≥ start; otherwise keep [startFile].
  String _adjustStartFileFromDeviceList(
      List<String> deviceFiles, String startFile) {
    if (deviceFiles.isEmpty) return startFile;
    final want = _partNumberFromFilename(startFile.toLowerCase()) ?? 0;
    final nums = <int>[];
    for (final raw in deviceFiles) {
      final name =
          (raw.contains('/') ? raw.split('/').last : raw).toLowerCase();
      if (!RegExp(r'^\d+\.opus$').hasMatch(name)) continue;
      final n = _partNumberFromFilename(name);
      if (n != null) nums.add(n);
    }
    if (nums.isEmpty) return startFile;
    final hasExact = deviceFiles.any((raw) {
      final name =
          (raw.contains('/') ? raw.split('/').last : raw).toLowerCase();
      return name == startFile.toLowerCase();
    });
    if (hasExact) return startFile;
    int? best;
    for (final n in nums) {
      if (n >= want && (best == null || n < best)) best = n;
    }
    best ??= nums.reduce((a, b) => a < b ? a : b);
    return '${best.toString().padLeft(4, '0')}.opus';
  }

  Future<List<_LocalPartInfo>> _listLocalPartsWithStatus(
      String deviceId, String sessionId) async {
    try {
      final sessionDirPath = await _deviceSessionDirectory(deviceId, sessionId);
      final sessionDir = Directory(sessionDirPath);
      if (!sessionDir.existsSync()) return [];
      final files = sessionDir.listSync().whereType<File>().where((f) {
        final name = p.basename(f.path).toLowerCase();
        return (name.endsWith('.opus') || name.endsWith('.opus.part')) &&
            !name.startsWith('part_last');
      }).toList();

      final result = <_LocalPartInfo>[];
      for (final f in files) {
        final name = p.basename(f.path);
        var stem = p.basenameWithoutExtension(name);
        if (stem.toLowerCase().endsWith('.opus')) {
          stem = p.basenameWithoutExtension(stem);
        }
        final n = partNumberFromSessionOpusFilename(stem);
        if (n == null) continue;
        final filename = '${n.toString().padLeft(4, '0')}.opus';
        final isPart = name.toLowerCase().endsWith('.opus.part');
        final size = await f.length();
        result.add(_LocalPartInfo(
          filename: filename,
          path: f.path,
          isComplete: !isPart && size > 0,
        ));
      }
      result.sort(
          (a, b) => compareSessionOpusPartFilename(a.filename, b.filename));
      return result;
    } catch (_) {
      return [];
    }
  }

  Future<RetryTransferResult> retryTransfer(String recordingId) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return RetryTransferResult.notConnected;
    final deviceId = conn.device.remoteId.toString();
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final rec = await recRepo.getById(recordingId);
    if (rec == null) return RetryTransferResult.notConnected;
    if (rec.deviceId != null && rec.deviceId != deviceId) {
      return RetryTransferResult.notConnected;
    }
    if (rec.transferState == 'done') return RetryTransferResult.notConnected;
    if (rec.transferState != 'transferring' &&
        rec.transferState != 'failed' &&
        rec.transferState != 'not_started') {
      return RetryTransferResult.notConnected;
    }
    if (_bleTransferGuardForRecordingStart) {
      await _clearRecordingStartGuardIfDeviceIdle(source: 'retryTransfer');
    }
    if (_bleTransferGuardForRecordingStart &&
        !_isRecordingStartGuardTarget(recordingId)) {
      AppLog.i(
        'retryTransfer: skip $recordingId (recording start guard active, '
        'target=${_bleTransferGuardRecordingId ?? "(pending)"})',
      );
      return RetryTransferResult.couldNotStart;
    }

    final sessionId = (rec.devicePath).trim();
    if (sessionId.isEmpty) return RetryTransferResult.notConnected;
    final sessionRoot =
        sessionId.contains('/') ? sessionId.split('/').first : sessionId;

    final live = await getRecordingStatus();
    if (live != null && (live.state == 'recording' || live.state == 'paused')) {
      if (!liveRecordingBleSyncEnabled) {
        AppLog.i(
          'retryTransfer: skip $recordingId '
          '(iOS recording-exclusive BLE mode active, '
          'session=${live.sessionId ?? "(empty)"})',
        );
        return RetryTransferResult.couldNotStart;
      }
      final liveSid = (live.sessionId ?? '').trim();
      if (liveSid.isNotEmpty &&
          sessionRoot.isNotEmpty &&
          liveSid != sessionRoot) {
        AppLog.w(
          'retryTransfer: device session=$liveSid (recording/paused), refuse retry for $sessionRoot',
        );
        return RetryTransferResult.deviceRecordingOtherSession;
      }
    }

    final snap = await _getSessionInfoAndFileList(sessionId);
    final info = snap?.info;
    final deviceList = snap?.files ?? [];
    final totalFiles = info != null ? (_parseInt(info['files']) ?? 0) : 0;

    // Post-stop fast path: slices already on disk — merge without re-download.
    final localPartsEarly =
        await _listLocalPartsWithStatus(deviceId, sessionId);
    final completeLocal = localPartsEarly.where((p) => p.isComplete).length;
    if (completeLocal > 0) {
      final needOnDevice =
          deviceList.isNotEmpty ? deviceList.length : totalFiles;
      if (needOnDevice <= 0 || completeLocal >= needOnDevice) {
        final merged = await _mergeAndCompleteFromLocalParts(
          recordingId,
          deviceId,
          sessionId,
          rec.expectedBytes,
        );
        bumpRecordingsLists(ref);
        if (merged) return RetryTransferResult.ok;
      }
    }

    String? startFile;
    final listTotal = deviceList.isNotEmpty ? deviceList.length : 0;
    final effectiveTotal = totalFiles > 0 ? totalFiles : listTotal;
    final fromLocal = await _computeStartFileFromLocalParts(
      deviceId,
      sessionId,
      expectedTotalFiles: effectiveTotal > 0 ? effectiveTotal : null,
    );
    if (fromLocal != null) {
      if (effectiveTotal > 0) {
        final startNum =
            int.tryParse(fromLocal.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        if (startNum > effectiveTotal) {
          final merged = await _mergeAndCompleteFromLocalParts(
              rec.id, deviceId, sessionId, rec.expectedBytes);
          bumpRecordingsLists(ref);
          if (merged) return RetryTransferResult.ok;
          AppLog.w(
            'retryTransfer: local merge unavailable for session=$sessionId, '
            'falling back to full re-download from 0001.opus',
          );
          startFile = '0001.opus';
        } else {
          startFile = fromLocal;
        }
      } else {
        startFile = fromLocal;
      }
    } else if (info != null) {
      final synced = _parseInt(info['synced']) ?? 0;
      if (synced > 0 && effectiveTotal > 0 && synced < effectiveTotal) {
        startFile = await _computeStartFileFromFirmwareSynced(
          deviceId: deviceId,
          sessionId: sessionId,
          synced: synced,
          effectiveTotal: effectiveTotal,
          logContext: 'retryTransfer',
        );
      }
    }
    startFile ??= '0001.opus';

    if (deviceList.isNotEmpty) {
      final adjusted = _adjustStartFileFromDeviceList(deviceList, startFile);
      if (adjusted != startFile) {
        AppLog.i(
          'retryTransfer: startFile=$startFile not on device (LIST), using $adjusted',
        );
        startFile = adjusted;
      }
    }

    AppLog.i(
        'retryTransfer: recording=$recordingId session=$sessionId startFile=$startFile');

    var expectedForDownload = rec.expectedBytes;
    final infoSize = _parseInt(info?['size']) ?? _parseInt(info?['bytes']);
    if (infoSize != null && infoSize > (expectedForDownload ?? 0)) {
      expectedForDownload = infoSize;
    }
    if (expectedForDownload != null &&
        expectedForDownload > (rec.expectedBytes ?? 0)) {
      await recRepo.updateTransfer(
        id: recordingId,
        state: rec.transferState,
        expectedBytes: expectedForDownload,
        sizeBytes: expectedForDownload,
      );
      bumpRecordingsLists(ref);
    }

    // Same checks as [downloadSessionToLocal] early exits so we can return [couldNotStart] without awaiting.
    // Fast Sync keeps [startWifiHandoff] until [transferWifiBatch] returns — without stopping Wi‑Fi first,
    // BLE [downloadSessionToLocal] is blocked and resync felt "broken".
    if (_wifiHandoffActive ||
        ref.read(wifiTransferControllerProvider).isActive) {
      AppLog.i(
        'retryTransfer: stopping Wi‑Fi sync so BLE can start (recording=$recordingId)',
      );
      final stopped = await ref
          .read(wifiTransferControllerProvider.notifier)
          .cancelAndAwaitFullyIdle();
      endWifiHandoff();
      if (!stopped) {
        AppLog.w(
          'retryTransfer: Wi‑Fi did not go idle in time (recording=$recordingId)',
        );
        return RetryTransferResult.couldNotStart;
      }
    }
    if (_bleTransferGuardForRecordingStart) {
      return RetryTransferResult.couldNotStart;
    }
    try {
      await _yieldBackgroundTransfersToForeground();
      // Phase 2: any device (foreground OR background) may already be running
      // a transfer for this recording — cancel the owning one before starting
      // a fresh `downloadSessionToLocal`. Using `_transferForRecording` so we
      // catch background-owned transfers too.
      if (_transferForRecording(recordingId) != null) {
        final cancelled = await cancelTransfer(recordingId);
        if (cancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      // Do not await the full transfer: [downloadSessionToLocal] runs until merge/idle (minutes). UI used to
      // show no SnackBar until completion — felt like "resync" did nothing while already transferring.
      unawaited(
        downloadSessionToLocal(
          recordingId: recordingId,
          sessionId: sessionId,
          expectedBytes: expectedForDownload ?? rec.expectedBytes,
          expectedTotalFiles: effectiveTotal > 0 ? effectiveTotal : null,
          startFile: startFile,
          continuous: true,
        ).then<void>((started) {
          bumpRecordingsLists(ref);
          if (!started) {
            AppLog.w(
              'retryTransfer: downloadSessionToLocal returned false (recordingId=$recordingId) — '
              'see logs (invalid session, mutex, etc.)',
            );
          }
        }).catchError((Object e, StackTrace st) {
          AppLog.w(
              'retryTransfer: background downloadSessionToLocal failed', e, st);
          bumpRecordingsLists(ref);
        }),
      );
      bumpRecordingsLists(ref);
      return RetryTransferResult.ok;
    } catch (e, st) {
      AppLog.w('retryTransfer failed', e, st);
      return RetryTransferResult.failed;
    }
  }

  void refreshTransferProgressUI() {
    bumpRecordingsLists(ref);
    final id = _activeTransferRecordingId;
    if (id != null) ref.invalidate(recordingByIdProvider(id));
  }

  /// Cancel the in-flight BLE file transfer for [recordingId].
  ///
  /// Phase 2: routes the cancel to the device that *owns* the transfer (via
  /// [_transferForRecording]). The owning device may be the current
  /// foreground OR a backgrounded link — either case works because every
  /// `_BackgroundLink` keeps its own `AtTransport`.
  ///
  /// When [skipAtCancel] is `true`, only the app-side download loop is wound
  /// down — no `AT+CANCEL` is sent to the firmware. This is required when the
  /// firmware is *recording* (`AT+START` active) at the same time as the
  /// transfer: the firmware's `xfer` cleanup races the recording thread for
  /// shared resources and hits an internal 2 s cleanup timeout, after which
  /// the BLE link drops and the device becomes unscannable until power-cycle
  /// (observed signature: `xfer cleanup timeout` → GATT silent disconnect).
  /// In that mode we let the firmware keep streaming chunks; the underlying
  /// notify characteristic stays subscribed (BLE flow control naturally
  /// throttles the firmware) and the chunks dispatch into the
  /// `jsonMessages` broadcast where nobody is listening, so they are dropped
  /// silently. `_resumeIncompleteTransfers` picks the row back up on the
  /// next promote / reconnect.
  Future<bool> cancelTransfer(
    String recordingId, {
    String? errorCode,
    bool skipAtCancel = false,
    bool keepPendingOnTimeout = false,
    bool fireAndForgetAtCancel = false,
    Duration atCancelTimeout = const Duration(seconds: 5),
    Duration maxStopWait = const Duration(milliseconds: 2500),
  }) async {
    final transfer = _transferForRecording(recordingId);
    if (transfer == null) return false;
    final ownerDeviceId = transfer.deviceId;
    // Find the AT transport for the owning device — foreground OR background.
    AtTransport? targetAt;
    if (state.connection?.device.remoteId.toString() == ownerDeviceId) {
      targetAt = _at;
    } else {
      targetAt = _backgrounds[ownerDeviceId]?.at;
    }
    if (targetAt == null && !skipAtCancel) {
      AppLog.w(
        'cancelTransfer: no AT transport for owner device=$ownerDeviceId, cannot cancel',
      );
      return false;
    }
    AppLog.i(
      'cancelTransfer: begin recordingId=$recordingId device=$ownerDeviceId '
      'errorCode=${errorCode ?? '(none)'} skipAtCancel=$skipAtCancel '
      'fireAndForgetAtCancel=$fireAndForgetAtCancel',
    );
    _logXferState('cancelTransfer.beforeAtCancel');
    transfer.cancelErrorCode = errorCode;
    transfer.cancelRequested = true;
    // iOS root fix for "AT+CANCEL never reaches the firmware":
    // the command RX characteristic is WRITE-WITHOUT-RESPONSE only and
    // CoreBluetooth keeps `canSendWriteWithoutResponse` false while the firmware
    // floods `fileData` notifications, so the AT+CANCEL write (both the
    // fire-and-forget recording preempt AND the Wi‑Fi handoff's blocking send)
    // is queued but never actually transmitted — neither flow can stop the BLE
    // pull in time. Disable the `fileData` CCCD first: that is a write-WITH-
    // response descriptor write which iOS schedules reliably even under load, so
    // the peripheral stops flooding, the link frees, and AT+CANCEL goes out.
    // Notify is re-enabled at the start of the next download leg in
    // [downloadSessionToLocal].
    if (!skipAtCancel && targetAt != null) {
      if (state.connection?.device.remoteId.toString() == ownerDeviceId) {
        _markFileNotifyDisabledForActiveLegs(ownerDeviceId);
      }
      try {
        await targetAt.setFileDataNotify(
          false,
          timeout: const Duration(seconds: 2),
        );
        AppLog.i(
          'cancelTransfer: disabled fileData notify to free link before '
          'AT+CANCEL ($recordingId)',
        );
      } catch (e, st) {
        AppLog.w(
          'cancelTransfer: disable fileData notify failed (continuing) '
          '($recordingId)',
          e,
          st,
        );
      }
    }
    if (skipAtCancel) {
      // Don't poke the firmware — just unblock the download loop so it sees
      // `cancelRequested` and exits its wait. The loop still needs a tick
      // to tear down its subscriptions and unregister the transfer.
      transfer.waitCompleter?.complete();
    } else if (fireAndForgetAtCancel) {
      // iOS: while the firmware is flooding the link with file-data notifies it
      // cannot answer AT+CANCEL in time, and a write-WITH-response send() both
      // joins the serial queue (stuck behind a delayed GSTAT reply) and then
      // waits up to 5s for an ack — observed ~12s total, which makes "tap record"
      // feel broken. Use writeCommandOnly (write-without-response, does NOT join
      // the serial queue) and do not wait for the ack; the download loop exits on
      // `cancelRequested` below. A late cancel reply is harmless — AtTransport.send
      // only lets a cancel waiter consume it.
      try {
        await targetAt!
            .writeCommandOnly('AT+CANCEL', withoutResponse: Platform.isIOS)
            .timeout(atCancelTimeout);
        AppLog.i('cancelTransfer: AT+CANCEL write-only sent for $recordingId');
      } catch (e, st) {
        AppLog.w(
          'cancelTransfer: AT+CANCEL write-only failed/timed out for '
          '$recordingId; continuing app-side cancel',
          e,
          st,
        );
      }
      transfer.waitCompleter?.complete();
    } else {
      var atCancelTimedOut = false;
      try {
        await targetAt!.send('AT+CANCEL', timeout: atCancelTimeout);
        AppLog.i('cancelTransfer: AT+CANCEL sent for $recordingId');
        transfer.waitCompleter?.complete();
      } catch (e, st) {
        atCancelTimedOut = keepPendingOnTimeout && e is TimeoutException;
        if (atCancelTimedOut) {
          AppLog.w(
            'cancelTransfer: AT+CANCEL timed out for $recordingId; '
            'keeping app-side cancel pending',
            e,
            st,
          );
          transfer.waitCompleter?.complete();
        } else {
          AppLog.w('cancelTransfer: AT+CANCEL failed', e, st);
          transfer.cancelRequested = false;
          transfer.cancelErrorCode = null;
          _logXferState('cancelTransfer.atFailed');
          return false;
        }
      }
      // Wait until [downloadSessionToLocal] finishes its leg (subscriptions
      // cancelled, transfer unregistered from the per-device map).
      const step = Duration(milliseconds: 50);
      final sw = Stopwatch()..start();
      while (_transferForDevice(ownerDeviceId)?.recordingId == recordingId &&
          sw.elapsed < maxStopWait) {
        await Future<void>.delayed(step);
      }
      if (_transferForDevice(ownerDeviceId)?.recordingId == recordingId) {
        AppLog.w(
          'cancelTransfer: active transfer still tracked for device=$ownerDeviceId '
          'after ${maxStopWait.inMilliseconds}ms',
        );
        if (atCancelTimedOut) {
          _logXferState('cancelTransfer.afterWaitTimeout');
          return false;
        }
      }
      _logXferState('cancelTransfer.afterWait');
      return true;
    }
    // Wait until [downloadSessionToLocal] finishes its leg (subscriptions
    // cancelled, transfer unregistered from the per-device map).
    const step = Duration(milliseconds: 50);
    final sw = Stopwatch()..start();
    while (_transferForDevice(ownerDeviceId)?.recordingId == recordingId &&
        sw.elapsed < maxStopWait) {
      await Future<void>.delayed(step);
    }
    if (_transferForDevice(ownerDeviceId)?.recordingId == recordingId) {
      AppLog.w(
        'cancelTransfer: active transfer still tracked for device=$ownerDeviceId '
        'after ${maxStopWait.inMilliseconds}ms',
      );
    }
    _logXferState('cancelTransfer.afterWait');
    return true;
  }

  /// Stop a stale [downloadSessionToLocal] after merge marked the row `done`.
  void abortStaleDownloadForRecording(String recordingId) {
    final transfer = _transferForRecording(recordingId);
    if (transfer == null) return;
    AppLog.i(
      'DeviceController: abort stale download for $recordingId (already synced)',
    );
    transfer.cancelErrorCode = 'already_synced';
    transfer.cancelRequested = true;
    transfer.waitCompleter?.complete();
  }

  /// Resume file name for UDP/BLE download (e.g. `0003.opus`) from existing local session parts.
  ///
  /// Queries `AT+LIST=$sessionId` first so [_computeStartFileFromLocalParts] can return
  /// `(maxNum+1).opus` when BLE cleanly finished a slice and got cancelled before opening
  /// the next one (no `part_*` left on disk → previously fell back to a fresh download from 0001).
  Future<String?> getResumeStartFileForSession(String sessionId) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null) return null;
    final deviceId = conn.device.remoteId.toString();

    int? expectedTotalFiles;
    if (at != null) {
      try {
        final resp = await at.send('AT+LIST=$sessionId',
            timeout: const Duration(seconds: 6));
        if (resp['ok'] == true) {
          final data = resp['data'];
          if (data is Map) {
            expectedTotalFiles = _parseInt(data['files'] ?? data['total']);
          }
        }
      } catch (e, st) {
        AppLog.w(
            'getResumeStartFileForSession: AT+LIST=$sessionId failed (non-fatal)',
            e,
            st);
      }
    }

    return _computeStartFileFromLocalParts(
      deviceId,
      sessionId,
      expectedTotalFiles: expectedTotalFiles,
    );
  }

  /// Shared BLE/Wi‑Fi resume snapshot: [startFile] + on-disk/DB byte floor + file index.
  Future<SessionResumeMarkers> resolveSessionResumeMarkersForSession({
    required String sessionId,
    int dbReceivedBytes = 0,
    String? startFile,
  }) async {
    final conn = state.connection;
    final sf = startFile ?? await getResumeStartFileForSession(sessionId);
    if (conn == null) {
      return SessionResumeMarkers(
        startFile: sf,
        resumeByteOffset: dbReceivedBytes < 0 ? 0 : dbReceivedBytes,
        resumeFileIndex: resumeFileIndexFromStartFile(sf),
      );
    }
    final accountKey = requireAccountDbKey(ref);
    final sessionDir = await AccountStoragePaths.deviceSessionDirectory(
      accountKey: accountKey,
      deviceId: conn.device.remoteId.toString(),
      sessionId: sessionId,
    );
    return resolveSessionResumeMarkers(
      sessionDirPath: sessionDir,
      startFile: sf,
      dbReceivedBytes: dbReceivedBytes,
    );
  }

  /// Recording sheet / foreground resume: device is still **recording** this session, DB row is still
  /// `transferring`, but BLE pull was cleared (background disconnect). Restart download from local parts.
  Future<void> resumeLiveRecordingTransferIfStalled({
    required String recordingId,
    required String sessionId,
  }) async {
    if (_disposed) return;
    if (_wifiHandoffActive) return;
    if (!liveRecordingBleSyncEnabled) {
      AppLog.d(
        'resumeLiveRecordingTransferIfStalled: skip $recordingId '
        '(iOS recording-exclusive BLE mode)',
      );
      return;
    }
    if (_activeTransferRecordingId != null) return;

    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;

    final now = DateTime.now();
    if (_lastLiveResumeBleRecordingId == recordingId &&
        _lastLiveResumeBleAt != null &&
        now.difference(_lastLiveResumeBleAt!) < const Duration(seconds: 4)) {
      return;
    }

    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final rec = await recRepo.getById(recordingId);
    if (rec == null || rec.source != 'device') return;
    if (rec.transferState != 'transferring' || rec.endedAt != null) return;

    final pathRoot = _normalizeRecordingSessionRoot(rec.devicePath);
    final argRoot = _normalizeRecordingSessionRoot(sessionId);
    if (pathRoot.isEmpty || argRoot.isEmpty || pathRoot != argRoot) return;

    final st = await getRecordingStatus();
    if (st == null) return;
    final gsidRoot = _normalizeRecordingSessionRoot(st.sessionId);
    if ((st.state != 'recording' && st.state != 'paused') ||
        gsidRoot.isEmpty ||
        gsidRoot != pathRoot) {
      return;
    }

    _lastLiveResumeBleAt = now;
    _lastLiveResumeBleRecordingId = recordingId;

    final sidForDownload = rec.devicePath.trim();
    final startFile = await _computeStartFileFromLocalParts(
        conn.device.remoteId.toString(), sidForDownload);
    AppLog.i(
      'resumeLiveRecordingTransferIfStalled: restart BLE download recordingId=$recordingId '
      'session=$sidForDownload startFile=$startFile',
    );
    unawaited(
      downloadSessionToLocal(
        recordingId: recordingId,
        sessionId: sidForDownload,
        expectedBytes: rec.expectedBytes,
        startFile: startFile,
        continuous: true,
        notifyOnComplete: false,
      ),
    );
  }

  Future<void> _resumeIncompleteTransfers({
    String? preferredRecordingId,
  }) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;
    if (_wifiHandoffActive) {
      AppLog.i(
        'resumeIncompleteTransfers: skip all (Wi‑Fi handoff active for $_wifiHandoffRecordingId)',
      );
      return;
    }
    if (_bleTransferGuardForRecordingStart &&
        !await _clearRecordingStartGuardIfDeviceIdle(
          source: 'resumeIncompleteTransfers',
        )) {
      AppLog.d('resumeIncompleteTransfers: skip (recording start guard)');
      return;
    }
    if (_resumeIncompleteTransfersBusy) {
      final explicit = (preferredRecordingId ?? '').trim();
      final pending =
          (_preferredBleResumeRecordingIdAfterWifiHandoff ?? '').trim();
      if (explicit.isNotEmpty || pending.isNotEmpty) {
        _resumeIncompleteTransfersRerunRequested = true;
        AppLog.i(
          'resumeIncompleteTransfers: busy → rerun requested '
          'preferredRecordingId=${explicit.isNotEmpty ? explicit : pending}',
        );
      }
      AppLog.d('resumeIncompleteTransfers: skip (already running)');
      return;
    }
    _resumeIncompleteTransfersBusy = true;
    try {
      final deviceId = conn.device.remoteId.toString();
      await _yieldBackgroundTransfersToForeground();
      // One transfer stream per device firmware — ignore other devices' pulls.
      final activeTransfer = _transferForDevice(deviceId);
      if (activeTransfer != null) {
        AppLog.i(
          'resumeIncompleteTransfers: skip (BLE transfer in progress on device $deviceId '
          'for ${activeTransfer.recordingId})',
        );
        _scheduleResumeIncompleteTransfersWhenBleIdle(
          reason: 'resume skipped while BLE transfer active',
          waitForRecordingId: activeTransfer.recordingId,
        );
        return;
      }
      await _withRecRepo((recRepo) async {
        var incomplete = await recRepo.listTransfersToResume(deviceId);
        final preferredId = (() {
          final explicit = (preferredRecordingId ?? '').trim();
          if (explicit.isNotEmpty) return explicit;
          final pending =
              (_preferredBleResumeRecordingIdAfterWifiHandoff ?? '').trim();
          return pending;
        })();
        bool shouldYieldToPreferred(String currentRecordingId) {
          final pending =
              (_preferredBleResumeRecordingIdAfterWifiHandoff ?? '').trim();
          if (pending.isEmpty || pending == currentRecordingId.trim()) {
            return false;
          }
          _resumeIncompleteTransfersRerunRequested = true;
          AppLog.i(
            'resumeIncompleteTransfers: yielding current recordingId=$currentRecordingId '
            'to preferredRecordingId=$pending',
          );
          return true;
        }

        if (preferredId.isNotEmpty &&
            !incomplete.any((r) => r.id.trim() == preferredId)) {
          final preferredRec = await recRepo.getById(preferredId);
          final canInjectPreferred = preferredRec != null &&
              !preferredRec.isDeleted &&
              preferredRec.source == 'device' &&
              preferredRec.transferState != 'done';
          if (canInjectPreferred) {
            incomplete = [preferredRec, ...incomplete];
            AppLog.i(
              'resumeIncompleteTransfers: injected preferred recordingId=$preferredId '
              'state=${preferredRec.transferState} session=${preferredRec.devicePath}',
            );
          } else {
            AppLog.i(
              'resumeIncompleteTransfers: preferred recordingId=$preferredId not injected '
              '(found=${preferredRec != null} '
              'deleted=${preferredRec?.isDeleted} '
              'source=${preferredRec?.source} '
              'state=${preferredRec?.transferState} '
              'deviceId=${preferredRec?.deviceId})',
            );
          }
        }
        if (incomplete.isEmpty) return;
        final recStatus = await getRecordingStatus();
        if (!liveRecordingBleSyncEnabled &&
            recStatus != null &&
            (recStatus.state == 'recording' || recStatus.state == 'paused')) {
          AppLog.i(
            'resumeIncompleteTransfers: skip all '
            '(iOS recording-exclusive BLE mode active, '
            'session=${recStatus.sessionId ?? "(empty)"})',
          );
          return;
        }
        var activeSession = '';
        if (recStatus != null &&
            (recStatus.state == 'recording' || recStatus.state == 'paused')) {
          activeSession = (recStatus.sessionId ?? '').trim();
          // GSTAT can lag right after AT+START: state is recording but session id empty — align with app.
          final appSid = (_activeRecordingSessionId ?? '').trim();
          if (activeSession.isEmpty && appSid.isNotEmpty) {
            AppLog.i(
              'resumeIncompleteTransfers: recording/paused but GSTAT session empty; '
              'using app activeRecordingSessionId=$appSid',
            );
            activeSession = appSid;
          }
        }
        // Do NOT use [_activeRecordingSessionId] when device is IDLE: it would filter the resume queue
        // to one stale session id and block syncing the next transferring row after the previous session
        // finished (user log: GSTAT session=20260407102256 while merging 20260401053505 → next item dropped).
        if (activeSession.isNotEmpty) {
          final activeRoot = _normalizeRecordingSessionRoot(activeSession);
          final before = incomplete.length;
          incomplete = incomplete.where((r) {
            return _normalizeRecordingSessionRoot(r.devicePath) == activeRoot;
          }).toList();
          if (incomplete.length < before) {
            // We are about to await the active session's (continuous) download
            // for the whole recording. The deferred sibling sessions were just
            // dropped from THIS pass and there is no other guaranteed trigger to
            // pick them up afterwards (post-stop resume fires while this leg is
            // still in progress and bails at "BLE transfer in progress"). Flag a
            // rerun — but ONLY when this pass still has a row to actually await
            // (incomplete.isNotEmpty); otherwise the early `if (incomplete.isEmpty)
            // return;` below would loop us straight back into another no-op pass
            // and spin the CPU. When the active session has no transferring row
            // yet, the deferred session(s) are picked up by the post-stop resume
            // once recording ends instead. With a row present, the rerun lets us
            // re-enter resume after this leg returns (recording stopped / transfer
            // completed) with the device idle and finally sync the deferred
            // session(s). Without this, a recording made while another session was
            // mid-transfer leaves that other session stuck "transferring" forever.
            if (incomplete.isNotEmpty) {
              _resumeIncompleteTransfersRerunRequested = true;
            }
            AppLog.i(
              'resumeIncompleteTransfers: active sessionRoot=$activeRoot '
              '(raw=$activeSession), only this session may sync now '
              '(deferred ${before - incomplete.length} other session(s) until recording stops or this transfer completes'
              '${incomplete.isNotEmpty ? '; rerun flagged' : ''})',
            );
          }
        }
        if (incomplete.isEmpty) return;

        // SANITY: drop rows whose sessionRoot is not actually present on this device.
        // Historical race in switch-while-recording could leave a row stamped with
        // [deviceId] but a [devicePath] that belongs to the *other* device's session.
        // If we let those reach AT+DOWNLOAD, the firmware silently ignores the unknown
        // session id and the AT serial queue is wedged for 8 s — that is exactly the
        // chain that took both devices offline in the user log (14:40:16.930
        // "sending DOWNLOAD sessionRoot=20260521064002" on CA:7B which only owned
        // session 20260521063609). [syncDeviceFileIndex] just populated
        // [_deviceListCursorRemoteSessionIds] with the complete current set; only
        // trust the cache when it was built for *this* device.
        final canSanityCheck = _deviceListCursorDeviceId == deviceId &&
            _deviceListCursorRemoteSessionIds.isNotEmpty;
        if (canSanityCheck) {
          final knownSessions = _deviceListCursorRemoteSessionIds;
          final stale = <Recording>[];
          final kept = <Recording>[];
          for (final r in incomplete) {
            final root = _normalizeRecordingSessionRoot(r.devicePath);
            if (root.isEmpty || knownSessions.contains(root)) {
              kept.add(r);
            } else {
              stale.add(r);
            }
          }
          if (stale.isNotEmpty) {
            AppLog.w(
              'resumeIncompleteTransfers: SANITY dropping ${stale.length} row(s) '
              'whose sessionRoot is not in device $deviceId session list '
              '(devicePaths=${stale.map((r) => r.devicePath).join(',')})',
            );
            for (final r in stale) {
              try {
                final hasLocal = (r.localPath ?? '').trim().isNotEmpty;
                if (hasLocal) {
                  await recRepo.updateDevicePresent(id: r.id, present: false);
                  await recRepo.updateTransfer(
                    id: r.id,
                    state: 'failed',
                    errorCode: 'session_not_on_device',
                    transferFinishedAt: DateTime.now(),
                  );
                } else {
                  await recRepo.deleteById(r.id);
                }
              } catch (e, st) {
                AppLog.w(
                    'resumeIncompleteTransfers: SANITY cleanup failed for ${r.id}',
                    e,
                    st);
              }
            }
          }
          incomplete = kept;
          if (incomplete.isEmpty) return;
        }

        // When device is recording, only rows for that session are left above. That is not redundant with the
        // global active-transfer mutex: the mutex prevents parallel AT+DOWNLOAD; this filter chooses *which*
        // session may sync among several DB rows while the mic session is open.

        // Queue: newest first (same axis as home list / [listTransfersToResume] DESC).
        incomplete.sort((a, b) {
          if (preferredId.isNotEmpty) {
            final aPref = a.id.trim() == preferredId;
            final bPref = b.id.trim() == preferredId;
            if (aPref != bPref) return aPref ? -1 : 1;
          }
          final ta = a.transferStartedAt ??
              a.createdAt ??
              DateTime.fromMillisecondsSinceEpoch(0);
          final tb = b.transferStartedAt ??
              b.createdAt ??
              DateTime.fromMillisecondsSinceEpoch(0);
          return tb.compareTo(ta);
        });

        AppLog.i(
          'resumeIncompleteTransfers: ${incomplete.length} incomplete for device $deviceId '
          'preferredRecordingId=${preferredId.isNotEmpty ? preferredId : '(none)'}',
        );
        if (preferredId.isNotEmpty &&
            !incomplete.any((r) => r.id.trim() == preferredId)) {
          _preferredBleResumeRecordingIdAfterWifiHandoff = null;
        }
        for (final rec in incomplete) {
          if (_bleTransferGuardForRecordingStart) {
            AppLog.d(
              'resumeIncompleteTransfers: stop loop (recording start guard — user started recording)',
            );
            break;
          }
          if (shouldYieldToPreferred(rec.id)) {
            break;
          }
          if (state.connection == null || _at == null) {
            AppLog.i(
                'resumeIncompleteTransfers: interrupted (disconnected), stop resume loop');
            break;
          }
          final sessionId = (rec.devicePath).trim();
          if (sessionId.isEmpty) continue;
          if (preferredId.isNotEmpty && rec.id.trim() == preferredId) {
            _preferredBleResumeRecordingIdAfterWifiHandoff = null;
          }
          if (_shouldSuppressBleResume(rec.id)) {
            AppLog.i(
              'resumeIncompleteTransfers: skip ${rec.id} (Wi‑Fi fast sync just finished this row)',
            );
            continue;
          }
          if (_transferForRecording(rec.id) != null) {
            AppLog.i(
              'resumeIncompleteTransfers: skip ${rec.id} (active BLE download on this row)',
            );
            continue;
          }
          final mergeQueue = ref.read(sessionMergeQueueProvider);
          if (rec.transferState == 'merging' ||
              mergeQueue.isMergingRecording(rec.id)) {
            AppLog.d(
              'resumeIncompleteTransfers: skip ${rec.id} (background merge in progress)',
            );
            continue;
          }
          if (rec.transferState == 'done') {
            continue;
          }
          if (await tryCompleteTransferFromLocalPartsIfReady(rec.id)) {
            continue;
          }

          String? startFile;
          var snapshot = await _getSessionInfoAndFileList(sessionId);
          var info = snapshot?.info;
          var totalFiles = _parseInt(info?['files']) ?? 0;
          var synced = _parseInt(info?['synced']) ?? 0;
          var deviceFiles = snapshot?.files ?? [];
          var effectiveTotal = _effectiveSessionFileTotal(
            totalFiles: totalFiles,
            synced: synced,
            deviceFiles: deviceFiles,
          );

          // Session no longer on device (AT+LIST=session returns empty/error, e.g. directory open -2): do not resume
          if (info == null && deviceFiles.isEmpty) {
            if (_recordingLikelyAfterWifiSetupFailure(rec)) {
              AppLog.i(
                'resumeIncompleteTransfers: AT+LIST inconclusive for session=$sessionId '
                'after Wi‑Fi setup failure — retrying once with settled BLE link',
              );
              await Future<void>.delayed(const Duration(milliseconds: 500));
              snapshot = await _getSessionInfoAndFileList(sessionId);
              info = snapshot?.info;
              totalFiles = _parseInt(info?['files']) ?? 0;
              synced = _parseInt(info?['synced']) ?? 0;
              deviceFiles = snapshot?.files ?? [];
              effectiveTotal = _effectiveSessionFileTotal(
                totalFiles: totalFiles,
                synced: synced,
                deviceFiles: deviceFiles,
              );
            }
          }

          if (info == null && deviceFiles.isEmpty) {
            if (shouldYieldToPreferred(rec.id)) {
              break;
            }
            final localParts =
                await _listLocalPartsWithStatus(deviceId, sessionId);
            final hasMergeableParts =
                localParts.any((p) => p.isComplete) || localParts.length > 1;
            final expectedBytes = rec.expectedBytes ?? 0;
            final localBytes = rec.receivedBytes ?? 0;
            final incompleteAfterWifi = _recordingLikelyAfterWifiSetupFailure(rec) &&
                expectedBytes > 0 &&
                localBytes < (expectedBytes * 0.9).round();
            if (incompleteAfterWifi) {
              startFile = await _computeStartFileFromLocalParts(
                deviceId,
                sessionId,
                expectedTotalFiles: effectiveTotal > 0 ? effectiveTotal : null,
              );
              startFile ??= '0001.opus';
              AppLog.i(
                'resumeIncompleteTransfers: session=$sessionId Wi‑Fi failed — '
                'resume BLE download from $startFile '
                '(local=$localBytes expected=$expectedBytes)',
              );
            } else if (hasMergeableParts) {
              AppLog.i(
                  'resumeIncompleteTransfers: session=$sessionId not on device, merging local parts only');
              final merged = await _mergeAndCompleteFromLocalParts(
                  rec.id, deviceId, sessionId, rec.expectedBytes);
              if (!merged) {
                AppLog.w(
                  'resumeIncompleteTransfers: session=$sessionId local merge unavailable '
                  'after device session disappeared, marking failed to drain queue',
                );
                await recRepo.updateTransfer(
                  id: rec.id,
                  state: 'failed',
                  errorCode: 'device_session_missing',
                  transferFinishedAt: DateTime.now(),
                  recordingState: 'failed',
                );
              }
              continue;
            } else {
              // Device no longer has this session and local has no mergeable parts
              final hasLocal = (rec.localPath ?? '').trim().isNotEmpty;
              if (hasLocal) {
                AppLog.i(
                    'resumeIncompleteTransfers: session=$sessionId not on device, marking devicePresent=false');
                await recRepo.updateDevicePresent(id: rec.id, present: false);
                await recRepo.updateTransfer(
                    id: rec.id,
                    state: 'failed',
                    errorCode: 'device_session_missing');
              } else {
                AppLog.i(
                    'resumeIncompleteTransfers: session=$sessionId not on device, deleting record');
                await recRepo.deleteById(rec.id);
              }
            }
            if (startFile == null) {
              continue;
            }
          }
          if (synced > 0 && synced < effectiveTotal && startFile == null) {
            startFile = await _computeStartFileFromFirmwareSynced(
              deviceId: deviceId,
              sessionId: sessionId,
              synced: synced,
              effectiveTotal: effectiveTotal,
              logContext: 'resumeIncompleteTransfers',
            );
            if (startFile != null) {
              AppLog.i(
                  'resumeIncompleteTransfers: session=$sessionId from firmware synced=$synced total=$effectiveTotal, startFile=$startFile');
            }
          }
          if (startFile == null) {
            final localParts =
                await _listLocalPartsWithStatus(deviceId, sessionId);
            for (final part in localParts) {
              if (deviceFiles.contains(part.filename) && !part.isComplete) {
                startFile = part.filename;
                AppLog.i(
                    'resumeIncompleteTransfers: session=$sessionId firstIncomplete=$startFile');
                break;
              }
            }
          }
          if (startFile == null) {
            final fromLocal = await _computeStartFileFromLocalParts(
              deviceId,
              sessionId,
              expectedTotalFiles: effectiveTotal > 0 ? effectiveTotal : null,
            );
            if (fromLocal != null) {
              final startNum =
                  int.tryParse(fromLocal.replaceAll(RegExp(r'[^0-9]'), '')) ??
                      0;
              if (effectiveTotal > 0 && startNum > effectiveTotal) {
                AppLog.w(
                    'resumeIncompleteTransfers: session=$sessionId startFile=$fromLocal exceeds total=$effectiveTotal, merging local parts only');
                final merged = await _mergeAndCompleteFromLocalParts(
                    rec.id, deviceId, sessionId, rec.expectedBytes);
                if (merged) {
                  continue;
                }
                AppLog.w(
                  'resumeIncompleteTransfers: session=$sessionId local merge unavailable '
                  'despite synced slices, falling back to full re-download',
                );
                startFile = '0001.opus';
              } else {
                startFile = fromLocal;
                AppLog.i(
                    'resumeIncompleteTransfers: session=$sessionId from local parts, startFile=$startFile total=$effectiveTotal');
              }
            }
          }
          if (startFile == null &&
              effectiveTotal > 0 &&
              synced >= effectiveTotal) {
            if (shouldYieldToPreferred(rec.id)) {
              break;
            }
            AppLog.i(
              'resumeIncompleteTransfers: session=$sessionId firmware synced>=total '
              '($synced/$effectiveTotal), no missing local slice — merging local parts',
            );
            final merged = await _mergeAndCompleteFromLocalParts(
                rec.id, deviceId, sessionId, rec.expectedBytes);
            if (merged) {
              continue;
            }
            AppLog.w(
              'resumeIncompleteTransfers: session=$sessionId has no usable local merge result, '
              'falling back to full re-download from 0001.opus',
            );
            startFile = '0001.opus';
          }
          if (state.connection == null || _at == null) {
            AppLog.i(
                'resumeIncompleteTransfers: disconnected before download, stop resume loop');
            break;
          }
          if (_transferForDevice(deviceId) != null) {
            AppLog.i(
              'resumeIncompleteTransfers: stop loop (BLE download started on $deviceId)',
            );
            break;
          }
          final freshRow = await _withRecRepo((r) => r.getById(rec.id));
          if (freshRow == null ||
              freshRow.isDeleted ||
              freshRow.transferState == 'done' ||
              freshRow.transferState == 'merging') {
            AppLog.d(
              'resumeIncompleteTransfers: skip ${rec.id} '
              '(fresh transfer_state=${freshRow?.transferState})',
            );
            continue;
          }
          if (_shouldSuppressBleResume(rec.id)) {
            continue;
          }
          if (await tryCompleteTransferFromLocalPartsIfReady(rec.id)) {
            continue;
          }
          try {
            await downloadSessionToLocal(
              recordingId: rec.id,
              sessionId: sessionId,
              expectedBytes: rec.expectedBytes,
              expectedTotalFiles: effectiveTotal > 0 ? effectiveTotal : null,
              startFile: startFile,
              continuous: true,
              notifyOnComplete: false,
            );
          } catch (e, st) {
            AppLog.w('resumeIncompleteTransfers: failed for ${rec.id}', e, st);
            final errMsg = e.toString();
            final isSessionNotFound =
                errMsg.toLowerCase().contains('session not found');
            if (isSessionNotFound &&
                await tryCompleteTransferFromLocalPartsIfReady(rec.id)) {
              continue;
            }
            // On resume failure update to failed so UI does not stay at 62% transferring
            await recRepo.updateTransfer(
              id: rec.id,
              state: 'failed',
              error: isSessionNotFound ? null : errMsg,
              errorCode: isSessionNotFound
                  ? 'device_session_missing_cannot_resume'
                  : null,
              receivedBytes: rec.receivedBytes,
              expectedBytes: rec.expectedBytes,
              transferFinishedAt: DateTime.now(),
              recordingState: 'failed',
            );
          }
        }
        if (incomplete.isNotEmpty) {
          bumpRecordingsLists(ref);
        }
      });
    } finally {
      _resumeIncompleteTransfersBusy = false;
      unawaited(drainPostMergeBleCleanupQueue());
      if (_resumeIncompleteTransfersRerunRequested) {
        _resumeIncompleteTransfersRerunRequested = false;
        final pending =
            (_preferredBleResumeRecordingIdAfterWifiHandoff ?? '').trim();
        scheduleMicrotask(
          () => unawaited(
            _resumeIncompleteTransfers(
              preferredRecordingId: pending.isNotEmpty ? pending : null,
            ),
          ),
        );
      }
    }
  }

  /// If slice file(s) are already on disk (e.g. live record-while-transfer or a
  /// prior partial pull), merge and mark [transfer_state] done without AT+DOWNLOAD.
  Future<bool> tryCompleteTransferFromLocalPartsIfReady(
      String recordingId) async {
    final conn = state.connection;
    if (conn == null) return false;
    if (_transferForRecording(recordingId) != null) return false;
    Recording? rec;
    try {
      rec = await _withRecRepo((r) => r.getById(recordingId));
    } catch (e) {
      if (isRecordingsDatabaseClosedError(e)) return false;
      rethrow;
    }
    if (rec == null || rec.transferState == 'done') return false;
    if (rec.transferState == 'merging') return false;
    final sessionId = rec.devicePath.trim();
    if (sessionId.isEmpty) return false;
    final deviceId = conn.device.remoteId.toString();
    if (rec.deviceId != null && rec.deviceId != deviceId) return false;

    final ourRoot = _normalizeRecordingSessionRoot(sessionId);
    if (rec.endedAt == null && ourRoot.isNotEmpty) {
      try {
        final st = await getRecordingStatus();
        if (st != null && (st.state == 'recording' || st.state == 'paused')) {
          final liveRoot = _normalizeRecordingSessionRoot(st.sessionId);
          if (liveRoot.isNotEmpty && liveRoot == ourRoot) {
            AppLog.d(
              'tryCompleteTransferFromLocalPartsIfReady: skip — firmware still '
              'recording sessionRoot=$ourRoot',
            );
            return false;
          }
        }
      } catch (_) {}
    }

    final mergedPath = await _deviceSessionOpusPath(deviceId, sessionId);
    final mergedFile = File(mergedPath);
    if (await mergedFile.exists()) {
      final len = await mergedFile.length();
      if (len > 0) {
        // Guard against a stale/partial merged file left by an earlier
        // interrupted transfer. If the device STILL has this session and its
        // real size is meaningfully larger than what we merged (or it has more
        // files than we hold locally), the on-disk merge is NOT the full
        // recording — marking done here collapses a long recording to a tiny
        // fraction of its duration (e.g. a 1h49m session showing as ~17min).
        // Delete the partial output and let the resume path re-pull instead.
        var deviceSessionBytes = 0;
        var deviceFileCount = 0;
        try {
          final snap = await _getSessionInfoAndFileList(sessionId);
          if (snap != null) {
            deviceSessionBytes = snap.info['size'] ?? 0;
            deviceFileCount = snap.files.isNotEmpty
                ? snap.files.length
                : (snap.info['files'] ?? 0);
          }
        } catch (_) {}
        final localCompleteCount =
            (await _listLocalPartsWithStatus(deviceId, sessionId))
                .where((p) => p.isComplete)
                .length;
        final mergedTooSmall = deviceSessionBytes > 0 &&
            len < (deviceSessionBytes * 0.9).round();
        final missingSlices =
            deviceFileCount > 0 && localCompleteCount < deviceFileCount;
        if (mergedTooSmall || missingSlices) {
          AppLog.w(
            'tryCompleteTransferFromLocalPartsIfReady: on-disk merged file '
            '($len B, localSlices=$localCompleteCount) inconsistent with device '
            'session (size=$deviceSessionBytes B, files=$deviceFileCount) for '
            '$recordingId — stale/partial merge, NOT marking done; re-pull',
          );
          try {
            await mergedFile.delete();
          } catch (_) {}
          if (deviceSessionBytes > 0 &&
              deviceSessionBytes != (rec.expectedBytes ?? 0)) {
            try {
              await _withRecRepo((r) => r.updateTransfer(
                    id: recordingId,
                    state: 'transferring',
                    expectedBytes: deviceSessionBytes,
                  ));
              bumpRecordingsLists(ref);
              ref.invalidate(recordingByIdProvider(recordingId));
            } catch (_) {}
          }
          return false;
        }
        AppLog.i(
          'tryCompleteTransferFromLocalPartsIfReady: merged file already on disk '
          '($len B) for $recordingId — marking done',
        );
        var durationSec = rec.durationSeconds;
        if (durationSec == null || durationSec <= 0) {
          durationSec =
              await resolveMergedOpusDurationSeconds(mergedPath, len) ??
                  estimateRawOpusDurationSecondsFromBytes(len);
        }
        final expectedBytes = rec.expectedBytes;
        await _withRecRepo((r) => r.updateTransfer(
              id: recordingId,
              state: 'done',
              progress: 1.0,
              localPath: mergedPath,
              sizeBytes: len,
              receivedBytes: len,
              expectedBytes: expectedBytes,
              transferFinishedAt: DateTime.now(),
              recordingState: 'done',
              durationSeconds: durationSec,
            ));
        bumpRecordingsLists(ref);
        ref.invalidate(recordingByIdProvider(recordingId));
        return true;
      }
    }

    final localParts = await _listLocalPartsWithStatus(deviceId, sessionId);
    final completeCount = localParts.where((p) => p.isComplete).length;
    if (completeCount == 0) return false;

    var needFiles = 0;
    try {
      final snap = await _getSessionInfoAndFileList(sessionId);
      if (snap != null) {
        needFiles = snap.files.isNotEmpty
            ? snap.files.length
            : (_parseInt(snap.info['files']) ?? 0);
      }
    } catch (_) {}
    if (needFiles == 0) {
      if (rec.endedAt == null) {
        AppLog.d(
          'tryCompleteTransferFromLocalPartsIfReady: skip — session not ended '
          'and file count unknown ($recordingId)',
        );
        return false;
      }
      AppLog.d(
        'tryCompleteTransferFromLocalPartsIfReady: skip — device file count '
        'unknown after stop ($recordingId, localSlices=$completeCount)',
      );
      return false;
    }
    if (needFiles > 0 && completeCount < needFiles) return false;

    AppLog.i(
      'tryCompleteTransferFromLocalPartsIfReady: merging $completeCount local '
      'slice(s) for $recordingId (device files=$needFiles)',
    );
    return _mergeAndCompleteFromLocalParts(
      recordingId,
      deviceId,
      sessionId,
      rec.expectedBytes,
    );
  }

  Future<bool> _mergeAndCompleteFromLocalParts(
    String recordingId,
    String deviceId,
    String sessionId,
    int? expectedBytes,
  ) async {
    Recording? rec;
    try {
      rec = await _withRecRepo((r) => r.getById(recordingId));
    } catch (e) {
      if (isRecordingsDatabaseClosedError(e)) return false;
      rethrow;
    }
    if (rec == null) return false;
    final sessionDir =
        Directory(await _deviceSessionDirectory(deviceId, sessionId));
    if (!sessionDir.existsSync()) {
      AppLog.w(
        'mergeAndCompleteFromLocalParts: sessionDir missing for session=$sessionId',
      );
      return false;
    }

    final queue = ref.read(sessionMergeQueueProvider);
    return queue.enqueue(SessionMergeJob(
      recordingId: recordingId,
      deviceId: deviceId,
      sessionId: sessionId,
      receivedBytes: rec.receivedBytes ?? 0,
      expectedBytes: expectedBytes ?? rec.expectedBytes,
      transferStartedAt: rec.transferStartedAt,
      fallbackDurationSeconds: rec.durationSeconds,
      deleteAfterSync: true,
      notifyOnComplete: false,
      strictSliceValidation: false,
      source: 'local_parts',
    ));
  }

  Future<String?> _computeStartFileFromFirmwareSynced({
    required String deviceId,
    required String sessionId,
    required int synced,
    required int effectiveTotal,
    required String logContext,
  }) async {
    if (synced <= 0 || effectiveTotal <= 0 || synced >= effectiveTotal) {
      return null;
    }

    final candidate = '${(synced + 1).toString().padLeft(4, '0')}.opus';
    final sessionDir =
        Directory(await _deviceSessionDirectory(deviceId, sessionId));
    final init =
        await _computeInitialReceivedFromLocalParts(sessionDir, candidate);
    // Only trust the firmware `synced` pointer to resume at synced+1 when ALL
    // local slices 0001..synced are actually present. Firmware `synced` is the
    // device-side counter and can run ahead of what we saved; if there is a
    // hole below it (e.g. only 0004 on disk, 0001-0003 missing) resuming at
    // synced+1 leaves those holes forever — the device only streams forward
    // from startFile, so the merge guard keeps seeing N<total and the session
    // loops on re-download. Detect the gap and restart from the first one.
    if (init.fileCount >= synced) {
      return candidate;
    }

    final firstGap = await _computeStartFileFromLocalParts(
      deviceId,
      sessionId,
      expectedTotalFiles: effectiveTotal,
    );
    AppLog.w(
      '$logContext: firmware synced=$synced but only ${init.fileCount} '
      'contiguous local slices before $candidate — restart from '
      '${firstGap ?? '0001.opus'}',
    );
    return firstGap ?? '0001.opus';
  }

  Future<String?> _computeStartFileFromLocalParts(
    String deviceId,
    String sessionId, {
    int? expectedTotalFiles,
  }) async {
    try {
      final sessionDir =
          Directory(await _deviceSessionDirectory(deviceId, sessionId));
      if (!sessionDir.existsSync()) return null;

      final files = sessionDir.listSync().whereType<File>().toList();
      final completeNums = <int>{};
      int maxNum = 0;
      var hasPartLast = false;
      for (final f in files) {
        final name = p.basename(f.path).toLowerCase();
        if (name.startsWith('part_last') &&
            (name.endsWith('.opus') || name.endsWith('.opus.part'))) {
          hasPartLast = true;
          continue;
        }
        if (!name.endsWith('.opus')) continue;
        final stem = p.basenameWithoutExtension(name);
        final n = partNumberFromSessionOpusFilename(stem);
        if (n != null && n > 0) {
          if (n > maxNum) maxNum = n;
          if (!stem.startsWith('part_') && name.endsWith('.opus')) {
            completeNums.add(n);
          }
        }
      }
      if (maxNum <= 0) return hasPartLast ? '0001.opus' : null;
      for (var n = 1; n <= maxNum; n++) {
        if (!completeNums.contains(n)) {
          return '${n.toString().padLeft(4, '0')}.opus';
        }
      }
      // No gap inside 1..maxNum. Decide whether to ask the device for `maxNum+1`:
      // — when [expectedTotalFiles] is known and `maxNum < expectedTotalFiles`, BLE clearly
      //   stopped on a slice boundary (e.g. cancelled right after `0075.opus` finished and
      //   before `0076.opus` opened, leaving no `part_*` behind). Returning `null` here
      //   would force the next AT+DOWNLOAD to re-pull `0001.opus` and overwrite the BLE
      //   work — the same failure mode as Wi‑Fi handoff restarting slices from 0001.
      // — when totals are unknown (LIST not ready right after STOP) but we already have
      //   contiguous `0001..maxNum` on disk, still continue at `maxNum+1` instead of
      //   a fresh `AT+DOWNLOAD=$sessionId` (firmware restarts from 0001).
      // — when totals match (all slices local), return null so merge can run.
      if (expectedTotalFiles != null) {
        if (maxNum < expectedTotalFiles) {
          return '${(maxNum + 1).toString().padLeft(4, '0')}.opus';
        }
        return null;
      }
      if (maxNum > 0 && completeNums.length == maxNum) {
        return '${(maxNum + 1).toString().padLeft(4, '0')}.opus';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// BLE [platformName] can lag after in-app rename; prefer local DB.
  Future<String> _resolvedDeviceDisplayName(
    String deviceId,
    String platformName, {
    String emptyFallback = 'SenseCraft Voice Clip',
  }) async {
    final p = platformName.trim();
    try {
      final repo = await ref.read(deviceRepositoryProvider.future);
      final d = await repo.getById(deviceId);
      final n = (d?.name ?? '').trim();
      if (n.isNotEmpty) return n;
    } catch (_) {}
    if (p.isNotEmpty) return p;
    return emptyFallback;
  }

  Future<bool> applyRecordingMode(RecordingMode mode) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;
    final deviceId = conn.device.remoteId.toString();
    final repo = await ref.read(deviceRepositoryProvider.future);

    final val = (mode == RecordingMode.enhanced) ? 'enhanced' : 'normal';
    try {
      final resp =
          await at.send('AT+MODE=$val', timeout: const Duration(seconds: 4));
      if (resp['ok'] == true) {
        await repo.updateRecordingMode(deviceId, mode);
        _bumpDeviceDbRevision();
        return true;
      }
      return false;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Outcome of [applyDeviceName].
  ///
  /// - [ok]: name was persisted on the device (or just locally when
  ///   `requireDevice=false` and offline).
  /// - [savedOnDeviceToo]: true when an AT+NAME write actually succeeded;
  ///   false when only the local DB was updated (offline, or device write
  ///   failed and `requireDevice=false`).
  /// - [errorCode]: i18n hint when [ok] is false. One of `device_offline`,
  ///   `name_invalid`, `device_rejected`, `at_failed`.
  /// - [atErrorMessage]: best-effort error from firmware when
  ///   `errorCode == 'device_rejected'`.
  ///
  /// Per `protocol.md` 3.3.7 AT+NAME survives reboots and is independent of
  /// BLE/WiFi advertised names. The App's local DB still mirrors the value
  /// so offline screens can show it before the next reconnect.
  Future<DeviceNameApplyResult> applyDeviceName(
    String? name, {
    bool requireDevice = true,
  }) async {
    final desired = (name ?? '').trim();
    final repo = await ref.read(deviceRepositoryProvider.future);
    // Validate App-side first to keep local DB clean.
    if (desired.isNotEmpty &&
        !RecordingSession.isValidUserDeviceName(desired)) {
      return const DeviceNameApplyResult.failure(errorCode: 'name_invalid');
    }

    final conn = state.connection;
    final at = _at;
    final deviceId =
        state.lastConnectedDeviceId ?? conn?.device.remoteId.toString();

    // Offline branch: local-only update.
    if (conn == null || at == null) {
      if (requireDevice) {
        return const DeviceNameApplyResult.failure(errorCode: 'device_offline');
      }
      if (deviceId == null) {
        return const DeviceNameApplyResult.failure(errorCode: 'device_offline');
      }
      try {
        await repo.updateName(deviceId, desired);
        _bumpDeviceDbRevision();
        // Queue: next [syncConnectedDeviceInfo] will reconcile.
        _pendingDeviceNamePush = desired;
        return DeviceNameApplyResult.success(savedOnDeviceToo: false);
      } catch (e) {
        return DeviceNameApplyResult.failure(
          errorCode: 'at_failed',
          atErrorMessage: e.toString(),
        );
      }
    }

    // Online branch: device first, DB second. If the device rejects (e.g.
    // length > 32 from a multi-byte locale), we don't write the local DB so
    // user re-enters something the firmware will accept.
    try {
      final session = RecordingSession(connection: conn, at: at);
      await session.setUserDeviceName(desired.isEmpty ? null : desired);
      await repo.updateName(conn.device.remoteId.toString(), desired);
      _pendingDeviceNamePush = null;
      _bumpDeviceDbRevision();
      return DeviceNameApplyResult.success(savedOnDeviceToo: true);
    } on ArgumentError {
      return const DeviceNameApplyResult.failure(errorCode: 'name_invalid');
    } on RecordingException catch (e) {
      AppLog.w('applyDeviceName: device rejected name', e);
      return DeviceNameApplyResult.failure(
        errorCode: 'device_rejected',
        atErrorMessage: e.message,
      );
    } catch (e, st) {
      AppLog.w('applyDeviceName: AT+NAME failed', e, st);
      return DeviceNameApplyResult.failure(
        errorCode: 'at_failed',
        atErrorMessage: e.toString(),
      );
    }
  }

  /// Cached "user changed name while offline" — flushed by
  /// [_reconcileDeviceNameAfterConnect] on the next successful connect.
  String? _pendingDeviceNamePush;

  /// Reconcile App-side device name with the firmware-persisted AT+NAME.
  ///
  /// Strategy:
  /// 1. If a pending offline rename exists, push it now (`AT+NAME=`).
  ///    Device is the source of truth on success — local DB already has the
  ///    pending value.
  /// 2. Else, read `AT+NAME?` and adopt the device value when present
  ///    (firmware was renamed by another phone before this pair).
  /// 3. When the device returns an empty name and we have a non-empty
  ///    local value, push the local value up so the device persists it.
  ///
  /// Best-effort: any failure logs and returns silently — recording / sync
  /// must not be blocked on a name reconcile.
  Future<void> _reconcileDeviceNameAfterConnect() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return;
    final deviceId = conn.device.remoteId.toString();
    final repo = await ref.read(deviceRepositoryProvider.future);
    try {
      final session = RecordingSession(connection: conn, at: at);

      final pending = _pendingDeviceNamePush;
      if (pending != null) {
        try {
          await session.setUserDeviceName(pending.isEmpty ? null : pending);
          _pendingDeviceNamePush = null;
          AppLog.i(
            'DeviceController: flushed pending offline rename '
            '"$pending" to device $deviceId',
          );
          return;
        } catch (e, st) {
          AppLog.w(
            'DeviceController: pending offline rename push failed; '
            'will retry next reconnect',
            e,
            st,
          );
          // Fall through to the read path so we at least mirror device state.
        }
      }

      final remote = (await session.getUserDeviceName()).trim();
      final dev = await repo.getById(deviceId);
      final local = (dev?.name ?? '').trim();
      if (remote.isNotEmpty && remote != local) {
        await repo.updateName(deviceId, remote);
        _bumpDeviceDbRevision();
        AppLog.i(
          'DeviceController: adopted device-persisted name '
          '"$remote" (was local "$local")',
        );
      } else if (remote.isEmpty &&
          local.isNotEmpty &&
          RecordingSession.isValidUserDeviceName(local)) {
        // Device has no name but App does — push local up so it survives
        // reboot / re-pair.
        try {
          await session.setUserDeviceName(local);
          AppLog.i(
            'DeviceController: pushed local name "$local" to empty device',
          );
        } catch (e, st) {
          AppLog.w(
            'DeviceController: push local name to empty device failed '
            '(non-fatal)',
            e,
            st,
          );
        }
      }
    } catch (e, st) {
      AppLog.w(
        'DeviceController: AT+NAME reconcile failed (non-fatal)',
        e,
        st,
      );
    }
  }

  Future<bool> factoryReset() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;
    try {
      final resp = await at.send('AT+FACTORY=confirm',
          timeout: const Duration(seconds: 10));
      final ok = resp['ok'] == true;
      if (ok) {
        // Device will reboot; proactively disconnect and mark offline.
        await disconnect();
      }
      return ok;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<void> _persistConnectedOnline() async {
    final conn = state.connection;
    if (conn == null) return;
    try {
      final repo = await ref.read(deviceRepositoryProvider.future);
      await repo.updateStatus(
        id: conn.device.remoteId.toString(),
        isOnline: true,
      );
      _bumpDeviceDbRevision();
    } catch (_) {}
  }

  Future<bool?> pollGstatAndPersist() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return null;
    final deviceId = conn.device.remoteId.toString();
    final repo = await ref.read(deviceRepositoryProvider.future);

    // Keep DB online flag aligned with the live link even while BLE transfer
    // is active (full GSTAT poll is skipped below during transfer).
    try {
      await repo.updateStatus(id: deviceId, isOnline: true);
      _bumpDeviceDbRevision();
    } catch (_) {}

    if (_activeTransferRecordingId != null) return null;

    try {
      final resp =
          await at.send('AT+GSTAT', timeout: const Duration(seconds: 4));
      if (resp['ok'] != true) return null;
      final data = resp['data'];
      final dataMap = data is Map
          ? Map<String, dynamic>.from(data)
          : const <String, dynamic>{};

      final battery = _parseInt(dataMap['battery']);
      await repo.updateStatus(
          id: deviceId, isOnline: true, batteryPercent: battery);
      _bumpDeviceDbRevision();

      final mode = (dataMap['mode'] ?? '').toString().trim().toLowerCase();
      final rm = switch (mode) {
        'enhanced' => RecordingMode.enhanced,
        'normal' => RecordingMode.normal,
        _ => null,
      };
      if (rm != null) {
        await repo.updateRecordingMode(deviceId, rm);
        _bumpDeviceDbRevision();
      }

      final pollDerived = _deriveRecStateFromGstatMap(dataMap);
      _onDerivedRecordingStateForDeferredResume(pollDerived);
      final isRecording = pollDerived == 'recording';

      // Best-effort duration support if firmware provides it.
      final dur = _parseInt(dataMap['duration']);
      if (isRecording) {
        if (dur != null && dur >= 0) {
          _recordingStartOffsetSeconds = dur;
          _recordingStartedAt = DateTime.now();
        } else {
          _recordingStartedAt ??= DateTime.now();
        }
      } else {
        _recordingStartedAt = null;
        _recordingStartOffsetSeconds = 0;
      }

      return isRecording;
    } catch (_) {
      return null;
    }
  }

  /// Page size for fetching all sessions (matches firmware `data.per_page`; using 25 wrongly stopped when the first screen had only 10 rows).
  static const int _listPerPage = 10;

  /// Upsert session rows from `AT+LIST` string ids into [remoteSessionIds].
  Future<void> _upsertDeviceListItemsIntoSet(
    String deviceId,
    String deviceName,
    Iterable<String> rawStrings,
    Set<String> remoteSessionIds,
    RecordingsRepository recRepo,
  ) async {
    var upsertIndex = 0;
    for (final item in rawStrings) {
      final s = item.trim();
      if (s.isEmpty) continue;
      final sessionId = s.contains('/') ? s.split('/').first : s;
      if (remoteSessionIds.contains(sessionId)) continue;
      remoteSessionIds.add(sessionId);
      final createdAt = parseSessionTimestamp(sessionId);
      final displayName = recordingDisplayNameForDevice(
        deviceName,
        createdAt ?? DateTime.now(),
      );

      await recRepo.upsertFromDeviceFile(
        deviceId: deviceId,
        devicePath: sessionId,
        name: displayName,
        sizeBytes: null,
        durationSeconds: null,
        createdAt: createdAt,
        startedAt: createdAt,
      );
      upsertIndex++;
      if (upsertIndex % 20 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Remove/update local rows for sessions no longer reported by the device.
  /// Only call when [remoteSessionIds] is the **complete** device session set.
  Future<void> _applyDeviceListRemoteCleanup(
    String deviceId,
    Set<String> remoteSessionIds,
    RecordingsRepository recRepo,
  ) async {
    final localBeforeCompare = await recRepo.listByDeviceId(deviceId);

    // Guard: an empty remote set almost always means AT+LIST failed or parsed
    // to nothing. Diffing against it would wipe every local device row, so do
    // nothing rather than risk deleting the user's whole list.
    if (remoteSessionIds.isEmpty) {
      if (localBeforeCompare.isNotEmpty) {
        AppLog.w(
          'deviceListCleanup: SKIP — remoteSessionIds empty but '
          '${localBeforeCompare.length} local rows for device=$deviceId '
          '(treat as AT+LIST failure, not a device wipe)',
        );
      }
      return;
    }

    for (final r in localBeforeCompare) {
      if (!r.devicePath.contains('/')) continue;
      final sessionId = r.devicePath.split('/').first;
      if (!remoteSessionIds.contains(sessionId)) continue;
      await recRepo.deleteById(r.id);
    }
    final local = await recRepo.listByDeviceId(deviceId);
    for (final r in local) {
      final sessionId = r.devicePath.contains('/')
          ? r.devicePath.split('/').first
          : r.devicePath;
      final stillOnDevice = remoteSessionIds.contains(sessionId);
      if (stillOnDevice) continue;

      // A row carries user-visible value once it has ANY content/metadata.
      // Never hard-delete those just because the device dropped the session
      // (or local_path was transiently cleared by a path migration) — only
      // mark them no-longer-on-device so the row (and any local file) stays.
      final hasValue = (r.localPath ?? '').trim().isNotEmpty ||
          r.transferState == 'failed' ||
          r.source == 'local' ||
          (r.name ?? '').trim().isNotEmpty ||
          (r.remoteUrl ?? '').trim().isNotEmpty ||
          (r.remoteId ?? '').trim().isNotEmpty ||
          r.asrResultId != null ||
          (r.transcript ?? '').trim().isNotEmpty ||
          (r.transcriptPath ?? '').trim().isNotEmpty;

      if (hasValue) {
        await recRepo.updateDevicePresent(id: r.id, present: false);
      } else {
        AppLog.d(
          'deviceListCleanup: delete empty stub id=${r.id} session=$sessionId',
        );
        await recRepo.deleteById(r.id);
      }
    }
  }

  /// Sync device session index into the local DB.
  ///
  /// - [fetchAllPages] `true` (**default**): page through all `AT+LIST` responses, diff against local, and clean up — most reliable for index and resume.
  /// - [fetchAllPages] `false`: first page + cursor continuation ([syncDeviceFileIndexContinue]); no "deleted on device" cleanup until full fetch completes.
  Future<int> syncDeviceFileIndex({bool fetchAllPages = true}) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return 0;

    state = state.copyWith(error: null);
    final deviceId = conn.device.remoteId.toString();
    final deviceName = await _resolvedDeviceDisplayName(
      deviceId,
      conn.device.platformName,
    );
    final recRepo = await ref.read(recordingsRepositoryProvider.future);

    if (fetchAllPages) {
      _resetDeviceListPaging();
    } else if (_deviceListCursorDeviceId == deviceId &&
        _deviceListCursorHasMorePages) {
      // User is loading further AT+LIST pages via list scroll; do not reset the cursor to only the first page.
      return _deviceListCursorRemoteSessionIds.length;
    } else {
      _resetDeviceListPaging();
    }

    final remoteSessionIds = <String>{};
    final rawItems = <String>[];

    try {
      if (fetchAllPages) {
        var page = 1;
        while (true) {
          try {
            final cmd = page == 1 ? 'AT+LIST' : 'AT+LIST?$page&$_listPerPage';
            final sessResp =
                await at.send(cmd, timeout: const Duration(seconds: 8));
            final pageItems = _parseAtListResponse(sessResp);
            rawItems.addAll(pageItems);
            await Future<void>.delayed(Duration.zero);
            final data = sessResp['data'];
            final total = _parseTotalFromListResponse(data);
            if (pageItems.isEmpty) break;
            if (total != null && rawItems.length >= total) break;
            final perHint = _parsePerPageFromListResponse(data);
            final effectivePerPage = perHint ?? _listPerPage;
            if (pageItems.length < effectivePerPage) break;
            page++;
          } catch (_) {
            break;
          }
        }
        await _upsertDeviceListItemsIntoSet(
            deviceId, deviceName, rawItems, remoteSessionIds, recRepo);
        await _applyDeviceListRemoteCleanup(
            deviceId, remoteSessionIds, recRepo);
        // Cache the freshly-fetched complete session set so downstream code
        // (notably [_resumeIncompleteTransfers]) can sanity-check session IDs
        // belong to *this* device before sending AT+DOWNLOAD. Without this,
        // a stale DB row referencing another device's session would issue
        // an unknown-session AT+DOWNLOAD that the firmware silently ignores,
        // wedging the AT serial queue for 8 s.
        _deviceListCursorDeviceId = deviceId;
        _deviceListCursorRemoteSessionIds
          ..clear()
          ..addAll(remoteSessionIds);
      } else {
        final sessResp =
            await at.send('AT+LIST', timeout: const Duration(seconds: 8));
        final pageItems = _parseAtListResponse(sessResp);
        final data = sessResp['data'];
        final total = _parseTotalFromListResponse(data);
        final perHint = _parsePerPageFromListResponse(data);
        final effectivePerPage = perHint ?? _listPerPage;

        await _upsertDeviceListItemsIntoSet(
            deviceId, deviceName, pageItems, remoteSessionIds, recRepo);

        _deviceListCursorDeviceId = deviceId;
        _deviceListCursorRemoteSessionIds
          ..clear()
          ..addAll(remoteSessionIds);
        _deviceListCursorTotal = total;

        final fullyKnown = pageItems.isEmpty ||
            (total != null && remoteSessionIds.length >= total) ||
            (pageItems.length < effectivePerPage);

        if (fullyKnown) {
          _deviceListCursorHasMorePages = false;
          await _applyDeviceListRemoteCleanup(
              deviceId, remoteSessionIds, recRepo);
        } else {
          _deviceListCursorHasMorePages = true;
          _deviceListCursorNextPage = 2;
        }
      }

      bumpRecordingsLists(ref);
      return remoteSessionIds.length;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return remoteSessionIds.length;
    }
  }

  /// Fetch the next `AT+LIST` page (after [syncDeviceFileIndex] with `fetchAllPages: false`, triggered by list scroll).
  ///
  /// When all pages are loaded, runs the same cleanup as a full sync and clears the cursor.
  Future<int> syncDeviceFileIndexContinue() async {
    if (_deviceListContinueInFlight) return 0;
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return 0;
    final deviceId = conn.device.remoteId.toString();
    if (!_deviceListCursorHasMorePages ||
        _deviceListCursorDeviceId != deviceId) {
      return 0;
    }

    _deviceListContinueInFlight = true;
    final deviceName = await _resolvedDeviceDisplayName(
      deviceId,
      conn.device.platformName,
    );
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    try {
      final page = _deviceListCursorNextPage;
      final cmd = 'AT+LIST?$page&$_listPerPage';
      final sessResp = await at.send(cmd, timeout: const Duration(seconds: 8));
      final pageItems = _parseAtListResponse(sessResp);
      final data = sessResp['data'];

      await _upsertDeviceListItemsIntoSet(deviceId, deviceName, pageItems,
          _deviceListCursorRemoteSessionIds, recRepo);

      final total = _deviceListCursorTotal ?? _parseTotalFromListResponse(data);
      if (_deviceListCursorTotal == null && total != null) {
        _deviceListCursorTotal = total;
      }
      final perHint = _parsePerPageFromListResponse(data);
      final effectivePerPage = perHint ?? _listPerPage;

      final done = pageItems.isEmpty ||
          (total != null &&
              _deviceListCursorRemoteSessionIds.length >= total) ||
          (pageItems.length < effectivePerPage);

      if (done) {
        _deviceListCursorHasMorePages = false;
        await _applyDeviceListRemoteCleanup(
            deviceId, _deviceListCursorRemoteSessionIds, recRepo);
        _resetDeviceListPaging();
      } else {
        _deviceListCursorNextPage = page + 1;
      }

      bumpRecordingsLists(ref);
      return pageItems.length;
    } catch (e, st) {
      AppLog.w('syncDeviceFileIndexContinue failed', e, st);
      return 0;
    } finally {
      _deviceListContinueInFlight = false;
    }
  }

  /// Parse `total` from an AT+LIST response (used when paging to know if everything was fetched).
  static int? _parseTotalFromListResponse(Object? data) {
    if (data is Map) {
      final m = Map<String, dynamic>.from(data);
      return _parseInt(m['total']);
    }
    return null;
  }

  static int? _parsePerPageFromListResponse(Object? data) {
    if (data is Map) {
      return _parseInt(Map<String, dynamic>.from(data)['per_page']);
    }
    return null;
  }

  /// One-line shape summary for every AT+LIST parse (filter `flutter` logs on `AT+LIST shape`).
  static String _atListResponseShapeSummary(Map<String, dynamic> resp) {
    final ok = resp['ok'];
    final top = resp.keys.map((k) => k.toString()).join(',');
    final branch = resp.containsKey('data')
        ? 'data'
        : resp.containsKey('sessions')
            ? 'sessions'
            : resp.containsKey('list')
                ? 'list'
                : 'none';
    final raw = resp['data'] ?? resp['sessions'] ?? resp['list'];
    String detail;
    if (raw == null) {
      detail = 'payload=null';
    } else if (raw is List) {
      detail =
          'List len=${raw.length} firstType=${raw.isEmpty ? "-" : raw.first.runtimeType}';
    } else if (raw is Map) {
      final m = Map<String, dynamic>.from(raw);
      detail = 'Map keys=[${m.keys.map((k) => k.toString()).join(",")}]';
    } else {
      detail = '${raw.runtimeType}';
    }
    return 'AT+LIST shape ok=$ok topKeys=[$top] branch=$branch $detail';
  }

  /// Truncated JSON for diagnosing unexpected LIST payloads (warning paths only).
  static String _atListResponseJsonSnippet(Map<String, dynamic> resp,
      {int maxLen = 900}) {
    try {
      final s = jsonEncode(resp);
      if (s.length <= maxLen) return s;
      return '${s.substring(0, maxLen)}…(totalLen=${s.length})';
    } catch (_) {
      final s = resp.toString();
      return s.length <= maxLen ? s : '${s.substring(0, maxLen)}…';
    }
  }

  static List<String> _parseAtListResponse(Map<String, dynamic>? resp) {
    if (resp == null) return const [];
    AppLog.i(_atListResponseShapeSummary(resp));
    if (resp['ok'] != true) {
      AppLog.w(
        'AT+LIST response ok!=true err=${resp['error'] ?? resp['message'] ?? resp['msg'] ?? ""} '
        'raw=${_atListResponseJsonSnippet(resp)}',
      );
    }

    Object? data = resp['data'] ?? resp['sessions'] ?? resp['list'];
    if (data is Map) {
      final m = Map<String, dynamic>.from(data);
      final next = m['sessions'] ?? m['items'] ?? m['data'];
      if (next != null) {
        data = next;
      } else {
        final id =
            (m['id'] ?? m['session'] ?? m['session_id'])?.toString().trim();
        if (id != null && id.isNotEmpty) return [id];
        if (_mapLooksLikeGstatOrListStatsPayload(m)) {
          AppLog.w(
            'AT+LIST: data map looks like GSTAT/session stats, not session names '
            '(keys=${m.keys.take(12).join(",")}) raw=${_atListResponseJsonSnippet(resp)}',
          );
          return const [];
        }
        AppLog.w(
          'AT+LIST: data map has no sessions/items/data — keys=${m.keys.take(12).join(",")} '
          'raw=${_atListResponseJsonSnippet(resp)}',
        );
        return const [];
      }
    }
    if (data is Map) {
      final m = Map<String, dynamic>.from(data);
      final id =
          (m['id'] ?? m['session'] ?? m['session_id'])?.toString().trim();
      if (id != null && id.isNotEmpty) return [id];
      if (_mapLooksLikeGstatOrListStatsPayload(m)) {
        AppLog.w(
          'AT+LIST: nested map looks like GSTAT/session stats, ignoring '
          '(keys=${m.keys.take(12).join(",")}) raw=${_atListResponseJsonSnippet(resp)}',
        );
        return const [];
      }
      final filesList = m['files'];
      if (filesList is List) {
        data = filesList;
      } else {
        AppLog.w(
          'AT+LIST: nested map is not a known session list shape — keys=${m.keys.take(12).join(",")} '
          'raw=${_atListResponseJsonSnippet(resp)}',
        );
        return const [];
      }
    }
    if (data is List) {
      final out = <String>[];
      for (final e in data) {
        if (e is Map) {
          final id =
              (e['id'] ?? e['session'] ?? e['session_id'])?.toString().trim();
          if (id != null && id.isNotEmpty) out.add(id);
        } else {
          final s = (e?.toString() ?? '').trim();
          if (s.isNotEmpty) out.add(s);
        }
      }
      if (out.isEmpty && data.isNotEmpty) {
        AppLog.w(
          'AT+LIST: list had ${data.length} element(s) but no session id fields '
          '(expected id/session/session_id on objects, or string ids) '
          'raw=${_atListResponseJsonSnippet(resp)}',
        );
      }
      return out;
    }
    final tail = _parseStringList(data);
    if (tail.isEmpty || (tail.length == 1 && tail.single.isEmpty)) {
      AppLog.w(
        'AT+LIST: fell through to _parseStringList with unexpected type=${data?.runtimeType} '
        'raw=${_atListResponseJsonSnippet(resp)}',
      );
    }
    return tail;
  }

  /// True when [m] is clearly not a session directory name / list wrapper (avoids `Map.toString()` as fake session id).
  static bool _mapLooksLikeGstatOrListStatsPayload(Map<String, dynamic> m) {
    final keys = m.keys.map((k) => k.toString().toLowerCase()).toSet();
    if (keys.contains('state') &&
        (keys.contains('battery') ||
            keys.contains('charging') ||
            keys.contains('free_space') ||
            keys.contains('bitrate'))) {
      return true;
    }
    if (keys.contains('files') &&
        keys.contains('synced') &&
        !keys.contains('id') &&
        !keys.contains('session_id') &&
        (keys.contains('size') ||
            keys.contains('sample_rate') ||
            keys.contains('bookmarks') ||
            keys.contains('channels'))) {
      return true;
    }
    return false;
  }

  static List<String> _parseStringList(Object? v) {
    if (v == null) return const [];
    if (v is Map) {
      try {
        AppLog.w(
          'AT+LIST: _parseStringList received Map — ignored (upstream should unwrap) '
          'mapKeys=${Map<String, dynamic>.from(v).keys.join(",")}',
        );
      } catch (_) {
        AppLog.w(
            'AT+LIST: _parseStringList received Map — ignored (upstream should unwrap)');
      }
      return const [];
    }
    if (v is List) {
      return v.map((e) => e?.toString() ?? '').toList();
    }
    if (v is String) {
      final s = v.trim();
      if (s.isEmpty) return const [];
      // Best-effort: allow "a,b,c" or '["a","b"]' (should be decoded already though).
      if (s.contains(',')) {
        return s
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      return [s];
    }
    return [v.toString()];
  }

  /// Rejects values that slipped into [device_path] from bad LIST parsing (would break AT+DOWNLOAD).
  static bool _isPlausibleBleSessionId(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return false;
    if (s.length > 220) return false;
    if (s.startsWith('{')) return false;
    final lower = s.toLowerCase();
    if (lower.contains('state:') && lower.contains('battery')) return false;
    if (lower.contains('free_space') && lower.contains('charging')) {
      return false;
    }
    return true;
  }

  static DateTime? _parseSessionTimestamp(String session) {
    final s = session.trim();
    // Support YYYYMMDD_HHMMSS (with underscore) and YYYYMMDDHHMMSS (no underscore, e.g. 20260227064855)
    RegExpMatch? m =
        RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$').firstMatch(s);
    m ??= RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$').firstMatch(s);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!) ?? 0;
    final mo = int.tryParse(m.group(2)!) ?? 1;
    final d = int.tryParse(m.group(3)!) ?? 1;
    final hh = int.tryParse(m.group(4)!) ?? 0;
    final mm = int.tryParse(m.group(5)!) ?? 0;
    final ss = int.tryParse(m.group(6)!) ?? 0;
    if (y <= 0) return null;
    // Firmware session id is usually UTC; convert to local time
    return DateTime.utc(y, mo, d, hh, mm, ss).toLocal();
  }

  /// Query [AT+GSTAT] on [at]. When [updateAppState] is false, parse only — used
  /// inside [downloadSessionToLocal] on the owning device's link after demote so
  /// foreground recording on another device does not block background transfers.
  Future<RecStatus?> getRecordingStatusForAt(
    AtTransport at, {
    bool updateAppState = false,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final resp = await at.send('AT+GSTAT', timeout: timeout);
      final data = resp['data'];
      final dataMap =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      const rootFallbackKeys = [
        'state',
        'recording',
        'session_id',
        'session',
        'duration',
        'duration_s',
        'battery',
        'charging',
        'free_space',
        'bitrate',
        'mode',
      ];
      for (final key in rootFallbackKeys) {
        if (!dataMap.containsKey(key) && resp.containsKey(key)) {
          dataMap[key] = resp[key];
        }
      }
      final recordingFlag = _parseTriBool(dataMap['recording']);

      final sessionId =
          (dataMap['session_id'] ?? dataMap['session'] ?? '').toString().trim();
      final sid = sessionId.isEmpty ? null : sessionId;

      final derived = _deriveRecStateFromGstatMap(dataMap);
      if (derived == 'recording' && _pauseCommandMatchesSession(sid)) {
        final dur = _currentRecordingClockSeconds(sessionId: sid);
        if (updateAppState) {
          _freezeRecordingClock(sessionId: sid);
          _setFirmwareRecState('paused');
        }
        return RecStatus(
            state: 'paused',
            durationSeconds: dur,
            file: null,
            sessionId: sid,
            isCharging: _parseChargingFromGstat(dataMap));
      }
      if (derived == 'paused' || derived == 'idle') {
        _clearPauseCommandInFlightIfMatched(sid);
      }

      if (derived == 'transmitting') {
        if (updateAppState) {
          _recordingStartedAt = null;
          _recordingStartOffsetSeconds = 0;
          _setFirmwareRecState('transmitting');
          _onDerivedRecordingStateForDeferredResume('transmitting');
        }
        return RecStatus(
            state: 'transmitting',
            durationSeconds: 0,
            file: null,
            sessionId: sid,
            isCharging: _parseChargingFromGstat(dataMap));
      }

      // Trust `recording:false` only when the state did not already identify
      // RECORDING/PAUSED/TRANSMITTING. Some iOS traces show firmware briefly
      // returning state=RECORDING with recording=false immediately after START.
      if (recordingFlag == false && derived == 'idle') {
        if (updateAppState) {
          _recordingStartedAt = null;
          _recordingStartOffsetSeconds = 0;
          _setFirmwareRecState('idle');
          _onDerivedRecordingStateForDeferredResume(derived);
        }
        return RecStatus(
            state: 'idle',
            durationSeconds: 0,
            file: null,
            sessionId: sid,
            isCharging: _parseChargingFromGstat(dataMap));
      }

      final st = derived;

      // When not recording, do not trust JSON `duration` (avoids stale cumulative seconds while state=IDLE misleading UI/sync).
      if (st == 'idle') {
        if (updateAppState) {
          _recordingStartedAt = null;
          _recordingStartOffsetSeconds = 0;
          _setFirmwareRecState('idle');
          _onDerivedRecordingStateForDeferredResume(derived);
        }
        return RecStatus(
            state: 'idle',
            durationSeconds: 0,
            file: null,
            sessionId: sid,
            isCharging: _parseChargingFromGstat(dataMap));
      }

      final dur = _resolveActiveRecordingDurationSeconds(
        dataMap: dataMap,
        state: st,
        sessionId: sid,
        updateAppState: updateAppState,
      );

      if (updateAppState) {
        _setFirmwareRecState(st);
        _onDerivedRecordingStateForDeferredResume(st);
      }
      return RecStatus(
          state: st,
          durationSeconds: dur,
          file: null,
          sessionId: sid,
          isCharging: _parseChargingFromGstat(dataMap));
    } catch (e) {
      if (updateAppState) {
        state = state.copyWith(error: e.toString());
      }
      return null;
    }
  }

  int _resolveActiveRecordingDurationSeconds({
    required Map<String, dynamic> dataMap,
    required String state,
    required String? sessionId,
    required bool updateAppState,
  }) {
    final reported =
        _parseInt(dataMap['duration']) ?? _parseInt(dataMap['duration_s']);
    final now = DateTime.now();

    if (reported != null && reported > 0) {
      final seconds = reported.clamp(0, 24 * 3600).toInt();
      if (updateAppState) {
        if (state == 'recording') {
          _recordingStartOffsetSeconds = seconds;
          _recordingStartedAt = now;
        } else if (state == 'paused') {
          _recordingStartOffsetSeconds = seconds;
          _recordingStartedAt = null;
        }
      }
      return seconds;
    }

    var seconds = 0;
    if (_recordingStartedAt != null) {
      seconds = _recordingStartOffsetSeconds;
      if (state == 'recording') {
        seconds += now.difference(_recordingStartedAt!).inSeconds;
      }
    }

    if (seconds <= 0) {
      final sessionStart = _parseSessionTimestamp(sessionId ?? '');
      if (sessionStart != null) {
        final inferred = now.difference(sessionStart).inSeconds;
        if (inferred >= 0 && inferred <= 24 * 3600) {
          seconds = inferred;
        }
      }
    }

    if (updateAppState) {
      if (state == 'recording') {
        if (seconds > 0) {
          _recordingStartOffsetSeconds = seconds.clamp(0, 24 * 3600).toInt();
          _recordingStartedAt = now;
        } else {
          _recordingStartedAt ??= now;
        }
      } else if (state == 'paused') {
        _recordingStartOffsetSeconds = seconds.clamp(0, 24 * 3600).toInt();
        _recordingStartedAt = null;
      }
    }

    if (seconds > 0) return seconds.clamp(0, 24 * 3600).toInt();
    return (reported ?? 0).clamp(0, 24 * 3600).toInt();
  }

  Future<RecStatus?> getRecordingStatus({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final at = _at;
    if (at == null) return null;
    return getRecordingStatusForAt(at, updateAppState: true, timeout: timeout);
  }

  Future<bool> _deviceAtAppearsRecordingOrPaused(AtTransport at) async {
    final rs = await getRecordingStatusForAt(at);
    if (rs == null) return false;
    return rs.state == 'recording' || rs.state == 'paused';
  }

  /// Best-effort single pass before [startRecording]: one [getRecordingStatus], then if needed
  /// STOP + short wait + **one** more GSTAT (or for paused, wait + one GSTAT). No retry loops.
  Future<bool> ensureIdle() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;

    try {
      var st = await getRecordingStatus();
      if (st == null) return false;
      if (st.state == 'idle') return true;

      if (st.state == 'recording') {
        try {
          await stopRecording();
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        st = await getRecordingStatus();
        return st?.state == 'idle';
      }

      if (st.state == 'transmitting') {
        try {
          // Short timeout: a busy (streaming) firmware won't ack in time and a
          // late cancel reply is now safely ignored by non-cancel AT waiters.
          await at.send('AT+CANCEL',
              timeout: const Duration(milliseconds: 1500));
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 600));
        st = await getRecordingStatus();
        return st?.state == 'idle';
      }

      // paused: no STOP here; give firmware a moment then one re-check.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      st = await getRecordingStatus();
      return st?.state == 'idle';
    } catch (_) {
      return false;
    }
  }

  String _recordingSessionFromStartResponse(Map<String, dynamic> resp) {
    final rootSession = (resp['session'] ?? '').toString().trim();
    final data = resp['data'];
    Map<String, dynamic> dataMap = const <String, dynamic>{};
    if (data is Map) {
      dataMap = Map<String, dynamic>.from(data);
    } else if (data is List && data.isNotEmpty && data.first is Map) {
      dataMap = Map<String, dynamic>.from(data.first as Map);
    }
    final dataSession =
        (dataMap['session'] ?? dataMap['id'] ?? dataMap['session_id'] ?? '')
            .toString()
            .trim();
    return dataSession.isNotEmpty ? dataSession : rootSession;
  }

  void _handleRecordingStartSession(
    SenseCraftVoiceConnection conn,
    String session, {
    required String logPrefix,
  }) {
    final sid = session.trim();
    if (sid.isEmpty) return;
    _activeRecordingSessionId = sid;
    final deviceId = conn.device.remoteId.toString();
    _bleTransferGuardRecordingId = '${deviceId}_$sid';
    if (liveRecordingBleSyncEnabled) {
      unawaited(_startLiveDownloadForDeviceInitiatedRecording(
        sessionId: sid,
      ));
    } else {
      AppLog.i(
        '$logPrefix: iOS recording-exclusive BLE mode - '
        'live download deferred until STOP',
      );
    }
  }

  Future<RecordingStartResult?> _adoptRecordingAfterStartIssue(
    SenseCraftVoiceConnection conn, {
    required String reason,
  }) async {
    RecordingStartResult? adoptLocal(String source) {
      final sid = (_activeRecordingSessionId ?? '').trim();
      final recState = state.firmwareRecState;
      if (sid.isEmpty || (recState != 'recording' && recState != 'paused')) {
        return null;
      }
      if (recState == 'recording') {
        _recordingStartedAt ??= DateTime.now();
      } else {
        _recordingStartedAt = null;
      }
      _setFirmwareRecState(recState);
      _adoptedRecordingDurationSecondsFromLastStart =
          activeRecordingDurationSeconds;
      _handleRecordingStartSession(
        conn,
        sid,
        logPrefix: 'startRecording',
      );
      AppLog.i(
        'startRecording: $reason, but device is already $recState '
        '(session=$sid, source=$source) - accepting',
      );
      return const RecordingStartResult.success();
    }

    final immediate = adoptLocal('cached-state');
    if (immediate != null) return immediate;

    // Give the unsolicited state event / real START ack a brief chance to
    // arrive after a busy iOS BLE transfer. This is intentionally short: the
    // UI has its own grace window, and we do not want to recreate the old
    // multi-second "tap record" stall.
    await Future<void>.delayed(const Duration(milliseconds: 650));
    final afterEvent = adoptLocal('state-event');
    if (afterEvent != null) return afterEvent;

    try {
      final st = await getRecordingStatus(
        timeout: const Duration(milliseconds: 1200),
      );
      if (st == null || (st.state != 'recording' && st.state != 'paused')) {
        return null;
      }
      final sid = (st.sessionId ?? _activeRecordingSessionId ?? '').trim();
      if (sid.isEmpty) return null;
      _activeRecordingSessionId = sid;
      final duration = st.durationSeconds;
      if (st.state == 'recording') {
        _resumeRecordingClock(
          sessionId: sid,
          reportedSeconds: duration > 0 ? duration : null,
        );
      } else {
        _freezeRecordingClock(
          sessionId: sid,
          reportedSeconds: duration > 0 ? duration : null,
        );
      }
      _setFirmwareRecState(st.state);
      _adoptedRecordingDurationSecondsFromLastStart = duration;
      _handleRecordingStartSession(
        conn,
        sid,
        logPrefix: 'startRecording',
      );
      AppLog.i(
        'startRecording: $reason, GSTAT shows ${st.state} '
        '(session=$sid, duration=${duration}s) - accepting',
      );
      return const RecordingStartResult.success();
    } catch (e, st) {
      AppLog.w(
        'startRecording: probe after START issue failed (non-fatal)',
        e,
        st,
      );
      return null;
    }
  }

  Future<RecordingStartResult> startRecording({String mode = 'normal'}) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return RecordingStartResult.failure();
    _bleTransferGuardForRecordingStart = true;
    _bleTransferGuardRecordingId = null;
    try {
      _adoptedRecordingDurationSecondsFromLastStart = null;

      // Stop BLE file transfer and device hotspot first; app-side Wi‑Fi Fast Sync is cancelled in UI before this.
      final transferStopped = await _stopBleTransferAndDeviceWifiForRecording();
      if (!transferStopped) {
        clearRecordingStartBleGuard();
        return RecordingStartResult.failure(
          atErrorMessage: 'BLE transfer is still stopping. Please try again.',
        );
      }

      // If firmware is already recording and session matches (or app has no active session), adopt — do not STOP + GSTAT spam.
      final pre = await getRecordingStatus(
        timeout: Platform.isIOS
            ? const Duration(milliseconds: 900)
            : const Duration(seconds: 3),
      );
      if (pre != null && pre.state == 'recording') {
        final devSid = (pre.sessionId ?? '').trim();
        if (devSid.isNotEmpty) {
          final appSid = (_activeRecordingSessionId ?? '').trim();
          if (appSid.isEmpty || appSid == devSid) {
            if (appSid.isEmpty) {
              _activeRecordingSessionId = devSid;
            }
            _setFirmwareRecState('recording');
            _adoptedRecordingDurationSecondsFromLastStart = pre.durationSeconds;
            AppLog.i(
              'startRecording: firmware already recording (session=$devSid), skip ensureIdle/START',
            );
            _handleRecordingStartSession(
              conn,
              devSid,
              logPrefix: 'startRecording',
            );
            // Android: guard stays on until live [downloadSessionToLocal] claims
            // the slot. iOS: guard stays on for the whole recording and is
            // cleared by STOP/IDLE.
            return const RecordingStartResult.success();
          }
        }
      }

      // [pre] is fresh from one GSTAT; if already idle, skip [ensureIdle] (avoids a second GSTAT + waits on the hot path).
      final idle = (pre != null && pre.state == 'idle')
          ? true
          : (Platform.isIOS && pre == null)
              ? true
              : await ensureIdle();
      if (!idle) {
        AppLog.w(
            'startRecording: device not idle after ensureIdle, proceeding anyway');
      }

      // Support normal/enhanced (aligned with Python record.py --mode).
      final firmwareMode = (mode == 'enhanced') ? 'enhanced' : 'normal';
      final startTimeout = Platform.isIOS
          ? const Duration(seconds: 8)
          : const Duration(seconds: 5);
      Map<String, dynamic> resp;
      try {
        resp = await _sendAtWithDisconnect(conn, at, 'AT+START=$firmwareMode',
            timeout: startTimeout);
      } catch (e, st) {
        if (Platform.isIOS) {
          final adopted = await _adoptRecordingAfterStartIssue(
            conn,
            reason: 'AT+START did not ack cleanly (${e.toString()})',
          );
          if (adopted != null) return adopted;
          AppLog.w('startRecording: AT+START failed on iOS', e, st);
          _bleTransferGuardForRecordingStart = false;
          _bleTransferGuardRecordingId = null;
          state = state.copyWith(error: e.toString());
          return RecordingStartResult.failure(atErrorMessage: e.toString());
        }
        resp = await _sendAtWithDisconnect(conn, at, 'AT+START',
            timeout: startTimeout);
      }
      if (AtTransport.looksLikeGstatOkReply(resp)) {
        final adopted = Platform.isIOS
            ? await _adoptRecordingAfterStartIssue(
                conn,
                reason: 'AT+START matched a GSTAT-shaped reply',
              )
            : null;
        if (adopted != null) return adopted;
        AppLog.w('startRecording: START matched GSTAT-shaped reply');
        _bleTransferGuardForRecordingStart = false;
        _bleTransferGuardRecordingId = null;
        return RecordingStartResult.failure(
          atErrorMessage: 'AT+START matched an unexpected GSTAT reply',
        );
      }
      final ok = resp['ok'] == true;
      if (!ok) {
        final msg = _recordingStartErrorMessageFromResponse(
            Map<String, dynamic>.from(resp));
        if (Platform.isIOS) {
          final adopted = await _adoptRecordingAfterStartIssue(
            conn,
            reason: 'AT+START replied ${msg ?? "ok=false"}',
          );
          if (adopted != null) return adopted;
        }
        AppLog.w('startRecording: START failed ($msg)');
        _bleTransferGuardForRecordingStart = false;
        _bleTransferGuardRecordingId = null;
        return RecordingStartResult.failure(atErrorMessage: msg);
      }
      _recordingStartedAt = DateTime.now();
      _recordingStartOffsetSeconds = 0;
      // Prefer session returned by AT+START. Some firmwares return at root; some in data; some wrap into list.
      final session = _recordingSessionFromStartResponse(resp);
      _setFirmwareRecState('recording');
      _handleRecordingStartSession(
        conn,
        session,
        logPrefix: 'startRecording',
      );
      // Android: guard remains true until live download claims the BLE slot.
      // iOS: guard remains true until STOP/IDLE so file transfer cannot
      // compete with recording controls.
      return const RecordingStartResult.success();
    } catch (e) {
      _bleTransferGuardForRecordingStart = false;
      _bleTransferGuardRecordingId = null;
      state = state.copyWith(error: e.toString());
      return RecordingStartResult.failure(atErrorMessage: e.toString());
    }
  }

  Future<bool> pauseRecording() => _pauseRecording();

  Future<bool> _pauseRecording({
    _RecordingClockSnapshot? optimisticPauseSnapshot,
  }) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) {
      _restoreOptimisticPauseClock(optimisticPauseSnapshot);
      return false;
    }
    final pauseSnapshot =
        optimisticPauseSnapshot ?? _beginOptimisticPauseClock();
    // iOS: free the link before AT+PAUSE for the same reason as AT+STOP/CANCEL —
    // a live record-while-transfer `fileData` flood keeps
    // `canSendWriteWithoutResponse` false so the write-without-response AT+PAUSE
    // never goes out → a "pause recording failed" toast. cancelTransfer (when a transfer is
    // registered) already does this, but cover the unmatched-flood case too.
    // Notify is re-enabled at the next download leg in [downloadSessionToLocal].
    await _disableFileDataNotifyToFreeBleLink(
      logContext: 'pauseRecording',
    );
    try {
      final pauseTimeout = Platform.isIOS
          ? const Duration(seconds: 8)
          : const Duration(seconds: 5);
      final resp = await _sendAtWithDisconnect(conn, at, 'AT+PAUSE',
          timeout: pauseTimeout);
      if (resp['ok'] == true) {
        if (AtTransport.looksLikeGstatOkReply(resp)) {
          final data = resp['data'];
          final dataMap = data is Map ? Map<String, dynamic>.from(data) : resp;
          final derived = _deriveRecStateFromGstatMap(dataMap);
          if (derived == 'paused') {
            final pauseSession =
                (dataMap['session'] ?? dataMap['session_id'] ?? '')
                    .toString()
                    .trim();
            final pauseDuration =
                _parseInt(dataMap['duration'] ?? dataMap['duration_s']);
            _freezeRecordingClock(
              sessionId: pauseSession.isNotEmpty ? pauseSession : null,
              reportedSeconds: pauseDuration,
            );
            _clearPauseCommandInFlightIfMatched(
                pauseSession.isNotEmpty ? pauseSession : null);
            _setFirmwareRecState('paused');
            return true;
          }
          AppLog.w(
            'pauseRecording: AT+PAUSE matched GSTAT-shaped notify, not pause ack '
            'keys=${resp.keys.toList()}',
          );
          state = state.copyWith(error: 'AT+PAUSE: unexpected GSTAT reply');
          _restoreOptimisticPauseClock(pauseSnapshot);
          return false;
        }
        final data = resp['data'];
        final dataMap = data is Map ? Map<String, dynamic>.from(data) : resp;
        final pauseSession = (dataMap['session'] ?? dataMap['session_id'] ?? '')
            .toString()
            .trim();
        final pauseDuration =
            _parseInt(dataMap['duration'] ?? dataMap['duration_s']);
        _freezeRecordingClock(
          sessionId: pauseSession.isNotEmpty ? pauseSession : null,
          reportedSeconds: pauseDuration,
        );
        _clearPauseCommandInFlightIfMatched(
            pauseSession.isNotEmpty ? pauseSession : null);
        _setFirmwareRecState('paused');
        return true;
      }
      state = state.copyWith(
          error: (resp['error'] ?? 'AT+PAUSE failed').toString());
      _restoreOptimisticPauseClock(pauseSnapshot);
      return false;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      _restoreOptimisticPauseClock(pauseSnapshot);
      return false;
    }
  }

  Future<bool> pauseRecordingWithSync(String recordingId) async {
    final conn = state.connection;
    if (conn == null) return false;
    final pauseSnapshot = _beginOptimisticPauseClock();
    // 1) If there is an active BLE pull, cancel it first (TRANSMITTING → RECORDING).
    // Only wait for the download leg when a transfer was actually registered.
    if (_transferForRecording(recordingId) != null) {
      final cancelled = await cancelTransfer(recordingId);
      if (cancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    return _pauseRecording(optimisticPauseSnapshot: pauseSnapshot);
  }

  Future<bool> resumeRecordingWithSync(String recordingId) async {
    final ok = await resumeRecording();
    if (!ok) return false;
    final conn = state.connection;
    if (conn == null) return true;
    final deviceId = conn.device.remoteId.toString();
    final recRepo = await ref.read(recordingsRepositoryProvider.future);
    final rec = await recRepo.getById(recordingId);
    if (rec == null) return true;
    final sessionId = (rec.devicePath).trim();
    if (sessionId.isEmpty) return true;
    String? startFile;
    int? totalFiles;
    try {
      final snap = await _getSessionInfoAndFileList(sessionId);
      if (snap != null) {
        final synced = _parseInt(snap.info['synced']) ?? 0;
        final deviceFiles = snap.files;
        final total = deviceFiles.isNotEmpty
            ? deviceFiles.length
            : (_parseInt(snap.info['files']) ?? 0);
        if (total > 0) totalFiles = total;
        if (synced > 0 && synced < total) {
          startFile = await _computeStartFileFromFirmwareSynced(
            deviceId: deviceId,
            sessionId: sessionId,
            synced: synced,
            effectiveTotal: total,
            logContext: 'resumeRecordingWithSync',
          );
        }
      }
      startFile ??= await _computeStartFileFromLocalParts(
        deviceId,
        sessionId,
        expectedTotalFiles: totalFiles,
      );
    } catch (_) {}
    unawaited(
      downloadSessionToLocal(
        recordingId: recordingId,
        sessionId: sessionId,
        expectedBytes: rec.expectedBytes,
        expectedTotalFiles: totalFiles,
        startFile: startFile,
        notifyOnComplete: true,
        continuous: true,
      ).catchError((Object e, StackTrace st) {
        AppLog.w(
          'DeviceController: resumeRecordingWithSync download failed',
          e,
          st,
        );
        return false;
      }),
    );
    return true;
  }

  Future<bool> resumeRecording() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;
    try {
      final resumeTimeout = Platform.isIOS
          ? const Duration(seconds: 8)
          : const Duration(seconds: 5);
      final resp = await _sendAtWithDisconnect(conn, at, 'AT+RESUME',
          timeout: resumeTimeout);
      if (resp['ok'] == true) {
        if (AtTransport.looksLikeGstatOkReply(resp)) {
          AppLog.w(
            'resumeRecording: AT+RESUME matched GSTAT-shaped notify, not resume ack '
            'keys=${resp.keys.toList()}',
          );
          state = state.copyWith(error: 'AT+RESUME: unexpected GSTAT reply');
          return false;
        }
        final data = resp['data'];
        final dataMap = data is Map ? Map<String, dynamic>.from(data) : resp;
        final resumeSession =
            (dataMap['session'] ?? dataMap['session_id'] ?? '')
                .toString()
                .trim();
        final resumeDuration =
            _parseInt(dataMap['duration'] ?? dataMap['duration_s']);
        _resumeRecordingClock(
          sessionId: resumeSession.isNotEmpty ? resumeSession : null,
          reportedSeconds: resumeDuration,
        );
        _setFirmwareRecState('recording');
        return true;
      }
      state = state.copyWith(
          error: (resp['error'] ?? 'AT+RESUME failed').toString());
      return false;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<RecStopResult?> stopRecording() async {
    final conn = state.connection;
    final at = _at;
    final fgId = conn?.device.remoteId.toString();
    final activeBefore = _activeRecordingSessionId;
    AppLog.i(
        'stopRecording: enter foreground=$fgId hasAt=${at != null} activeSess=$activeBefore');
    if (conn == null || at == null) {
      AppLog.w(
          'stopRecording: bail early — no foreground connection or transport');
      return null;
    }

    // Issue AT+STOP. Two failure modes feed into the "verify with GSTAT"
    // recovery path below:
    //   1. send threw (timeout / disconnect race / serial queue cancelled)
    //   2. firmware replied ok=false (commonly code 4005 = "Not currently
      //      recording", but we hit "stop recording failed" toasts in the wild whenever
    //      the firmware uses non-English or otherwise-worded errors that the
    //      keyword detector misses)
    // In both cases the real source of truth is the device's current state,
    // not the AT reply — so we re-probe with AT+GSTAT and treat "device is
    // already idle" as success. This eliminates spurious "stop failed" toasts
    // when the firmware actually finished the session (device-button STOP,
    // SD card / battery auto-stop, or any racy disconnect right after STOP).
    // Both platforms hit the same contention: while a live record-while-transfer
    // pull floods the `fileData` notify characteristic, the BLE link is saturated
    // so the AT+STOP reply (and on iOS the AT+STOP write itself) is delayed past
    // the timeout → spurious "stop recording failed" toast on every finish.
    //   • iOS: the command RX characteristic is WRITE-WITHOUT-RESPONSE only, and
    //     CoreBluetooth keeps `canSendWriteWithoutResponse` false under the flood,
    //     so AT+STOP is queued but never transmitted.
    //   • Android: AT+STOP writes fine but its JSON *reply* gets stuck behind the
    //     inbound fileData notify backlog and stopRecording() times out (8s).
    // Disable the `fileData` CCCD first (a reliable write-WITH-response descriptor
    // write) to free the link before AT+STOP. Notify is re-enabled at the next
    // download leg in [downloadSessionToLocal] (also un-gated for Android there).
    await _disableFileDataNotifyToFreeBleLink(logContext: 'stopRecording');

    Map<String, dynamic>? resp;
    Object? sendErr;
    StackTrace? sendStack;
    try {
      final stopTimeout = Platform.isIOS
          ? const Duration(seconds: 10)
          : const Duration(seconds: 8);
      resp = await _sendAtWithDisconnect(conn, at, 'AT+STOP',
          timeout: stopTimeout);
      AppLog.i(
          'stopRecording: AT+STOP reply ok=${resp['ok']} keys=${resp.keys.toList()}');
    } catch (e, st) {
      sendErr = e;
      sendStack = st;
      AppLog.w('stopRecording: AT+STOP send failed', e, st);
    }

    final ok = resp != null && resp['ok'] == true;

    if (!ok) {
      // 2a. firmware explicitly told us "already not recording" — common error
      // shape. Treat as success.
      if (resp != null &&
          _isNoActiveSessionStopResponse(Map<String, dynamic>.from(resp))) {
        AppLog.i(
            'stopRecording: AT+STOP returned not-recording error → treating as already-stopped');
        return _finalizeStopAsAlreadyIdle(activeBefore);
      }

      // 2b. send threw OR firmware ok=false (unknown msg). Verify with one
      // GSTAT. If firmware shows idle/transmitting, the user's intent ("stop
      // this recording") is satisfied no matter what the ack said.
      try {
        final stChk = await getRecordingStatus();
        if (stChk != null &&
            (stChk.state == 'idle' || stChk.state == 'transmitting')) {
          AppLog.i(
              'stopRecording: AT+STOP failed/errored but GSTAT shows ${stChk.state} → treating as already-stopped');
          return _finalizeStopAsAlreadyIdle(activeBefore, stOverride: stChk);
        }
        AppLog.w(
            'stopRecording: AT+STOP failed and GSTAT still shows ${stChk?.state ?? "null"} → reporting failure');
      } catch (e, st) {
        AppLog.w(
            'stopRecording: verify-GSTAT after STOP failure also threw', e, st);
      }

      if (sendErr != null) {
        state = state.copyWith(error: sendErr.toString());
        AppLog.w('stopRecording: returning null after send error', sendErr,
            sendStack);
      } else {
        AppLog.w(
            'stopRecording: returning null — AT+STOP ok=false and firmware still active');
      }
      return null;
    }

    // ok=true success path
    final data = resp['data'];
    final dataMap = data is Map
        ? Map<String, dynamic>.from(data)
        : const <String, dynamic>{};
    final dur = _parseInt(dataMap['duration']) ?? 0;
    final size =
        _parseInt(dataMap['total_size']) ?? _parseInt(dataMap['size']) ?? 0;
    final rootSession = (resp['session'] ?? '').toString().trim();
    final dataSession = (dataMap['session'] ?? '').toString().trim();
    var session = (_activeRecordingSessionId ?? '').trim();
    if (session.isEmpty) {
      session = dataSession.isNotEmpty ? dataSession : rootSession;
    }
    _recordingStartedAt = null;
    _recordingStartOffsetSeconds = 0;
    _activeRecordingSessionId = null;
    _setFirmwareRecState('idle');
    _prevDerivedRecStateForDeferredResume = 'idle';
    final stopDeviceId = state.connection?.device.remoteId.toString();
    if (stopDeviceId != null) {
      _noteDeviceSessionRootPresent(stopDeviceId, session);
    }
    _onRecordingStoppedForTransfer(session);
    _deferBleResumeAfterRecordingStop(sessionId: session);
    AppLog.i(
        'stopRecording: success session=$session duration=${dur}s size=${size}B');
    return RecStopResult(
        file: session.isEmpty ? null : session,
        durationSeconds: dur,
        sizeBytes: size);
  }

  /// Shared finalizer for the two paths where AT+STOP didn't succeed cleanly
  /// but the device is already idle (so the user's "stop this recording"
  /// intent is satisfied): either firmware explicitly returned a
  /// "not recording" error, or AT+STOP itself failed but a follow-up GSTAT
  /// showed the device is no longer recording.
  ///
  /// Resolves the session id from [activeBefore] → fresh GSTAT → AT+LIST
  /// fallback so downstream UI / transfer pipeline can still look up the
  /// correct row to start the post-stop transfer.
  Future<RecStopResult> _finalizeStopAsAlreadyIdle(
    String? activeBefore, {
    RecStatus? stOverride,
  }) async {
    _recordingStartedAt = null;
    _recordingStartOffsetSeconds = 0;
    RecStatus? st = stOverride;
    if (st == null) {
      try {
        st = await getRecordingStatus();
      } catch (_) {}
    }
    var session = (activeBefore ?? _activeRecordingSessionId ?? '').trim();
    var dur = st?.durationSeconds ?? 0;
    if (session.isEmpty) {
      final sid = (st?.sessionId ?? '').trim();
      if (sid.isNotEmpty) session = sid;
    }
    if (session.isEmpty) {
      session = (await getLatestSessionId() ?? '').trim();
    }
    if (st == null) {
      _setFirmwareRecState('idle');
      _prevDerivedRecStateForDeferredResume = 'idle';
    }
    _activeRecordingSessionId = null;
    _onRecordingStoppedForTransfer(session);
    _deferBleResumeAfterRecordingStop(sessionId: session);
    return RecStopResult(
      file: session.isEmpty ? null : session,
      durationSeconds: dur,
      sizeBytes: 0,
    );
  }

  /// Best-effort: query the latest session id from `AT+LIST`.
  ///
  /// This is used as a fallback when `AT+STOP` doesn't return `session`.
  Future<String?> getLatestSessionId() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return null;
    try {
      // The firmware may need a short time after STOP to finalize session metadata.
      // Python scripts often wait ~1s before LIST; we instead retry a few times here.
      Map<String, dynamic> resp = const <String, dynamic>{};
      List<String> ids = const <String>[];

      List<String> extractIds(Map<String, dynamic> r) {
        Object? data = r['data'] ?? r['sessions'] ?? r['list'];
        // Unwrap common nesting: {"data":{"sessions":[...]}} — never fall back to raw `m`
        // (that may be GSTAT-shaped JSON; Map.toString() became a bogus "session id").
        if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          final next = m['sessions'] ?? m['items'] ?? m['data'];
          data = next ?? m;
        }

        final out = <String>[];
        void addId(Object? v) {
          final s = (v ?? '').toString().trim();
          if (s.isNotEmpty) out.add(s);
        }

        if (data is List) {
          for (final e in data) {
            if (e is Map) {
              addId(e['id'] ?? e['session'] ?? e['session_id']);
            } else {
              addId(e);
            }
          }
        } else if (data is Map) {
          final m = Map<String, dynamic>.from(data);
          if (_mapLooksLikeGstatOrListStatsPayload(m)) {
            return out;
          }
          // Sometimes the list is under a key even after unwrap.
          final innerList = m['sessions'] ?? m['items'];
          if (innerList is List) {
            for (final e in innerList) {
              if (e is Map) addId(e['id'] ?? e['session'] ?? e['session_id']);
            }
          } else {
            addId(m['id'] ?? m['session'] ?? m['session_id']);
          }
        } else {
          // allow "a,b,c" fallback
          for (final s in _parseStringList(data)) {
            addId(s);
          }
        }
        return out;
      }

      for (var attempt = 0; attempt < 3; attempt++) {
        ids = [];
        var page = 1;
        while (true) {
          final cmd = page == 1 ? 'AT+LIST' : 'AT+LIST?$page&$_listPerPage';
          resp = await _sendAtWithDisconnect(conn, at, cmd,
              timeout: const Duration(seconds: 10));
          if (resp['ok'] != true && page == 1 && attempt == 0) {
            try {
              resp = await _sendAtWithDisconnect(conn, at, 'AT+LIST?',
                  timeout: const Duration(seconds: 10));
            } catch (_) {}
          }
          if (resp['ok'] != true) break;
          final parsed = extractIds(resp);
          ids = [...ids, ...parsed];
          final data = resp['data'];
          final total = _parseTotalFromListResponse(data);
          if (parsed.isEmpty) break;
          if (total != null && ids.length >= total) break;
          final perHint = _parsePerPageFromListResponse(data);
          final effectivePerPage = perHint ?? _listPerPage;
          if (parsed.length < effectivePerPage) break;
          page++;
        }
        if (ids.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      if (ids.isEmpty) return null;

      // Prefer ids that look like "YYYYMMDD_HHMMSS".
      final candidates =
          ids.where((s) => RegExp(r'^\d{8}_\d{6}$').hasMatch(s)).toList();
      final pool = candidates.isNotEmpty ? candidates : ids;

      // Pick the max timestamp if parsable; else last one.
      DateTime? bestTs;
      String best = pool.last;
      for (final s in pool) {
        final ts = _parseSessionTimestamp(s);
        if (ts == null) continue;
        if (bestTs == null || ts.isAfter(bestTs)) {
          bestTs = ts;
          best = s;
        }
      }
      return best.trim().isEmpty ? null : best;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  Future<Map<String, int>?> getSessionInfo(String sessionId) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return null;
    try {
      final resp = await _sendAtWithDisconnect(conn, at, 'AT+LIST=$sessionId',
          timeout: const Duration(seconds: 8));
      if (resp['ok'] != true) return null;
      final data = resp['data'];
      if (data == null) return null;
      if (data is Map) {
        final m = Map<String, dynamic>.from(data);
        return {
          'files': _parseInt(m['files']) ?? 0,
          'size': _parseInt(m['size']) ?? 0,
          'synced': _parseInt(m['synced']) ?? 0,
        };
      }
      if (data is List) {
        return {'files': data.length, 'size': 0, 'synced': 0};
      }
      return null;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// Send `AT+MARK` to add a bookmark at the current recording position.
  ///
  /// Per `protocol.md` 3.3.2 / Appendix E.5, the firmware also emits an
  /// `event:"mark"` notify after the ack — the controller flags this call
  /// so the resulting [DeviceBookmarkNotice] is attributed to the App
  /// (rather than the device button) for UI purposes.
  Future<bool> markRecording({String? note}) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;
    final cmd = (note != null && note.trim().isNotEmpty)
        ? 'AT+MARK=${note.trim()}'
        : 'AT+MARK';
    try {
      _appInitiatedMarkPending = true;
      // iOS: same write-without-response starvation as AT+STOP/AT+CANCEL.
      // During a live record-while-transfer pull the `fileData` flood keeps
      // CoreBluetooth's `canSendWriteWithoutResponse` false, so AT+MARK is
      // queued and transmitted late (acks observed climbing 248ms→2s under
      // load). A 3s timeout abandons the command prematurely → markRecording
      // returns false → UI shows "not ready" even though the firmware later
      // registers the bookmark. Use a generous timeout so the queued write
      // still completes; the notify-based fallback covers any lost ack.
      final markTimeout = Platform.isIOS
          ? const Duration(seconds: 10)
          : const Duration(seconds: 3);
      final resp = await _sendAtWithDisconnect(conn, at, cmd,
          timeout: markTimeout);
      final ok = resp['ok'] == true;
      if (!ok) {
        // Notify never arrived; clear the hint so the next bookmark notify
        // (which will be device-button driven) is correctly attributed.
        _appInitiatedMarkPending = false;
      }
      return ok;
    } catch (e) {
      _appInitiatedMarkPending = false;
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> downloadSessionToLocal({
    required String recordingId,
    required String sessionId,
    int? expectedBytes,
    int? expectedTotalFiles,
    String? startFile,
    bool deleteAfterSync = true,
    bool notifyOnComplete = true,
    bool continuous = false,

    /// When [true], allowed while [_bleTransferGuardForRecordingStart] is on (new session live pull only).
    bool allowDuringRecordingStartGuard = false,
  }) async {
    final initialConn = state.connection;
    final initialAt = _at;
    if (initialConn == null || initialAt == null) return false;
    if (_bleTransferGuardForRecordingStart) {
      await _clearRecordingStartGuardIfDeviceIdle(
        source: 'downloadSessionToLocal',
      );
    }
    if (!liveRecordingBleSyncEnabled &&
        (((_activeRecordingSessionId ?? '').trim().isNotEmpty) ||
            state.firmwareAppearsRecordingOrPaused)) {
      AppLog.i(
        'downloadSessionToLocal: skip $recordingId '
        '(iOS recording-exclusive BLE mode active)',
      );
      return false;
    }
    if (_wifiHandoffActive) {
      AppLog.i(
        'downloadSessionToLocal: skip $recordingId (Wi‑Fi handoff active for $_wifiHandoffRecordingId)',
      );
      _clearRecordingStartBleGuardIfLivePullAborted(
        allowDuringRecordingStartGuard,
        recordingId: recordingId,
      );
      return false;
    }
    if (!_recordingStartGuardAllows(
      recordingId: recordingId,
      allowDuringRecordingStartGuard: allowDuringRecordingStartGuard,
    )) {
      AppLog.w(
        'downloadSessionToLocal: blocked (recording start guard) '
        'recordingId=$recordingId target=${_bleTransferGuardRecordingId ?? "(pending)"} '
        'allow=$allowDuringRecordingStartGuard',
      );
      return false;
    }
    if (!_isPlausibleBleSessionId(sessionId)) {
      AppLog.e(
        'downloadSessionToLocal: refuse AT+DOWNLOAD — invalid sessionId (likely bad LIST parse in DB): '
        '${sessionId.length > 120 ? "${sessionId.substring(0, 120)}…" : sessionId}',
      );
      final recRepoEarly = await ref.read(recordingsRepositoryProvider.future);
      await recRepoEarly.updateTransfer(
        id: recordingId,
        state: 'transferring',
        errorCode: 'invalid_session_id',
        error:
            'Invalid session id stored for this recording (device list parse). Try re-sync from device list.',
        recordingState: 'transferring',
      );
      bumpRecordingsLists(ref);
      ref.invalidate(recordingByIdProvider(recordingId));
      _clearRecordingStartBleGuardIfLivePullAborted(
        allowDuringRecordingStartGuard,
        recordingId: recordingId,
      );
      return false;
    }
    await _yieldBackgroundTransfersToForeground();
    final chainDeviceId = initialConn.device.remoteId.toString();
    final prevBleDownload = _bleDownloadExclusiveChainByDevice[chainDeviceId] ??
        Future<void>.value();
    final bleDownloadGate = Completer<void>();
    final chainFuture = bleDownloadGate.future;
    _bleDownloadExclusiveChainByDevice[chainDeviceId] = chainFuture;
    await prevBleDownload;
    // Re-bind link after chain wait: a caller may have passed the entry check
    // before GATT dropped, then queued behind an in-flight download that ended
    // on disconnect — do not send AT+DOWNLOAD with stale conn/at.
    final connAfterWait = state.connection;
    final atAfterWait = _at;
    if (connAfterWait == null ||
        atAfterWait == null ||
        connAfterWait.device.remoteId.toString() != chainDeviceId) {
      AppLog.i(
        'downloadSessionToLocal: skip $recordingId after BLE chain wait (link gone)',
      );
      _clearRecordingStartBleGuardIfLivePullAborted(
        allowDuringRecordingStartGuard,
        recordingId: recordingId,
      );
      bleDownloadGate.complete();
      if (_bleDownloadExclusiveChainByDevice[chainDeviceId] == chainFuture) {
        _bleDownloadExclusiveChainByDevice.remove(chainDeviceId);
      }
      return false;
    }
    final conn = connAfterWait;
    final at = atAfterWait;
    if (!_recordingStartGuardAllows(
      recordingId: recordingId,
      allowDuringRecordingStartGuard: allowDuringRecordingStartGuard,
    )) {
      AppLog.w(
        'downloadSessionToLocal: skip $recordingId after BLE chain wait '
        '(recording start guard target=${_bleTransferGuardRecordingId ?? "(pending)"}, '
        'allow=$allowDuringRecordingStartGuard)',
      );
      bleDownloadGate.complete();
      if (_bleDownloadExclusiveChainByDevice[chainDeviceId] == chainFuture) {
        _bleDownloadExclusiveChainByDevice.remove(chainDeviceId);
      }
      return false;
    }
    // Re-check Wi‑Fi handoff AFTER the chain await: a caller that passed the entry check
    // before [startWifiHandoff] could otherwise wake here once the previous BLE leg
    // finished and fire a fresh `AT+DOWNLOAD` over BLE while the Wi‑Fi flow is bringing
    // up the AP. The firmware then rejects the UDP `AT+DOWNLOAD` with
    // `transfer already in progress`, which surfaces as Wi‑Fi "stuck at 100%, no rate".
    if (_wifiHandoffActive) {
      AppLog.i(
        'downloadSessionToLocal: skip $recordingId after BLE chain wait '
        '(Wi‑Fi handoff active for $_wifiHandoffRecordingId)',
      );
      _clearRecordingStartBleGuardIfLivePullAborted(
        allowDuringRecordingStartGuard,
        recordingId: recordingId,
      );
      bleDownloadGate.complete();
      if (_bleDownloadExclusiveChainByDevice[chainDeviceId] == chainFuture) {
        _bleDownloadExclusiveChainByDevice.remove(chainDeviceId);
      }
      return false;
    }
    // When true, firmware may still be draining after AT+CANCEL (async on device); delay before
    // [bleDownloadGate.complete] so the next AT+DOWNLOAD does not get "Transfer already in progress".
    var deferBleChainReleaseForFirmwareCancel = false;
    try {
      SentryService.breadcrumb(
        'BLE download started',
        category: 'transfer',
        data: {
          'recording_id': recordingId,
          'session_id': sessionId,
          if (startFile != null) 'start_file': startFile,
        },
      );
      final effectiveDeleteAfterSync = deleteAfterSync;
      final deviceId = conn.device.remoteId.toString();
      final recRepo = TransferRecordingsRepository(ref);
      final startedAt = DateTime.now();

      Directory sessionDir;
      try {
        sessionDir =
            Directory(await _deviceSessionDirectory(deviceId, sessionId));
        await sessionDir.create(recursive: true);
      } catch (e) {
        await recRepo.updateTransfer(
          id: recordingId,
          state: 'failed',
          error: e.toString(),
          errorCode: 'create_local_dir_failed',
        );
        _clearRecordingStartBleGuardIfLivePullAborted(
          allowDuringRecordingStartGuard,
          recordingId: recordingId,
        );
        return false;
      }
      var effectiveStartFile = startFile;
      var initialReceived = 0;
      var initialFileCount = 0;
      final existingRowEarly = await recRepo.getById(recordingId);
      if (existingRowEarly?.transferState == 'done') {
        AppLog.i(
          'downloadSessionToLocal: skip — recording already done id=$recordingId',
        );
        return true;
      }
      if (await tryCompleteTransferFromLocalPartsIfReady(recordingId)) {
        return true;
      }
      if ((effectiveStartFile == null || effectiveStartFile.trim().isEmpty) &&
          (existingRowEarly?.receivedBytes ?? 0) > 0) {
        effectiveStartFile = await _computeStartFileFromLocalParts(
          deviceId,
          sessionId,
          expectedTotalFiles: expectedTotalFiles,
        );
        if (effectiveStartFile != null) {
          AppLog.i(
            'downloadSessionToLocal: resume startFile=$effectiveStartFile '
            '(received=${existingRowEarly?.receivedBytes ?? 0} in DB)',
          );
        }
      }
      if (effectiveStartFile != null && effectiveStartFile.isNotEmpty) {
        final startNum = _partNumberFromFilename(effectiveStartFile);
        final init = await _computeInitialReceivedFromLocalParts(
            sessionDir, effectiveStartFile);
        initialReceived = init.bytes;
        initialFileCount = init.fileCount;
        if (startNum != null &&
            startNum > 1 &&
            (initialReceived == 0 || initialFileCount == 0)) {
          final preservedReceived = existingRowEarly?.receivedBytes ?? 0;
          if (preservedReceived > 0) {
            AppLog.w(
              'downloadSessionToLocal: startFile=$effectiveStartFile but no local parts yet '
              '(initialReceived=$initialReceived) — keep resume file (do not restart 0001)',
            );
          } else {
            AppLog.w(
                'downloadSessionToLocal: startFile=$effectiveStartFile but no local parts (initialReceived=$initialReceived), falling back to 0001.opus');
            effectiveStartFile = '0001.opus';
            try {
              for (final f in sessionDir.listSync().whereType<File>()) {
                final name = p.basename(f.path).toLowerCase();
                if (name.endsWith('.opus') || name.endsWith('.opus.part')) {
                  await f.delete();
                }
              }
            } catch (e) {
              AppLog.w(
                  'downloadSessionToLocal: clear session dir failed (non-fatal)',
                  e);
            }
          }
        } else if (initialReceived > 0 || initialFileCount > 0) {
          AppLog.i(
              'downloadSessionToLocal: resume from $startFile, initialReceived=$initialReceived initialFileCount=$initialFileCount');
        }
      }

      int received = initialReceived;
      int fileIndex = 0;
      bool downloading = false;
      var fileCompleteCount = initialFileCount;
      var lastDataAt = DateTime.now();
      Timer? watchdog;

      /// Set when continuous BLE pull idles ≥3 minutes: end leg without merge, prompt user to resync.
      var stalledNoData3MinLeg = false;

      /// Cache expectedBytes to avoid frequent getById during transfer; DB may close in background and getById throws database_closed.
      var cachedExpectedBytes = expectedBytes;
      final bleFrameState = BleTransferFrameState()
        ..fileCompleteCount = fileCompleteCount;

      File? currentTmp;
      IOSink? currentSink;

      /// Rename tmp to out; fallback to copy+delete when rename fails (e.g. iOS cross-volume).
      Future<void> renameOrCopyPart(File tmp, File out) async {
        try {
          await tmp.rename(out.path);
        } catch (e) {
          if (e is PathNotFoundException ||
              e.toString().contains('No such file')) {
            rethrow;
          }
          // Fallback: copy then delete (e.g. rename fails on some iOS configs).
          try {
            await tmp.copy(out.path);
            await tmp.delete();
          } catch (_) {
            rethrow;
          }
        }
      }

      Future<void> openNewTmp() async {
        await currentSink?.flush();
        await currentSink?.close();
        currentSink = null;
        currentTmp = null;
        // Use an extension that we can merge even if firmware never sends file_complete.
        final tmp = File(p.join(sessionDir.path,
            '_part_${DateTime.now().microsecondsSinceEpoch}_$fileIndex.opus.part'));
        fileIndex++;
        currentTmp = tmp;
        currentSink = tmp.openWrite(mode: FileMode.writeOnlyAppend);
      }

      Future<void> finalizeCurrentFile(String filename) async {
        final tmp = currentTmp;
        if (tmp == null) return;
        await currentSink?.flush();
        await currentSink?.close();
        currentSink = null;

        // If no bytes were written, just delete tmp.
        final len = await tmp.length();
        if (len <= 0) {
          try {
            await tmp.delete();
          } catch (_) {}
          currentTmp = null;
          return;
        }

        // Ensure we always end up with a .opus part on disk for merging.
        final fallbackName =
            'part_${fileIndex.toString().padLeft(4, '0')}.opus';
        var outName = filename.isEmpty ? fallbackName : filename;
        if (!outName.toLowerCase().endsWith('.opus')) {
          outName = '$outName.opus';
        }
        final safe = BleTransferFrameHandler.sanitizeFilename(outName);
        final out = File(p.join(sessionDir.path, safe));
        AppLog.i(
            'downloadSessionToLocal: slice file saved name="$safe" bytes=$len');

        // After IOSink.close(), some devices need longer than 50ms before the file is
        // visible for rename; otherwise we drop the whole slice (e.g. missing 0003.opus → short merge).
        // iOS exhibits the same write-behind lag as Android, so give both 200ms.
        final initialSettleMs = (Platform.isAndroid || Platform.isIOS) ? 200 : 50;
        await Future<void>.delayed(Duration(milliseconds: initialSettleMs));
        for (var attempt = 0; attempt < 5; attempt++) {
          if (await tmp.exists()) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (attempt == 4) {
            AppLog.w(
              'downloadSessionToLocal: tmp file missing before rename path=${tmp.path} '
              '(slice bytes=$len) — slice lost; try re-sync session',
            );
            currentTmp = null;
            return;
          }
        }

        try {
          if (await out.exists()) {
            // Avoid overwriting: append a suffix.
            final base = p.basenameWithoutExtension(safe);
            final ext = p.extension(safe);
            final alt = File(p.join(sessionDir.path,
                '${base}_${DateTime.now().millisecondsSinceEpoch}$ext'));
            await renameOrCopyPart(tmp, alt);
          } else {
            await renameOrCopyPart(tmp, out);
          }
        } catch (e) {
          // If rename fails, keep tmp as-is (still mergeable by extension check below).
          AppLog.w('downloadSessionToLocal: rename part failed', e,
              StackTrace.current);
        } finally {
          currentTmp = null;
        }
      }

      // Serialize throttled progress writes (same pattern as Wi‑Fi). Declared
      // before [mergeAllParts] / download try so both can drain the chain.
      var progressWriteChain = Future<void>.value();

      Future<bool> mergeAllParts({int? expectedTotalFiles}) async {
        await progressWriteChain;
        final queue = ref.read(sessionMergeQueueProvider);
        final enqueued = await queue.enqueue(SessionMergeJob(
          recordingId: recordingId,
          deviceId: deviceId,
          sessionId: sessionId,
          receivedBytes: received,
          expectedBytes: cachedExpectedBytes ?? expectedBytes,
          transferStartedAt: startedAt,
          deleteAfterSync: effectiveDeleteAfterSync,
          notifyOnComplete: notifyOnComplete,
          strictSliceValidation: true,
          source: 'ble',
          expectedTotalFiles:
              (expectedTotalFiles != null && expectedTotalFiles > 1)
                  ? expectedTotalFiles
                  : null,
        ));
        if (enqueued) {
          suppressBleResumeAfterWifiFastSync(
            recordingId,
            ttl: const Duration(seconds: 15),
          );
        }
        return enqueued;
      }

      if (continuous) {
        final activeId = _activeTransferRecordingId;
        if (activeId != null && activeId != recordingId) {
          final targetRoot = _normalizeRecordingSessionRoot(sessionId);
          final recStatus = await getRecordingStatusForAt(at);
          final liveRoot = _normalizeRecordingSessionRoot(recStatus?.sessionId);
          if (recStatus != null &&
              (recStatus.state == 'recording' || recStatus.state == 'paused') &&
              liveRoot.isNotEmpty &&
              targetRoot.isNotEmpty &&
              targetRoot != liveRoot) {
            final activeRec = await recRepo.getById(activeId);
            if (activeRec != null) {
              final activeRecRoot =
                  _normalizeRecordingSessionRoot(activeRec.devicePath);
              if (activeRecRoot == liveRoot) {
                AppLog.w(
                  'downloadSessionToLocal: block preempting live sessionRoot=$liveRoot '
                  'transfer ($activeId) for other sessionRoot=$targetRoot',
                );
                _clearRecordingStartBleGuardIfLivePullAborted(
                  allowDuringRecordingStartGuard,
                  recordingId: recordingId,
                );
                return false;
              }
            }
          }
          AppLog.i(
            'downloadSessionToLocal: pausing transfer $activeId (recording $sessionId takes priority)',
          );
          final cancelled = await cancelTransfer(activeId);
          if (cancelled) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
      }
      final initialProgress =
          _transferProgressOrNull(initialReceived, expectedBytes);
      final existingRow = await recRepo.getById(recordingId);
      final preservedReceived = existingRow?.receivedBytes ?? 0;
      // DB `receivedBytes` can accumulate across Wi‑Fi/BLE legs and exceed the
      // session size. Reconcile with on-disk bytes and cap at expected so the UI
      // does not jump to "merging" while slices are still missing.
      final expForSeed = expectedBytes ??
          cachedExpectedBytes ??
          existingRow?.expectedBytes ??
          0;
      final preservedTooHigh =
          expForSeed > 0 && preservedReceived > expForSeed * 1.05;
      final writeReceived = _reconcileTransferReceivedBytes(
        preserved: preservedTooHigh ? 0 : preservedReceived,
        local: initialReceived,
        expected: expForSeed,
      );
      var writeProgress = initialProgress;
      if ((writeProgress ?? 0) < 0.01 && writeReceived > 0) {
        final exp =
            expectedBytes ?? cachedExpectedBytes ?? existingRow?.expectedBytes;
        writeProgress = _transferProgressOrNull(writeReceived, exp) ??
            existingRow?.transferProgress;
      }
      await recRepo.updateTransfer(
        id: recordingId,
        state: 'transferring',
        progress: writeProgress,
        receivedBytes: writeReceived,
        expectedBytes:
            expectedBytes != null && expectedBytes > 0 ? expectedBytes : null,
        sizeBytes: expectedBytes != null && expectedBytes > 0
            ? expectedBytes
            : existingRow?.sizeBytes,
        error: '',
        errorCode: '',
        mtu: state.mtu,
        transferStartedAt: startedAt,
        recordingState: 'transferring',
      );
      bumpRecordingsLists(ref);
      ref.invalidate(recordingByIdProvider(recordingId));
      received = writeReceived;

      if (allowDuringRecordingStartGuard &&
          _bleTransferGuardForRecordingStart &&
          _isRecordingStartGuardTarget(recordingId)) {
        _bleTransferGuardForRecordingStart = false;
        _bleTransferGuardRecordingId = null;
        AppLog.d(
          'downloadSessionToLocal: recording-start guard released, claiming BLE slot for $recordingId',
        );
      }
      // Phase 2 — per-device transfer context. `myTransfer` is the single
      // source of truth for cancel/wait state for THIS download loop; the
      // legacy `_activeTransferRecordingId` field is just a foreground UI
      // mirror updated by `_registerTransfer`. After demote-to-background
      // the mirror clears but `myTransfer` keeps running on its own at/conn
      // (captured at the top of this function), so the loop can finish in
      // the background while the user works on a different device.
      final ownerDeviceId = conn.device.remoteId.toString();
      final myTransfer = _registerTransfer(
        deviceId: ownerDeviceId,
        recordingId: recordingId,
      );
      myTransfer.lastDataAt = lastDataAt;
      void touchLastDataAt() {
        final now = DateTime.now();
        lastDataAt = now;
        myTransfer.lastDataAt = now;
      }
      final pullSessionRoot = _normalizeRecordingSessionRoot(sessionId);
      unawaited(_persistConnectedOnline());
      var cancelTransferReason = 'user_cancelled';
      var deviceReportedIdle = false;

      bool transferEventSessionMatches(String? eventSession, String label) {
        final eventRoot = _normalizeRecordingSessionRoot(eventSession);
        if (eventRoot.isEmpty ||
            pullSessionRoot.isEmpty ||
            eventRoot == pullSessionRoot) {
          return true;
        }
        AppLog.w(
          'downloadSessionToLocal: ignore $label for sessionRoot=$eventRoot '
          '(pull sessionRoot=$pullSessionRoot)',
        );
        return false;
      }

      void resetBleFrameAssemblyForIgnoredNotify() {
        bleFrameState.currentFilename = null;
        bleFrameState.currentFileDeclaredSize = 0;
        bleFrameState.bytesThisFile = 0;
        bleFrameState.fileCrc = 0;
        bleFrameState.nextSeq = 0;
      }

      Future<void> probeDeviceIdleForContinuousLeg() async {
        if (!continuous) return;
        try {
          final recSt = await getRecordingStatusForAt(at);
          if (recSt == null || recSt.state != 'idle') return;
          final liveRoot = _normalizeRecordingSessionRoot(recSt.sessionId);
          final ourRoot = _normalizeRecordingSessionRoot(sessionId);
          final sessionMatches =
              ourRoot.isEmpty || liveRoot.isEmpty || liveRoot == ourRoot;
          if (sessionMatches) {
            deviceReportedIdle = true;
            myTransfer.sessionEndedOnDevice = true;
            AppLog.i(
              'downloadSessionToLocal: GSTAT idle at leg start (session=$sessionId) — '
              'shorter finish threshold',
            );
          }
        } catch (e, st) {
          AppLog.w(
            'downloadSessionToLocal: GSTAT idle probe failed (non-fatal): $e',
            e,
            st,
          );
        }
      }

      var lastProgressInvalidateAt = DateTime.now();
      var lastInvalidatedProgress = initialProgress ?? 0.0;

      /// Last [received] value written to DB from stream (avoids spamming SQLite).
      var lastDbProgressReceived = initialReceived;
      var lastDbProgressAt = DateTime.now();
      // Throttle the per-notification "is this download still needed?" DB probe.
      // Reading SQLite on EVERY BLE notify serializes the notify chain behind a
      // platform-channel round-trip; on iOS that round-trip is slow enough to
      // backpressure the link all the way to the firmware (≈halved throughput).
      // The probe only needs to catch the rare case where the row flipped to
      // `done` via another path — checking a few times per second is plenty,
      // and once it trips it sets `cancelRequested`, which short-circuits every
      // later packet at the top of the chain anyway.
      var lastStillNeededCheckAt =
          DateTime.now().subtract(const Duration(seconds: 5));
      StreamSubscription<List<int>>? fileSub;
      StreamSubscription<Map<String, dynamic>>? jsonSub;
      final progressRefreshTimer =
          Timer.periodic(const Duration(seconds: 3), (_) {
        // Background-running transfer: still bump lists so the recordings
        // page progress bar moves for THIS row even if it's not the
        // foreground device. We just skip the `recordingByIdProvider`
        // invalidate when this isn't the foreground row (avoids needless
        // rebuild on details page of a different device).
        if (_transferForDevice(ownerDeviceId)?.recordingId != recordingId) {
          return;
        }
        bumpRecordingsLists(ref);
        if (state.connection?.device.remoteId.toString() == ownerDeviceId) {
          ref.invalidate(recordingByIdProvider(recordingId));
        }
      });
      final disconnectPair = debouncedDisconnectFuture(conn.device,
          debounce: const Duration(milliseconds: 500));
      final transferStartedAt = DateTime.now();
      Timer? progressLogTimer;
      if (continuous) {
        progressLogTimer = Timer.periodic(const Duration(seconds: 60), (_) {
          if (!downloading) return;
          final elapsed =
              DateTime.now().difference(transferStartedAt).inSeconds;
          final idleSec = DateTime.now().difference(lastDataAt).inSeconds;
          AppLog.i(
            'downloadSessionToLocal: progress received=$received fileCompleteCount=$fileCompleteCount '
            'elapsed=${elapsed}s idle=${idleSec}s expectedBytes=$expectedBytes',
          );
        });
      }

      try {
        await openNewTmp();
        // Wi‑Fi–aligned progress: filled from each AT+DOWNLOAD `data` (files / bytes|size).
        // Declared before [reportReceiveProgressAfterAdd] so the closure can capture them.
        final seededDeviceTotalFiles =
            expectedTotalFiles != null && expectedTotalFiles > 0
                ? expectedTotalFiles
                : 0;
        var bleXferDeviceTotalFiles = seededDeviceTotalFiles;
        var bleXferDeviceTotalFilesReliable = seededDeviceTotalFiles > 0;
        var bleXferDeviceSessionBytes = 0;

        Future<void> reportReceiveProgressAfterAdd(int chunkLen) async {
          if (chunkLen <= 0) return;
          // Throttle DB writes: at least 8 KiB new bytes or 250ms since last write
          // (aligned with Wi‑Fi).
          final now = DateTime.now();
          const minBytesStep = 8192;
          const minInterval = Duration(milliseconds: 250);
          if (received - lastDbProgressReceived < minBytesStep &&
              now.difference(lastDbProgressAt) < minInterval) {
            return;
          }
          lastDbProgressReceived = received;
          lastDbProgressAt = now;
          final snapshotReceived = received;
          final snapshotFileCompleteCount = fileCompleteCount;
          final snapshotBytesThisFile = bleFrameState.bytesThisFile;
          final snapshotFileDeclared = bleFrameState.currentFileDeclaredSize;
          final snapshotFramed = bleFrameState.useFraming;
          final snapshotDeviceTotalFiles = bleXferDeviceTotalFiles;
          final snapshotDeviceSessionBytes = bleXferDeviceSessionBytes;

          progressWriteChain = progressWriteChain.then((_) async {
            try {
              final repo = await ref.read(recordingsRepositoryProvider.future);
              var exp = cachedExpectedBytes;
              if (exp == null || exp <= 0) {
                final rec = await repo.getById(recordingId);
                if (rec != null) cachedExpectedBytes = rec.expectedBytes;
                exp = rec?.expectedBytes ?? cachedExpectedBytes;
              }
              final prog = _wifiAlignedBleTransferProgress(
                framedMode: snapshotFramed,
                currentFileDeclaredSize: snapshotFileDeclared,
                bytesThisFile: snapshotBytesThisFile,
                receivedSession: snapshotReceived,
                expectedSession: exp,
                filesCompleted: snapshotFileCompleteCount,
                deviceTotalFiles: snapshotDeviceTotalFiles,
                deviceSessionBytes: snapshotDeviceSessionBytes,
              );
              await repo.updateTransfer(
                id: recordingId,
                state: 'transferring',
                progress: prog,
                receivedBytes: snapshotReceived,
                expectedBytes: exp ??
                    (expectedBytes != null && expectedBytes > 0
                        ? expectedBytes
                        : null),
                lastPacketAt: DateTime.now(),
                error: '',
                errorCode: '',
              );
              final nowInv = DateTime.now();
              final hasExpected = (exp ?? 0) > 0;
              final shouldInvalidate = hasExpected
                  ? (prog != null &&
                      (prog - lastInvalidatedProgress).abs() >= 0.01)
                  : true;
              if (shouldInvalidate &&
                  nowInv.difference(lastProgressInvalidateAt).inMilliseconds >=
                      500) {
                lastProgressInvalidateAt = nowInv;
                if (prog != null) lastInvalidatedProgress = prog;
                bumpRecordingsLists(ref);
                ref.invalidate(recordingByIdProvider(recordingId));
              }
            } catch (e, st) {
              if (_isSqfliteDatabaseClosed(e)) {
                AppLog.d(
                    'downloadSessionToLocal: skip progress DB update (database closed)');
                return;
              }
              AppLog.w(
                  'downloadSessionToLocal: fileData progress update failed',
                  e,
                  st);
            }
          }).catchError((_) {});
        }

        var startFileForDownload = effectiveStartFile;
        var isFirstAtDownload = true;
        var crcFailureCount = 0;
        const maxCrcResyncAttempts = 3;
        // Live-record (continuous) AT+DOWNLOAD can race the firmware writer:
        // the device reports `File read error: -9` and emits TRANSFER_DONE
        // with files=0/bytes=0 *before* a single FILE_START / chunk goes out.
        // We ignore that TD while still recording (correct: more bytes may
        // come). On real STOP (event:state IDLE) the file is closed and a
        // fresh AT+DOWNLOAD almost always succeeds — retry here instead of
        // waiting for the resume queue (we still hold the slot, and the
        // user's recording sheet is already on the "finished" panel).
        var zeroByteIdleRetryCount = 0;
        const maxZeroByteIdleRetries = 2;

        // Must be visible after the leg loop so we can drain pending FILE_END / finalize before merge.
        Future<void> bleFileNotifyChain = Future<void>.value();

        transferLegLoop:
        while (true) {
          effectiveStartFile = startFileForDownload;
          final legDone = Completer<void>();
          myTransfer.waitCompleter = legDone;
          var legEndReason = _BleTransferLegEnd.unknown;
          String? crcResyncStartFile;
          String? spuriousTdResumeStartFile;
          var downloadMetaSeenForLeg = false;

          Future<bool> ensureDownloadStillNeeded() async {
            // Throttled: skip the SQLite probe if we checked very recently. This
            // keeps the BLE notify chain from stalling on a per-packet DB read
            // (the iOS throughput regression). `cancelRequested` is still checked
            // unthrottled at the top of the chain, so we never miss a cancel.
            final now = DateTime.now();
            if (now.difference(lastStillNeededCheckAt) <
                const Duration(seconds: 2)) {
              return true;
            }
            lastStillNeededCheckAt = now;
            final row = await recRepo.getById(recordingId);
            if (row?.transferState != 'done') return true;
            AppLog.i(
              'downloadSessionToLocal: stop BLE notify — recording already done',
            );
            myTransfer.cancelErrorCode = 'already_synced';
            myTransfer.cancelRequested = true;
            if (!legDone.isCompleted) legDone.complete();
            return false;
          }

          void maybeFinishLegAfterFileComplete() {
            if (!continuous) return;
            if (!myTransfer.sessionEndedOnDevice && !deviceReportedIdle) {
              return;
            }
            if (received <= 0) return;
            final total = bleXferDeviceTotalFiles;
            if (total <= 0 && fileCompleteCount <= 0) return;
            if (!bleXferDeviceTotalFilesReliable || total <= 0) {
              AppLog.d(
                'downloadSessionToLocal: post-stop slice(s) $fileCompleteCount/$total '
                'but totalFiles is unknown — wait for TRANSFER_DONE or idle watchdog',
              );
              return;
            }

            final sessBytes = bleXferDeviceSessionBytes > 0
                ? bleXferDeviceSessionBytes
                : (cachedExpectedBytes ?? expectedBytes);
            // Per-leg AT+DOWNLOAD often reports total=1 while many slices stream;
            // rely on session bytes (not slice count vs total=1) before finishing.
            if (total > 1) {
              if (fileCompleteCount < total) return;
            } else {
              if (sessBytes == null || sessBytes <= 0) {
                AppLog.d(
                  'downloadSessionToLocal: post-stop slice(s) $fileCompleteCount/$total '
                  'but session bytes unknown — keep downloading',
                );
                return;
              }
              if (received < (sessBytes * 0.95).round()) {
                AppLog.d(
                  'downloadSessionToLocal: post-stop slice(s) $fileCompleteCount/$total '
                  'but received=$received < 95% sessionBytes=$sessBytes — keep downloading',
                );
                return;
              }
            }

            final exp = sessBytes ?? cachedExpectedBytes ?? expectedBytes;
            if (exp != null && exp > 0 && received < (exp * 0.9).round()) {
              AppLog.d(
                'downloadSessionToLocal: post-stop slice(s) $fileCompleteCount/$total '
                'but received=$received < 90% expected=$exp — keep downloading',
              );
              return;
            } else if (exp == null && total <= 0) {
              AppLog.d(
                'downloadSessionToLocal: post-stop slice(s) done but totalFiles=0 '
                'and no expectedBytes — keep downloading',
              );
              return;
            }

            AppLog.i(
              'downloadSessionToLocal: all slice(s) received after stop '
              '($fileCompleteCount/$total, received=$received) — finishing leg for merge',
            );
            if (!legDone.isCompleted) legDone.complete();
          }

          // Serialize notify handling: async callbacks would interleave on DATA / FILE_END /
          // FILE_START and corrupt bleFrameState.fileCrc + filename (false CRC mismatch → spurious CANCEL).
          bleFileNotifyChain = Future<void>.value();
          // Keep [bleXferDeviceTotalFiles] / [bleXferDeviceSessionBytes] across legs —
          // firmware returns them on every AT+DOWNLOAD (e.g. total=31, bytes=11096136).
          // Resetting each leg made progress fall back to filesOnly (1/1) until the
          // JSON response arrived, even while FILE_START/DATA were already streaming.

          // Start listening before sending AT+DOWNLOAD to avoid missing early packets.
          downloading = true;
          fileSub = at.fileDataBytes.listen((notifyBytes) {
            bleFileNotifyChain = bleFileNotifyChain.then((_) async {
              if (myTransfer.cancelRequested) {
                if (!legDone.isCompleted) legDone.complete();
                return;
              }
              if (!await ensureDownloadStillNeeded()) return;
              if (!downloading) return;

              final frame = BleTransferFrameHandler.handle(
                bytes: notifyBytes,
                state: bleFrameState,
                effectiveStartFile: effectiveStartFile,
              );

              if (frame is BleTransferFrameInvalid) {
                AppLog.w(
                  'downloadSessionToLocal: invalid BLE file frame: ${frame.reason}',
                );
                return;
              }
              if (frame is BleTransferFrameUnexpectedRaw) {
                AppLog.w(
                  'downloadSessionToLocal: raw chunk while framed mode (len=${frame.length}), ignoring',
                );
                return;
              }
              if (frame is BleTransferFrameRaw) {
                touchLastDataAt();
                final n = frame.bytes.length;
                if (received == 0 && n > 0) {
                  AppLog.i(
                    'downloadSessionToLocal: first chunk from firmware (legacy raw) $n bytes',
                  );
                }
                received += n;
                try {
                  currentSink?.add(frame.bytes);
                } catch (_) {}
                await reportReceiveProgressAfterAdd(n);
                return;
              }
              if (frame is BleTransferFrameFileStart) {
                touchLastDataAt();
                AppLog.i(
                  'downloadSessionToLocal: BLE FILE_START name=${frame.filename} size=${frame.fileSize} bytes',
                );
                unawaited(() async {
                  try {
                    final repo =
                        await ref.read(recordingsRepositoryProvider.future);
                    var exp = cachedExpectedBytes;
                    if (exp == null || exp <= 0) {
                      final rec = await repo.getById(recordingId);
                      if (rec != null) cachedExpectedBytes = rec.expectedBytes;
                      exp = rec?.expectedBytes ?? cachedExpectedBytes;
                    }
                    final progStart = _wifiAlignedBleTransferProgress(
                      framedMode: bleFrameState.useFraming,
                      currentFileDeclaredSize:
                          bleFrameState.currentFileDeclaredSize,
                      bytesThisFile: 0,
                      receivedSession: received,
                      expectedSession: exp,
                      filesCompleted: fileCompleteCount,
                      deviceTotalFiles: bleXferDeviceTotalFiles,
                      deviceSessionBytes: bleXferDeviceSessionBytes,
                    );
                    await repo.updateTransfer(
                      id: recordingId,
                      state: 'transferring',
                      progress: progStart,
                      receivedBytes: received,
                      expectedBytes: exp ??
                          (expectedBytes != null && expectedBytes > 0
                              ? expectedBytes
                              : null),
                      lastPacketAt: DateTime.now(),
                      error: '',
                      errorCode: '',
                    );
                    bumpRecordingsLists(ref);
                    ref.invalidate(recordingByIdProvider(recordingId));
                  } catch (e, st) {
                    if (_isSqfliteDatabaseClosed(e)) {
                      AppLog.d(
                        'downloadSessionToLocal: skip FILE_START DB flush (database closed)',
                      );
                      return;
                    }
                    AppLog.w(
                      'downloadSessionToLocal: FILE_START progress flush failed',
                      e,
                      st,
                    );
                  }
                }());
                return;
              }
              if (frame is BleTransferFrameData) {
                if (frame.orphanBeforeFileStart && !downloadMetaSeenForLeg) {
                  resetBleFrameAssemblyForIgnoredNotify();
                  AppLog.w(
                    'downloadSessionToLocal: ignore BLE DATA before FILE_START/AT+DOWNLOAD meta '
                    '(seq=${frame.seq}, len=${frame.payload.length}, '
                    'pull sessionRoot=$pullSessionRoot)',
                  );
                  return;
                }
                touchLastDataAt();
                if (frame.duplicateSeq) {
                  AppLog.d(
                    'downloadSessionToLocal: BLE DATA duplicate seq=${frame.seq} expected=${bleFrameState.nextSeq}',
                  );
                  return;
                }
                if (frame.seqJump) {
                  AppLog.w(
                    'downloadSessionToLocal: BLE DATA seq jump ${frame.seq} vs ${bleFrameState.nextSeq - 1}, accepting',
                  );
                }
                final n = frame.payload.length;
                if (received == 0 && n > 0) {
                  AppLog.i(
                    'downloadSessionToLocal: first chunk from firmware (BLE DATA) $n bytes',
                  );
                }
                received += n;
                try {
                  currentSink?.add(frame.payload);
                } catch (_) {}
                await reportReceiveProgressAfterAdd(n);
                return;
              }
              if (frame is BleTransferFrameFileEndStale) {
                touchLastDataAt();
                AppLog.d(
                  'downloadSessionToLocal: ignore stale FILE_END CRC for ${frame.filename} '
                  '(already have $fileCompleteCount complete slice(s); devCrc=0x${frame.deviceCrc32.toRadixString(16)})',
                );
                return;
              }
              if (frame is BleTransferFrameFileEndCrcMismatch) {
                touchLastDataAt();
                AppLog.w(
                  'downloadSessionToLocal: BLE FILE_END CRC mismatch local=0x${frame.localCrc32.toRadixString(16)} '
                  'device=0x${frame.deviceCrc32.toRadixString(16)} name=${frame.filename} — discarding partial, AT+CANCEL + resync from next slice',
                );
                try {
                  await currentSink?.flush();
                } catch (_) {}
                try {
                  await currentSink?.close();
                } catch (_) {}
                currentSink = null;
                final tmp = currentTmp;
                currentTmp = null;
                if (tmp != null) {
                  try {
                    if (await tmp.exists()) await tmp.delete();
                  } catch (_) {}
                }
                legEndReason = _BleTransferLegEnd.crcResync;
                crcResyncStartFile = frame.resyncStartFile;
                try {
                  await _sendAtWithDisconnect(conn, at, 'AT+CANCEL',
                      timeout: const Duration(seconds: 5));
                } catch (e, st) {
                  AppLog.w(
                    'downloadSessionToLocal: AT+CANCEL after CRC mismatch failed (non-fatal)',
                    e,
                    st,
                  );
                }
                await Future<void>.delayed(const Duration(milliseconds: 400));
                await openNewTmp();
                if (!legDone.isCompleted) legDone.complete();
                return;
              }
              if (frame is BleTransferFrameFileEndOk) {
                touchLastDataAt();
                fileCompleteCount = bleFrameState.fileCompleteCount;
                await finalizeCurrentFile(frame.filename);
                await openNewTmp();
                try {
                  var exp = cachedExpectedBytes;
                  if (exp == null || exp <= 0) {
                    final rec = await recRepo.getById(recordingId);
                    if (rec != null) cachedExpectedBytes = rec.expectedBytes;
                    exp = rec?.expectedBytes ?? cachedExpectedBytes;
                  }
                  final prog = _wifiAlignedBleTransferProgress(
                    framedMode: frame.usedFraming,
                    currentFileDeclaredSize: frame.declaredFileSize,
                    bytesThisFile: frame.bytesThisFile,
                    receivedSession: received,
                    expectedSession: exp,
                    filesCompleted: fileCompleteCount,
                    deviceTotalFiles: bleXferDeviceTotalFiles,
                    deviceSessionBytes: bleXferDeviceSessionBytes,
                  );
                  await recRepo.updateTransfer(
                    id: recordingId,
                    state: 'transferring',
                    progress: prog,
                    receivedBytes: received,
                    expectedBytes: exp,
                    lastPacketAt: DateTime.now(),
                    error: '',
                    errorCode: '',
                  );
                  bumpRecordingsLists(ref);
                  ref.invalidate(recordingByIdProvider(recordingId));
                } catch (e, st) {
                  AppLog.w(
                    'downloadSessionToLocal: BLE FILE_END progress update failed',
                    e,
                    st,
                  );
                }
                maybeFinishLegAfterFileComplete();
                return;
              }
              if (frame is BleTransferFrameTransferDone) {
                if (!transferEventSessionMatches(
                  frame.sessionId,
                  'BLE TRANSFER_DONE(files=${frame.fileCount})',
                )) {
                  return;
                }
                touchLastDataAt();
                final files = frame.fileCount;
                if (files > 0) {
                  bleXferDeviceTotalFiles =
                      math.max(bleXferDeviceTotalFiles, files);
                  bleXferDeviceTotalFilesReliable = true;
                }
                AppLog.i(
                  'downloadSessionToLocal: BLE TRANSFER_DONE session=${frame.sessionId} files=$files '
                  'received=$received fileCompleteCount=$fileCompleteCount',
                );
                if (received == 0 && files == 0) {
                  AppLog.i(
                    'downloadSessionToLocal: ignoring TRANSFER_DONE (received=0, files=0), waiting for data',
                  );
                  return;
                }
                if (files == 0 && received > 0) {
                  if (!continuous) {
                    AppLog.i(
                      'downloadSessionToLocal: TRANSFER_DONE (files=0) with data, will finish after short idle',
                    );
                    return;
                  }
                  final totalFiles = bleXferDeviceTotalFiles;
                  final sessionBytes = bleXferDeviceSessionBytes;
                  final haveAllSlices =
                      totalFiles > 0 && fileCompleteCount >= totalFiles;
                  final haveAllBytes = sessionBytes > 0 &&
                      received >= (sessionBytes - 2048).clamp(0, sessionBytes);
                  if (haveAllSlices || haveAllBytes) {
                    AppLog.i(
                      'downloadSessionToLocal: TRANSFER_DONE files=0 but session looks complete '
                      '(slices=$fileCompleteCount/$totalFiles bytes=$received/$sessionBytes) — finishing leg',
                    );
                  } else if (allowDuringRecordingStartGuard &&
                      !myTransfer.sessionEndedOnDevice &&
                      !deviceReportedIdle) {
                    AppLog.i(
                      'downloadSessionToLocal: ignoring TRANSFER_DONE (files=0) in continuous live-record mode '
                      '(3min no-data pause or more payload)',
                    );
                    return;
                  } else if (allowDuringRecordingStartGuard &&
                      (myTransfer.sessionEndedOnDevice || deviceReportedIdle)) {
                    if (fileCompleteCount <= 0 &&
                        !haveAllBytes &&
                        !haveAllSlices) {
                      AppLog.w(
                        'downloadSessionToLocal: ignore TRANSFER_DONE files=0 after idle '
                        '(no slices; bytes=$received sessionBytes=$sessionBytes) — abort stale leg',
                      );
                      myTransfer.cancelErrorCode = 'already_synced';
                      myTransfer.cancelRequested = true;
                      if (!legDone.isCompleted) legDone.complete();
                      return;
                    }
                    AppLog.i(
                      'downloadSessionToLocal: TRANSFER_DONE files=0 after session ended — finishing leg',
                    );
                  } else {
                    final nextPart = fileCompleteCount + 1;
                    spuriousTdResumeStartFile =
                        '${nextPart.toString().padLeft(4, '0')}.opus';
                    legEndReason = _BleTransferLegEnd.spuriousTdResume;
                    AppLog.w(
                      'downloadSessionToLocal: TRANSFER_DONE files=0 mid fixed session '
                      '(slices=$fileCompleteCount/${totalFiles > 0 ? totalFiles : '?'}, '
                      'bytes=$received/${sessionBytes > 0 ? sessionBytes : '?'}) — '
                      'retry leg from $spuriousTdResumeStartFile',
                    );
                    if (!legDone.isCompleted) legDone.complete();
                    return;
                  }
                }
                double? doneProg;
                int? doneExpected;
                var exp = cachedExpectedBytes;
                if (exp == null || exp <= 0) {
                  final fetched = await recRepo.getById(recordingId);
                  if (fetched != null) {
                    cachedExpectedBytes = fetched.expectedBytes;
                  }
                  exp = fetched?.expectedBytes ?? cachedExpectedBytes;
                }
                doneProg = _wifiAlignedBleTransferProgress(
                  framedMode: bleFrameState.useFraming,
                  currentFileDeclaredSize:
                      bleFrameState.currentFileDeclaredSize,
                  bytesThisFile: bleFrameState.bytesThisFile,
                  receivedSession: received,
                  expectedSession: exp,
                  filesCompleted: fileCompleteCount,
                  deviceTotalFiles: bleXferDeviceTotalFiles,
                  deviceSessionBytes: bleXferDeviceSessionBytes,
                );
                doneExpected = exp ??
                    (expectedBytes != null && expectedBytes > 0
                        ? expectedBytes
                        : null);
                if (_bleTransferDoneMeansSessionComplete(
                  eventFileCount: files,
                  fileCompleteCount: fileCompleteCount,
                  deviceTotalFilesFromDownload: bleXferDeviceTotalFiles,
                )) {
                  final expForDone = doneExpected ?? 0;
                  if (expForDone > 0 && received > (expForDone * 1.02).round()) {
                    AppLog.w(
                      'downloadSessionToLocal: BLE TRANSFER_DONE slices complete '
                      'but received=$received > expected=$expForDone — '
                      'not setting progress 1.0 (inflated resume counter)',
                    );
                    doneProg = (received / expForDone).clamp(0.0, 0.99);
                  } else {
                    doneProg = 1.0;
                    AppLog.i(
                      'downloadSessionToLocal: BLE TRANSFER_DONE session complete '
                      '($fileCompleteCount/$bleXferDeviceTotalFiles slices, event files=$files) → '
                      'progress 1.0 (merge may follow)',
                    );
                  }
                } else if (files > 0) {
                  AppLog.d(
                    'downloadSessionToLocal: BLE TRANSFER_DONE — '
                    'progress from current slice or session ($doneProg) not 1.0 (files=$files)',
                  );
                }
                await recRepo.updateTransfer(
                  id: recordingId,
                  state: 'transferring',
                  progress: doneProg,
                  receivedBytes: received,
                  expectedBytes: doneExpected,
                  lastPacketAt: DateTime.now(),
                  error: '',
                  errorCode: '',
                );
                bumpRecordingsLists(ref);
                ref.invalidate(recordingByIdProvider(recordingId));
                if (!legDone.isCompleted) legDone.complete();
                return;
              }
            }).catchError((Object e, StackTrace st) {
              AppLog.w(
                  'downloadSessionToLocal: BLE fileData notify chain error',
                  e,
                  st);
            });
          }, onError: (e, st) {
            AppLog.w('downloadSessionToLocal: fileData stream error', e, st);
          });

          jsonSub = at.jsonMessages.listen((msg) async {
            try {
              // Some firmwares wrap event into data: {"ok":true,"data":{"event":"..."}}
              final data = msg['data'];
              final dataMap = data is Map
                  ? Map<String, dynamic>.from(data)
                  : const <String, dynamic>{};
              final event =
                  ((msg['event'] ?? dataMap['event'] ?? '')).toString();

              final parsed = TransferJsonEventParser.parse(msg);
              if (parsed == null) return;

              if (parsed is TransferJsonFileComplete) {
                if (!transferEventSessionMatches(
                  parsed.sessionId,
                  'JSON file_complete',
                )) {
                  return;
                }
                if (bleFrameState.useFraming) {
                  AppLog.d(
                      'downloadSessionToLocal: ignore JSON file_complete (BLE binary frames)');
                  return;
                }
                final filename = parsed.filename;
                fileCompleteCount++;
                bleFrameState.fileCompleteCount = fileCompleteCount;
                AppLog.i(
                    'downloadSessionToLocal: file_complete #$fileCompleteCount filename="$filename" received=$received');
                await finalizeCurrentFile(filename);
                await openNewTmp();
                var exp = cachedExpectedBytes;
                if (exp == null || exp <= 0) {
                  final rec = await recRepo.getById(recordingId);
                  if (rec != null) cachedExpectedBytes = rec.expectedBytes;
                  exp = rec?.expectedBytes ?? cachedExpectedBytes;
                }
                final prog = _wifiAlignedBleTransferProgress(
                  framedMode: bleFrameState.useFraming,
                  currentFileDeclaredSize:
                      bleFrameState.currentFileDeclaredSize,
                  bytesThisFile: bleFrameState.bytesThisFile,
                  receivedSession: received,
                  expectedSession: exp,
                  filesCompleted: fileCompleteCount,
                  deviceTotalFiles: bleXferDeviceTotalFiles,
                  deviceSessionBytes: bleXferDeviceSessionBytes,
                );
                await recRepo.updateTransfer(
                  id: recordingId,
                  state: 'transferring',
                  progress: prog,
                  receivedBytes: received,
                  expectedBytes: exp,
                  lastPacketAt: DateTime.now(),
                  error: '',
                  errorCode: '',
                );
                bumpRecordingsLists(ref);
                ref.invalidate(recordingByIdProvider(recordingId));
                maybeFinishLegAfterFileComplete();
                return;
              }
              if (parsed is TransferJsonTransferComplete) {
                if (!transferEventSessionMatches(
                  parsed.sessionId,
                  'JSON transfer_complete(files=${parsed.files})',
                )) {
                  return;
                }
                if (bleFrameState.useFraming) {
                  AppLog.d(
                      'downloadSessionToLocal: ignore JSON transfer_complete (BLE binary frames)');
                  return;
                }
                final files = parsed.files;
                if (files > 0) {
                  bleXferDeviceTotalFiles =
                      math.max(bleXferDeviceTotalFiles, files);
                  bleXferDeviceTotalFilesReliable = true;
                }
                AppLog.i(
                    'downloadSessionToLocal: transfer_complete received=$received files=$files fileCompleteCount=$fileCompleteCount');
                if (TransferJsonTransferCompletePolicy
                    .shouldIgnoreEmptyTransferComplete(
                  receivedBytes: received,
                  files: files,
                )) {
                  AppLog.i(
                      'downloadSessionToLocal: ignoring transfer_complete (received=0, files=0), waiting for data');
                  return;
                }
                // Firmware sends transfer_complete(session=X,files=7) first, then transfer_complete(session=,files=0).
                // While recording and transferring, firmware may wrongly send files=0 between files; a 10s idle timeout would finish early and fire AT+DELETE. Trust files=0 only when not continuous.
                if (files == 0 && received > 0) {
                  if (!continuous) {
                    AppLog.i(
                      'downloadSessionToLocal: transfer_complete (files=0) when we have data, will finish after idle watchdog',
                    );
                    return;
                  }
                  final totalFiles = bleXferDeviceTotalFiles;
                  final sessionBytes = bleXferDeviceSessionBytes;
                  if (TransferJsonTransferCompletePolicy
                      .looksLikeSessionComplete(
                    fileCompleteCount: fileCompleteCount,
                    deviceTotalFiles: totalFiles,
                    receivedBytes: received,
                    deviceSessionBytes: sessionBytes,
                  )) {
                    AppLog.i(
                      'downloadSessionToLocal: transfer_complete files=0 but session looks complete '
                      '(slices=$fileCompleteCount/$totalFiles bytes=$received/$sessionBytes) — finishing leg',
                    );
                    // Fall through.
                  } else if (allowDuringRecordingStartGuard) {
                    AppLog.i(
                      'downloadSessionToLocal: ignoring transfer_complete (files=0) in continuous live-record mode',
                    );
                    return;
                  } else {
                    final nextPart = fileCompleteCount + 1;
                    spuriousTdResumeStartFile =
                        '${nextPart.toString().padLeft(4, '0')}.opus';
                    legEndReason = _BleTransferLegEnd.spuriousTdResume;
                    AppLog.w(
                      'downloadSessionToLocal: transfer_complete files=0 mid fixed session — '
                      'retry leg from $spuriousTdResumeStartFile',
                    );
                    if (!legDone.isCompleted) legDone.complete();
                    return;
                  }
                }
                // Matches Python transfer.py: non-continuous transfer_complete means the whole transfer is done — allow 100% so UI does not stall before merge.
                // Multi-file continuous: same as BLE TRANSFER_DONE — do not force 1.0 while the next file is still streaming or the banner stays full.
                double? tcProg = 1.0;
                int? tcExpected;
                if (continuous) {
                  var exp = cachedExpectedBytes;
                  if (exp == null || exp <= 0) {
                    final fetched = await recRepo.getById(recordingId);
                    if (fetched != null) {
                      cachedExpectedBytes = fetched.expectedBytes;
                    }
                    exp = fetched?.expectedBytes ?? cachedExpectedBytes;
                  }
                  tcProg = _wifiAlignedBleTransferProgress(
                    framedMode: bleFrameState.useFraming,
                    currentFileDeclaredSize:
                        bleFrameState.currentFileDeclaredSize,
                    bytesThisFile: bleFrameState.bytesThisFile,
                    receivedSession: received,
                    expectedSession: exp,
                    filesCompleted: fileCompleteCount,
                    deviceTotalFiles: bleXferDeviceTotalFiles,
                    deviceSessionBytes: bleXferDeviceSessionBytes,
                  );
                  tcExpected = exp ??
                      (expectedBytes != null && expectedBytes > 0
                          ? expectedBytes
                          : null);
                  if (_bleTransferDoneMeansSessionComplete(
                    eventFileCount: files,
                    fileCompleteCount: fileCompleteCount,
                    deviceTotalFilesFromDownload: bleXferDeviceTotalFiles,
                  )) {
                    tcProg = 1.0;
                    AppLog.i(
                      'downloadSessionToLocal: transfer_complete session complete '
                      '($fileCompleteCount/$bleXferDeviceTotalFiles slices, event files=$files) → '
                      'progress 1.0 (merge may follow)',
                    );
                  }
                } else {
                  tcExpected = expectedBytes != null && expectedBytes > 0
                      ? expectedBytes
                      : null;
                }
                await recRepo.updateTransfer(
                  id: recordingId,
                  state: 'transferring',
                  progress: tcProg,
                  receivedBytes: received,
                  expectedBytes: tcExpected,
                  lastPacketAt: DateTime.now(),
                  error: '',
                  errorCode: '',
                );
                bumpRecordingsLists(ref);
                ref.invalidate(recordingByIdProvider(recordingId));
                if (!legDone.isCompleted) legDone.complete();
                return;
              }
              // Appendix E / protocol 7.1: IDLE/RECORDING may use `event:"state"`
              // (not only legacy `state_change`). Without handling `"state"` here,
              // continuous live-record never sets [deviceReportedIdle], the 180s
              // watchdog is the only leg completion path, and TRANSFER_DONE
              // (files=0) mid-session stays ignored — the file never merges after
              // a device-button STOP.
              if (event == 'state_change' || event == 'state') {
                final newState = (event == 'state_change'
                        ? (dataMap['new'] ?? msg['new'] ?? '')
                        : (dataMap['state'] ?? msg['state'] ?? ''))
                    .toString()
                    .toUpperCase()
                    .trim();
                if (newState == 'IDLE') {
                  final evSid = (dataMap['session'] ?? msg['session'] ?? '')
                      .toString()
                      .trim();
                  final ourRoot = _normalizeRecordingSessionRoot(sessionId);
                  final evRoot = _normalizeRecordingSessionRoot(evSid);
                  final sessionMatches =
                      evSid.isEmpty || ourRoot.isEmpty || evRoot == ourRoot;
                  if (sessionMatches) {
                    deviceReportedIdle = true;
                    myTransfer.sessionEndedOnDevice = true;
                    AppLog.i(
                      'downloadSessionToLocal: device reported IDLE ($event '
                      'session=$evSid), shorter finish threshold for this pull',
                    );
                  } else {
                    AppLog.d(
                      'downloadSessionToLocal: ignoring IDLE ($event) for '
                      'session=$evSid (pull sessionRoot=$ourRoot)',
                    );
                  }
                }
                // When device starts recording, if current transfer is old session (resume), stop it; firmware will AT+CANCEL, sync cancel here to avoid waiting.
                if ((newState == 'RECORDING' || newState == 'REC') &&
                    !continuous) {
                  AppLog.i(
                      'downloadSessionToLocal: device started recording, canceling transfer of old session $sessionId');
                  cancelTransferReason = 'device_recording_resume_later';
                  myTransfer.cancelRequested = true;
                }
                return;
              }
            } catch (e, st) {
              AppLog.w(
                  'downloadSessionToLocal: jsonMessages handler error', e, st);
            }
          }, onError: (e, st) {
            AppLog.w('downloadSessionToLocal: jsonMessages error', e, st);
          });

          // When device is recording, only allow transfer of current recording session; when resuming old session, if device is recording another session, do not start transfer.
          if (effectiveStartFile != null &&
              effectiveStartFile.trim().isNotEmpty) {
            final recStatus = await getRecordingStatusForAt(at);
            if (recStatus?.state == 'recording' &&
                _normalizeRecordingSessionRoot(recStatus?.sessionId)
                    .isNotEmpty) {
              final activeRoot =
                  _normalizeRecordingSessionRoot(recStatus!.sessionId);
              final ourRoot = _normalizeRecordingSessionRoot(sessionId);
              if (ourRoot != activeRoot) {
                AppLog.i(
                    'downloadSessionToLocal: owner device recording sessionRoot=$activeRoot, '
                    'deferring transfer of sessionRoot=$ourRoot');
                await recRepo.updateTransfer(
                  id: recordingId,
                  state: 'transferring',
                  progress: expectedBytes != null && expectedBytes > 0
                      ? (initialReceived / expectedBytes).clamp(0.0, 0.99)
                      : null,
                  errorCode: 'device_recording_resume_later',
                  receivedBytes: initialReceived,
                  expectedBytes: expectedBytes,
                  transferStartedAt: startedAt,
                  recordingState: 'transferring',
                );
                bumpRecordingsLists(ref);
                ref.invalidate(recordingByIdProvider(recordingId));
                downloading = false;
                await fileSub.cancel();
                fileSub = null;
                await jsonSub.cancel();
                jsonSub = null;
                if (myTransfer.waitCompleter == legDone) {
                  myTransfer.waitCompleter = null;
                }
                return false;
              }
            }
          }
          final downloadCmd = (effectiveStartFile != null &&
                  effectiveStartFile.trim().isNotEmpty)
              ? 'AT+DOWNLOAD=$sessionId:${effectiveStartFile.trim()}'
              : 'AT+DOWNLOAD=$sessionId';
          // Re-check right before sending: this leg may have been queued behind
          // a live record-while-transfer download on the per-device chain. That
          // live download releases the chain as soon as it ENQUEUES the merge,
          // but the merge (mark `done` + AT+DELETE of the firmware session) runs
          // async afterwards. Without this re-check the early `done` guard (read
          // before this wait) is stale, and we fire a fresh AT+DOWNLOAD for a
          // session the merge already deleted → "Session or file not found" and
          // a phantom progress bar that appears then vanishes.
          final preSendRow = await recRepo.getById(recordingId);
          if (preSendRow == null ||
              preSendRow.transferState == 'done' ||
              preSendRow.transferState == 'merging' ||
              ref
                  .read(sessionMergeQueueProvider)
                  .isMergingRecording(recordingId) ||
              _shouldSuppressBleResume(recordingId)) {
            AppLog.i(
              'downloadSessionToLocal: skip AT+DOWNLOAD — recording '
              '${preSendRow?.transferState ?? 'missing'} / merge in flight '
              '($recordingId); not re-downloading deleted session',
            );
            myTransfer.cancelErrorCode = 'already_synced';
            myTransfer.cancelRequested = true;
            if (!legDone.isCompleted) legDone.complete();
            break transferLegLoop;
          }
          if (state.connection == null || _at == null) {
            AppLog.i(
              'downloadSessionToLocal: skip AT+DOWNLOAD — BLE link gone ($recordingId)',
            );
            throw StateError('device disconnected');
          }
          // A prior emergency AT+CANCEL / AT+STOP (recording preempt, Wi‑Fi
          // handoff, or stopRecording link-free) disabled the fileData CCCD to
          // free the link; re-enable it here or this leg would receive no file
          // bytes. Required on Android too now that stopRecording disables the
          // notify there — leaving it iOS-only would strand Android with the
          // notify off forever. Idempotent if it was never disabled.
          if (Platform.isIOS || Platform.isAndroid) {
            try {
              await _at!.setFileDataNotify(
                true,
                timeout: const Duration(seconds: 2),
              );
              // Fresh leg with the notify back on: clear the "dead leg" flag so
              // the watchdog uses the normal no-data windows again.
              myTransfer.fileNotifyDisabledWhileActive = false;
            } catch (e, st) {
              AppLog.w(
                'downloadSessionToLocal: re-enable fileData notify failed '
                '(continuing) ($recordingId)',
                e,
                st,
              );
            }
          }
          await probeDeviceIdleForContinuousLeg();
          AppLog.i(
              'downloadSessionToLocal: sending ${downloadCmd.length}B AT command DOWNLOAD sessionRoot=${sessionId.contains('/') ? sessionId.split('/').first : sessionId}');
          if (startFileForDownload == null ||
              startFileForDownload.trim().isEmpty) {
            if (isFirstAtDownload) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
              isFirstAtDownload = false;
            }
          } else {
            isFirstAtDownload = false;
          }
          const maxRetries = 4;
          Map<String, dynamic>? lastResp;
          for (var attempt = 0; attempt < maxRetries; attempt++) {
            if (attempt > 0) {
              AppLog.i(
                  'downloadSessionToLocal: AT+DOWNLOAD retry #$attempt after Session not found');
              await Future<void>.delayed(const Duration(milliseconds: 800));
            }
            lastResp = await _sendAtWithDisconnect(conn, at, downloadCmd,
                timeout: const Duration(seconds: 8));
            if (lastResp['ok'] == true) break;
            final err = (lastResp['error'] ?? lastResp['msg'] ?? '')
                .toString()
                .toLowerCase();
            if (err.contains('session not found') && attempt < maxRetries - 1) {
              continue;
            }
            if (err.contains('transfer already in progress') &&
                attempt < maxRetries - 1) {
              // FIRMWARE BUG GUARD: while the firmware is *recording*,
              // sending `AT+CANCEL` to abort an in-progress transfer races
              // the recording thread for shared resources and hits the
              // `xfer cleanup timeout` 2 s window — after which BLE drops
              // silently and the device becomes unscannable. This happens
              // when we previously demoted a recording device (which we
              // intentionally did NOT cancel — see
              // `_demoteCurrentToBackground` `skipAtCancel`) and the
              // firmware is still streaming the same session: the new
              // `AT+DOWNLOAD` here collides with the old one.
              //
              // Recovery: bail out of the download gracefully with
              // `device_recording_resume_later`. `_resumeIncompleteTransfers`
              // will retry once the firmware transitions out of recording
              // (state-change handler runs on every GSTAT idle event), at
              // which point `AT+CANCEL` is safe again.
              if (await _deviceAtAppearsRecordingOrPaused(at)) {
                AppLog.w(
                  'downloadSessionToLocal: AT+DOWNLOAD busy AND owner device is recording — '
                  'skip AT+CANCEL (would crash xfer cleanup), aborting to retry later',
                );
                await recRepo.updateTransfer(
                  id: recordingId,
                  state: 'transferring',
                  progress: expectedBytes != null && expectedBytes > 0
                      ? (initialReceived / expectedBytes).clamp(0.0, 0.99)
                      : null,
                  errorCode: 'device_recording_resume_later',
                  receivedBytes: initialReceived,
                  expectedBytes: expectedBytes,
                  transferStartedAt: startedAt,
                  recordingState: 'transferring',
                );
                bumpRecordingsLists(ref);
                ref.invalidate(recordingByIdProvider(recordingId));
                downloading = false;
                await fileSub?.cancel();
                fileSub = null;
                await jsonSub?.cancel();
                jsonSub = null;
                if (myTransfer.waitCompleter == legDone) {
                  myTransfer.waitCompleter = null;
                }
                return false;
              }
              AppLog.w(
                'downloadSessionToLocal: AT+DOWNLOAD busy, sending AT+CANCEL then retry (${attempt + 1}/$maxRetries)',
              );
              try {
                await _sendAtWithDisconnect(conn, at, 'AT+CANCEL',
                    timeout: const Duration(seconds: 5));
              } catch (e, st) {
                AppLog.w(
                    'downloadSessionToLocal: AT+CANCEL before DOWNLOAD retry failed',
                    e,
                    st);
              }
              await Future<void>.delayed(const Duration(milliseconds: 1200));
              continue;
            }
            throw Exception(
                'AT+DOWNLOAD failed: ${lastResp['error'] ?? lastResp['msg'] ?? 'unknown'}');
          }

          final lr = lastResp;
          if (lr == null || lr['ok'] != true) {
            throw StateError('AT+DOWNLOAD: expected ok response');
          }
          downloadMetaSeenForLeg = true;
          final dlData = lr['data'];
          if (dlData is Map) {
            final dm = Map<String, dynamic>.from(dlData);
            final df = _parseInt(dm['files'] ?? dm['total']);
            final db = _parseInt(dm['bytes'] ?? dm['size']);
            if (df != null && df > 0) {
              final next = (initialFileCount > 0 && df < initialFileCount + 1)
                  ? initialFileCount + 1
                  : df;
              if (!continuous || df > 1 || bleXferDeviceTotalFilesReliable) {
                bleXferDeviceTotalFiles =
                    math.max(bleXferDeviceTotalFiles, next);
                bleXferDeviceTotalFilesReliable = true;
              } else {
                AppLog.d(
                  'downloadSessionToLocal: AT+DOWNLOAD reports total=$df in continuous mode; '
                  'treat as unknown until LIST/TRANSFER_DONE confirms total files',
                );
              }
            }
            if (db != null && db > 0) {
              bleXferDeviceSessionBytes = db;
              if (db > (cachedExpectedBytes ?? 0)) {
                cachedExpectedBytes = db;
              }
            }
            AppLog.i(
              'downloadSessionToLocal: AT+DOWNLOAD meta '
              'total=$bleXferDeviceTotalFiles bytes=$bleXferDeviceSessionBytes '
              'startFile=${dm['file'] ?? startFileForDownload ?? '0001.opus'}',
            );
          }
          if (bleXferDeviceSessionBytes > (cachedExpectedBytes ?? 0)) {
            cachedExpectedBytes = bleXferDeviceSessionBytes;
          }

          // Persist AT+DOWNLOAD metadata immediately so banner/list use determinate progress
          // (received / expected or DB transfer_progress) like Wi‑Fi. Otherwise the first
          // throttled progress write (8 KiB / 2 s) and/or prog=null before FILE_START often
          // leave expected_bytes=0 and transfer_progress=null → indeterminate bar on iOS.
          if (bleXferDeviceTotalFiles > 0 || bleXferDeviceSessionBytes > 0) {
            try {
              var exp = cachedExpectedBytes;
              if (exp == null || exp <= 0) {
                final row = await recRepo.getById(recordingId);
                if (row != null && (row.expectedBytes ?? 0) > 0) {
                  cachedExpectedBytes = row.expectedBytes;
                  exp = row.expectedBytes;
                }
              }
              final prog = _wifiAlignedBleTransferProgress(
                framedMode: bleFrameState.useFraming,
                currentFileDeclaredSize: bleFrameState.currentFileDeclaredSize,
                bytesThisFile: bleFrameState.bytesThisFile,
                receivedSession: received,
                expectedSession: exp,
                filesCompleted: fileCompleteCount,
                deviceTotalFiles: bleXferDeviceTotalFiles,
                deviceSessionBytes: bleXferDeviceSessionBytes,
              );
              final int? expToDb = (exp != null && exp > 0)
                  ? exp
                  : (expectedBytes != null && expectedBytes > 0
                      ? expectedBytes
                      : null);
              await recRepo.updateTransfer(
                id: recordingId,
                state: 'transferring',
                progress: prog,
                receivedBytes: received,
                expectedBytes: expToDb,
                lastPacketAt: DateTime.now(),
                error: '',
                errorCode: '',
              );
              bumpRecordingsLists(ref);
              ref.invalidate(recordingByIdProvider(recordingId));
            } catch (e, st) {
              AppLog.w(
                'downloadSessionToLocal: flush AT+DOWNLOAD meta to DB failed',
                e,
                st,
              );
            }
          }

          // Watchdog (no AT+GSTAT):
          // - continuous live record: 180s no data → pause (stalled_no_data_3min)
          // - continuous + session idle / near-complete: much shorter (iOS BG freeze)
          // - non-continuous: 5s/10s no data → finish leg (no IDLE check)
          // - User cancel via myTransfer.cancelRequested
          watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
            if (!downloading || legDone.isCompleted) return;
            if (myTransfer.cancelRequested) {
              AppLog.i('downloadSessionToLocal: cancel requested, finishing');
              if (!legDone.isCompleted) legDone.complete();
              return;
            }
            final idleFor = DateTime.now().difference(lastDataAt);
            if (continuous) {
              const stallSeconds = 180;
              // After a real stop ([event:"state"] → IDLE), firmware may emit
              // TRANSFER_DONE (files=0) we intentionally ignore while
              // recording; once IDLE is seen, finish the leg after a short
              // quiet period instead of waiting 3 minutes.
              final sessionEnded =
                  deviceReportedIdle || myTransfer.sessionEndedOnDevice;
              final totalSlices = bleXferDeviceTotalFiles;
              // totalSlices==0 means slice count unknown — treat as incomplete.
              final slicesIncomplete =
                  totalSlices <= 0 || fileCompleteCount < totalSlices;
              // After STOP the firmware may pause between slice files; a 2s gap
              // must not end the leg while 0001..00NN are still in flight.
              // The app disabled this link's fileData notify to flush AT+STOP on
              // iOS, so no more bytes can arrive on this leg. Don't wait the full
              // 180s — pause for resync quickly so the post-stop resume re-issues
              // AT+DOWNLOAD (which re-enables the notify) and continues from
              // received bytes.
              final notifyDead = myTransfer.fileNotifyDisabledWhileActive;
              final expForNear = bleXferDeviceSessionBytes > 0
                  ? bleXferDeviceSessionBytes
                  : (cachedExpectedBytes ?? expectedBytes);
              final declared = bleFrameState.currentFileDeclaredSize;
              final nearSession = expForNear != null &&
                  expForNear > 0 &&
                  received >= (expForNear * 0.90).round();
              final nearFile = declared > 0 &&
                  bleFrameState.bytesThisFile >= (declared * 0.90).round();
              final nearComplete = nearSession || nearFile;
              final Duration idleCap;
              if (sessionEnded) {
                if (!slicesIncomplete) {
                  idleCap = const Duration(seconds: 2);
                } else if (notifyDead) {
                  idleCap = const Duration(seconds: 5);
                } else if (nearComplete) {
                  // iOS background often freezes notify a few KB short of
                  // FILE_END — don't sit at ~92% for 3 minutes.
                  idleCap = const Duration(seconds: 12);
                } else {
                  idleCap = const Duration(seconds: 45);
                }
              } else if (nearComplete) {
                idleCap = const Duration(seconds: 20);
              } else {
                idleCap = const Duration(seconds: stallSeconds);
              }
              if (received > 0 && idleFor >= idleCap) {
                if (sessionEnded) {
                  if (slicesIncomplete) {
                    AppLog.w(
                      'downloadSessionToLocal: post-IDLE quiet '
                      '${idleFor.inSeconds}s (cap=${idleCap.inSeconds}s) but slices incomplete '
                      '($fileCompleteCount/$totalSlices nearComplete=$nearComplete) — '
                      'pausing for resync (not merging partial session)',
                    );
                    stalledNoData3MinLeg = true;
                  } else {
                    AppLog.i(
                      'downloadSessionToLocal: continuous: post-IDLE quiet '
                      '${idleFor.inSeconds}s — finishing leg '
                      '(slices=$fileCompleteCount/$totalSlices)',
                    );
                  }
                } else {
                  AppLog.w(
                    'downloadSessionToLocal: no data ${idleFor.inSeconds}s '
                    '(>=${idleCap.inSeconds}s), pausing transfer (stalled_no_data_3min)',
                  );
                  stalledNoData3MinLeg = true;
                }
                if (!legDone.isCompleted) legDone.complete();
              }
              return;
            }

            final noDataThreshold = deviceReportedIdle
                ? const Duration(seconds: 5)
                : const Duration(seconds: 10);
            if (idleFor < noDataThreshold) return;

            AppLog.i(
              'downloadSessionToLocal: no data ${idleFor.inSeconds}s (non-continuous), finishing leg without GSTAT',
            );
            if (!legDone.isCompleted) legDone.complete();
          });

          final legWinner = await Future.any([
            legDone.future.then((_) => 'leg'),
            disconnectPair.future.then((_) => 'disconnect'),
          ]);
          if (legWinner == 'disconnect' && !legDone.isCompleted) {
            throw StateError('device disconnected');
          }

          downloading = false;
          await fileSub?.cancel();
          fileSub = null;
          await jsonSub?.cancel();
          jsonSub = null;
          watchdog.cancel();
          watchdog = null;
          if (myTransfer.waitCompleter == legDone) {
            myTransfer.waitCompleter = null;
          }

          if (myTransfer.cancelRequested) {
            break transferLegLoop;
          }

          // Session ended while this leg's fileData notify was already dead
          // (iOS STOP link flush). Pause as a resumable stalled leg so the
          // post-stop resume re-downloads the remaining bytes right away.
          if (myTransfer.resyncRequested) {
            myTransfer.resyncRequested = false;
            stalledNoData3MinLeg = true;
            AppLog.i(
              'downloadSessionToLocal: resync requested (fileData notify '
              'dropped on STOP) — pausing leg for immediate resume',
            );
            break transferLegLoop;
          }

          if (stalledNoData3MinLeg) {
            break transferLegLoop;
          }

          if (legEndReason == _BleTransferLegEnd.crcResync &&
              crcResyncStartFile != null) {
            crcFailureCount++;
            if (crcFailureCount > maxCrcResyncAttempts) {
              throw StateError(
                'BLE FILE_END CRC mismatch after $maxCrcResyncAttempts resync attempts; start=$crcResyncStartFile',
              );
            }
            AppLog.i(
              'downloadSessionToLocal: CRC resync $crcFailureCount/$maxCrcResyncAttempts → next AT+DOWNLOAD from $crcResyncStartFile',
            );
            try {
              await bleFileNotifyChain;
            } catch (e, st) {
              AppLog.w(
                'downloadSessionToLocal: notify chain before CRC resync leg',
                e,
                st,
              );
            }
            startFileForDownload = crcResyncStartFile;
            deviceReportedIdle = false;
            bleFrameState.useFraming = false;
            bleFrameState.currentFilename = null;
            bleFrameState.currentFileDeclaredSize = 0;
            bleFrameState.bytesThisFile = 0;
            bleFrameState.fileCrc = 0;
            bleFrameState.nextSeq = 0;
            continue transferLegLoop;
          }
          // See `zeroByteIdleRetryCount` declaration above. Order matters:
          // place this BEFORE the unconditional `break transferLegLoop` and
          // AFTER the cancel/stalled/crc/spuriousTD paths so we don't fight
          // them.
          if (continuous &&
              received == 0 &&
              deviceReportedIdle &&
              !myTransfer.cancelRequested &&
              legEndReason == _BleTransferLegEnd.unknown &&
              zeroByteIdleRetryCount < maxZeroByteIdleRetries) {
            zeroByteIdleRetryCount++;
            AppLog.w(
              'downloadSessionToLocal: continuous: leg ended with received=0 '
              'after device IDLE (likely firmware "File read error: -9" race) — '
              'retry AT+DOWNLOAD ($zeroByteIdleRetryCount/$maxZeroByteIdleRetries) '
              'after AT+CANCEL settle',
            );
            try {
              await bleFileNotifyChain;
            } catch (e, st) {
              AppLog.w(
                'downloadSessionToLocal: notify chain before zero-byte IDLE '
                'retry leg',
                e,
                st,
              );
            }
            try {
              await _sendAtWithDisconnect(conn, at, 'AT+CANCEL',
                  timeout: const Duration(seconds: 5));
            } catch (e, st) {
              AppLog.w(
                'downloadSessionToLocal: AT+CANCEL before zero-byte IDLE '
                'retry failed',
                e,
                st,
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 600));
            // Restart from the beginning of the session: nothing was
            // received, so we don't have a partial file to resume from.
            startFileForDownload = null;
            deviceReportedIdle = false;
            bleFrameState.useFraming = false;
            bleFrameState.currentFilename = null;
            bleFrameState.currentFileDeclaredSize = 0;
            bleFrameState.bytesThisFile = 0;
            bleFrameState.fileCrc = 0;
            bleFrameState.nextSeq = 0;
            legEndReason = _BleTransferLegEnd.unknown;
            continue transferLegLoop;
          }
          if (legEndReason == _BleTransferLegEnd.spuriousTdResume &&
              spuriousTdResumeStartFile != null) {
            AppLog.i(
              'downloadSessionToLocal: spurious TRANSFER_DONE — next AT+DOWNLOAD from '
              '$spuriousTdResumeStartFile',
            );
            try {
              await bleFileNotifyChain;
            } catch (e, st) {
              AppLog.w(
                'downloadSessionToLocal: notify chain before spurious TD resume leg',
                e,
                st,
              );
            }
            try {
              await _sendAtWithDisconnect(conn, at, 'AT+CANCEL',
                  timeout: const Duration(seconds: 5));
            } catch (e, st) {
              AppLog.w(
                'downloadSessionToLocal: AT+CANCEL before spurious TD resume failed',
                e,
                st,
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 400));
            startFileForDownload = spuriousTdResumeStartFile;
            spuriousTdResumeStartFile = null;
            deviceReportedIdle = false;
            bleFrameState.useFraming = false;
            bleFrameState.currentFilename = null;
            bleFrameState.currentFileDeclaredSize = 0;
            bleFrameState.bytesThisFile = 0;
            bleFrameState.fileCrc = 0;
            bleFrameState.nextSeq = 0;
            legEndReason = _BleTransferLegEnd.unknown;
            continue transferLegLoop;
          }
          break transferLegLoop;
        }

        try {
          await bleFileNotifyChain;
        } catch (e, st) {
          AppLog.w(
            'downloadSessionToLocal: BLE notify chain before finalize/merge',
            e,
            st,
          );
        }

        if (myTransfer.cancelRequested) {
          final code = myTransfer.cancelErrorCode ?? cancelTransferReason;
          if (code == 'already_synced') {
            return true;
          }
          final benign = isBenignTransferPauseCode(code);
          await recRepo.updateTransfer(
            id: recordingId,
            state: 'transferring',
            progress: expectedBytes != null && expectedBytes > 0
                ? (received / expectedBytes).clamp(0.0, 0.99)
                : null,
            errorCode: benign ? '' : code,
            error: benign ? '' : null,
            receivedBytes: received,
            expectedBytes: expectedBytes != null && expectedBytes > 0
                ? expectedBytes
                : null,
            transferStartedAt: startedAt,
            recordingState: 'transferring',
          );
          bumpRecordingsLists(ref);
          ref.invalidate(recordingByIdProvider(recordingId));
          return false;
        }

        // Close and finalize any remaining tmp data (best-effort).
        // If we didn't get a final file_complete, keep the last partial part as a normal .opus.
        await finalizeCurrentFile(
            fileCompleteCount > 0 ? '' : 'part_last.opus');
        // Brief wait so in-flight file_complete callbacks can finish renames, avoiding mergeAllParts vs finalizeCurrentFile races.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final totalSlicesForMerge = bleXferDeviceTotalFiles;
        final sliceCountKnown = totalSlicesForMerge > 1;
        // `fileCompleteCount` tracks file_complete callbacks for THIS leg; it can
        // over-count what is actually on disk if a slice was dropped at rename or
        // deleted as a 0-byte file (esp. iOS write-behind). It can also UNDER the
        // real picture: the firmware slice total (`bleXferDeviceTotalFiles`) can
        // run ahead by one during record-while-transfer / reconnect (e.g. it
        // reports total=5 for a 4-slice session). So decide completeness from the
        // on-disk inventory, and treat BYTES as authoritative: if the contiguous
        // local slices already sum to the device session size, the recording is
        // whole regardless of an off-by-one file count. Only when bytes are ALSO
        // short do we treat a slice-count shortfall as a truncated tail.
        final sessBytesForMerge = bleXferDeviceSessionBytes > 0
            ? bleXferDeviceSessionBytes
            : (cachedExpectedBytes ?? expectedBytes ?? 0);
        var localSlicesComplete = false;
        var localMaxIndex = 0;
        var localMissingCount = 0;
        var localContiguousBytes = 0;
        if (sliceCountKnown) {
          try {
            final sd =
                Directory(await _deviceSessionDirectory(deviceId, sessionId));
            if (sd.existsSync()) {
              final partFiles = sd.listSync().whereType<File>().where((f) {
                final lower = f.path.toLowerCase();
                return lower.endsWith('.opus') || lower.endsWith('.opus.part');
              }).toList();
              final nonEmpty = <File>[];
              for (final f in partFiles) {
                try {
                  if (await f.length() > 0) nonEmpty.add(f);
                } catch (_) {}
              }
              final inv = inventorySessionOpusParts(nonEmpty);
              localMaxIndex = inv.maxIndex;
              localMissingCount = inv.missingIndices.length;
              for (final f in inv.orderedCompleteSlices) {
                try {
                  localContiguousBytes += await f.length();
                } catch (_) {}
              }
              final byteComplete = sessBytesForMerge > 0 &&
                  localContiguousBytes >= (sessBytesForMerge * 0.98).round();
              final sliceComplete = inv.maxIndex >= totalSlicesForMerge &&
                  inv.missingIndices.isEmpty;
              localSlicesComplete = byteComplete || sliceComplete;
            }
          } catch (_) {}
        }
        // Slice-count shortfall alone is not enough — the firmware total can be
        // inflated. Require BOTH a slice-count shortfall AND a byte shortfall
        // before refusing to merge, so a complete recording with an off-by-one
        // total still merges.
        final slicesIncomplete = sliceCountKnown && !localSlicesComplete;
        final bytesIncomplete = !sliceCountKnown &&
            sessBytesForMerge > 0 &&
            received < (sessBytesForMerge * 0.95).round();
        // Short recording (< one 2‑min slice) paused/stopped before any slice
        // finished: this leg pulled nothing (received == 0, no completed file).
        // Don't run it through the incomplete‑resume / give‑up bookkeeping or
        // surface `stalled_no_data_3min` — both flash a transient error in the
        // banner + file list for a clip that only lasted a few seconds. Keep the
        // row benign so the immediate post‑pause/stop resume just shows the
        // normal download (matches how the > 2‑min case already behaves).
        if (stalledNoData3MinLeg && received <= 0 && fileCompleteCount <= 0) {
          AppLog.i(
            'downloadSessionToLocal: empty short leg paused/stopped before any '
            'complete slice (received=$received files=$fileCompleteCount) — '
            'keeping row benign, deferring to post‑stop resume '
            '(recording=$recordingId)',
          );
          final eb = cachedExpectedBytes ?? expectedBytes;
          await recRepo.updateTransfer(
            id: recordingId,
            state: 'transferring',
            errorCode: '',
            error: '',
            receivedBytes: received,
            expectedBytes: eb != null && eb > 0 ? eb : null,
            transferStartedAt: startedAt,
            recordingState: 'transferring',
          );
          bumpRecordingsLists(ref);
          ref.invalidate(recordingByIdProvider(recordingId));
          refreshTransferProgressUI();
          stalledNoData3MinLeg = false;
          return false;
        }
        if (slicesIncomplete || bytesIncomplete) {
          final attempts = (_incompleteResumeAttempts[recordingId] ?? 0) + 1;
          _incompleteResumeAttempts[recordingId] = attempts;
          AppLog.w(
            'downloadSessionToLocal: skip merge — firmware payload incomplete '
            '($fileCompleteCount/$totalSlicesForMerge received=$received '
            'sessionBytes=$sessBytesForMerge localMax=$localMaxIndex '
            'localMissing=$localMissingCount localBytes=$localContiguousBytes) '
            'attempt=$attempts/$_maxIncompleteResumeAttempts',
          );
          // Bail out of the resume loop once we have re-downloaded this session
          // [_maxIncompleteResumeAttempts] times without ever reaching `total`.
          // Re-pulling forever (a slice truly missing/corrupt on device, or a
          // persistent total mismatch) just burns BLE/battery. Salvage-merge
          // whatever complete local slices we have; if even that fails, mark
          // failed so the transfer queue drains instead of spinning.
          if (attempts >= _maxIncompleteResumeAttempts) {
            _incompleteResumeAttempts.remove(recordingId);
            // When the device demonstrably still holds slices we don't have
            // locally (e.g. the tail slice keeps timing out under BLE
            // congestion), salvaging now would merge only what we have and mark
            // a SHORT recording as "done" — silently dropping the tail (user
            // sees 27 min instead of 28). The device file is preserved
            // (post-merge cleanup skips AT+DELETE while local is short), so keep
            // the transfer resumable and let a later, less-congested sync finish
            // it. Only escalate to "failed" (never a short "done") after several
            // give-up cycles so we never spin forever.
            final deviceHasMore = sliceCountKnown && !localSlicesComplete;
            if (deviceHasMore) {
              final eb = cachedExpectedBytes ?? expectedBytes;
              final expProg = eb != null && eb > 0
                  ? (received / eb).clamp(0.0, 0.99)
                  : _transferProgressOrNull(received, expectedBytes);
              final cycles = (_incompleteGiveupCycles[recordingId] ?? 0) + 1;
              _incompleteGiveupCycles[recordingId] = cycles;
              if (cycles >= _maxIncompleteGiveupCycles) {
                _incompleteGiveupCycles.remove(recordingId);
                AppLog.w(
                  'downloadSessionToLocal: tail unrecoverable after $cycles '
                  'give-up cycles (session=$sessionId local=$localMaxIndex/'
                  '$totalSlicesForMerge) — marking failed for manual re-sync, '
                  'NOT salvaging a short recording',
                );
                await recRepo.updateTransfer(
                  id: recordingId,
                  state: 'failed',
                  progress: expProg,
                  errorCode: 'transfer_incomplete_giveup',
                  receivedBytes: received,
                  expectedBytes: eb != null && eb > 0 ? eb : null,
                  transferStartedAt: startedAt,
                  transferFinishedAt: DateTime.now(),
                  recordingState: 'failed',
                );
                bumpRecordingsLists(ref);
                ref.invalidate(recordingByIdProvider(recordingId));
                return false;
              }
              AppLog.w(
                'downloadSessionToLocal: give up this leg but device still has '
                'slices (local=$localMaxIndex/$totalSlicesForMerge) — keep '
                'resumable (cycle $cycles/$_maxIncompleteGiveupCycles), NOT '
                'salvaging short',
              );
              await recRepo.updateTransfer(
                id: recordingId,
                state: 'transferring',
                progress: expProg,
                // Auto-resume scheduled — avoid flashing list/banner resync.
                errorCode: '',
                error: '',
                receivedBytes: received,
                expectedBytes: eb != null && eb > 0 ? eb : null,
                transferStartedAt: startedAt,
                recordingState: 'transferring',
              );
              bumpRecordingsLists(ref);
              ref.invalidate(recordingByIdProvider(recordingId));
              _scheduleResumeIncompleteTransfersAfterBleTransfer();
              return false;
            }
            AppLog.w(
              'downloadSessionToLocal: giving up resume after $attempts attempts '
              '(session=$sessionId $fileCompleteCount/$totalSlicesForMerge) — '
              'salvage-merging local parts',
            );
            final salvaged = await _mergeAndCompleteFromLocalParts(
                recordingId, deviceId, sessionId, cachedExpectedBytes ?? expectedBytes);
            if (salvaged) return true;
            await recRepo.updateTransfer(
              id: recordingId,
              state: 'failed',
              errorCode: 'transfer_incomplete_giveup',
              receivedBytes: received,
              transferFinishedAt: DateTime.now(),
              recordingState: 'failed',
            );
            bumpRecordingsLists(ref);
            ref.invalidate(recordingByIdProvider(recordingId));
            return false;
          }
          final eb = cachedExpectedBytes ?? expectedBytes;
          var effectiveReceived = received;
          if (eb != null && eb > 0 && received > eb) {
            effectiveReceived = _reconcileTransferReceivedBytes(
              preserved: received,
              local: localContiguousBytes,
              expected: eb,
            );
            AppLog.i(
              'downloadSessionToLocal: reconcile received $received → '
              '$effectiveReceived for resume (expected=$eb localBytes=$localContiguousBytes)',
            );
          }
          var expProg = eb != null && eb > 0
              ? (effectiveReceived / eb).clamp(0.0, 0.99)
              : _transferProgressOrNull(effectiveReceived, expectedBytes);
          await recRepo.updateTransfer(
            id: recordingId,
            state: 'transferring',
            progress: expProg,
            // Auto-resume is scheduled below — keep list/banner passive.
            errorCode: '',
            error: '',
            receivedBytes: effectiveReceived,
            expectedBytes: eb != null && eb > 0 ? eb : null,
            transferStartedAt: startedAt,
            recordingState: 'transferring',
          );
          bumpRecordingsLists(ref);
          ref.invalidate(recordingByIdProvider(recordingId));
          _scheduleResumeIncompleteTransfersAfterBleTransfer();
          return false;
        }
        if (stalledNoData3MinLeg) {
          final eb = expectedBytes;
          var expProg = eb != null && eb > 0
              ? (received / eb).clamp(0.0, 0.99)
              : _transferProgressOrNull(received, expectedBytes);
          final expFromCache = cachedExpectedBytes;
          if (expProg == null && expFromCache != null && expFromCache > 0) {
            expProg = (received / expFromCache).clamp(0.0, 0.99);
          }
          // Keep the row benign while auto-resume re-issues AT+DOWNLOAD.
          // Writing `stalled_no_data_3min` here flashes the list/banner resync
          // control between legs (very visible on short iOS clips).
          await recRepo.updateTransfer(
            id: recordingId,
            state: 'transferring',
            progress: expProg,
            errorCode: '',
            error: '',
            receivedBytes: received,
            expectedBytes: eb != null && eb > 0
                ? eb
                : (expFromCache != null && expFromCache > 0
                    ? expFromCache
                    : null),
            transferStartedAt: startedAt,
            recordingState: 'transferring',
          );
          bumpRecordingsLists(ref);
          ref.invalidate(recordingByIdProvider(recordingId));
          refreshTransferProgressUI();
          stalledNoData3MinLeg = false;
          // Auto-retry after iOS BG freeze / near-complete stall — do not wait
          // for a manual "resync" tap.
          _scheduleResumeIncompleteTransfersAfterBleTransfer();
          return false;
        }
        final merged = await mergeAllParts(
          expectedTotalFiles:
              sliceCountKnown ? totalSlicesForMerge : null,
        );
        if (merged) {
          _incompleteResumeAttempts.remove(recordingId);
          _incompleteGiveupCycles.remove(recordingId);
        }
        return merged;
      } catch (e) {
        // Device disconnected (e.g. iOS screen off causes BLE disconnect): do not run salvage merge, keep transferring for resume after reconnect.
        // Otherwise would wrongly trigger mergeAllParts -> AT+MARKS -> AT+DELETE and mark transfer as "complete".
        final isDisconnect = _isDisconnectError(e);
        final idleMs = DateTime.now().difference(lastDataAt).inMilliseconds;
        AppLog.w(
          'downloadSessionToLocal: catch received=$received lastDataAt=${idleMs}ms ago isDisconnect=$isDisconnect',
          e,
          StackTrace.current,
        );

        // Non-disconnect exception but still receiving recently: may be transient, wait briefly for in-flight data before finalize.
        if (!isDisconnect && received > 0 && idleMs < 3000) {
          final receivedBeforeWait = received;
          AppLog.i(
              'downloadSessionToLocal: catch but still receiving recently (${idleMs}ms ago), waiting 2s for in-flight data');
          await Future<void>.delayed(const Duration(seconds: 2));
          AppLog.i(
              'downloadSessionToLocal: after 2s wait received=$received (was $receivedBeforeWait, +${received - receivedBeforeWait})');
        }

        if (!isDisconnect) {
          final row = await recRepo.getById(recordingId);
          if (row?.transferState == 'done') {
            return true;
          }
          if (await tryCompleteTransferFromLocalPartsIfReady(recordingId)) {
            return true;
          }
          // Best-effort salvage: only merge when expectedBytes is known and received>=90%.
          // During record-while-transfer expectedBytes is null, do not merge (battery notify etc. may trigger catch; if exp<=0 merge would wrongly delete device session).
          try {
            downloading = false;
            await finalizeCurrentFile(
                fileCompleteCount > 0 ? '' : 'part_last.opus');
            if (received > 0) {
              var exp = expectedBytes ?? 0;
              if (exp <= 0) {
                final rec = await recRepo.getById(recordingId);
                exp = rec?.expectedBytes ?? 0;
              }
              // Only salvage merge when total size known and received >= 90%; record-while-transfer (exp<=0) do not merge, keep transferring
              if (exp > 0 && received >= exp * 0.9) {
                final merged = await mergeAllParts();
                if (merged) return true;
              }
            }
          } catch (_) {}
        } else {
          // On disconnect still finalize current part so resume after reconnect works correctly
          try {
            downloading = false;
            await finalizeCurrentFile(
                fileCompleteCount > 0 ? '' : 'part_last.opus');
          } catch (_) {}
        }

        // When device disconnects keep transferring so _resumeIncompleteTransfers can resume after reconnect.
        // Other exceptions (timeout, checksum fail, etc.) mark as failed.
        if (isDisconnect) {
          AppLog.i(
              'downloadSessionToLocal: device disconnected during transfer, keeping transferring for resume');
          await recRepo.updateTransfer(
            id: recordingId,
            state: 'transferring',
            progress: expectedBytes != null && expectedBytes > 0
                ? (received / expectedBytes).clamp(0.0, 0.99)
                : null,
            errorCode: 'device_disconnected_resume_after_reconnect',
            receivedBytes: received,
            expectedBytes: expectedBytes != null && expectedBytes > 0
                ? expectedBytes
                : null,
            transferStartedAt: startedAt,
            recordingState: 'transferring',
          );
        } else {
          await recRepo.updateTransfer(
            id: recordingId,
            state: 'failed',
            error: e.toString(),
            receivedBytes: received,
            expectedBytes: expectedBytes != null && expectedBytes > 0
                ? expectedBytes
                : null,
            transferStartedAt: startedAt,
            transferFinishedAt: DateTime.now(),
            recordingState: 'failed',
          );
        }
        bumpRecordingsLists(ref);
        ref.invalidate(recordingByIdProvider(recordingId));
        return false;
      } finally {
        downloading = false;
        try {
          await progressWriteChain;
        } catch (_) {}
        // Phase 2: per-device unregister. Drops `myTransfer` from
        // `_transfersByDevice`, and (only if it was the foreground mirror)
        // clears `_activeTransferRecordingId` + UI state.
        deferBleChainReleaseForFirmwareCancel = myTransfer.cancelRequested;
        _unregisterTransfer(myTransfer);
        myTransfer.waitCompleter = null;
        myTransfer.cancelRequested = false;
        myTransfer.cancelErrorCode = null;
        progressRefreshTimer.cancel();
        progressLogTimer?.cancel();
        watchdog?.cancel();
        disconnectPair.cancel();
        try {
          await currentSink?.flush();
          await currentSink?.close();
        } catch (_) {}
        fileSub?.cancel();
        jsonSub?.cancel();
      }
    } finally {
      if (deferBleChainReleaseForFirmwareCancel) {
        await Future<void>.delayed(const Duration(milliseconds: 650));
      }
      bleDownloadGate.complete();
      if (_bleDownloadExclusiveChainByDevice[chainDeviceId] == chainFuture) {
        _bleDownloadExclusiveChainByDevice.remove(chainDeviceId);
      }
      unawaited(drainPostMergeBleCleanupQueue());
    }
  }

  /// After transfer completes, fetch bookmarks and save as JSON (aligned with Python get_bookmarks + bookmarks.json).
  /// Pages through all bookmarks (matches py_test get_bookmarks).
  Future<void> _fetchAndSaveBookmarks(
    SenseCraftVoiceConnection conn,
    AtTransport at,
    String sessionId,
    String mergedPath,
  ) async {
    try {
      final bookmarks = <Map<String, dynamic>>[];
      var page = 1;
      while (true) {
        final cmd = 'AT+MARKS=$sessionId?$page&$_listPerPage';
        var resp = await _sendAtWithDisconnect(conn, at, cmd,
            timeout: const Duration(seconds: 6));
        if (resp['ok'] != true && page == 1) {
          resp = await _sendAtWithDisconnect(conn, at, 'AT+MARKS=$sessionId',
              timeout: const Duration(seconds: 6));
        }
        if (resp['ok'] != true) break;
        final data = resp['data'];
        final dataMap = data is Map
            ? Map<String, dynamic>.from(data)
            : const <String, dynamic>{};
        final list = dataMap['bookmarks'];
        final items = list is List ? list : <dynamic>[];
        for (final b in items) {
          if (b is! Map) continue;
          final m = Map<String, dynamic>.from(b);
          bookmarks.add({
            'offset': m['offset'] ?? 0,
            'note': (m['note'] ?? '').toString(),
          });
        }
        final total = _parseInt(dataMap['total']) ?? bookmarks.length;
        if (bookmarks.length >= total || items.isEmpty) break;
        page++;
        if ((page - 1) * _listPerPage >= total) break;
      }
      final dir = p.dirname(mergedPath);
      final base = p.basenameWithoutExtension(mergedPath);
      final path = p.join(dir, '${base}_bookmarks.json');
      final file = File(path);
      await file.writeAsString(jsonEncode(bookmarks), encoding: utf8);
      if (bookmarks.isNotEmpty) {
        AppLog.i(
            'downloadSessionToLocal: saved ${bookmarks.length} bookmarks to $path');
      }
    } catch (e, st) {
      AppLog.w('downloadSessionToLocal: AT+MARKS failed (non-fatal)', e, st);
    }
  }

  static int? _partNumberFromFilename(String name) =>
      partNumberFromSessionOpusFilename(name);

  /// Resume from breakpoint: compute bytes and file count already received before resume from existing parts in sessionDir.
  /// If startFile is e.g. "0006.opus", only count files with part index < 6, for correct progress and duration display.
  static Future<({int bytes, int fileCount})>
      _computeInitialReceivedFromLocalParts(
    Directory sessionDir,
    String startFile,
  ) async {
    final startNum = _partNumberFromFilename(startFile);
    if (startNum == null) return (bytes: 0, fileCount: 0);
    if (!sessionDir.existsSync()) return (bytes: 0, fileCount: 0);

    final files = sessionDir.listSync().whereType<File>().where((f) {
      final name = p.basename(f.path).toLowerCase();
      return name.endsWith('.opus') || name.endsWith('.opus.part');
    }).toList();

    Future<int> partLastTailBytes() async {
      var sum = 0;
      for (final f in files) {
        final bn = p.basename(f.path).toLowerCase();
        if (!bn.startsWith('part_last')) continue;
        try {
          sum += await f.length();
        } catch (e) {
          if (e is PathNotFoundException ||
              e.toString().contains('No such file')) {
            continue;
          }
          rethrow;
        }
      }
      return sum;
    }

    // File-level resume cannot continue inside `part_last`; restart 0001 and
    // ignore the stale tail for progress. Merge inventory also ignores it once
    // a complete numbered slice exists.
    if (startNum <= 1) {
      return (bytes: 0, fileCount: 0);
    }

    int total = 0;
    int count = 0;
    for (final f in files) {
      final n = _partNumberFromFilename(p.basename(f.path));
      if (n != null && n < startNum) {
        try {
          total += await f.length();
          count++;
        } catch (e) {
          // Race with file_complete: between listSync and length, file_complete may have renamed _part_*.part to NNNN.opus.
          if (e is PathNotFoundException ||
              e.toString().contains('No such file')) {
            continue;
          }
          rethrow;
        }
      }
    }
    // Mid-slice tail saved as part_last* is not indexed < startNum (part_last sorts as 999999).
    total += await partLastTailBytes();
    return (bytes: total, fileCount: count);
  }

  static int? _parseInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  /// GSTAT `recording` field: `null` if absent (legacy firmware — fall back to `state` only).
  static bool? _parseTriBool(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return null;
  }

  static bool? _parseChargingFromGstat(Map<String, dynamic> dataMap) {
    final v = dataMap['charging'];
    if (v == true) return true;
    if (v == false) return false;
    if (v is num) return v != 0;
    final s = v?.toString().trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
    return null;
  }

  /// Best-effort align device RTC with the phone clock via `AT+TIME=<unix_s>`.
  ///
  /// [force] skips the 1 h idle throttle (connect, device details entry).
  /// Returns true when the command acked ok; failures are non-fatal.
  Future<bool> syncDeviceTime({bool force = false}) async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return false;

    final deviceId = conn.device.remoteId.toString();
    if (!force) {
      final last = _lastDeviceTimeSyncAt[deviceId];
      if (last != null &&
          DateTime.now().difference(last) < _kDeviceTimeSyncMinInterval) {
        AppLog.i(
          'syncDeviceTime: skip $deviceId '
          '(last ok ${DateTime.now().difference(last).inMinutes}m ago)',
        );
        return false;
      }
    }

    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final resp = await _sendAtWithDisconnect(conn, at, 'AT+TIME=$ts',
          timeout: const Duration(seconds: 4));
      if (resp['ok'] == true) {
        _lastDeviceTimeSyncAt[deviceId] = DateTime.now();
        AppLog.i('syncDeviceTime: ok deviceId=$deviceId ts=$ts force=$force');
        return true;
      }
      AppLog.w('syncDeviceTime: ok=false resp=$resp');
      return false;
    } catch (e, st) {
      AppLog.w('syncDeviceTime failed', e, st);
      return false;
    }
  }

  /// Record that the user opened device details (starts the 1 h idle window).
  void markDeviceDetailsVisited() {
    _lastDeviceDetailsVisitAt = DateTime.now();
  }

  /// Device details entry: sync RTC only when not recording or transferring.
  Future<void> syncDeviceTimeOnDetailsEntry() async {
    markDeviceDetailsVisited();
    if (!_isDeviceIdleForTimeSync()) {
      AppLog.i('syncDeviceTimeOnDetailsEntry: skip (recording or transfer in progress)');
      return;
    }
    await syncDeviceTime(force: true);
  }

  /// True when the foreground link is not recording or syncing files.
  bool _isDeviceIdleForTimeSync() {
    if (_wifiHandoffActive) return false;
    if ((_activeRecordingSessionId ?? '').trim().isNotEmpty) return false;
    final fw = state.firmwareRecState;
    if (fw == 'recording' || fw == 'paused' || fw == 'transmitting') {
      return false;
    }
    if (_activeTransferRecordingId != null) return false;
    if (_bleTransferGuardForRecordingStart) return false;
    try {
      if (ref.read(wifiTransferControllerProvider).isActive) return false;
    } catch (_) {}
    return true;
  }

  /// While the user stays on other pages (not device details) for ≥1 h, and the
  /// device is idle, re-sync RTC. Eligibility re-checked every
  /// [_kIdleTimeSyncCheckInterval] from [DeviceStatusPoller].
  Future<void> maybeSyncDeviceTimeWhenIdle() async {
    if (_disposed) return;
    final now = DateTime.now();
    if (now.isBefore(_nextIdleTimeSyncCheckAt)) return;
    _nextIdleTimeSyncCheckAt = now.add(_kIdleTimeSyncCheckInterval);

    if (state.connection == null || _at == null) return;
    if (!_isDeviceIdleForTimeSync()) return;

    final deviceId = state.connection!.device.remoteId.toString();
    final lastSync = _lastDeviceTimeSyncAt[deviceId];
    if (lastSync != null &&
        now.difference(lastSync) < _kDeviceTimeSyncMinInterval) {
      return;
    }

    final lastDetails = _lastDeviceDetailsVisitAt;
    if (lastDetails != null) {
      if (now.difference(lastDetails) < _kDeviceTimeSyncMinInterval) return;
    } else {
      final connectedAt = _lastConnectedAt;
      if (connectedAt == null ||
          now.difference(connectedAt) < _kDeviceTimeSyncMinInterval) {
        return;
      }
    }

    AppLog.i(
      'maybeSyncDeviceTimeWhenIdle: syncing $deviceId '
      '(idle, >=1h since details visit or connect)',
    );
    await syncDeviceTime(force: true);
  }

  /// Run a "basic info" AT test similar to Python test_01_basic:
  /// - AT+VERSION
  /// - AT+TIME?
  /// - AT+GSTAT
  /// - AT+PAIR?
  ///
  /// Returns a [DeviceRuntimeInfo] object; null if not connected.
  Future<DeviceRuntimeInfo?> readRuntimeInfo() async {
    final conn = state.connection;
    final at = _at;
    if (conn == null || at == null) return null;

    String? firmware;
    String? deviceTime;
    String? stateStr;
    int? battery;
    String? mode;
    String? pairStatus;
    String? pairAddr;

    try {
      // 1) VERSION
      try {
        final resp =
            await at.send('AT+VERSION', timeout: const Duration(seconds: 5));
        if (resp['ok'] == true) {
          final rootFirmware = (resp['firmware'] ?? '').toString().trim();
          final data = resp['data'];
          final dataMap = data is Map
              ? Map<String, dynamic>.from(data)
              : const <String, dynamic>{};
          final dataFirmware = (dataMap['firmware'] ?? '').toString().trim();
          firmware = (dataFirmware.isNotEmpty ? dataFirmware : rootFirmware);
        }
      } catch (e, st) {
        AppLog.w('AT+VERSION failed (readRuntimeInfo)', e, st);
      }

      // 2) TIME?
      try {
        final resp =
            await at.send('AT+TIME?', timeout: const Duration(seconds: 4));
        if (resp['ok'] == true) {
          // Some firmwares may return {"time": ...}, others {"data":{"time":...}}
          final rootTime = resp['time'];
          final data = resp['data'];
          final dataMap = data is Map
              ? Map<String, dynamic>.from(data)
              : const <String, dynamic>{};
          final dataTime = dataMap['time'];
          final t = (dataTime ?? rootTime);
          if (t != null) deviceTime = formatDeviceAtTime(t);
        }
      } catch (e, st) {
        AppLog.w('AT+TIME? failed (readRuntimeInfo)', e, st);
      }

      // 3) GSTAT
      try {
        final resp =
            await at.send('AT+GSTAT', timeout: const Duration(seconds: 4));
        if (resp['ok'] == true) {
          final data = resp['data'];
          final dataMap = data is Map
              ? Map<String, dynamic>.from(data)
              : const <String, dynamic>{};
          stateStr = (dataMap['state'] ?? '').toString();
          battery = _parseInt(dataMap['battery']);
          mode = (dataMap['mode'] ?? '').toString();
        }
      } catch (e, st) {
        AppLog.w('AT+GSTAT failed (readRuntimeInfo)', e, st);
      }

      // 4) PAIR?
      try {
        final resp =
            await at.send('AT+PAIR?', timeout: const Duration(seconds: 6));
        if (resp['ok'] == true) {
          pairStatus = (resp['value'] ?? resp['status'] ?? '').toString();
          pairAddr = (resp['addr'] ?? '').toString();
        }
      } on TimeoutException catch (e) {
        // Treat missing/slow PAIR? response as non-fatal: many firmwares only
        // reply when already bonded, or may drop the link during this call.
        AppLog.i('AT+PAIR? timeout (readRuntimeInfo): $e');
      } catch (e, st) {
        AppLog.w('AT+PAIR? failed (readRuntimeInfo)', e, st);
      }

      return DeviceRuntimeInfo(
        firmware: firmware,
        deviceTime: deviceTime,
        state: stateStr,
        batteryPercent: battery,
        mode: mode,
        pairStatus: pairStatus,
        pairAddress: pairAddr,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }
}

class RecStatus {
  final String state; // idle | recording | paused | transmitting | error
  final int durationSeconds;
  final String? file;

  /// session_id when device is recording (from AT+GSTAT data.session_id)
  final String? sessionId;

  /// From AT+GSTAT `charging`; null when firmware did not report it.
  final bool? isCharging;
  const RecStatus(
      {required this.state,
      required this.durationSeconds,
      required this.file,
      this.sessionId,
      this.isCharging});
}

class RecStopResult {
  final String? file;
  final int durationSeconds;
  final int sizeBytes;
  const RecStopResult(
      {required this.file,
      required this.durationSeconds,
      required this.sizeBytes});
}

/// Local part file info for per-file validation.
class _LocalPartInfo {
  final String filename;
  final String path;
  final bool isComplete;
  const _LocalPartInfo(
      {required this.filename, required this.path, required this.isComplete});
}

/// Format firmware `AT+TIME?` value (often ISO-8601 UTC) for UI display.
String? formatDeviceAtTime(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  final dt = DateTime.tryParse(s);
  if (dt == null) return s;
  final local = dt.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm:$ss';
}

/// Basic runtime info, mirroring Python Test 1 (VERSION/TIME/GSTAT/PAIR).
class DeviceRuntimeInfo {
  final String? firmware;
  final String? deviceTime;
  final String? state;
  final int? batteryPercent;
  final String? mode;
  final String? pairStatus;
  final String? pairAddress;

  const DeviceRuntimeInfo({
    this.firmware,
    this.deviceTime,
    this.state,
    this.batteryPercent,
    this.mode,
    this.pairStatus,
    this.pairAddress,
  });
}
