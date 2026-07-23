/// Extract complete JSON objects (`{...}`) from a potentially chunked stream.
class JsonObjectFramer {
  String _buf = '';

  Iterable<String> feed(String chunk) sync* {
    if (chunk.isEmpty) return;
    _buf += chunk;

    while (true) {
      final start = _buf.indexOf('{');
      if (start == -1) {
        // No object start; avoid unbounded growth.
        if (_buf.length > 4096) _buf = _buf.substring(_buf.length - 1024);
        return;
      }
      if (start > 0) {
        _buf = _buf.substring(start);
      }

      final end = _findJsonObjectEnd(_buf);
      if (end == null) return; // need more data

      final obj = _buf.substring(0, end);
      _buf = _buf.substring(end);
      final trimmed = obj.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }

  /// End index (exclusive) of the first complete JSON object, or `null` if
  /// the buffer is still incomplete.
  int? _findJsonObjectEnd(String s) {
    var depth = 0;
    var inString = false;
    var escaped = false;

    for (var i = 0; i < s.length; i++) {
      final ch = s.codeUnitAt(i);

      if (inString) {
        if (escaped) {
          escaped = false;
          continue;
        }
        if (ch == 0x5C /* \ */) {
          escaped = true;
          continue;
        }
        if (ch == 0x22 /* " */) {
          inString = false;
        }
        continue;
      }

      if (ch == 0x22 /* " */) {
        inString = true;
        continue;
      }

      if (ch == 0x7B /* { */) {
        depth++;
        continue;
      }
      if (ch == 0x7D /* } */) {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return null;
  }
}
