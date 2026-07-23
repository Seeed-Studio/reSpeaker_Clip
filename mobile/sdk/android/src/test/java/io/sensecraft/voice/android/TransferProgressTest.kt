package io.sensecraft.voice.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferProgressTest {
    @Test
    fun sessionTransferCompletion() {
        assertTrue(
            TransferProgress.sessionTransferBytesComplete(
                eventFileCount = 2,
                fileCompleteCount = 1,
                deviceTotalFilesFromDownload = 2,
            ),
        )
        assertFalse(
            TransferProgress.sessionTransferBytesComplete(
                eventFileCount = 1,
                fileCompleteCount = 1,
                deviceTotalFilesFromDownload = 3,
            ),
        )
    }

    @Test
    fun wifiAlignedProgress() {
        val ratio = TransferProgress.wifiAligned(
            framedMode = true,
            currentFileDeclaredSize = 100,
            bytesThisFile = 40,
            receivedSession = 240,
            expectedSession = 1000,
            filesCompleted = 2,
            deviceTotalFiles = 5,
            deviceSessionBytes = 1000,
        )
        assertTrue(ratio != null && kotlin.math.abs(ratio - 0.24) < 0.0001)
    }
}
