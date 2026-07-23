import 'dart:convert';
import 'dart:typed_data';

Uint8List _asUint8(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);

/// One notification payload on the BLE File Data characteristic
/// (`6E400004-...`). The Clip protocol delivers one frame per notification.
const int kClipFrameData = 0x01;
const int kClipFrameFileStart = 0x10;
const int kClipFrameFileEnd = 0x11;
const int kClipFrameTransferDone = 0x12;

/// DATA layout: `type(1) + seq(2 LE) + len(2 LE) + payload`. No per-frame CRC
/// on BLE — the GATT stack guarantees integrity.
const int kClipDataHeaderSize = 5;

sealed class ClipFileDataParsed {
  const ClipFileDataParsed();
}

/// Legacy: entire notify body is raw file bytes (pre–binary-frame firmware).
final class ClipParsedRaw extends ClipFileDataParsed {
  const ClipParsedRaw(this.bytes);
  final Uint8List bytes;
}

final class ClipParsedData extends ClipFileDataParsed {
  const ClipParsedData(this.seq, this.payload);
  final int seq;
  final Uint8List payload;
}

final class ClipParsedFileStart extends ClipFileDataParsed {
  const ClipParsedFileStart(this.filename, this.fileSize);
  final String filename;
  final int fileSize;
}

final class ClipParsedFileEnd extends ClipFileDataParsed {
  const ClipParsedFileEnd(this.crc32);
  final int crc32;
}

final class ClipParsedTransferDone extends ClipFileDataParsed {
  const ClipParsedTransferDone(this.sessionId, this.fileCount);
  final String sessionId;
  final int fileCount;
}

/// Malformed frame that looked like a typed frame but failed length checks.
final class ClipParsedInvalid extends ClipFileDataParsed {
  const ClipParsedInvalid(this.reason);
  final String reason;
}

/// Parse a single BLE file-data notification.
ClipFileDataParsed parseClipFileDataNotify(List<int> data) {
  if (data.isEmpty) {
    return const ClipParsedInvalid('empty');
  }
  final u8 = _asUint8(data);
  final t = u8[0];
  switch (t) {
    case kClipFrameData:
      if (u8.length < kClipDataHeaderSize) {
        return ClipParsedInvalid('DATA short header len=${u8.length}');
      }
      final len = u8[3] | (u8[4] << 8);
      if (u8.length != kClipDataHeaderSize + len) {
        return ClipParsedInvalid(
          'DATA len mismatch total=${u8.length} payload=$len',
        );
      }
      final seq = u8[1] | (u8[2] << 8);
      return ClipParsedData(
        seq,
        Uint8List.sublistView(
          u8,
          kClipDataHeaderSize,
          kClipDataHeaderSize + len,
        ),
      );
    case kClipFrameFileStart:
      if (u8.length < 3) {
        return ClipParsedInvalid('FILE_START short len=${u8.length}');
      }
      final fnLen = u8[1];
      if (u8.length < 2 + fnLen + 4) {
        return ClipParsedInvalid(
          'FILE_START bad fnLen=$fnLen total=${u8.length}',
        );
      }
      final nameBytes = u8.sublist(2, 2 + fnLen);
      final filename = utf8.decode(nameBytes, allowMalformed: true);
      final metaOff = 2 + fnLen;
      final bd = ByteData.sublistView(u8, metaOff, metaOff + 4);
      final fileSize = bd.getUint32(0, Endian.little);
      return ClipParsedFileStart(filename, fileSize);
    case kClipFrameFileEnd:
      if (u8.length < 5) {
        return ClipParsedInvalid('FILE_END short len=${u8.length}');
      }
      final bd = ByteData.sublistView(u8, 1, 5);
      final crc = bd.getUint32(0, Endian.little);
      return ClipParsedFileEnd(crc);
    case kClipFrameTransferDone:
      if (u8.length < 3) {
        return ClipParsedInvalid('TRANSFER_DONE short len=${u8.length}');
      }
      final sidLen = u8[1];
      if (u8.length < 2 + sidLen + 4) {
        return ClipParsedInvalid('TRANSFER_DONE bad sidLen=$sidLen');
      }
      final sidBytes = u8.sublist(2, 2 + sidLen);
      final sessionId = utf8.decode(sidBytes, allowMalformed: true);
      final fcOff = 2 + sidLen;
      final bd = ByteData.sublistView(u8, fcOff, fcOff + 4);
      final fileCount = bd.getUint32(0, Endian.little);
      return ClipParsedTransferDone(sessionId, fileCount);
    default:
      return ClipParsedRaw(u8);
  }
}
