import '../server/server_exception.dart';

/// Server [user_prompt_templates.name] column limit.
const int kPromptTemplateNameMaxRunes = 128;

/// Supplementary-plane Unicode (e.g. emoji) needs MySQL utf8mb4.
bool containsUnsupportedDbChars(String text) {
  for (final r in text.runes) {
    if (r > 0xffff) return true;
  }
  return false;
}

bool _hasControlChars(String text) {
  for (final r in text.runes) {
    if (r < 0x20) return true;
  }
  return false;
}

/// Allows common whitespace (tab/LF/CR) for multi-line prompt bodies.
bool _hasDisallowedControlChars(String text) {
  for (final r in text.runes) {
    if (r == 0x09 || r == 0x0a || r == 0x0d) continue;
    if (r < 0x20) return true;
  }
  return false;
}

bool isValidPromptTemplateName(String name) {
  final t = name.trim();
  if (t.isEmpty) return false;
  if (t.runes.length > kPromptTemplateNameMaxRunes) return false;
  if (_hasControlChars(t)) return false;
  return true;
}

bool isValidPromptTemplateContent(String content) {
  final t = content.trim();
  if (t.isEmpty) return false;
  if (_hasDisallowedControlChars(t)) return false;
  return true;
}

/// MySQL utf8 / error 1366 / biz code 15006 from prompt template APIs.
bool isPromptTemplateCharsetServerError(ServerException e) {
  if (e.bizCode == 15006) return true;
  final blob = '${e.message}\n${e.details ?? ''}'.toLowerCase();
  return blob.contains('incorrect string value') ||
      blob.contains('error 1366') ||
      e.errorKey == 'prompt_template_unsupported_chars';
}
