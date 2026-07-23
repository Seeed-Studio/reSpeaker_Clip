package io.sensecraft.voice.android

import org.json.JSONObject

sealed class TransferJsonEvent {
    data class FileComplete(val filename: String, val sessionId: String = "") : TransferJsonEvent()
    data class TransferComplete(val files: Int, val sessionId: String = "") : TransferJsonEvent()
    data class Other(val event: String) : TransferJsonEvent()
}

object TransferJsonEventParser {
    fun parse(msg: JsonObject): TransferJsonEvent? {
        val data = msg.optJSONObject("data") ?: JSONObject()
        val event = msg.optStringOrNull("event") ?: data.optStringOrNull("event") ?: return null
        val sessionId = msg.optStringOrNull("session")
            ?: msg.optStringOrNull("session_id")
            ?: data.optStringOrNull("session")
            ?: data.optStringOrNull("session_id")
            ?: ""

        return when (event) {
            "file_complete" -> TransferJsonEvent.FileComplete(
                filename = msg.optStringOrNull("filename") ?: data.optStringOrNull("filename").orEmpty(),
                sessionId = sessionId
            )
            "transfer_complete" -> TransferJsonEvent.TransferComplete(
                files = msg.optIntOrNull("files") ?: data.optIntOrNull("files") ?: 0,
                sessionId = sessionId
            )
            else -> TransferJsonEvent.Other(event)
        }
    }
}

object TransferJsonTransferCompletePolicy {
    fun looksLikeSessionComplete(
        fileCompleteCount: Int,
        deviceTotalFiles: Int,
        receivedBytes: Int,
        deviceSessionBytes: Int
    ): Boolean {
        val haveAllSlices = deviceTotalFiles > 0 && fileCompleteCount >= deviceTotalFiles
        val haveAllBytes = deviceSessionBytes > 0 &&
            receivedBytes >= (deviceSessionBytes - 2048).coerceAtLeast(0)
        return haveAllSlices || haveAllBytes
    }

    fun shouldIgnoreEmptyTransferComplete(receivedBytes: Int, files: Int): Boolean =
        receivedBytes == 0 && files == 0
}
