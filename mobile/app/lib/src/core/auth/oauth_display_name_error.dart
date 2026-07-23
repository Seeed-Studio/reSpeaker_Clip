import '../server/server_exception.dart';
import '../validation/text_charset.dart';

/// MySQL `utf8` (3-byte) cannot store emoji / supplementary Unicode in `name`.
bool isOAuthDisplayNameDbCharsetError(ServerException e) {
  if (isPromptTemplateCharsetServerError(e)) return false;
  final blob = '${e.message}\n${e.details ?? ''}'.toLowerCase();
  return blob.contains('incorrect string value') ||
      blob.contains('error 1366') ||
      blob.contains('utf8mb4');
}
