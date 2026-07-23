import '../server_exception.dart';
import 'sensecraft_error_codes.dart';

/// Parsed SenseCraft response envelope: `{ code, msg, data }`.
///
/// Different from the self-hosted backend's `{ code, message, result, details }`:
/// - field is `msg` not `message`
/// - payload field is `data` not `result`
/// - `code` may be `int` or `string`
///
/// Success is determined by [SenseCraftErrorCodes.isOk].
class SenseCraftEnvelope {
  final int code;
  final String? msg;
  final Object? data;

  const SenseCraftEnvelope({required this.code, required this.msg, required this.data});

  bool get isOk => SenseCraftErrorCodes.isOk(code);

  /// Returns [data] cast to [Map] or throws if shape doesn't match.
  Map<String, dynamic> requireDataMap({int? statusCode, required String fallbackMessage}) {
    final d = data;
    if (d is! Map) {
      throw ServerException(
        fallbackMessage,
        bizCode: code,
        statusCode: statusCode,
        data: d,
      );
    }
    return d.cast<String, dynamic>();
  }
}

/// Parses a raw response body into a [SenseCraftEnvelope].
///
/// Throws a [ServerException] when the body is not a JSON object, or when
/// the envelope's `code` is non-success. On success returns the parsed
/// envelope so the caller can pull fields out of `data`.
SenseCraftEnvelope parseSenseCraftEnvelope(
  Object? body, {
  int? statusCode,
  required String fallbackMessage,
}) {
  if (body is! Map) {
    throw ServerException(
      fallbackMessage,
      messageKey: 'authRequestFormat',
      statusCode: statusCode,
      data: body,
    );
  }
  final m = body.cast<String, dynamic>();
  final code = parseSenseCraftCode(m['code']);
  final msg = m['msg']?.toString() ?? m['message']?.toString();
  final data = m['data'];
  final env = SenseCraftEnvelope(code: code, msg: msg, data: data);
  if (!env.isOk) {
    final fallback = (msg ?? '').trim().isEmpty ? fallbackMessage : msg!.trim();
    throw ServerException(
      fallback,
      bizCode: code,
      statusCode: statusCode,
      data: body,
    );
  }
  return env;
}
