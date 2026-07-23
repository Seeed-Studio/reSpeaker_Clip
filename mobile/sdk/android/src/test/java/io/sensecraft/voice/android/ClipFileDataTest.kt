package io.sensecraft.voice.android

import org.junit.Assert.assertEquals
import org.junit.Test

class ClipFileDataTest {
    @Test
    fun parseFileStart() {
        val name = "a.opus".toByteArray()
        val bytes = byteArrayOf(
            kClipFrameFileStart.toByte(),
            name.size.toByte(),
        ) + name + byteArrayOf(0x34, 0x12, 0x00, 0x00)
        when (val parsed = parseClipFileDataNotify(bytes)) {
            is ClipFileDataParsed.FileStart -> {
                assertEquals("a.opus", parsed.filename)
                assertEquals(0x1234, parsed.fileSize)
            }
            else -> throw AssertionError("unexpected frame: $parsed")
        }
    }
}
