import 'dart:typed_data';

/// zlib / IEEE CRC-32 (same as Python `binascii.crc32`).
int crc32Ieee(Uint8List bytes, [int crc = 0]) {
  var c = (~crc) & 0xffffffff;
  for (final b in bytes) {
    c = _crc32Table[(c ^ b) & 0xff] ^ (c >> 8);
    c &= 0xffffffff;
  }
  return (~c) & 0xffffffff;
}

final List<int> _crc32Table = List<int>.generate(256, (i) {
  var c = i;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1);
    c &= 0xffffffff;
  }
  return c;
});
