import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../server_exception.dart';
import 'sensecraft_paas_client.dart';

/// Reseaker / Voice Clip firmware bundle SKU registered in SenseCAP PaaS.
const String kRespeakerFirmwareSku = 'voice_respeaker_clip';

/// Parsed response of `GET /portalapi/hardware/get_new_version` (SenseCAP envelope `data`).
///
/// When no firmware needs to be flashed the gateway may return success with no
/// `resource_url`. Use [hasUpdate] to branch the UI.
@immutable
class FirmwareUpdateInfo {
  final String currentVer;
  final String resourceVer;
  final String resourceUrl;
  final String? resourceName;
  final String? resourceDesc;
  final bool mustUpdate;

  const FirmwareUpdateInfo({
    required this.currentVer,
    required this.resourceVer,
    required this.resourceUrl,
    required this.resourceName,
    required this.resourceDesc,
    required this.mustUpdate,
  });

  /// True iff the server is asking us to install something newer.
  bool get hasUpdate =>
      resourceUrl.trim().isNotEmpty && resourceVer.trim().isNotEmpty;

  factory FirmwareUpdateInfo.fromJson(Map<String, dynamic> j) {
    String pickStr(List<String> keys) {
      for (final k in keys) {
        final v = j[k];
        if (v == null) continue;
        final s = v.toString().trim();
        if (s.isNotEmpty) return s;
      }
      return '';
    }

    final mustRaw =
        j['must_update'] ?? j['force_update'] ?? j['need_update'] ?? j['mustUpdate'];
    bool mustUpdate;
    if (mustRaw is bool) {
      mustUpdate = mustRaw;
    } else if (mustRaw is num) {
      mustUpdate = mustRaw.toInt() != 0;
    } else {
      mustUpdate = mustRaw?.toString().trim().toLowerCase() == 'true';
    }
    return FirmwareUpdateInfo(
      currentVer: pickStr(const ['current_ver', 'cur_ver', 'local_ver', 'currentVer']),
      resourceVer: pickStr(const [
        'resource_ver',
        'new_version',
        'latest_ver',
        'target_ver',
        'version',
        'resourceVer',
      ]),
      resourceUrl: pickStr(const [
        'resource_url',
        'url',
        'download_url',
        'package_url',
        'resourceUrl',
      ]),
      resourceName: () {
        final n = pickStr(const ['resource_name', 'name', 'resourceName']);
        return n.isEmpty ? null : n;
      }(),
      resourceDesc: () {
        final d = pickStr(
            const ['resource_desc', 'desc', 'description', 'resourceDesc']);
        return d.isEmpty ? null : d;
      }(),
      mustUpdate: mustUpdate,
    );
  }
}

/// description.json shape published next to the firmware binary.
@immutable
class FirmwareDescription {
  final String fwv;
  final String bundleSku;
  final int? type;
  final String originMd5;
  final String filename;

  const FirmwareDescription({
    required this.fwv,
    required this.bundleSku,
    required this.type,
    required this.originMd5,
    required this.filename,
  });

  factory FirmwareDescription.fromJson(Map<String, dynamic> j) {
    final t = j['type'];
    return FirmwareDescription(
      fwv: (j['fwv'] ?? '').toString().trim(),
      bundleSku: (j['bundle_sku'] ?? '').toString().trim(),
      type: t is num ? t.toInt() : int.tryParse(t?.toString() ?? ''),
      originMd5: (j['originmd5'] ?? '').toString().trim(),
      filename: (j['filename'] ?? '').toString().trim(),
    );
  }
}

/// Calls the SenseCAP PaaS firmware endpoints + downloads bundle assets.
class FirmwareApi {
  final SenseCraftPaasClient _client;

  FirmwareApi(this._client);

  /// `GET /hardware/get_new_version`
  ///
  /// [currentVersion] is the device's running firmware version (`ver` param).
  /// Returns `null` when the gateway response signals "no update available"
  /// (success code, but no [FirmwareUpdateInfo.resourceUrl]).
  Future<FirmwareUpdateInfo?> checkUpdate({
    required String currentVersion,
    String sku = kRespeakerFirmwareSku,
    bool isPrepub = false,
  }) async {
    // Portal expects every query value as a string (e.g. is_prepub
    // must be "false", not omitted / bool).
    final queryParameters = <String, String>{
      'ver': currentVersion.trim(),
      'sku': sku.trim(),
      'is_prepub': isPrepub ? 'true' : 'false',
    };
    final resp = await _client.getJson(
      '/hardware/get_new_version',
      queryParameters: queryParameters,
    );
    final env = _client.readEnvelope(
      resp,
      fallbackMessage: 'Failed to check firmware update.',
    );
    var data = env.data;
    if (data is Map) {
      final m = data.cast<String, dynamic>();
      final inner = m['firmware'] ?? m['data'] ?? m['result'] ?? m['info'];
      if (inner is Map) {
        data = inner;
      }
    }
    if (data is! Map) return null;
    final info = FirmwareUpdateInfo.fromJson(data.cast<String, dynamic>());
    if (!info.hasUpdate) return null;
    return info;
  }

  /// Fetches the description.json referenced by `resource_url` and returns the
  /// resolved download URL for the actual firmware binary.
  ///
  /// Per PaaS doc the binary lives in the same resource folder as the JSON,
  /// e.g. `…/xxxx-1727315750103/description.json` →
  ///       `…/xxxx-1727315750103/{filename}`.
  Future<FirmwareDownloadTarget> resolveDownloadTarget(
    FirmwareUpdateInfo info,
  ) async {
    final url = info.resourceUrl;
    if (url.isEmpty) {
      throw ServerException(
        'Firmware update has no resource_url.',
        messageKey: 'firmwareUpdateNoResource',
      );
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.json,
    ));
    final Response<Object?> resp;
    try {
      resp = await dio.get<Object?>(url);
    } on DioException catch (e) {
      throw ServerException(
        e.message ?? 'Failed to load firmware description.',
        statusCode: e.response?.statusCode,
        data: e.response?.data,
      );
    }
    // Some statics CDNs serve JSON with content-type text/plain → the body
    // arrives as a String. Normalize both shapes.
    Object? body = resp.data;
    if (body is String) {
      try {
        body = jsonDecode(body);
      } catch (_) {/* fall through */}
    }
    if (body is! Map) {
      throw ServerException(
        'Firmware description has unexpected shape.',
        statusCode: resp.statusCode,
        data: body,
      );
    }
    final desc = FirmwareDescription.fromJson(body.cast<String, dynamic>());
    if (desc.filename.isEmpty) {
      throw ServerException(
        'Firmware description is missing filename.',
        statusCode: resp.statusCode,
        data: body,
      );
    }
    final downloadUri = _resolveSibling(Uri.parse(url), desc.filename);
    return FirmwareDownloadTarget(
      info: info,
      description: desc,
      downloadUrl: downloadUri.toString(),
    );
  }

  /// Streams [target] to [destination]. Reports progress via [onProgress]
  /// (`received`, `total`; `total` may be -1 when the server omits
  /// Content-Length). Validates MD5 against [FirmwareDescription.originMd5]
  /// after download.
  Future<File> downloadFirmware({
    required FirmwareDownloadTarget target,
    required File destination,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      // OTA bundles are usually ≤ 5 MB but the gateway is occasionally slow,
      // so we set a generous receive timeout.
      receiveTimeout: const Duration(minutes: 5),
      responseType: ResponseType.bytes,
    ));
    try {
      await dio.download(
        target.downloadUrl,
        destination.path,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw ServerException(
        e.message ?? 'Failed to download firmware.',
        statusCode: e.response?.statusCode,
        data: e.response?.data,
      );
    }
    final expected = target.description.originMd5.trim().toLowerCase();
    if (expected.isNotEmpty) {
      final actual = await _md5OfFile(destination);
      if (actual.toLowerCase() != expected) {
        try {
          await destination.delete();
        } catch (_) {/* ignore */}
        throw ServerException(
          'Firmware download corrupted (md5 mismatch).',
          messageKey: 'firmwareDownloadCorrupted',
        );
      }
    }
    return destination;
  }

  static Uri _resolveSibling(Uri base, String filename) {
    final segments = List<String>.from(base.pathSegments);
    if (segments.isNotEmpty) {
      segments.removeLast();
    }
    segments.add(filename);
    // Percent-encode each segment so '+' in filenames (e.g. clip-0.0.3+0-ota.zip)
    // is sent as %2B. OSS and many HTTP stacks treat bare '+' in paths as space.
    final encodedPath = segments.map(Uri.encodeComponent).join('/');
    return base.replace(path: '/$encodedPath');
  }

  static Future<String> _md5OfFile(File f) async {
    final captured = <Digest>[];
    final sink = ChunkedConversionSink<Digest>.withCallback(captured.addAll);
    final converter = md5.startChunkedConversion(sink);
    final stream = f.openRead();
    await for (final chunk in stream) {
      converter.add(chunk);
    }
    converter.close();
    return captured.single.toString();
  }
}

@immutable
class FirmwareDownloadTarget {
  final FirmwareUpdateInfo info;
  final FirmwareDescription description;
  final String downloadUrl;

  const FirmwareDownloadTarget({
    required this.info,
    required this.description,
    required this.downloadUrl,
  });
}
