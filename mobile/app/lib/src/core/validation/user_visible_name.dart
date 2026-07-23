/// Display-name limits shared with device rename UI ([kUserVisibleNameMaxLength]).
/// Aligned with firmware `AT+NAME` (1–32 printable UTF-8 characters).
const int kUserVisibleNameMaxLength = 32;

/// Folder names in the Files filter sheet.
const int kFolderNameMaxLength = 24;

/// Printable name, 1–[maxLength] characters (no control chars).
bool isValidPrintableName(String name, {required int maxLength}) {
  final t = name.trim();
  if (t.isEmpty) return false;
  if (t.runes.length > maxLength) return false;
  for (final r in t.runes) {
    if (r < 0x20) return false;
  }
  return true;
}

/// Printable name, 1–[kUserVisibleNameMaxLength] characters (no control chars).
bool isValidUserVisibleName(String name) =>
    isValidPrintableName(name, maxLength: kUserVisibleNameMaxLength);

/// Folder name, 1–[kFolderNameMaxLength] characters (no control chars).
bool isValidFolderName(String name) =>
    isValidPrintableName(name, maxLength: kFolderNameMaxLength);

/// Truncate to [max] runes for pre-filling rename fields.
String clipUserVisibleName(String name, {int max = kUserVisibleNameMaxLength}) {
  final t = name.trim();
  final runes = t.runes.toList();
  if (runes.length <= max) return t;
  return String.fromCharCodes(runes.take(max));
}
