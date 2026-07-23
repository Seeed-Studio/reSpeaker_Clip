package io.sensecraft.voice.android

import kotlin.math.max

object TransferProgress {
    fun wifiAligned(
        framedMode: Boolean,
        currentFileDeclaredSize: Int,
        bytesThisFile: Int,
        receivedSession: Int,
        expectedSession: Int?,
        filesCompleted: Int,
        deviceTotalFiles: Int,
        deviceSessionBytes: Int,
    ): Double? {
        var ratio: Double? = null
        if (expectedSession != null && expectedSession > 0) {
            val uncapped = receivedSession.toDouble() / expectedSession.toDouble()
            if (uncapped <= 1.05 || deviceTotalFiles <= 0) {
                ratio = uncapped.coerceIn(0.0, 0.995)
            }
        }
        if (ratio == null && deviceTotalFiles > 0 && deviceSessionBytes > 0) {
            val filePart = filesCompleted.toDouble() / deviceTotalFiles.toDouble()
            val bytePart = (receivedSession.toDouble() / deviceSessionBytes.toDouble()).coerceIn(0.0, 1.0)
            ratio = (filePart + bytePart / deviceTotalFiles.toDouble()).coerceIn(0.0, 0.995)
        } else if (ratio == null && deviceTotalFiles > 0) {
            ratio = if (framedMode && currentFileDeclaredSize > 0) {
                val inFlight = (bytesThisFile.toDouble() / currentFileDeclaredSize.toDouble()).coerceIn(0.0, 1.0)
                val denom = max(deviceTotalFiles, filesCompleted + if (inFlight > 0) 1 else 0)
                ((filesCompleted.toDouble() + inFlight) / denom.toDouble()).coerceIn(0.0, 0.995)
            } else {
                (filesCompleted.toDouble() / deviceTotalFiles.toDouble()).coerceIn(0.0, 0.995)
            }
        } else if (ratio == null && framedMode && currentFileDeclaredSize > 0) {
            ratio = (bytesThisFile.toDouble() / currentFileDeclaredSize.toDouble()).coerceIn(0.0, 0.995)
        }
        return ratio
    }

    fun uncappedRatio(
        framedMode: Boolean,
        currentFileDeclaredSize: Int,
        bytesThisFile: Int,
        receivedSession: Int,
        expectedSession: Int?,
        filesCompleted: Int,
        deviceTotalFiles: Int,
        deviceSessionBytes: Int,
    ): Double {
        if (expectedSession != null && expectedSession > 0) {
            return receivedSession.toDouble() / expectedSession.toDouble()
        }
        if (deviceTotalFiles > 0 && deviceSessionBytes > 0) {
            val filePart = filesCompleted.toDouble() / deviceTotalFiles.toDouble()
            val bytePart = (receivedSession.toDouble() / deviceSessionBytes.toDouble()).coerceIn(0.0, 1.0)
            return filePart + bytePart / deviceTotalFiles.toDouble()
        }
        if (deviceTotalFiles > 0) {
            return if (framedMode && currentFileDeclaredSize > 0) {
                val inFlight = (bytesThisFile.toDouble() / currentFileDeclaredSize.toDouble()).coerceIn(0.0, 1.0)
                val denom = max(deviceTotalFiles, filesCompleted + if (inFlight > 0) 1 else 0)
                (filesCompleted.toDouble() + inFlight) / denom.toDouble()
            } else {
                filesCompleted.toDouble() / deviceTotalFiles.toDouble()
            }
        }
        if (framedMode && currentFileDeclaredSize > 0) {
            return bytesThisFile.toDouble() / currentFileDeclaredSize.toDouble()
        }
        return 0.0
    }

    fun branchLabel(
        framedMode: Boolean,
        currentFileDeclaredSize: Int,
        bytesThisFile: Int,
        receivedSession: Int,
        expectedSession: Int?,
        filesCompleted: Int,
        deviceTotalFiles: Int,
        deviceSessionBytes: Int,
    ): String {
        if (expectedSession != null && expectedSession > 0) {
            val uncapped = receivedSession.toDouble() / expectedSession.toDouble()
            if (uncapped <= 1.05 || deviceTotalFiles <= 0) {
                return "expectedSession"
            }
        }
        if (deviceTotalFiles > 0 && deviceSessionBytes > 0) {
            return "files+sessionBytes"
        }
        if (deviceTotalFiles > 0) {
            return if (framedMode && currentFileDeclaredSize > 0) "files+sliceBytes" else "filesOnly"
        }
        if (framedMode && currentFileDeclaredSize > 0) {
            return "sliceBytes"
        }
        return "null"
    }

    fun sessionTransferBytesComplete(
        eventFileCount: Int,
        fileCompleteCount: Int,
        deviceTotalFilesFromDownload: Int,
    ): Boolean {
        if (deviceTotalFilesFromDownload <= 0) return false
        return eventFileCount >= deviceTotalFilesFromDownload ||
            fileCompleteCount >= deviceTotalFilesFromDownload
    }
}
