package io.sensecraft.voice.android

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

class AtTransport(
    private val connection: SenseCraftVoiceConnection,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val jsonFramer = JsonObjectFramer()
    private val jsonHub = MutableSharedFlow<JsonObject>(extraBufferCapacity = 128)
    private val sendMutex = Mutex()
    val jsonMessages: Flow<JsonObject> = jsonHub.asSharedFlow()

    init {
        scope.launch {
            connection.responseNotifyBytes().collect { chunk ->
                ingestResponseChunk(chunk)
            }
        }
    }

    suspend fun send(
        atCommand: String,
        timeoutMs: Long = 5_000,
        withoutResponse: Boolean = false,
        interChunkDelayMs: Long = 16,
    ): JsonObject = sendMutex.withLock {
        val replyDeferred = scope.async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
            jsonMessages.first { shouldAccept(it, atCommand) }
        }
        try {
            connection.writeCommand(
                atCommand,
                withoutResponse = withoutResponse,
                interChunkDelayMs = interChunkDelayMs,
            )
            withTimeoutResult(timeoutMs) { replyDeferred.await() }
        } catch (t: Throwable) {
            replyDeferred.cancel()
            throw t
        }
    }

    suspend fun writeCommandOnly(
        atCommand: String,
        withoutResponse: Boolean = false,
        interChunkDelayMs: Long = 16,
    ) {
        connection.writeCommand(atCommand, withoutResponse, interChunkDelayMs)
    }

    fun close() {
        scope.cancel()
    }

    private suspend fun ingestResponseChunk(data: ByteArray) {
        val chunk = data.toString(Charsets.UTF_8)
        for (json in jsonFramer.feed(chunk)) {
            jsonHub.emit(decodeJsonObject(json))
        }
    }

    private fun decodeJsonObject(json: String): JsonObject {
        return try {
            JSONObject(json)
        } catch (_: Throwable) {
            JSONObject().apply {
                put("ok", false)
                put("error", "JSON decode failed")
                put("raw", json)
            }
        }
    }

    private fun shouldAccept(msg: JsonObject, atCommand: String): Boolean {
        if (isSyntheticFramerFailure(msg)) return false
        val upper = atCommand.uppercase()
        if (!upper.startsWith("AT+CANCEL") && isCancelReply(msg)) return false
        if (isEventMessage(msg)) return false
        if (upper.startsWith("AT+CANCEL") && !isCancelReply(msg)) return false
        if (upper.startsWith("AT+START") && looksLikeGstatOkReply(msg)) return false
        if (upper.startsWith("AT+DOWNLOAD") && looksLikeGstatOkReply(msg)) return false
        if (upper.startsWith("AT+PAUSE") && looksLikeGstatOkReply(msg)) return false
        if (upper.startsWith("AT+RESUME") && looksLikeGstatOkReply(msg)) return false
        if (upper.startsWith("AT+GSTAT") && !looksLikeGstatOkReply(msg)) return false
        if (upper.startsWith("AT+STOP")) {
            if (!hasSession(msg) && !isStopFailureReply(msg)) return false
            if (msg.optBoolean("ok") && hasSession(msg) && !isStopAckShape(msg)) return false
        }
        return true
    }

    private fun isSyntheticFramerFailure(msg: JsonObject): Boolean {
        if (msg.optBoolean("ok")) return false
        return (msg.optStringOrNull("error") ?: "").contains("JSON decode failed")
    }

    private fun isEventMessage(msg: JsonObject): Boolean {
        return msg.optStringOrNull("event") != null || msg.optJSONObject("data")?.optStringOrNull("event") != null
    }

    private fun looksLikeGstatOkReply(msg: JsonObject): Boolean {
        if (isEventMessage(msg)) return false
        if (!msg.optBoolean("ok")) return false
        responseCmdTag(msg)?.let { if (it == "GSTAT") return true }
        val data = msg.optJSONObject("data") ?: return false
        val state = data.optStringOrNull("state")
        if (state.isNullOrEmpty()) return false
        if (data.has("battery") || data.has("free_space") || data.has("bitrate") || data.has("charging")) {
            return true
        }
        return data.has("recording") && (data.has("session") || data.has("duration"))
    }

    private fun hasSession(msg: JsonObject): Boolean {
        return !msg.optStringOrNull("session").isNullOrEmpty() ||
            !msg.optJSONObject("data")?.optStringOrNull("session").isNullOrEmpty()
    }

    private fun isStopFailureReply(msg: JsonObject): Boolean {
        return msg.has("ok") && !msg.optBoolean("ok")
    }

    private fun isStopAckShape(msg: JsonObject): Boolean {
        if (msg.has("ok") && !msg.optBoolean("ok")) return true
        val data = msg.optJSONObject("data") ?: return false
        if (data.has("frames") || data.has("file_count") || data.has("total_size")) return true
        responseCmdTag(msg)?.let { if (it == "STOP") return true }
        return !data.has("state") && hasSession(msg)
    }

    private fun isCancelReply(msg: JsonObject): Boolean {
        if (isEventMessage(msg)) return false
        val data = msg.optJSONObject("data")
        if (data?.has("canceled") == true) return true
        if (msg.has("ok") && !msg.optBoolean("ok")) {
            val detail = msg.optStringOrNull("msg")
                ?: msg.optStringOrNull("error")
                ?: msg.optStringOrNull("message")
                ?: data?.optStringOrNull("msg")
                ?: data?.optStringOrNull("error")
                ?: data?.optStringOrNull("message")
            return detail?.lowercase()?.contains("no active transfer") == true
        }
        return false
    }

    private fun responseCmdTag(msg: JsonObject): String? {
        msg.optStringOrNull("cmd")?.uppercase()?.let { return it }
        return msg.optJSONObject("data")?.optStringOrNull("cmd")?.uppercase()
    }
}
