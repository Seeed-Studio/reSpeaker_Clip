package io.sensecraft.voice.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BleTransferFrameHandlerTest {
    @Test
    fun handleFileLifecycle() {
        val state = BleTransferFrameState()
        val name = "0001.opus".toByteArray()
        val startBytes = byteArrayOf(
            kClipFrameFileStart.toByte(),
            name.size.toByte(),
        ) + name + byteArrayOf(0x03, 0x00, 0x00, 0x00)

        when (val result = BleTransferFrameHandler.handle(startBytes, state)) {
            is BleTransferFrameResult.FileStart -> {
                assertEquals("0001.opus", result.filename)
                assertEquals(3, result.fileSize)
            }
            else -> throw AssertionError("unexpected start frame: $result")
        }

        val payload = byteArrayOf(0x01, 0x02, 0x03)
        val crc = crc32Ieee(payload)
        val dataBytes = byteArrayOf(
            kClipFrameData.toByte(),
            0x00,
            0x00,
            0x03,
            0x00,
        ) + payload

        when (val result = BleTransferFrameHandler.handle(dataBytes, state)) {
            is BleTransferFrameResult.Data -> {
                assertEquals(0, result.seq)
                assertEquals(true, result.payload.contentEquals(payload))
                assertFalse(result.duplicateSeq)
                assertFalse(result.seqJump)
                assertFalse(result.orphanBeforeFileStart)
            }
            else -> throw AssertionError("unexpected data frame: $result")
        }

        val endBytes = byteArrayOf(
            kClipFrameFileEnd.toByte(),
            (crc and 0xff).toByte(),
            ((crc shr 8) and 0xff).toByte(),
            ((crc shr 16) and 0xff).toByte(),
            ((crc shr 24) and 0xff).toByte(),
        )

        when (val result = BleTransferFrameHandler.handle(endBytes, state)) {
            is BleTransferFrameResult.FileEndOk -> {
                assertEquals("0001.opus", result.filename)
                assertEquals(crc, result.localCrc32)
                assertEquals(crc, result.deviceCrc32)
                assertEquals(1, result.fileCompleteCount)
                assertEquals(3, result.declaredFileSize)
                assertEquals(3, result.bytesThisFile)
                assertTrue(result.usedFraming)
            }
            else -> throw AssertionError("unexpected end frame: $result")
        }
    }
}
