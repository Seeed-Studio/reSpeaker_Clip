import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../http/api_client.dart';
import '../server_error_codes.dart';
import '../server_exception.dart';
import 'auth_api.dart';
import '../crypto/password_hasher.dart';

class UserProfile {
  final int id;
  final String? name;
  final String? email;
  final bool? emailVerified;
  final String? avatarUrl;
  final String? provider;
  final String? role;
  /// SenseCraft `getUserOrgInfo.has_pwd` — whether a local password is set.
  final bool? hasPwd;

  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.emailVerified,
    required this.avatarUrl,
    required this.provider,
    required this.role,
    this.hasPwd,
  });

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        id: (j['id'] is num) ? (j['id'] as num).toInt() : 0,
        name: j['name']?.toString(),
        email: j['email']?.toString(),
        emailVerified: j['email_verified'] is bool ? (j['email_verified'] as bool) : null,
        avatarUrl: j['avatar_url']?.toString(),
        provider: j['provider']?.toString(),
        role: j['role']?.toString(),
        hasPwd: j['has_pwd'] is bool ? (j['has_pwd'] as bool) : null,
      );

  factory UserProfile.fromAuthAppUser(AuthAppUser u) {
    final idNum = int.tryParse((u.id ?? '').toString());
    return UserProfile(
      id: idNum ?? 0,
      name: u.name,
      email: u.email,
      emailVerified: u.emailVerified,
      avatarUrl: u.avatarUrl,
      provider: u.provider,
      role: u.role,
      hasPwd: null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'email': email,
        'email_verified': emailVerified,
        'avatar_url': avatarUrl,
        'provider': provider,
        'role': role,
        if (hasPwd != null) 'has_pwd': hasPwd,
      };
}

/// `GET /api/v1/user/getSecurityInfo` — user-center linked account metadata.
///
/// See SenseCraft authapi linked-accounts endpoint.
class UserSecurityInfo {
  final String accountType;
  final int? allowRecv;
  final String? email;
  final String? foreignId;
  final bool? hasPwd;
  final Object? mobilePhone;

  const UserSecurityInfo({
    required this.accountType,
    this.allowRecv,
    this.email,
    this.foreignId,
    this.hasPwd,
    this.mobilePhone,
  });

  factory UserSecurityInfo.fromJson(Map<String, dynamic> j) => UserSecurityInfo(
        accountType: (j['account_type'] ?? '').toString(),
        allowRecv: (j['allow_recv'] is num) ? (j['allow_recv'] as num).toInt() : null,
        email: j['email']?.toString(),
        foreignId: j['foreign_id']?.toString(),
        hasPwd: j['has_pwd'] is bool ? (j['has_pwd'] as bool) : null,
        mobilePhone: j['mobile_phone'],
      );

  /// Third-party IdP bindings as returned by user center.
  static const Set<String> oauthAccountTypes = {'google', 'github', 'apple'};

  /// `true` when [accountType] is not one of [oauthAccountTypes] (non-empty).
  ///
  /// Used to show "SenseCraft / native account" as the primary binding when the
  /// account was not created via Apple / Google / GitHub OAuth.
  bool get isSenseCraftNativeBinding {
    final t = accountType.trim().toLowerCase();
    if (t.isEmpty) return false;
    return !oauthAccountTypes.contains(t);
  }
}

class OssUploadResult {
  final String? contentType;
  final String? objectKey;
  final String publicUrl;
  final int? size;
  final String? type;

  const OssUploadResult({
    required this.contentType,
    required this.objectKey,
    required this.publicUrl,
    required this.size,
    required this.type,
  });

  factory OssUploadResult.fromJson(Map<String, dynamic> j) => OssUploadResult(
        contentType: j['content_type']?.toString(),
        objectKey: j['object_key']?.toString(),
        publicUrl: (j['public_url'] ?? '').toString(),
        size: (j['size'] is num) ? (j['size'] as num).toInt() : null,
        type: j['type']?.toString(),
      );
}

/// Response `result` from `GET /api/v1/user/presignUpload` (avatar / direct OSS PUT).
class UserPresignUpload {
  final String uploadUrl;
  final String publicUrl;
  final String? objectKey;
  /// Uppercase HTTP verb for the upload request (only **PUT** is implemented).
  final String method;
  final Map<String, String> uploadHeaders;

  const UserPresignUpload({
    required this.uploadUrl,
    required this.publicUrl,
    required this.objectKey,
    required this.method,
    required this.uploadHeaders,
  });

  factory UserPresignUpload.fromResultMap(Map<String, dynamic> j) {
    String pickUrl(Iterable<String> keys) {
      for (final k in keys) {
        final v = j[k];
        if (v != null) {
          final s = v.toString().trim();
          if (s.isNotEmpty) return s;
        }
      }
      return '';
    }

    final uploadUrl = pickUrl(const [
      'upload_url',
      'uploadUrl',
      'url',
      'presigned_url',
      'presignedUrl',
    ]);
    final publicUrl = pickUrl(const [
      'access_url',
      'accessUrl',
      'public_url',
      'publicUrl',
      'file_url',
      'fileUrl',
      'cdn_url',
    ]);
    final objectKey = j['object_key']?.toString().trim() ?? j['objectKey']?.toString().trim();
    final methodRaw = (j['method'] ?? 'PUT').toString().trim();
    final method = methodRaw.isEmpty ? 'PUT' : methodRaw.toUpperCase();

    final headers = <String, String>{};
    final rawH = j['headers'] ?? j['upload_headers'] ?? j['uploadHeaders'];
    if (rawH is Map) {
      rawH.forEach((k, v) {
        if (k == null || v == null) return;
        final ks = k.toString().trim();
        if (ks.isEmpty) return;
        headers[ks] = v.toString();
      });
    }

    return UserPresignUpload(
      uploadUrl: uploadUrl,
      publicUrl: publicUrl,
      objectKey: (objectKey != null && objectKey.isNotEmpty) ? objectKey : null,
      method: method,
      uploadHeaders: headers,
    );
  }
}

class UserApi {
  final ApiClient _client;
  UserApi(this._client);

  static String? guessImageContentTypeForPath(String path) =>
      _guessContentTypeForPath(path);

  /// PUT [file] to [presign.uploadUrl] (shared by self-hosted and SenseCraft presign).
  static Future<OssUploadResult> uploadFileViaPresign({
    required File file,
    required UserPresignUpload presign,
    required String type,
    String? contentType,
    int? presignStatusCode,
    Object? presignResponseForError,
  }) async {
    if (presign.uploadUrl.isEmpty) {
      throw ServerException(
        'Presign upload failed: missing upload URL.',
        messageKey: 'userApiUploadMissingResult',
        statusCode: presignStatusCode,
        data: presignResponseForError,
      );
    }
    if (presign.publicUrl.isEmpty) {
      throw ServerException(
        'Presign upload failed: missing public URL.',
        messageKey: 'userApiUploadMissingPublicUrl',
        statusCode: presignStatusCode,
        data: presignResponseForError,
      );
    }
    if (presign.method != 'PUT') {
      throw ServerException(
        'Presign upload: method ${presign.method} is not supported (expected PUT).',
        messageKey: 'userApiUploadFailed',
        statusCode: presignStatusCode,
        data: presignResponseForError,
      );
    }

    const extendedTimeout = Duration(seconds: 180);
    final bytes = await file.readAsBytes();
    final putHeaders = <String, String>{...presign.uploadHeaders};
    putHeaders.putIfAbsent(
      HttpHeaders.contentTypeHeader,
      () => contentType ?? 'application/octet-stream',
    );

    final putDio = Dio(
      BaseOptions(
        connectTimeout: extendedTimeout,
        sendTimeout: extendedTimeout,
        receiveTimeout: extendedTimeout,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ),
    );
    try {
      await putDio.put<dynamic>(
        presign.uploadUrl,
        data: bytes,
        options: Options(headers: putHeaders),
      );
    } on DioException catch (e) {
      throw ServerException(
        e.message ?? 'Upload to storage failed.',
        messageKey: 'userApiUploadFailed',
        statusCode: e.response?.statusCode,
        data: e.response?.data,
      );
    }

    return OssUploadResult(
      contentType: contentType,
      objectKey: presign.objectKey,
      publicUrl: presign.publicUrl,
      size: bytes.length,
      type: type,
    );
  }

  Map<String, dynamic> _ensureOkEnvelope(
    Object? data, {
    int? statusCode,
    required String fallbackMessage,
    String? fallbackMessageKey,
  }) {
    if (data is! Map) {
      throw ServerException(
        fallbackMessage,
        messageKey: fallbackMessageKey,
        statusCode: statusCode,
        data: data,
      );
    }
    final m = data.cast<String, dynamic>();
    final biz = (m['code'] is num) ? (m['code'] as num).toInt() : 0;
    if (!ServerErrorCodes.isOk(biz)) {
      throw ServerException(
        (m['message'] ?? fallbackMessage).toString(),
        bizCode: biz,
        details: m['details']?.toString(),
        statusCode: statusCode,
        data: data,
      );
    }
    return m;
  }

  /// Multipart threshold: use chunked upload above this size.
  static const int _chunkedUploadThresholdBytes = 5 * 1024 * 1024; // 5MB

  /// `POST /api/v1/oss/upload` or chunked upload for large files.
  ///
  /// - **avatar**: `GET /api/v1/user/presignUpload` then **PUT** file bytes to
  ///   the signed URL (`file_type` / `content_type` query params per backend).
  /// - **other types**: small (≤5MB) multipart `POST /api/v1/oss/upload`, large
  ///   chunked upload (init → chunk × N → complete).
  /// - [type]: e.g. `avatar`, `audio`
  /// Returns: result.public_url
  Future<OssUploadResult> uploadToOss({
    required File file,
    required String type,
    void Function(int sent, int total)? onProgress,
  }) async {
    final t = type.trim();
    if (t.isEmpty) {
      throw ServerException('Upload failed: type cannot be empty.', messageKey: 'userApiUploadTypeEmpty');
    }
    if (!file.existsSync()) {
      throw ServerException('Upload failed: file not found.', messageKey: 'userApiUploadFileNotFound');
    }

    if (t == 'avatar') {
      return _uploadAvatarViaPresign(file: file, type: t);
    }

    final size = await file.length();
    if (size <= _chunkedUploadThresholdBytes) {
      return _uploadToOssSimple(file: file, type: t);
    }
    return _uploadToOssChunked(file: file, type: t, onProgress: onProgress);
  }

  static String? _guessContentTypeForPath(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.heic':
        return 'image/heic';
      default:
        return null;
    }
  }

  /// `GET /api/v1/user/presignUpload?file_type=&content_type=` then PUT body to signed URL.
  Future<OssUploadResult> _uploadAvatarViaPresign({
    required File file,
    required String type,
  }) async {
    final contentType = _guessContentTypeForPath(file.path);
    final query = <String, dynamic>{'file_type': type};
    if (contentType != null && contentType.isNotEmpty) {
      query['content_type'] = contentType;
    }

    final presignResp = await _client.request<Object>(
      '/api/v1/user/presignUpload',
      method: 'GET',
      queryParameters: query,
    );
    final m = _ensureOkEnvelope(
      presignResp.data,
      statusCode: presignResp.statusCode,
      fallbackMessage: 'Presign upload failed.',
      fallbackMessageKey: 'userApiUploadFailed',
    );
    final rawResult = m['result'];
    if (rawResult is! Map) {
      throw ServerException(
        'Presign upload failed: response missing result.',
        messageKey: 'userApiUploadMissingResult',
        statusCode: presignResp.statusCode,
        data: presignResp.data,
      );
    }
    final presign = UserPresignUpload.fromResultMap(rawResult.cast<String, dynamic>());
    return UserApi.uploadFileViaPresign(
      file: file,
      presign: presign,
      type: type,
      contentType: contentType,
      presignStatusCode: presignResp.statusCode,
      presignResponseForError: presignResp.data,
    );
  }

  Future<OssUploadResult> _uploadToOssSimple({
    required File file,
    required String type,
  }) async {
    const extendedTimeout = Duration(seconds: 120);
    final form = FormData();
    form.fields.add(MapEntry('type', type));
    form.files.add(
      MapEntry(
        'file',
        await MultipartFile.fromFile(file.path),
      ),
    );

    final resp = await _client.request<Object>(
      '/api/v1/oss/upload',
      method: 'POST',
      data: form,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: extendedTimeout,
        receiveTimeout: extendedTimeout,
      ),
    );
    return _parseOssUploadResult(resp, type);
  }

  static const int _chunkUploadMaxRetries = 3;

  Future<OssUploadResult> _uploadToOssChunked({
    required File file,
    required String type,
    void Function(int sent, int total)? onProgress,
  }) async {
    const chunkSize = 5 * 1024 * 1024; // 5MB
    const extendedTimeout = Duration(seconds: 60);

    // 1. init
    final initResp = await _client.request<Object>(
      '/api/v1/oss/upload/init',
      method: 'POST',
      data: {
        'type': type,
        'filename': p.basename(file.path),
      },
      options: Options(receiveTimeout: extendedTimeout),
    );
    final initM = _ensureOkEnvelope(
      initResp.data,
      statusCode: initResp.statusCode,
      fallbackMessage: 'Upload init failed.',
      fallbackMessageKey: 'userApiUploadFailed',
    );
    final initResult = initM['result'];
    if (initResult is! Map) {
      throw ServerException(
        'Upload init failed: response missing result.',
        messageKey: 'userApiUploadMissingResult',
        statusCode: initResp.statusCode,
        data: initResp.data,
      );
    }
    final uploadId = (initResult['upload_id'] ?? '').toString();
    if (uploadId.isEmpty) {
      throw ServerException(
        'Upload init failed: missing upload_id.',
        messageKey: 'userApiUploadMissingResult',
        statusCode: initResp.statusCode,
        data: initResp.data,
      );
    }

    // 2. upload chunks with retry
    final totalSize = await file.length();
    final totalChunks = (totalSize / chunkSize).ceil();
    var sent = 0;

    final raf = await file.open(mode: FileMode.read);
    try {
      for (var i = 0; i < totalChunks; i++) {
        final remaining = totalSize - (i * chunkSize);
        final toRead = math.min(chunkSize, remaining);
        final chunkBytes = await raf.read(toRead);

        for (var attempt = 0; attempt < _chunkUploadMaxRetries; attempt++) {
          try {
            final form = FormData();
            form.fields.add(MapEntry('upload_id', uploadId));
            form.fields.add(MapEntry('chunk_index', i.toString()));
            form.files.add(
              MapEntry(
                'chunk',
                MultipartFile.fromBytes(
                  chunkBytes,
                  filename: 'chunk_$i',
                ),
              ),
            );
            await _client.request<Object>(
              '/api/v1/oss/upload/chunk',
              method: 'POST',
              data: form,
              options: Options(
                contentType: 'multipart/form-data',
                sendTimeout: extendedTimeout,
                receiveTimeout: extendedTimeout,
              ),
            );
            break;
          } catch (e) {
            if (attempt >= _chunkUploadMaxRetries - 1) rethrow;
            await Future<void>.delayed(
              Duration(seconds: math.min(8, math.pow(2, attempt).toInt())),
            );
          }
        }

        sent += chunkBytes.length;
        onProgress?.call(sent, totalSize);
      }
    } finally {
      await raf.close();
    }

    // 3. complete
    const completeTimeout = Duration(seconds: 180);
    final completeResp = await _client.request<Object>(
      '/api/v1/oss/upload/complete',
      method: 'POST',
      data: {'upload_id': uploadId},
      options: Options(receiveTimeout: completeTimeout),
    );
    return _parseOssUploadResult(completeResp, type);
  }

  OssUploadResult _parseOssUploadResult(Response<Object> resp, String type) {
    final m = _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Upload failed.',
      fallbackMessageKey: 'userApiUploadFailed',
    );
    final result = m['result'];
    if (result is! Map) {
      throw ServerException(
        'Upload failed: response missing result.',
        messageKey: 'userApiUploadMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    final r = OssUploadResult.fromJson(result.cast<String, dynamic>());
    if (r.publicUrl.trim().isEmpty) {
      throw ServerException(
        'Upload failed: response missing public_url.',
        messageKey: 'userApiUploadMissingPublicUrl',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return r;
  }

  /// `POST /api/v1/user/logout`
  Future<void> logout() async {
    final resp = await _client.request<Object>(
      '/api/v1/user/logout',
      method: 'POST',
    );
    _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Logout failed.',
      fallbackMessageKey: 'userApiLogoutFailed',
    );
  }

  /// `POST /api/v1/user/deactivate`
  Future<void> deactivate() async {
    final resp = await _client.request<Object>(
      '/api/v1/user/deactivate',
      method: 'POST',
    );
    _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Account deactivation failed.',
      fallbackMessageKey: 'userApiDeactivateFailed',
    );
  }

  /// `POST /api/v1/user/password/reset`
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/password/reset',
      method: 'POST',
      data: {
        'email': email,
        'code': code,
        'new_password': md5Hex(newPassword),
      },
    );
    _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Password reset failed.',
      fallbackMessageKey: 'userApiResetPasswordFailed',
    );
  }

  /// `PUT /api/v1/user/password`
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/password',
      method: 'PUT',
      data: {
        'old_password': oldPassword.isEmpty ? '' : md5Hex(oldPassword),
        'new_password': md5Hex(newPassword),
      },
    );
    _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Password change failed.',
      fallbackMessageKey: 'userApiChangePasswordFailed',
    );
  }

  /// `PUT /api/v1/user`
  Future<UserProfile?> updateProfile({String? avatarUrl, String? name}) async {
    final data = <String, dynamic>{};
    final au = (avatarUrl ?? '').trim();
    final n = (name ?? '').trim();
    if (au.isNotEmpty) data['avatar_url'] = au;
    if (n.isNotEmpty) data['name'] = n;

    final resp = await _client.request<Object>(
      '/api/v1/user',
      method: 'PUT',
      data: data,
    );
    final m = _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Update profile failed.',
      fallbackMessageKey: 'userApiUpdateProfileFailed',
    );
    final result = m['result'];
    if (result is! Map) {
      // Backend compatibility: some endpoints may not return result; code=200 counts as success.
      return null;
    }
    return UserProfile.fromJson(result.cast<String, dynamic>());
  }

  /// `PUT /api/v1/user/email`
  Future<UserProfile?> updateEmail({required String email, required String code}) async {
    final resp = await _client.request<Object>(
      '/api/v1/user/email',
      method: 'PUT',
      data: {'email': email, 'code': code},
    );
    final m = _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Update email failed.',
      fallbackMessageKey: 'userApiUpdateEmailFailed',
    );
    final result = m['result'];
    if (result is! Map) {
      // Backend compatibility: some endpoints may not return result; code=200 counts as success.
      return null;
    }
    return UserProfile.fromJson(result.cast<String, dynamic>());
  }

  /// `GET /api/v1/user`
  Future<UserProfile> getMe() async {
    final resp = await _client.request<Object>(
      '/api/v1/user',
      method: 'GET',
    );
    final m = _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Failed to get user info.',
      fallbackMessageKey: 'userApiGetMeFailed',
    );
    final result = m['result'];
    if (result is! Map) {
      throw ServerException(
        'Failed to get user info: response missing result.',
        messageKey: 'userApiGetMeMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return UserProfile.fromJson(result.cast<String, dynamic>());
  }

  /// `GET /api/v1/user/getSecurityInfo`
  Future<UserSecurityInfo> getSecurityInfo() async {
    final resp = await _client.request<Object>(
      '/api/v1/user/getSecurityInfo',
      method: 'GET',
    );
    final m = _ensureOkEnvelope(
      resp.data,
      statusCode: resp.statusCode,
      fallbackMessage: 'Get security info failed.',
      fallbackMessageKey: 'userApiGetSecurityInfoFailed',
    );
    final result = m['result'];
    if (result is! Map) {
      throw ServerException(
        'Get security info: response missing result.',
        messageKey: 'userApiGetSecurityInfoMissingResult',
        statusCode: resp.statusCode,
        data: resp.data,
      );
    }
    return UserSecurityInfo.fromJson(result.cast<String, dynamic>());
  }
}

