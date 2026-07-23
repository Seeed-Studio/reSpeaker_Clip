package io.sensecraft.voice.android

import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.onEach
import org.json.JSONObject

enum class SdkLogLevel { DEBUG, INFO, WARNING, ERROR }

fun interface SdkLogHandler {
    fun log(level: SdkLogLevel, message: String, error: Throwable?, stackTrace: Throwable?)
}

object SdkLog {
    private val silent = SdkLogHandler { _, _, _, _ -> }
    @Volatile private var handler: SdkLogHandler = silent

    fun bind(handler: SdkLogHandler?) {
        this.handler = handler ?: silent
    }

    fun d(message: String, error: Throwable? = null) = handler.log(SdkLogLevel.DEBUG, message, error, error)
    fun i(message: String, error: Throwable? = null) = handler.log(SdkLogLevel.INFO, message, error, error)
    fun w(message: String, error: Throwable? = null) = handler.log(SdkLogLevel.WARNING, message, error, error)
    fun e(message: String, error: Throwable? = null) = handler.log(SdkLogLevel.ERROR, message, error, error)
}

sealed class SenseCraftVoiceError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class Timeout(message: String) : SenseCraftVoiceError(message)
    class Unsupported(message: String) : SenseCraftVoiceError(message)
    class BluetoothUnavailable(message: String) : SenseCraftVoiceError(message)
    class BluetoothUnauthorized : SenseCraftVoiceError("Bluetooth permission denied")
    class MissingCharacteristic(message: String) : SenseCraftVoiceError(message)
    class InvalidResponse(message: String) : SenseCraftVoiceError(message)
    class ConnectionFailed(message: String) : SenseCraftVoiceError(message)
    class Internal(message: String) : SenseCraftVoiceError(message)
}

suspend fun <T> withTimeoutResult(
    timeoutMs: Long,
    block: suspend () -> T
): T = kotlinx.coroutines.withTimeout(timeoutMs) { block() }

class SerialAsyncQueue {
    private val gate = Channel<Unit>(capacity = 1).apply { trySend(Unit) }

    suspend fun <T> run(block: suspend () -> T): T {
        gate.receive()
        try {
            return block()
        } finally {
            gate.trySend(Unit)
        }
    }
}

class BroadcastHub<T> {
    private val flow = MutableSharedFlow<T>(extraBufferCapacity = 128)
    fun stream(): Flow<T> = flow.asSharedFlow()
    suspend fun publish(value: T) { flow.emit(value) }
    fun tryPublish(value: T) { flow.tryEmit(value) }
}

fun crc32Ieee(bytes: ByteArray, seed: Long = 0): Long {
    var crc = seed.inv()
    for (b in bytes) {
        crc = _crc32Table[((crc xor (b.toLong() and 0xff)) and 0xff).toInt()] xor (crc ushr 8)
    }
    return crc.inv() and 0xffffffffL
}

private val _crc32Table: LongArray = LongArray(256) { i ->
    var c = i.toLong()
    repeat(8) {
        c = if ((c and 1L) != 0L) (0xedb88320L xor (c ushr 1)) else (c ushr 1)
    }
    c
}

internal fun JSONObject.optStringOrNull(name: String): String? {
    if (!has(name) || isNull(name)) return null
    val s = opt(name)?.toString()?.trim()
    return if (s.isNullOrEmpty()) null else s
}

internal fun JSONObject.optIntOrNull(name: String): Int? {
    if (!has(name) || isNull(name)) return null
    return when (val v = opt(name)) {
        is Int -> v
        is Long -> v.toInt()
        is Double -> v.toInt()
        is Number -> v.toInt()
        is String -> v.trim().toIntOrNull()
        else -> v?.toString()?.trim()?.toIntOrNull()
    }
}

internal fun JSONObject.optBoolOrNull(name: String): Boolean? {
    if (!has(name) || isNull(name)) return null
    return when (val v = opt(name)) {
        is Boolean -> v
        is Number -> v.toInt() != 0
        is String -> when (v.trim().lowercase()) {
            "true", "1", "yes" -> true
            "false", "0", "no" -> false
            else -> null
        }
        else -> v?.toString()?.trim()?.lowercase()?.let {
            when (it) {
                "true", "1", "yes" -> true
                "false", "0", "no" -> false
                else -> null
            }
        }
    }
}

