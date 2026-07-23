/// Plain-text formatting for transcript/summary export and clipboard.
class TranscriptBlock {
  final String speaker;
  final String time;
  final String text;

  const TranscriptBlock({
    required this.speaker,
    required this.time,
    required this.text,
  });
}

bool transcriptBlockShowsSpeakerLabel(String speaker) {
  final t = speaker.trim();
  if (t.isEmpty) return false;
  if (t.toLowerCase() == 'transcript') return false;
  return true;
}

String _speakerSuffix(String speaker) {
  return speaker.trim().toLowerCase().startsWith('speaker') ? ': ' : '：';
}

String _stripTranscriptTemplatePrefix(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;

  final inlinePrefixes = <RegExp>[
    RegExp(r'^\*\*transcript\*\*\s*:\s*', caseSensitive: false),
    RegExp(r'^\*\*transcription\*\*\s*:\s*', caseSensitive: false),
    RegExp(r'^transcript\s*:\s*', caseSensitive: false),
    RegExp(r'^transcription\s*:\s*', caseSensitive: false),
    RegExp(r'^转写\s*[:：]\s*'),
  ];
  for (final re in inlinePrefixes) {
    final n = s.replaceFirst(re, '');
    if (n != s) {
      s = n.trim();
      break;
    }
  }

  final splitLines = s.split('\n');
  if (splitLines.length >= 2) {
    final first = splitLines.first.trim();
    if (RegExp(r'^transcript\s*:?\s*$', caseSensitive: false).hasMatch(first) ||
        RegExp(r'^transcription\s*:?\s*$', caseSensitive: false)
            .hasMatch(first) ||
        first == '转写' ||
        first == '转写:' ||
        first == '转写：') {
      s = splitLines.sublist(1).join('\n').trim();
    }
  }
  return s;
}

String _normalizeTranscriptDisplayText(String input) {
  var text = input.trim();
  if (text.isEmpty) return '';
  text = text.replaceAll(RegExp(r'\s+'), ' ');
  const cjk = r'\u4E00-\u9FFF';
  const cjkPunctuation = r'\u3000-\u303F\uFF00-\uFFEF';
  final rules = <RegExp>[
    RegExp('([$cjk])\\s+([$cjk])'),
    RegExp('([$cjk])\\s+([$cjkPunctuation])'),
    RegExp('([$cjkPunctuation])\\s+([$cjk])'),
    RegExp('([A-Za-z])\\s+([0-9])'),
    RegExp('([0-9])\\s+([A-Za-z])'),
  ];
  while (true) {
    var next = text;
    for (final rule in rules) {
      next = next.replaceAllMapped(
        rule,
        (match) => '${match.group(1) ?? ''}${match.group(2) ?? ''}',
      );
    }
    if (next == text) break;
    text = next;
  }
  return text.trim();
}

String _finalizeTranscriptBlockText(String raw) {
  return _normalizeTranscriptDisplayText(_stripTranscriptTemplatePrefix(raw));
}

List<TranscriptBlock> parseTranscriptBlocks(String raw) {
  final normalized = raw.trim();
  if (normalized.isEmpty) return const <TranscriptBlock>[];
  final out = <TranscriptBlock>[];
  final speakerInlineRe = RegExp(r'^(说话人\s*\d+|Speaker\s*\d+)[:：]\s*(.*)$');
  final lines = normalized
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);

  if (lines.any((line) => speakerInlineRe.hasMatch(line))) {
    TranscriptBlock? current;
    for (final line in lines) {
      final inlineMatch = speakerInlineRe.firstMatch(line);
      if (inlineMatch != null) {
        if (current != null) {
          out.add(current);
        }
        final speaker = (inlineMatch.group(1) ?? '').trim();
        final firstText = _finalizeTranscriptBlockText(
          inlineMatch.group(2)?.trim() ?? '',
        );
        current = TranscriptBlock(
          speaker: speaker,
          time: '',
          text: firstText,
        );
        continue;
      }
      if (current == null) {
        current = TranscriptBlock(
          speaker: '',
          time: '',
          text: _finalizeTranscriptBlockText(line),
        );
        continue;
      }
      current = TranscriptBlock(
        speaker: current.speaker,
        time: current.time,
        text: _finalizeTranscriptBlockText(
          [current.text, line]
              .where((part) => part.trim().isNotEmpty)
              .join(' ')
              .trim(),
        ),
      );
    }
    if (current != null) {
      out.add(current);
    }
    return out.where((block) => block.text.trim().isNotEmpty).toList();
  }

  final blocks = normalized.split('\n\n');
  for (final b in blocks) {
    final blockLines = b.split('\n');
    if (blockLines.isEmpty) continue;
    final head = blockLines.first;
    final inlineMatch = speakerInlineRe.firstMatch(head.trim());
    if (inlineMatch != null) {
      final speaker = (inlineMatch.group(1) ?? '').trim();
      final firstText = inlineMatch.group(2)?.trim() ?? '';
      final restText = blockLines.skip(1).join('\n').trim();
      final text = _finalizeTranscriptBlockText([firstText, restText]
          .where((part) => part.trim().isNotEmpty)
          .join('\n')
          .trim());
      final fallback = _finalizeTranscriptBlockText(b.trim());
      out.add(TranscriptBlock(
          speaker: speaker, time: '', text: text.isEmpty ? fallback : text));
      continue;
    }
    final parts = head.split('@');
    final hasMeta = parts.length > 1;
    final speaker = hasMeta ? parts.first.trim() : '';
    final time = hasMeta ? parts[1].trim() : '';
    final text = _finalizeTranscriptBlockText(
      blockLines.skip(1).join('\n').trim(),
    );
    final fallback = _finalizeTranscriptBlockText(b.trim());
    out.add(TranscriptBlock(
        speaker: speaker, time: time, text: text.isEmpty ? fallback : text));
  }
  return out;
}

String formatTranscriptForExport(String raw) {
  final blocks = parseTranscriptBlocks(raw);
  if (blocks.isEmpty) return raw.trim();
  final lines = <String>[];
  for (final block in blocks) {
    if (transcriptBlockShowsSpeakerLabel(block.speaker)) {
      lines.add(
          '${block.speaker}${_speakerSuffix(block.speaker)}${block.text}');
    } else {
      lines.add(block.text);
    }
  }
  return lines.join('\n\n').trim();
}

String _stripLeadingHashes(String s) {
  final t = s.trimLeft();
  var i = 0;
  while (i < t.length && t[i] == '#') {
    i++;
  }
  while (i < t.length && t[i] == ' ') {
    i++;
  }
  return i >= t.length ? t : t.substring(i);
}

String _stripInlineMarkdown(String text) {
  var s = text;
  while (true) {
    final bold = RegExp(r'\*\*(.+?)\*\*').firstMatch(s);
    if (bold != null) {
      s = s.replaceFirst(bold.group(0)!, bold.group(1)!);
      continue;
    }
    final italic = RegExp(r'(?<!\*)\*([^*]+?)\*(?!\*)').firstMatch(s);
    if (italic != null) {
      s = s.replaceFirst(italic.group(0)!, italic.group(1)!);
      continue;
    }
    break;
  }
  return s;
}

/// Plain text aligned with on-screen summary (strip markdown/code fences).
String formatSummaryForExport(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return trimmed;

  final out = <String>[];
  for (final rawLine in trimmed.split('\n')) {
    final line = rawLine.trim();
    if (line.startsWith('```')) continue;
    if (line.isEmpty) {
      out.add('');
      continue;
    }
    var content = rawLine;
    if (line.startsWith('#')) {
      content = _stripLeadingHashes(line);
    } else if (line.startsWith('- ')) {
      content = '- ${_stripInlineMarkdown(line.substring(2).trimLeft())}';
    } else {
      content = _stripInlineMarkdown(rawLine.trimRight());
    }
    out.add(content);
  }
  return out.join('\n').trim();
}
