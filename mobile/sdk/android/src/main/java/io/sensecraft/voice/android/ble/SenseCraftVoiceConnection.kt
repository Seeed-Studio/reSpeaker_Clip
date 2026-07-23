package io.sensecraft.voice.android

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

class SenseCraftVoiceConnection internal constructor(
    val device: BluetoothDevice,
    internal val gatt: BluetoothGatt,
    val commandRx: BluetoothGattCharacteristic,
    val responseTx: BluetoothGattCharacteristic,
    val fileData: BluetoothGattCharacteristic,
    val mtu: MtuManager,
    internal val batteryCharacteristic: BluetoothGattCharacteristic? = null,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val responseHub = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64)
    private val fileDataHub = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64)
    private val batteryHub = MutableSharedFlow<Int>(extraBufferCapacity = 16)
    internal var pendingWrite: CompletableDeferred<Unit>? = null
    internal val closed = AtomicBoolean(false)

    fun responseNotifyBytes(): Flow<ByteArray> = responseHub.asSharedFlow()
    fun fileDataNotifyBytes(): Flow<ByteArray> = fileDataHub.asSharedFlow()
    fun batteryLevelStream(): Flow<Int>? = batteryCharacteristic?.let { batteryHub.asSharedFlow() }

    internal fun publishResponse(bytes: ByteArray) {
        responseHub.tryEmit(bytes)
    }

    internal fun publishFileData(bytes: ByteArray) {
        fileDataHub.tryEmit(bytes)
    }

    internal fun publishBattery(level: Int) {
        batteryHub.tryEmit(level.coerceIn(0, 100))
    }

    internal fun onMtuChanged(mtuValue: Int) {
        mtu.onMtuChanged(mtuValue)
    }

    internal fun onWriteComplete(error: Throwable? = null) {
        val pending = pendingWrite ?: return
        pendingWrite = null
        if (error != null) {
            pending.completeExceptionally(error)
        } else {
            pending.complete(Unit)
        }
    }

    internal fun close() {
        if (!closed.compareAndSet(false, true)) return
        scope.cancel()
    }

    @SuppressLint("MissingPermission")
    suspend fun writeCommand(
        command: String,
        withoutResponse: Boolean = false,
        interChunkDelayMs: Long = 16,
    ) {
        val bytes = command.toByteArray(Charsets.UTF_8)
        val chunkSize = mtu.writePayloadSize(withResponse = !withoutResponse)
        val chunks = bytes.toList().chunked(chunkSize).map { chunk -> chunk.toByteArray() }
        for ((index, chunk) in chunks.withIndex()) {
            coroutineContext.ensureActive()
            writeChunk(chunk, withoutResponse)
            if (withoutResponse && index + 1 < chunks.size && interChunkDelayMs > 0) {
                delay(interChunkDelayMs)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private suspend fun writeChunk(bytes: ByteArray, withoutResponse: Boolean) {
        val type = if (withoutResponse) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        commandRx.writeType = type
        commandRx.value = bytes
        if (withoutResponse) {
            gatt.writeCharacteristic(commandRx)
            return
        }
        val pending = CompletableDeferred<Unit>()
        pendingWrite = pending
        if (!gatt.writeCharacteristic(commandRx)) {
            pendingWrite = null
            throw SenseCraftVoiceError.ConnectionFailed("writeCharacteristic returned false")
        }
        pending.await()
    }
}

private fun List<Byte>.toByteArray(): ByteArray = ByteArray(size) { index -> this[index] }
