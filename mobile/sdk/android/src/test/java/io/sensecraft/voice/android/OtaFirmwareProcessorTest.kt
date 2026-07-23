package io.sensecraft.voice.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class OtaFirmwareProcessorTest {
    @Test
    fun processBinWrapsImageZero() {
        val data = byteArrayOf(1, 2, 3, 4, 5)
        val images = OtaFirmwareProcessor.processBin(data)
        assertEquals(1, images.size)
        assertEquals(0, images[0].imageIndex)
        assertEquals(5, images[0].data.size)
    }

    @Test
    fun processBinThrowsWhenEmpty() {
        assertThrows(OtaFirmwareException::class.java) {
            OtaFirmwareProcessor.processBin(byteArrayOf())
        }
    }
}
