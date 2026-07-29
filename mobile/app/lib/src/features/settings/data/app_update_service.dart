import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.platform,
    required this.channel,
    required this.packageName,
    required this.currentVersionCode,
    required this.currentVersionName,
    required this.latestVersionCode,
    required this.latestVersionName,
    required this.minSupportedVersionCode,
    required this.updateAvailable,
    required this.forceUpdate,
    required this.action,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.publishedAt,
  });

  final String platform;
  final String channel;
  final String packageName;
  final int currentVersionCode;
  final String currentVersionName;
  final int latestVersionCode;
  final String latestVersionName;
  final int minSupportedVersionCode;
  final bool updateAvailable;
  final bool forceUpdate;
  final String action;
  final String downloadUrl;
  final List<String> releaseNotes;
  final DateTime? publishedAt;
}

class AppUpdateServiceException implements Exception {
  AppUpdateServiceException(this.message);
  final String message;

  @override
  String toString() => message;
}

const String kAppChannel =
    String.fromEnvironment('APP_CHANNEL', defaultValue: 'store');
const String kAppUpdateBaseUrl =
    'https://sensecraft-voice-update-worker.seeed.cc';
const String kDirectApkChannel = 'android_direct_apk';
const String kAppUpdatePath = '/api/v1/app/update/check';

final appChannelProvider = Provider<String>((_) => kAppChannel);
final appUpdateCanCheckProvider = Provider<bool>((ref) {
  return Platform.isAndroid &&
      ref.watch(appChannelProvider) == kDirectApkChannel;
});

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService(
    baseUrl: kAppUpdateBaseUrl,
    channel: ref.watch(appChannelProvider),
  );
});

final appUpdateInfoProvider = FutureProvider<AppUpdateInfo?>((ref) async {
  final service = ref.watch(appUpdateServiceProvider);
  if (!service.canCheck) return null;
  try {
    return await service.checkForUpdate();
  } catch (_) {
    return null;
  }
});

class AppUpdateService {
  AppUpdateService({
    required this.baseUrl,
    required this.channel,
    Dio? dio,
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 12),
                responseType: ResponseType.json,
              ),
            );

  final String baseUrl;
  final String channel;
  final Dio _dio;

  bool get canCheck => Platform.isAndroid && channel == kDirectApkChannel;

  Future<AppUpdateInfo?> checkForUpdate() async {
    if (!canCheck) return null;
    if (baseUrl.trim().isEmpty) {
      throw AppUpdateServiceException('App update service is not configured');
    }

    final info = await PackageInfo.fromPlatform();
    final currentVersionCode = int.tryParse(info.buildNumber) ?? 0;
    final currentVersionName = info.version.trim();
    final uri = _buildCheckUri(
        info.packageName, currentVersionCode, currentVersionName);
    final resp = await _dio.getUri<Map<String, dynamic>>(uri);
    final data = resp.data;
    if (data == null) {
      throw AppUpdateServiceException('Empty update response');
    }

    final code = _asInt(data['code']);
    if (code != 0) {
      final message = (data['message'] ?? 'update check failed').toString();
      throw AppUpdateServiceException(message);
    }

    final payloadRaw = data['data'];
    if (payloadRaw is! Map) {
      throw AppUpdateServiceException('Invalid update payload');
    }
    final payload = Map<String, dynamic>.from(payloadRaw);

    final responsePlatform = (payload['platform'] ?? 'android').toString();
    final responseChannel = (payload['channel'] ?? channel).toString();
    final responsePackageName =
        (payload['packageName'] ?? info.packageName).toString();
    final latestVersionCode = _asInt(payload['latestVersionCode']);
    final minSupportedVersionCode = _asInt(payload['minSupportedVersionCode']);
    final updateAvailable = payload['updateAvailable'] == true;
    final forceUpdate = payload['forceUpdate'] == true;
    final latestVersionName = (payload['latestVersionName'] ?? '').toString();
    final action = (payload['action'] ?? 'download').toString();
    final downloadUrl = (payload['downloadUrl'] ?? '').toString();
    final releaseNotes = _asStringList(payload['releaseNotes']);
    final publishedAt =
        DateTime.tryParse((payload['publishedAt'] ?? '').toString());

    _validateUpdatePayload(
      platform: responsePlatform,
      channel: responseChannel,
      packageName: responsePackageName,
      expectedPackageName: info.packageName,
      action: action,
      downloadUrl: downloadUrl,
      updateAvailable: updateAvailable,
    );

    return AppUpdateInfo(
      platform: responsePlatform,
      channel: responseChannel,
      packageName: responsePackageName,
      currentVersionCode: currentVersionCode,
      currentVersionName: currentVersionName,
      latestVersionCode: latestVersionCode,
      latestVersionName: latestVersionName,
      minSupportedVersionCode: minSupportedVersionCode,
      updateAvailable: updateAvailable,
      forceUpdate: forceUpdate,
      action: action,
      downloadUrl: downloadUrl,
      releaseNotes: releaseNotes,
      publishedAt: publishedAt,
    );
  }

  Future<void> openUpdateUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (!_isHttpsUri(uri)) {
      throw AppUpdateServiceException('Invalid update url');
    }
    final ok = await launchUrl(uri!, mode: LaunchMode.externalApplication);
    if (!ok) {
      throw AppUpdateServiceException('Could not open update url');
    }
  }

  Uri _buildCheckUri(
      String packageName, int currentVersionCode, String currentVersionName) {
    final base = Uri.parse(baseUrl.trim());
    final path = base.path.endsWith(kAppUpdatePath)
        ? base.path
        : _joinPath(base.path, kAppUpdatePath);
    return base.replace(
      path: path,
      queryParameters: {
        ...base.queryParameters,
        'platform': 'android',
        'channel': channel,
        'versionCode': '$currentVersionCode',
        'versionName': currentVersionName,
        'packageName': packageName,
      },
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static List<String> _asStringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((item) => item.toString())
        .where((item) => item.trim().isNotEmpty)
        .toList();
  }

  static void _validateUpdatePayload({
    required String platform,
    required String channel,
    required String packageName,
    required String expectedPackageName,
    required String action,
    required String downloadUrl,
    required bool updateAvailable,
  }) {
    if (platform.toLowerCase() != 'android') {
      throw AppUpdateServiceException('Unsupported update platform');
    }
    if (channel != kDirectApkChannel) {
      throw AppUpdateServiceException('Unsupported update channel');
    }
    if (packageName != expectedPackageName) {
      throw AppUpdateServiceException('Update package does not match this app');
    }
    if (action != 'download') {
      throw AppUpdateServiceException('Unsupported update action');
    }
    if (updateAvailable && !_isHttpsUri(Uri.tryParse(downloadUrl))) {
      throw AppUpdateServiceException('Invalid update url');
    }
  }

  static bool _isHttpsUri(Uri? uri) {
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  static String _joinPath(String left, String right) {
    final a = left.endsWith('/') ? left.substring(0, left.length - 1) : left;
    final b = right.startsWith('/') ? right.substring(1) : right;
    if (a.isEmpty) return '/$b';
    return '$a/$b';
  }
}
