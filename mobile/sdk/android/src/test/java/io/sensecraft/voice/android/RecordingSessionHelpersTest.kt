package io.sensecraft.voice.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class RecordingSessionHelpersTest {
    @Test
    fun retryPolicyMatchesFailureKinds() {
        val defaultPolicy = DownloadStartRetryPolicy()
        assertTrue(defaultPolicy.shouldRetry(DownloadStartFailureKind.SESSION_NOT_FOUND))
        assertFalse(defaultPolicy.shouldRetry(DownloadStartFailureKind.TRANSFER_BUSY))
        assertFalse(defaultPolicy.shouldRetry(DownloadStartFailureKind.OTHER))

        val resilient = DownloadStartRetryPolicy.resilient()
        assertTrue(resilient.shouldRetry(DownloadStartFailureKind.SESSION_NOT_FOUND))
        assertTrue(resilient.shouldRetry(DownloadStartFailureKind.TRANSFER_BUSY))
        assertFalse(resilient.shouldRetry(DownloadStartFailureKind.OTHER))
    }

    @Test
    fun recordingExceptionCarriesCode() {
        val error = RecordingException("boom", null, "busy")
        assertEquals("busy", error.code)
        assertTrue(error.message!!.contains("boom"))
    }

    @Test
    fun runtimeInfoModel() {
        val status = DeviceStatus(
            state = "recording",
            isRecording = true,
            sessionId = "s1",
            batteryPercent = 88,
            isCharging = false,
            freeSpaceBytes = 1024,
            bitrate = 128000,
            recordingMode = RecordingMode.NORMAL,
            recordingSeconds = 12,
            firmwareVersion = "1.0.0",
            raw = org.json.JSONObject(),
        )
        val info = DeviceRuntimeInfo(
            firmwareVersion = "1.0.0",
            rawDeviceTime = 123,
            deviceTime = Date(123000L),
            status = status,
            pairStatus = "paired",
            pairAddress = "AA:BB",
            versionReply = null,
            timeReply = null,
            statusReply = null,
            pairReply = null,
        )

        assertEquals("s1", info.sessionId)
        assertEquals("recording", info.state)
        assertTrue(info.formattedDeviceTime?.isNotEmpty() == true)
        assertTrue(info.hasAnyData)
    }
}
