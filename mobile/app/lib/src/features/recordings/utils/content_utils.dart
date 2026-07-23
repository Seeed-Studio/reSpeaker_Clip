/// Re-render stored summary version titles (localized prefix + Vn) for the current language,
/// so UI language changes do not leave the wrong prefix (e.g. Chinese title in English mode).
String localizeSummaryVersionTitle(String storedTitle, String currentPrefix) {
  final t = storedTitle.trim();
  if (t.isEmpty) return currentPrefix;
  // Legacy default titles (Chinese Summary / English Summary) follow UI language
  if (t == '总结' || t == 'Summary') return currentPrefix;
  final match = RegExp(r'^(总结|Summary)\s+V(\d+)$').firstMatch(t);
  if (match != null) {
    return '$currentPrefix V${match.group(2)!}';
  }
  return t;
}

/// Whether [text] looks like an error (transcribe/summary failure, etc.),
/// and should not be used as a preview or snippet.
bool isErrorLikeContent(String? text) {
  if (text == null || text.trim().isEmpty) return false;
  final lower = text.trim().toLowerCase();
  // Transcription failure patterns
  if (lower.contains('transcription failed') ||
      lower.contains('语音识别失败') ||
      lower.startsWith('deepgram:') ||
      lower.contains('deepgram_empty_transcript') ||
      lower.contains('asrtranscribemissingresult') ||
      lower.contains('deepgram parse:') ||
      lower.contains('deepgram api:') ||
      lower.contains('deepgram fetch')) {
    return true;
  }
  // Summary / LLM failure patterns
  if (lower.contains('summary failed') ||
      lower.contains('总结失败') ||
      lower.contains('llm chat failed') ||
      lower.contains('stream error')) {
    return true;
  }
  // Generic: short text that looks like an error line
  if (lower.length < 120 &&
      (lower.contains('error:') ||
          lower.contains('err:') ||
          lower.contains('exception:') ||
          lower.contains('failed:') ||
          lower.contains('internal server error'))) {
    return true;
  }
  return false;
}

bool _isAsciiDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

bool _isSummaryVersionSuffix(String suffix) {
  if (suffix.length < 2) return false;
  if (suffix[0].toLowerCase() != 'v') return false;
  return suffix.substring(1).codeUnits.every(_isAsciiDigit);
}

String _collapseInlineWhitespace(String input) {
  final out = StringBuffer();
  var previousWasSpace = false;
  for (final rune in input.runes) {
    final isSpace =
        rune == 0x20 || rune == 0x09 || rune == 0x0a || rune == 0x0d;
    if (isSpace) {
      if (!previousWasSpace) out.write(' ');
      previousWasSpace = true;
    } else {
      out.writeCharCode(rune);
      previousWasSpace = false;
    }
  }
  return out.toString().trim();
}

String _stripSummaryTitleLine(String line) {
  var s = line.trim();
  if (s.startsWith('```')) return '';
  while (s.startsWith('#')) {
    s = s.substring(1).trimLeft();
  }
  if (s.startsWith('- ') || s.startsWith('* ') || s.startsWith('+ ')) {
    s = s.substring(2).trimLeft();
  }
  final firstSpace = s.indexOf(' ');
  if (firstSpace > 0) {
    final token = s.substring(0, firstSpace);
    final marker = token.endsWith('.') || token.endsWith(')')
        ? token.substring(0, token.length - 1)
        : '';
    if (marker.isNotEmpty && marker.codeUnits.every(_isAsciiDigit)) {
      s = s.substring(firstSpace + 1).trimLeft();
    }
  }
  for (final ch in const ['*', '_', '`', '>', '#']) {
    s = s.replaceAll(ch, '');
  }
  return s.trim();
}

/// Flatten summary markdown into a single plain-text paragraph.
String plainSummaryTextFromMarkdown(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map(_stripSummaryTitleLine)
      .where((line) => line.isNotEmpty && !isErrorLikeContent(line))
      .toList(growable: false);
  if (lines.isEmpty) return '';
  return _collapseInlineWhitespace(lines.join(' '));
}

String _truncateRunes(String source, {required int maxRunes}) {
  final runes = source.runes.toList(growable: false);
  if (runes.length <= maxRunes) return source;
  return '${String.fromCharCodes(runes.take(maxRunes))}…';
}

/// First sentence of summary plain text (list labels; default max 48 runes).
String summaryFirstSentenceFromText(String text, {int maxRunes = 48}) {
  final plain = plainSummaryTextFromMarkdown(text);
  if (plain.isEmpty) return '';

  var end = plain.length;
  for (var i = 0; i < plain.length; i++) {
    final c = plain[i];
    if ('。！？!?'.contains(c)) {
      end = i + 1;
      break;
    }
    if (c == '.' &&
        (i + 1 == plain.length ||
            plain[i + 1] == ' ' ||
            plain[i + 1] == '\n')) {
      end = i + 1;
      break;
    }
  }
  final sentence = plain.substring(0, end).trim();
  return _truncateRunes(sentence, maxRunes: maxRunes);
}

/// Short chip title (first meaningful line, max ~18 runes).
String compactSummaryTitleFromText(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map(_stripSummaryTitleLine)
      .where((line) => line.isNotEmpty && !isErrorLikeContent(line))
      .toList(growable: false);
  if (lines.isEmpty) return '';
  final source = _collapseInlineWhitespace(lines.first);
  return _truncateRunes(source, maxRunes: 18);
}

/// True when [title] is the default localized version label (e.g. "Summary V2").
bool isGenericSummaryVersionTitle(String title, String localizedPrefix) {
  final normalized = _collapseInlineWhitespace(title);
  if (normalized.isEmpty) return true;
  final prefixes = <String>[
    localizedPrefix.trim(),
    'Summary',
    '总结',
  ].where((v) => v.isNotEmpty);
  final normalizedLower = normalized.toLowerCase();
  for (final prefix in prefixes) {
    final prefixLower = prefix.toLowerCase();
    if (!normalizedLower.startsWith(prefixLower)) continue;
    final suffix = normalized.substring(prefix.length).trimLeft();
    if (_isSummaryVersionSuffix(suffix)) return true;
  }
  return false;
}

/// Plain-text label for summary / session history rows (list + picker).
///
/// Priority: meaningful [storedTitle] → first sentence of [summaryContent]
/// → generic version label → [sessionIdFallback] / [emptyFallback].
String summaryHistoryDisplayTitle({
  required String localizedGenericPrefix,
  String? storedTitle,
  String? summaryContent,
  String? sessionIdFallback,
  String? emptyFallback,
  int maxRunes = 48,
}) {
  final localized =
      localizeSummaryVersionTitle(storedTitle ?? '', localizedGenericPrefix);
  final generic = isGenericSummaryVersionTitle(localized, localizedGenericPrefix);

  if (!generic) {
    final plainTitle = plainSummaryTextFromMarkdown(localized);
    if (plainTitle.isNotEmpty) {
      return _truncateRunes(plainTitle, maxRunes: maxRunes);
    }
  }

  final firstSentence =
      summaryFirstSentenceFromText(summaryContent ?? '', maxRunes: maxRunes);
  if (firstSentence.isNotEmpty) return firstSentence;

  if (generic && localized.trim().isNotEmpty) return localized;

  final sid = sessionIdFallback?.trim() ?? '';
  if (sid.isNotEmpty) return sid;
  return emptyFallback ?? localizedGenericPrefix;
}
