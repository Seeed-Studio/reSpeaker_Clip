import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hash plaintext password with MD5 (hex, lowercase) before sending to server.
///
/// Convention: UTF-8 encode, then md5, then output hex.
String md5Hex(String input) {
  final bytes = utf8.encode(input);
  return md5.convert(bytes).toString();
}

