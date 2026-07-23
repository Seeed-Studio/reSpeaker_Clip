package io.sensecraft.voice.android

import android.bluetooth.BluetoothDevice
import android.content.Context
import io.runtime.mcumgr.ble.McuMgrBleTransport
import io.runtime.mcumgr.dfu.FirmwareUpgradeCallback
import io.runtime.mcumgr.dfu.FirmwareUpgradeController
import io.runtime.mcumgr.dfu.mcuboot.FirmwareUpgradeManager
import io.runtime.mcumgr.dfu.mcuboot.model.ImageSet
import io.runtime.mcumgr.dfu.mcuboot.model.TargetImage
import io.runtime.mcumgr.exception.McuMgrException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class NordicMcuMgrOtaTransport(
    context: Context,
    private val device: BluetoothDevice,
    private val mode: FirmwareUpgradeManager.Mode = FirmwareUpgradeManager.Mode.CONFIRM_ONLY,
    private val eraseAppSettings: Boolean = true,
    private val estimatedSwapTimeSeconds: Int = 0,
    private val windowCapacity: Int = 1,
    private val memoryAlignment: Int = 4,
) : OtaUpgradeTransport {
    private val appContext = context.applicationContext
    private val callbackScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var transport: McuMgrBleTransport? = null
    private var manager: FirmwareUpgradeManager? = null

    override suspend fun upgrade(
        deviceId: String,
        images: List<OtaImage>,
        progress: suspend (OtaProgress) -> Unit,
    ) {
        val totalBytes = images.sumOf { it.data.size }
        val imageSet = ImageSet()
        for (image in images) {
            imageSet.add(TargetImage(image.imageIndex, TargetImage.SLOT_SECONDARY, image.data))
        }

        suspendCancellableCoroutine<Unit> { continuation ->
            val bleTransport = McuMgrBleTransport(appContext, device)
            transport = bleTransport
            val upgradeManager = FirmwareUpgradeManager(
                bleTransport,
                object : FirmwareUpgradeCallback<FirmwareUpgradeManager.State> {
                    override fun onUpgradeStarted(controller: FirmwareUpgradeController) {
                        emit(progress, OtaPhase.PREPARING, 0.0, 0, totalBytes, "Reading bootloader info...")
                    }

                    override fun onStateChanged(
                        previousState: FirmwareUpgradeManager.State,
                        newState: FirmwareUpgradeManager.State,
                    ) {
                        emit(
                            progress,
                            mapState(newState),
                            if (newState == FirmwareUpgradeManager.State.UPLOAD) 0.0 else 1.0,
                            if (newState == FirmwareUpgradeManager.State.UPLOAD) 0 else totalBytes,
                            totalBytes,
                            stateText(newState),
                        )
                    }

                    override fun onUpgradeCompleted() {
                        emit(progress, OtaPhase.SUCCESS, 1.0, totalBytes, totalBytes, "Upgrade complete")
                        cleanup()
                        if (continuation.isActive) continuation.resume(Unit)
                    }

                    override fun onUpgradeFailed(
                        state: FirmwareUpgradeManager.State,
                        error: McuMgrException,
                    ) {
                        cleanup()
                        if (continuation.isActive) continuation.resumeWithException(error)
                    }

                    override fun onUpgradeCanceled(state: FirmwareUpgradeManager.State) {
                        emit(progress, OtaPhase.CANCELLED, 0.0, 0, totalBytes, "Cancelled")
                        cleanup()
                        if (continuation.isActive) {
                            continuation.resumeWithException(SenseCraftVoiceError.Internal("OTA cancelled"))
                        }
                    }

                    override fun onUploadProgressChanged(bytesSent: Int, imageSize: Int, timestamp: Long) {
                        val ratio = if (imageSize > 0) bytesSent.toDouble() / imageSize.toDouble() else 0.0
                        emit(
                            progress,
                            OtaPhase.UPLOADING,
                            ratio.coerceIn(0.0, 1.0),
                            bytesSent,
                            imageSize.takeIf { it > 0 } ?: totalBytes,
                            "Uploading firmware...",
                        )
                    }
                },
            )
            manager = upgradeManager
            upgradeManager.setCallbackOnUiThread(false)
            upgradeManager.setMode(mode)

            continuation.invokeOnCancellation {
                runCatching { upgradeManager.cancel() }
                cleanup()
            }

            try {
                val settings = FirmwareUpgradeManager.Settings.Builder()
                    .setEraseAppSettings(eraseAppSettings)
                    .setEstimatedSwapTime(estimatedSwapTimeSeconds)
                    .setWindowCapacity(windowCapacity)
                    .setMemoryAlignment(memoryAlignment)
                    .build()
                upgradeManager.start(imageSet, settings)
            } catch (t: Throwable) {
                cleanup()
                if (continuation.isActive) continuation.resumeWithException(t)
            }
        }
    }

    override suspend fun cancel() {
        manager?.cancel()
        cleanup()
    }

    private fun emit(
        progress: suspend (OtaProgress) -> Unit,
        phase: OtaPhase,
        ratio: Double,
        bytesSent: Int,
        totalBytes: Int,
        message: String,
    ) {
        callbackScope.launch {
            progress(OtaProgress(phase, ratio, bytesSent, totalBytes, message))
        }
    }

    private fun cleanup() {
        manager = null
        transport?.release()
        transport = null
    }

    private fun mapState(state: FirmwareUpgradeManager.State): OtaPhase = when (state) {
        FirmwareUpgradeManager.State.VALIDATE -> OtaPhase.VALIDATING
        FirmwareUpgradeManager.State.UPLOAD -> OtaPhase.UPLOADING
        FirmwareUpgradeManager.State.TEST,
        FirmwareUpgradeManager.State.CONFIRM -> OtaPhase.VALIDATING
        FirmwareUpgradeManager.State.RESET -> OtaPhase.RESETTING
        FirmwareUpgradeManager.State.NONE -> OtaPhase.PREPARING
    }

    private fun stateText(state: FirmwareUpgradeManager.State): String = when (state) {
        FirmwareUpgradeManager.State.VALIDATE -> "Validating..."
        FirmwareUpgradeManager.State.UPLOAD -> "Uploading firmware..."
        FirmwareUpgradeManager.State.TEST -> "Testing..."
        FirmwareUpgradeManager.State.RESET -> "Resetting device..."
        FirmwareUpgradeManager.State.CONFIRM -> "Confirming..."
        FirmwareUpgradeManager.State.NONE -> "Preparing..."
    }
}
