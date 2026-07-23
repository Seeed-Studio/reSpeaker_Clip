import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/log/app_log.dart';
import '../../../core/observability/sentry_service.dart';
import '../../../core/server/sensecraft_paas/firmware_api.dart';
import '../../../core/server/sensecraft_paas/sensecraft_paas_providers.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/widgets/app_pill_button.dart';
import '../data/device_repository.dart';
import 'device_controller.dart';

final _deviceByIdProvider = FutureProvider.family<Device?, String>((ref, id) async {
  // Re-fetch when device info is persisted (battery/firmware/mode/online).
  // The cloud-update check below depends on a non-empty `firmwareVersion`
  // populated by `syncConnectedDeviceInfo` after BLE link-up, so we must
  // rebuild when that revision bumps.
  ref.watch(deviceDbRevisionProvider);
  final repo = await ref.watch(deviceRepositoryProvider.future);
  return repo.getById(id);
});

/// OTA firmware update page. Protocol: SMP 00001530-1212-EFDE-1523-785FEABCD123,
/// characteristic DA2E7828-FBCE-4E01-AE9E-261174997C48, aligned with noaflutterdemo and SenseCraft Voice Clip AT protocol doc.
class FirmwareUpdatePage extends ConsumerStatefulWidget {
  final String deviceId;

  const FirmwareUpdatePage({super.key, required this.deviceId});

  @override
  ConsumerState<FirmwareUpdatePage> createState() => _FirmwareUpdatePageState();
}

enum _FwUiStep { ready, uploading, success, failure }

enum _CloudCheckPhase { idle, checking, noUpdate, hasUpdate, downloading, downloaded, error }

class _FirmwareUpdatePageState extends ConsumerState<FirmwareUpdatePage> {
  _FwUiStep _step = _FwUiStep.ready;
  String _selectedFilePath = '';
  String _selectedFileName = '';
  int _selectedFileSize = 0;
  /// True when [_selectedFilePath] was populated by the cloud download flow.
  /// Used to label the UI ("From cloud" vs. "Local file") and to clean up the
  /// temp file after a successful OTA.
  bool _selectedFromCloud = false;
  /// Raw OTA byte progress; UI smooths display in [_ProgressView].
  final ValueNotifier<double> _otaProgressTarget = ValueNotifier<double>(0);
  StreamSubscription<OtaProgress>? _otaProgressSub;
  OtaSession? _otaSession;
  String _statusText = '';
  String? _errorMessage;
  RecStatus? _recStatus;
  bool _recStatusLoaded = false;

  // -- Cloud firmware check / download state ----------------------------
  _CloudCheckPhase _cloudPhase = _CloudCheckPhase.idle;
  FirmwareUpdateInfo? _cloudInfo;
  String? _cloudError;
  double _downloadProgress = 0;
  int _downloadBytesTotal = 0;
  CancelToken? _downloadCancel;
  bool _cloudCheckTriggered = false;

  void _cancelOtaStreams() {
    _otaProgressSub?.cancel();
    _otaProgressSub = null;
    unawaited(_otaSession?.cancel());
  }

  @override
  void dispose() {
    _cancelOtaStreams();
    unawaited(_otaSession?.dispose());
    _downloadCancel?.cancel('FirmwareUpdatePage disposed');
    _otaProgressTarget.dispose();
    super.dispose();
  }

  bool get _isConnected {
    final state = ref.read(deviceControllerProvider);
    return state.connection?.device.remoteId.toString() == widget.deviceId;
  }

  void _ensureRecStatusLoaded() {
    if (_recStatusLoaded || _step != _FwUiStep.ready) return;
    _recStatusLoaded = true;
    if (!_isConnected) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _step != _FwUiStep.ready) return;
      ref.read(deviceControllerProvider.notifier).getRecordingStatus().then((s) {
        if (mounted) setState(() => _recStatus = s);
      });
    });
  }

  Future<void> _selectFirmwareFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip', 'bin'],
      );
      if (result == null) return;
      final path = result.files.single.path;
      if (path == null) return;
      final file = File(path);
      final size = await file.length();
      if (!mounted) return;
      setState(() {
        _selectedFilePath = path;
        _selectedFileName = result.files.single.name;
        _selectedFileSize = size;
        _selectedFromCloud = false;
        _errorMessage = null;
      });
    } catch (e) {
      AppLog.w('FirmwareUpdatePage: select file failed', e, StackTrace.current);
      if (mounted) {
        setState(() => _errorMessage = e.toString());
      }
    }
  }

  /// Triggers a cloud firmware check the first time the [_ReadyView] is built
  /// after the on-device firmware version is known. Subsequent rebuilds become
  /// no-ops; the user can manually retry via the "Check again" affordance.
  void _ensureCloudCheckTriggered(Device device) {
    if (_cloudCheckTriggered) return;
    final version = (device.firmwareVersion ?? '').trim();
    if (version.isEmpty) return;
    _cloudCheckTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_runCloudCheck(version));
    });
  }

  Future<void> _runCloudCheck(String currentVersion) async {
    if (!mounted) return;
    setState(() {
      _cloudPhase = _CloudCheckPhase.checking;
      _cloudError = null;
      _cloudInfo = null;
    });
    try {
      final api = ref.read(firmwareApiProvider);
      final info = await api.checkUpdate(currentVersion: currentVersion);
      if (!mounted) return;
      setState(() {
        _cloudInfo = info;
        _cloudPhase = info == null
            ? _CloudCheckPhase.noUpdate
            : _CloudCheckPhase.hasUpdate;
      });
    } catch (e, st) {
      AppLog.w('FirmwareUpdatePage: cloud check failed', e, st);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _cloudPhase = _CloudCheckPhase.error;
        _cloudError = _cloudErrorText(e, l10n);
      });
    }
  }

  Future<void> _recheckCloud() async {
    final device = await ref.read(_deviceByIdProvider(widget.deviceId).future);
    final version = (device?.firmwareVersion ?? '').trim();
    if (version.isEmpty) return;
    await _runCloudCheck(version);
  }

  Future<void> _downloadCloudFirmware() async {
    final info = _cloudInfo;
    if (info == null) return;
    setState(() {
      _cloudPhase = _CloudCheckPhase.downloading;
      _cloudError = null;
      _downloadProgress = 0;
      _downloadBytesTotal = 0;
    });
    final cancel = CancelToken();
    _downloadCancel = cancel;
    try {
      final api = ref.read(firmwareApiProvider);
      final target = await api.resolveDownloadTarget(info);
      final tmp = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = p.join(tmp.path, 'firmware_${ts}_${target.description.filename}');
      final file = File(outPath);
      await api.downloadFirmware(
        target: target,
        destination: file,
        cancelToken: cancel,
        onProgress: (recv, total) {
          if (!mounted) return;
          setState(() {
            _downloadBytesTotal = total;
            _downloadProgress = total > 0 ? (recv / total).clamp(0.0, 1.0) : 0.0;
          });
        },
      );
      if (!mounted) return;
      final size = await file.length();
      setState(() {
        _selectedFilePath = file.path;
        _selectedFileName = target.description.filename;
        _selectedFileSize = size;
        _selectedFromCloud = true;
        _cloudPhase = _CloudCheckPhase.downloaded;
        _downloadProgress = 1.0;
        _errorMessage = null;
      });
    } catch (e, st) {
      AppLog.w('FirmwareUpdatePage: cloud download failed', e, st);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      setState(() {
        _cloudPhase = _CloudCheckPhase.hasUpdate;
        _cloudError = _cloudErrorText(e, l10n);
      });
    } finally {
      _downloadCancel = null;
    }
  }

  void _cancelDownload() {
    final c = _downloadCancel;
    if (c != null && !c.isCancelled) {
      c.cancel('User cancelled');
    }
    if (mounted) {
      setState(() {
        _cloudPhase = _CloudCheckPhase.hasUpdate;
      });
    }
  }

  Future<void> _cleanupCloudFirmwareFile() async {
    if (!_selectedFromCloud) return;
    final path = _selectedFilePath;
    if (path.isEmpty) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e, st) {
      AppLog.w('FirmwareUpdatePage: cleanup cloud file failed', e, st);
    }
  }

  static const _minProgressDisplayDuration = Duration(milliseconds: 2500);

  /// Maps PaaS / network failures to user-facing copy (avoid raw
  /// [ServerException.toString] in the UI).
  String _cloudErrorText(Object e, AppLocalizations l10n) {
    if (e is ServerException) {
      if (e.bizCode == 11201) return l10n.cloudFirmwareNoPermission;
      if (e.bizCode == 11102) return l10n.cloudFirmwareInvalidToken;
      final msg = e.message.trim();
      if (msg.isNotEmpty) return msg;
    }
    return e.toString();
  }

  Future<void> _startOtaUpdate() async {
    if (_selectedFilePath.isEmpty || !_isConnected) return;

    final uploadStartTime = DateTime.now();
    _cancelOtaStreams();
    await _otaSession?.dispose();
    _otaSession = null;
    _otaProgressTarget.value = 0;
    setState(() {
      _step = _FwUiStep.uploading;
      _statusText = '';
      _errorMessage = null;
    });

    try {
      final file = File(_selectedFilePath);
      final session = OtaSession(deviceId: widget.deviceId);
      _otaSession = session;

      _otaProgressSub = session.events.listen(
        (p) {
          if (!mounted) return;
          if (p.progress >= 0) {
            _otaProgressTarget.value = p.progress.clamp(0.0, 1.0);
          } else if (p.phase == OtaPhase.success ||
              p.phase == OtaPhase.validating ||
              p.phase == OtaPhase.resetting) {
            _otaProgressTarget.value = 1.0;
          }
          setState(() => _statusText = p.message);
        },
        cancelOnError: false,
      );

      final ok = await session.upgrade(file);
      if (!ok) {
        throw session.lastError ?? StateError('OTA upgrade failed');
      }

      if (!mounted) return;
      final repo = await ref.read(deviceRepositoryProvider.future);
      await repo.updateFirmwareInfo(
        id: widget.deviceId,
        firmwareVersion: null,
        hasFirmwareUpdate: false,
      );
      ref.invalidate(_deviceByIdProvider(widget.deviceId));

      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        _otaProgressTarget.value = 1.0;
        setState(() {
          _statusText = l10n.otaCompleting;
        });
      }
      final elapsed = DateTime.now().difference(uploadStartTime);
      final remaining = _minProgressDisplayDuration - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }

      if (!mounted) return;
      setState(() => _step = _FwUiStep.success);
      unawaited(_cleanupCloudFirmwareFile());

      ref
          .read(deviceControllerProvider.notifier)
          .kickAutoReconnect(initialDelay: const Duration(seconds: 3));
    } catch (e) {
      AppLog.w('FirmwareUpdatePage: OTA failed', e, StackTrace.current);
      if (!mounted) return;
      if (e is StateError && e.message.contains('widget disposed')) {
        return;
      }
      unawaited(
        SentryService.captureOtaFailure(
          deviceId: widget.deviceId,
          error: e,
        ),
      );
      setState(() {
        _step = _FwUiStep.failure;
        _errorMessage = e.toString();
      });
    } finally {
      _cancelOtaStreams();
      await _otaSession?.dispose();
      _otaSession = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final asyncDevice = ref.watch(_deviceByIdProvider(widget.deviceId));

    return asyncDevice.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: Text(AppLocalizations.of(context)!.firmwareUpdate)),
        body: Center(child: Text(e.toString())),
      ),
      data: (device) {
        final l10n = AppLocalizations.of(context)!;
        if (device == null) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.firmwareUpdate)),
            body: Center(child: Text(l10n.deviceNotFound)),
          );
        }

        final version = device.firmwareVersion ?? '--';
        final connected = _isConnected;

        return Scaffold(
          backgroundColor: AppColors.surface,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            centerTitle: true,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(l10n.firmwareUpdate),
          ),
          body: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SizedBox(
                    height: constraints.maxHeight,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: switch (_step) {
                  _FwUiStep.ready => () {
                      _ensureRecStatusLoaded();
                      _ensureCloudCheckTriggered(device);
                      return _ReadyView(
                        key: const ValueKey('ready'),
                        primary: primary,
                        device: device,
                        connected: connected,
                        recStatus: _recStatus,
                        recStatusLoaded: _recStatusLoaded,
                        selectedFileName: _selectedFileName,
                        selectedFileSize: _selectedFileSize,
                        selectedFromCloud: _selectedFromCloud,
                        errorMessage: _errorMessage,
                        cloudPhase: _cloudPhase,
                        cloudInfo: _cloudInfo,
                        cloudError: _cloudError,
                        downloadProgress: _downloadProgress,
                        downloadBytesTotal: _downloadBytesTotal,
                        onSelectFile: _selectFirmwareFile,
                        onCheckCloud: _recheckCloud,
                        onDownloadCloud: _downloadCloudFirmware,
                        onCancelDownload: _cancelDownload,
                        onStartUpdate: _startOtaUpdate,
                        l10n: l10n,
                      );
                    }(),
                  _FwUiStep.uploading => _ProgressView(
                      key: const ValueKey('uploading'),
                      primary: primary,
                      title: _statusText.isNotEmpty ? _statusText : l10n.uploadingFirmware,
                      firmwareLabel: version,
                      progressTarget: _otaProgressTarget,
                      hintTitle: l10n.keepDeviceClose,
                      hintText: l10n.doNotTurnOffDuringInstall,
                      l10n: l10n,
                    ),
                  _FwUiStep.success => _SuccessView(
                      key: const ValueKey('success'),
                      primary: primary,
                      version: version,
                      onBack: () => Navigator.of(context).pop(),
                      l10n: l10n,
                    ),
                  _FwUiStep.failure => _FailureView(
                      key: const ValueKey('failure'),
                      primary: primary,
                      errorMessage: _errorMessage,
                      onBack: () => Navigator.of(context).pop(),
                      l10n: l10n,
                    ),
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ReadyView extends StatelessWidget {
  const _ReadyView({
    super.key,
    required this.primary,
    required this.device,
    required this.connected,
    required this.recStatus,
    required this.recStatusLoaded,
    required this.selectedFileName,
    required this.selectedFileSize,
    required this.selectedFromCloud,
    required this.errorMessage,
    required this.cloudPhase,
    required this.cloudInfo,
    required this.cloudError,
    required this.downloadProgress,
    required this.downloadBytesTotal,
    required this.onSelectFile,
    required this.onCheckCloud,
    required this.onDownloadCloud,
    required this.onCancelDownload,
    required this.onStartUpdate,
    required this.l10n,
  });

  final Color primary;
  final Device device;
  final bool connected;
  final RecStatus? recStatus;
  final bool recStatusLoaded;
  final String selectedFileName;
  final int selectedFileSize;
  final bool selectedFromCloud;
  final String? errorMessage;
  final _CloudCheckPhase cloudPhase;
  final FirmwareUpdateInfo? cloudInfo;
  final String? cloudError;
  final double downloadProgress;
  final int downloadBytesTotal;
  final VoidCallback onSelectFile;
  final VoidCallback onCheckCloud;
  final VoidCallback onDownloadCloud;
  final VoidCallback onCancelDownload;
  final VoidCallback onStartUpdate;
  final AppLocalizations l10n;

  bool get _batteryOk {
    if (recStatus?.isCharging == true) return true;
    final b = device.batteryPercent;
    if (b == null) return true; // Unknown: allow until GSTAT/battery is known
    return b >= 50;
  }

  bool get _notRecording {
    if (!recStatusLoaded || recStatus == null) return true; // Unknown: allow
    return recStatus!.state != 'recording' && recStatus!.state != 'paused';
  }

  bool get _allChecksPass => connected && _batteryOk && _notRecording;

  bool get _downloading => cloudPhase == _CloudCheckPhase.downloading;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                _buildCloudCard(context),
                const SizedBox(height: 14),
                _buildLocalCard(context),
                if (!connected) ...[
                  const SizedBox(height: 14),
                  _buildNotConnectedBanner(),
                ],
                const SizedBox(height: 18),
                _buildSystemCheckCard(),
                if (errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE57373)),
                    ),
                    child: Text(errorMessage!, style: const TextStyle(fontSize: 13, color: Color(0xFFC62828))),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        AppBlackPillButton(
          label: l10n.startFirmwareUpdate,
          onPressed: (_allChecksPass && selectedFileName.isNotEmpty && !_downloading) ? onStartUpdate : null,
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.laterButton, style: const TextStyle(color: AppColors.textPlaceholder, fontWeight: FontWeight.w500, fontSize: AppTypography.s14)),
        ),
      ],
    );
  }

  Widget _buildCloudCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F6),
        borderRadius: BorderRadius.circular(AppRadii.r18),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: primary.withValues(alpha: 0.3), width: 1),
                ),
                child: Icon(Icons.cloud_outlined, color: primary, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.cloudFirmwareTitle,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textTertiary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (cloudPhase == _CloudCheckPhase.noUpdate ||
                  cloudPhase == _CloudCheckPhase.error)
                TextButton(
                  onPressed: onCheckCloud,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 28),
                  ),
                  child: Text(
                    l10n.cloudFirmwareCheckAgain,
                    style: TextStyle(color: primary, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _buildCloudBody(context),
        ],
      ),
    );
  }

  Widget _buildCloudBody(BuildContext context) {
    switch (cloudPhase) {
      case _CloudCheckPhase.idle:
      case _CloudCheckPhase.checking:
        return Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.cloudFirmwareChecking,
                style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
              ),
            ),
          ],
        );
      case _CloudCheckPhase.noUpdate:
        return Row(
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF34A853), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.firmwareUpToDate,
                style: const TextStyle(fontSize: 14, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        );
      case _CloudCheckPhase.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline, color: Color(0xFFE25555), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.cloudFirmwareCheckFailed,
                    style: const TextStyle(fontSize: 14, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            if ((cloudError ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(cloudError!, style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
            ],
          ],
        );
      case _CloudCheckPhase.hasUpdate:
      case _CloudCheckPhase.downloading:
      case _CloudCheckPhase.downloaded:
        final info = cloudInfo;
        if (info == null) {
          return Text(l10n.cloudFirmwareCheckFailed, style: const TextStyle(fontSize: 14));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.newFirmwareVersion(info.resourceVer),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            if ((info.resourceName ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(info.resourceName!.trim(), style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
            ],
            if ((info.resourceDesc ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                info.resourceDesc!.trim(),
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4),
              ),
            ],
            if (info.mustUpdate) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3DB),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  l10n.firmwareMustUpdate,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8B6914), fontWeight: FontWeight.w600),
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (cloudPhase == _CloudCheckPhase.downloading)
              _buildDownloadingControls()
            else if (cloudPhase == _CloudCheckPhase.downloaded)
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Color(0xFF34A853), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.firmwareDownloadedReady,
                      style: const TextStyle(fontSize: 13, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onDownloadCloud,
                  icon: const Icon(Icons.download_outlined, size: 20),
                  label: Text(l10n.downloadFirmwareButton),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.pill)),
                  ),
                ),
              ),
            if ((cloudError ?? '').isNotEmpty && cloudPhase != _CloudCheckPhase.downloading) ...[
              const SizedBox(height: 8),
              Text(cloudError!, style: const TextStyle(fontSize: 12, color: Color(0xFFC62828))),
            ],
          ],
        );
    }
  }

  Widget _buildDownloadingControls() {
    final percent = (downloadProgress * 100).clamp(0, 100).round();
    final progressLabel = downloadBytesTotal > 0
        ? '$percent%  (${_formatSize((downloadProgress * downloadBytesTotal).round())} / ${_formatSize(downloadBytesTotal)})'
        : l10n.cloudFirmwareDownloading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: LinearProgressIndicator(
            value: downloadBytesTotal > 0 ? downloadProgress : null,
            minHeight: 8,
            color: primary,
            backgroundColor: const Color(0xFFE4E4E4),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                progressLabel,
                style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
            ),
            TextButton(
              onPressed: onCancelDownload,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(l10n.cancelButton, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLocalCard(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F6),
        borderRadius: BorderRadius.circular(AppRadii.r18),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: primary.withValues(alpha: 0.3), width: 1),
                ),
                child: Icon(Icons.folder_open, color: primary, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.localFirmwareTitle,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textTertiary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (selectedFileName.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.grayE0),
              ),
              child: Row(
                children: [
                  Icon(
                    selectedFromCloud ? Icons.cloud_done_outlined : Icons.insert_drive_file_outlined,
                    size: 20,
                    color: primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedFileName,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          selectedFileSize > 0
                              ? '${selectedFromCloud ? l10n.fromCloudLabel : l10n.fromLocalLabel} · ${_formatSize(selectedFileSize)}'
                              : (selectedFromCloud ? l10n.fromCloudLabel : l10n.fromLocalLabel),
                          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (selectedFileName.isNotEmpty) const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _downloading ? null : onSelectFile,
              icon: const Icon(Icons.folder_open, size: 20),
              label: Text(selectedFileName.isEmpty ? l10n.selectFirmwareFile : l10n.selectFirmwareFileAgain),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.pill)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotConnectedBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3DB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFC7A400)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFC7A400), size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.otaDeviceNotConnected,
              style: const TextStyle(fontSize: 14, color: Color(0xFF8B6914)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemCheckCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F6),
        borderRadius: BorderRadius.circular(AppRadii.r18),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.systemCheckTitle,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.textTertiary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 14),
          _SystemCheckItem(
            icon: Icons.battery_charging_full,
            label: l10n.batteryCheckLabel,
            passed: _batteryOk,
            unknown: device.batteryPercent == null && recStatus?.isCharging == null,
          ),
          const SizedBox(height: 12),
          _SystemCheckItem(
            icon: Icons.mic_off,
            label: l10n.notRecordingLabel,
            passed: _notRecording,
            unknown: !recStatusLoaded,
          ),
          const SizedBox(height: 12),
          _SystemCheckItem(
            icon: Icons.bluetooth_connected,
            label: l10n.deviceConnectedLabel,
            passed: connected,
            unknown: false,
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _SystemCheckItem extends StatelessWidget {
  const _SystemCheckItem({
    required this.icon,
    required this.label,
    required this.passed,
    required this.unknown,
  });

  final IconData icon;
  final String label;
  final bool passed;
  final bool unknown;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Icon(icon, size: 22, color: passed ? primary : (unknown ? AppColors.textTertiary : AppColors.danger)),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 14, color: AppColors.textPrimary, fontWeight: FontWeight.w500))),
        Icon(
          passed ? Icons.check_circle : (unknown ? Icons.help_outline : Icons.cancel),
          size: 22,
          color: passed ? primary : (unknown ? AppColors.textTertiary : AppColors.danger),
        ),
      ],
    );
  }
}

class _ProgressView extends StatefulWidget {
  const _ProgressView({
    super.key,
    required this.primary,
    required this.title,
    required this.firmwareLabel,
    required this.progressTarget,
    required this.hintTitle,
    required this.hintText,
    required this.l10n,
  });

  final Color primary;
  final String title;
  final String firmwareLabel;
  final ValueListenable<double> progressTarget;
  final String hintTitle;
  final String hintText;
  final AppLocalizations l10n;

  @override
  State<_ProgressView> createState() => _ProgressViewState();
}

/// Smooths mcumgr progress (many small BLE updates) so the bar and % do not flicker.
class _ProgressViewState extends State<_ProgressView> with SingleTickerProviderStateMixin {
  static const double _snapEpsilon = 0.001;
  static const double _lerpFactor = 0.22;

  late final Ticker _ticker;
  double _displayProgress = 0;
  double _targetProgress = 0;

  @override
  void initState() {
    super.initState();
    _targetProgress = widget.progressTarget.value.clamp(0.0, 1.0);
    _displayProgress = _targetProgress;
    widget.progressTarget.addListener(_onTargetChanged);
    _ticker = createTicker(_onTick);
  }

  @override
  void didUpdateWidget(covariant _ProgressView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progressTarget != widget.progressTarget) {
      oldWidget.progressTarget.removeListener(_onTargetChanged);
      widget.progressTarget.addListener(_onTargetChanged);
      _onTargetChanged();
    }
  }

  @override
  void dispose() {
    widget.progressTarget.removeListener(_onTargetChanged);
    _ticker.dispose();
    super.dispose();
  }

  void _onTargetChanged() {
    _targetProgress = widget.progressTarget.value.clamp(0.0, 1.0);
    if (!_ticker.isActive && (_displayProgress - _targetProgress).abs() > _snapEpsilon) {
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final t = _targetProgress;
    var d = _displayProgress;
    final diff = t - d;
    if (diff.abs() < _snapEpsilon) {
      if ((d - t).abs() > _snapEpsilon * 0.1) {
        setState(() => _displayProgress = t);
      }
      _ticker.stop();
      return;
    }
    d = d + diff * _lerpFactor;
    setState(() => _displayProgress = d.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_displayProgress * 100).round().clamp(0, 100);
    return Column(
      children: [
        const SizedBox(height: 36),
        Text(widget.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w500, fontSize: AppTypography.s18)),
        const SizedBox(height: 10),
        Text('$percent%', style: Theme.of(context).textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: AppTypography.s24)),
        const SizedBox(height: 30),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: LinearProgressIndicator(
            value: _displayProgress,
            minHeight: 10,
            color: widget.primary,
            backgroundColor: const Color(0xFFE4E4E4),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${widget.l10n.firmwareLabel} ${widget.firmwareLabel}', style: const TextStyle(color: AppColors.textTertiary, fontWeight: FontWeight.w500, fontSize: AppTypography.s14)),
            Text(widget.l10n.remaining, style: const TextStyle(color: AppColors.textTertiary, fontWeight: FontWeight.w500, fontSize: AppTypography.s14)),
          ],
        ),
        const SizedBox(height: 36),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          decoration: BoxDecoration(
            color: AppColors.surfaceSubtle,
            borderRadius: BorderRadius.circular(AppRadii.r16),
            border: Border.all(color: AppColors.grayE0),
          ),
          child: Column(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3DB),
                  borderRadius: BorderRadius.circular(AppRadii.r26),
                ),
                child: const Icon(Icons.warning_amber_rounded, color: Color(0xFFC7A400), size: 28),
              ),
              const SizedBox(height: 14),
              Text(widget.hintTitle, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: AppTypography.s14), textAlign: TextAlign.center),
              const SizedBox(height: 10),
              Text(widget.hintText, style: TextStyle(color: widget.primary.withValues(alpha: 0.85), height: 1.4, fontWeight: FontWeight.w500, fontSize: AppTypography.s14), textAlign: TextAlign.center),
            ],
          ),
        ),
      ],
    );
  }
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({
    super.key,
    required this.primary,
    required this.version,
    required this.onBack,
    required this.l10n,
  });

  final Color primary;
  final String version;
  final VoidCallback onBack;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 70),
        _BigCheckIcon(primary: primary),
        const SizedBox(height: 28),
        Text(
          l10n.updateSuccessfulTitle,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w500, fontSize: AppTypography.s22),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        Text(
          l10n.updateSuccessfulMessageWait,
          style: const TextStyle(color: Color(0xFF9CA3AF), height: 1.4, fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        AppPrimaryPillButton(label: l10n.backToDevice, onPressed: onBack),
        const SizedBox(height: 26),
      ],
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({
    super.key,
    required this.primary,
    this.errorMessage,
    required this.onBack,
    required this.l10n,
  });

  final Color primary;
  final String? errorMessage;
  final VoidCallback onBack;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 70),
        Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(color: const Color(0xFFFFE5E5), borderRadius: BorderRadius.circular(80)),
          child: const Center(child: Icon(Icons.close, size: 56, color: Color(0xFFE25555))),
        ),
        const SizedBox(height: 26),
        Text(
          l10n.updateFailedTitle,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w500, fontSize: AppTypography.s22),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          errorMessage ?? l10n.updateFailedMessage,
          style: const TextStyle(color: Color(0xFF9CA3AF), height: 1.4, fontWeight: FontWeight.w500, fontSize: AppTypography.s14),
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        AppPrimaryPillButton(label: l10n.backToDevice, onPressed: onBack),
        const SizedBox(height: 26),
      ],
    );
  }
}

class _BigCheckIcon extends StatelessWidget {
  final Color primary;

  const _BigCheckIcon({required this.primary});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(90),
      ),
      child: Center(
        child: Container(
          width: 128,
          height: 128,
          decoration: BoxDecoration(color: primary, borderRadius: BorderRadius.circular(64)),
          child: const Icon(Icons.check, color: Colors.white, size: 56),
        ),
      ),
    );
  }
}
