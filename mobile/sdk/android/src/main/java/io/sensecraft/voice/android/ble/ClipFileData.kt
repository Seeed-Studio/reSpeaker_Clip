package io.sensecraft.voice.android

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets

const val kClipFrameData: Int = 0x01
const val kClipFrameFileStart: Int = 0x10
const val kClipFrameFileEnd: Int = 0x11
const val kClipFrameTransferDone: Int = 0x12
const val kClipDataHeaderSize = 5

sealed class ClipFileDataParsed {
    data class Raw(val bytes: ByteArray) : ClipFileDataParsed()
    data class Data(val seq: Int, val payload: ByteArray) : ClipFileDataParsed()
    data class FileStart(val filename: String, val fileSize: Int) : ClipFileDataParsed()
    data class FileEnd(val crc32: Long) : ClipFileDataParsed()
    data class TransferDone(val sessionId: String, val fileCount: Int) : ClipFileDataParsed()
    data class Invalid(val reason: String) : ClipFileDataParsed()
}

fun parseClipFileDataNotify(data: ByteArray): ClipFileDataParsed {
    if (data.isEmpty()) return ClipFileDataParsed.Invalid("empty")
    when (data[0].toInt() and 0xff) {
        kClipFrameData -> {
            if (data.size < kClipDataHeaderSize) return ClipFileDataParsed.Invalid("DATA short header len=${data.size}")
            val len = (data[3].toInt() and 0xff) or ((data[4].toInt() and 0xff) shl 8)
            if (data.size != kClipDataHeaderSize + len) {
                return ClipFileDataParsed.Invalid("DATA len mismatch total=${data.size} payload=$len")
            }
            val seq = (data[1].toInt() and 0xff) or ((data[2].toInt() and 0xff) shl 8)
            return ClipFileDataParsed.Data(seq, data.copyOfRange(kClipDataHeaderSize, kClipDataHeaderSize + len))
        }
        kClipFrameFileStart -> {
            if (data.size < 3) return ClipFileDataParsed.Invalid("FILE_START short len=${data.size}")
            val fnLen = data[1].toInt() and 0xff
            if (data.size < 2 + fnLen + 4) {
                return ClipFileDataParsed.Invalid("FILE_START bad fnLen=$fnLen total=${data.size}")
            }
            val filename = String(data, 2, fnLen, StandardCharsets.UTF_8)
            val off = 2 + fnLen
            val fileSize = ByteBuffer.wrap(data, off, 4).order(ByteOrder.LITTLE_ENDIAN).int
            return ClipFileDataParsed.FileStart(filename, fileSize)
        }
        kClipFrameFileEnd -> {
            if (data.size < 5) return ClipFileDataParsed.Invalid("FILE_END short len=${data.size}")
            val crc = ByteBuffer.wrap(data, 1, 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL
            return ClipFileDataParsed.FileEnd(crc)
        }
        kClipFrameTransferDone -> {
            if (data.size < 3) return ClipFileDataParsed.Invalid("TRANSFER_DONE short len=${data.size}")
            val sidLen = data[1].toInt() and 0xff
            if (data.size < 2 + sidLen + 4) {
                return ClipFileDataParsed.Invalid("TRANSFER_DONE bad sidLen=$sidLen")
            }
            val sessionId = String(data, 2, sidLen, StandardCharsets.UTF_8)
            val off = 2 + sidLen
            val fileCount = ByteBuffer.wrap(data, off, 4).order(ByteOrder.LITTLE_ENDIAN).int
            return ClipFileDataParsed.TransferDone(sessionId, fileCount)
        }
        else -> return ClipFileDataParsed.Raw(data)
    }
}

