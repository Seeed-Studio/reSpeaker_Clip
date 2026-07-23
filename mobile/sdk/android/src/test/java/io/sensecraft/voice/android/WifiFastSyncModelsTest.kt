package io.sensecraft.voice.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WifiFastSyncModelsTest {
    private val hotspot = WifiHotspotInfo(
        enabled = true,
        ssid = "SenseCraft-Voice",
        password = "password",
        ip = "192.168.4.1",
        port = 8089,
    )

    @Test
    fun batchItemCarriesResumeMetadata() {
        val item = WifiBatchItem(
            recordingId = "local-1",
            sessionId = "device-1",
            sessionDirectory = File("session"),
            expectedBytes = 4096,
            startFile = "0004.opus",
            resumeByteOffset = 3072,
        )
        assertEquals("0004.opus", item.startFile)
        assertEquals(3072, item.resumeByteOffset)
        assertEquals(4096, item.expectedBytes)
    }

    @Test
    fun batchResultExposesFallbackAndSuccessSemantics() {
        val success = WifiFastSyncBatchResult(succeeded = 2)
        assertTrue(success.isOverallSuccess)
        assertFalse(success.shouldFallBackToBle)

        val fallback = WifiFastSyncBatchResult(
            failed = 1,
            bleFallbackReason = WifiBleFallbackReason.PHONE_WIFI_DISCONNECTED,
            fallbackHotspot = hotspot,
        )
        assertFalse(fallback.isOverallSuccess)
        assertTrue(fallback.shouldFallBackToBle)
        assertEquals(hotspot, fallback.fallbackHotspot)
    }

    @Test
    fun verifyFailureRetainsKindAndHotspot() {
        val failure = WifiVerifyFailure(WifiVerifyFailureKind.TIMED_OUT, hotspot)
        assertEquals(WifiVerifyFailureKind.TIMED_OUT, failure.kind)
        assertEquals(hotspot, failure.hotspot)
        assertTrue(failure.message.orEmpty().contains("timed_out"))
    }
}
