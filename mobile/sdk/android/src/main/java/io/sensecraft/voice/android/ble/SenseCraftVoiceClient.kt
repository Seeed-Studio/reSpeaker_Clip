package io.sensecraft.voice.android

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SenseCraftVoiceScanResult(
    val device: BluetoothDevice,
    val name: String,
    val rssi: Int,
    val advertisementData: Map<String, Any?>,
    val isConnectable: Boolean,
) {
    val id: String get() = device.address
}

enum class BluetoothAdapterState {
    UNKNOWN, OFF, TURNING_ON, ON, TURNING_OFF, UNAUTHORIZED, UNSUPPORTED
}

class SenseCraftVoiceClient(private val context: Context) : BluetoothGattCallback() {
    private val appContext = context.applicationContext
    private val bluetoothManager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = bluetoothManager?.adapter
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _scanResults = MutableStateFlow<List<SenseCraftVoiceScanResult>>(emptyList())
    val scanResults: StateFlow<List<SenseCraftVoiceScanResult>> = _scanResults.asStateFlow()
    private val _isScanning = MutableStateFlow(false)
    val isScanning: StateFlow<Boolean> = _isScanning.asStateFlow()
    private val _adapterState = MutableStateFlow(currentAdapterState())
    val adapterState: StateFlow<BluetoothAdapterState> = _adapterState.asStateFlow()

    private val sessions = ConcurrentHashMap<String, PeripheralSession>()
    private val scanCache = ConcurrentHashMap<String, SenseCraftVoiceScanResult>()
    private var scanJob: Job? = null
    private var scanCallback: ScanCallback? = null

    private data class PeripheralSession(
        val device: BluetoothDevice,
        var gatt: BluetoothGatt? = null,
        var connection: SenseCraftVoiceConnection? = null,
        var connectDeferred: CompletableDeferred<SenseCraftVoiceConnection>? = null,
        var disconnectDeferred: CompletableDeferred<Unit>? = null,
        var commandCharacteristic: BluetoothGattCharacteristic? = null,
        var responseCharacteristic: BluetoothGattCharacteristic? = null,
        var fileDataCharacteristic: BluetoothGattCharacteristic? = null,
        var batteryCharacteristic: BluetoothGattCharacteristic? = null,
        var responseNotified: Boolean = false,
        var fileDataNotified: Boolean = false,
        var batteryNotified: Boolean = false,
        var servicesDiscoveryStarted: Boolean = false,
        val notifiedCharacteristics: MutableSet<UUID> = linkedSetOf(),
        val notificationQueue: ArrayDeque<NotificationRequest> = ArrayDeque(),
    )

    private data class NotificationRequest(
        val characteristic: BluetoothGattCharacteristic,
        val required: Boolean,
    )

    fun currentAdapterState(): BluetoothAdapterState {
        val a = adapter ?: return BluetoothAdapterState.UNSUPPORTED
        return when (a.state) {
            BluetoothAdapter.STATE_OFF -> BluetoothAdapterState.OFF
            BluetoothAdapter.STATE_TURNING_ON -> BluetoothAdapterState.TURNING_ON
            BluetoothAdapter.STATE_ON -> BluetoothAdapterState.ON
            BluetoothAdapter.STATE_TURNING_OFF -> BluetoothAdapterState.TURNING_OFF
            else -> BluetoothAdapterState.UNKNOWN
        }
    }

    fun getCurrentAdapterState(): BluetoothAdapterState = currentAdapterState()

    fun createEnableBluetoothIntent(): Intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)

    fun turnOnAdapter(): Intent = createEnableBluetoothIntent()

    /**
     * Scans for Clip devices. The default name-based mode accepts devices whose
     * advertised name contains "Clip", because some firmware does not advertise
     * the custom service UUID.
     */
    @SuppressLint("MissingPermission")
    suspend fun startScan(timeoutMs: Long = 12_000, filterByService: Boolean = false) {
        val a = adapter ?: throw SenseCraftVoiceError.BluetoothUnavailable("Bluetooth adapter unavailable")
        if (a.state != BluetoothAdapter.STATE_ON) throw bluetoothStateError()
        if (!SenseCraftVoicePermissions.hasPermissions(appContext, includeWifi = false)) {
            throw SenseCraftVoiceError.BluetoothUnauthorized()
        }
        stopScan()
        val scanner = a.bluetoothLeScanner ?: throw SenseCraftVoiceError.BluetoothUnavailable("BLE scanner unavailable")
        _isScanning.value = true
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val filters = if (filterByService) listOf(ScanFilter.Builder().setServiceUuid(android.os.ParcelUuid(SenseCraftVoiceBleUuids.clipAtService)).build()) else emptyList()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) =
                publishScanResult(result, filterByName = !filterByService)

            override fun onBatchScanResults(results: MutableList<ScanResult>) =
                results.forEach { publishScanResult(it, filterByName = !filterByService) }

            override fun onScanFailed(errorCode: Int) {
                SdkLog.w("BLE scan failed: $errorCode")
                _isScanning.value = false
            }
        }
        scanCallback = cb
        scanner.startScan(filters, settings, cb)
        scanJob = scope.launch {
            delay(timeoutMs)
            stopScan()
        }
    }

    @SuppressLint("MissingPermission")
    fun stopScan() {
        scanJob?.cancel()
        scanJob = null
        val a = adapter ?: return
        val scanner = a.bluetoothLeScanner ?: return
        scanCallback?.let { scanner.stopScan(it) }
        scanCallback = null
        _isScanning.value = false
    }

    @SuppressLint("MissingPermission")
    suspend fun connect(result: SenseCraftVoiceScanResult): SenseCraftVoiceConnection {
        return connect(result.device)
    }

    @SuppressLint("MissingPermission")
    suspend fun connectByAddress(address: String): SenseCraftVoiceConnection? {
        val a = adapter ?: return null
        val device = try { a.getRemoteDevice(address) } catch (_: IllegalArgumentException) { return null }
        return connect(device)
    }

    suspend fun connectByDeviceId(deviceId: String): SenseCraftVoiceConnection? {
        return connectByAddress(deviceId)
    }

    @SuppressLint("MissingPermission")
    suspend fun connect(device: BluetoothDevice): SenseCraftVoiceConnection {
        if (adapter?.state != BluetoothAdapter.STATE_ON) throw bluetoothStateError()
        val session = sessions.getOrPut(device.address) { PeripheralSession(device) }
        session.connection?.takeIf { !it.closed.get() }?.let { return it }
        val deferred = CompletableDeferred<SenseCraftVoiceConnection>()
        session.connectDeferred = deferred
        session.disconnectDeferred = null
        session.responseNotified = false
        session.fileDataNotified = false
        session.batteryNotified = false
        session.servicesDiscoveryStarted = false
        session.notificationQueue.clear()
        val existingGatt = session.gatt
        val gatt = existingGatt ?: connectGatt(device).also { session.gatt = it }
        if (existingGatt != null) {
            requestMtuThenDiscoverServices(gatt, session)
        }
        return withTimeoutResult(15_000) { deferred.await() }
    }

    @SuppressLint("MissingPermission")
    suspend fun disconnect(connection: SenseCraftVoiceConnection) {
        val session = sessions[connection.device.address] ?: return
        val gatt = session.gatt ?: return
        val deferred = CompletableDeferred<Unit>()
        session.disconnectDeferred = deferred
        gatt.disconnect()
        withTimeoutResult(8_000) { deferred.await() }
        gatt.close()
        session.connection?.close()
        sessions.remove(connection.device.address)
    }

    fun close() {
        stopScan()
        sessions.values.forEach { it.connection?.close() }
        sessions.clear()
        scope.cancel()
    }

    @SuppressLint("MissingPermission")
    private fun connectGatt(device: BluetoothDevice): BluetoothGatt {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(appContext, false, this, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(appContext, false, this)
        }
    }

    private fun publishScanResult(result: ScanResult, filterByName: Boolean) {
        val name = result.device.name
            ?: result.scanRecord?.deviceName
            ?: "Unknown"
        if (filterByName && !name.contains("Clip", ignoreCase = true)) return
        scanCache[result.device.address] = SenseCraftVoiceScanResult(
            device = result.device,
            name = name,
            rssi = result.rssi,
            advertisementData = emptyMap(),
            isConnectable = true,
        )
        _scanResults.value = scanCache.values.sortedByDescending { it.rssi }
    }

    override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
        val session = sessions[gatt.device.address] ?: return
        when {
            status != BluetoothGatt.GATT_SUCCESS -> failSession(gatt, session, SenseCraftVoiceError.ConnectionFailed("status=$status"))
            newState == BluetoothProfile.STATE_CONNECTED -> {
                session.gatt = gatt
                requestMtuThenDiscoverServices(gatt, session)
            }
            newState == BluetoothProfile.STATE_DISCONNECTED -> {
                session.connection?.close()
                if (session.connectDeferred?.isCompleted != true) {
                    session.connectDeferred?.completeExceptionally(SenseCraftVoiceError.ConnectionFailed("disconnected"))
                } else {
                    session.disconnectDeferred?.complete(Unit)
                }
                session.disconnectDeferred = null
                session.connectDeferred = null
                sessions.remove(gatt.device.address)
            }
        }
    }

    override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
        val session = sessions[gatt.device.address] ?: return
        session.connection?.onMtuChanged(mtu)
        discoverServices(gatt, session)
    }

    private fun requestMtuThenDiscoverServices(gatt: BluetoothGatt, session: PeripheralSession) {
        // Android permits only one asynchronous GATT operation at a time.
        // Start service discovery from onMtuChanged instead of racing it with requestMtu.
        if (!gatt.requestMtu(247)) {
            discoverServices(gatt, session)
        }
    }

    private fun discoverServices(gatt: BluetoothGatt, session: PeripheralSession) {
        if (session.servicesDiscoveryStarted) return
        session.servicesDiscoveryStarted = true
        if (!gatt.discoverServices()) {
            failSession(
                gatt,
                session,
                SenseCraftVoiceError.ConnectionFailed("discoverServices returned false"),
            )
        }
    }

    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
        val session = sessions[gatt.device.address] ?: return
        if (status != BluetoothGatt.GATT_SUCCESS) {
            failSession(gatt, session, SenseCraftVoiceError.ConnectionFailed("services status=$status"))
            return
        }
        val service = gatt.getService(SenseCraftVoiceBleUuids.clipAtService)
            ?: run {
                failSession(gatt, session, SenseCraftVoiceError.MissingCharacteristic("Clip AT service missing"))
                return
            }
        session.commandCharacteristic = service.getCharacteristic(SenseCraftVoiceBleUuids.commandRxCharacteristic)
        session.responseCharacteristic = service.getCharacteristic(SenseCraftVoiceBleUuids.responseTxCharacteristic)
        session.fileDataCharacteristic = service.getCharacteristic(SenseCraftVoiceBleUuids.fileDataCharacteristic)
        session.batteryCharacteristic = gatt.getService(SenseCraftVoiceBleUuids.batteryService)
            ?.getCharacteristic(SenseCraftVoiceBleUuids.batteryLevelCharacteristic)

        val command = session.commandCharacteristic
        val response = session.responseCharacteristic
        val fileData = session.fileDataCharacteristic
        if (command == null || response == null || fileData == null) {
            failSession(gatt, session, SenseCraftVoiceError.MissingCharacteristic("missing command/response/fileData characteristic"))
            return
        }

        val connection = session.connection ?: SenseCraftVoiceConnection(
            device = gatt.device,
            gatt = gatt,
            commandRx = command,
            responseTx = response,
            fileData = fileData,
            mtu = MtuManager(gatt),
            batteryCharacteristic = session.batteryCharacteristic,
        ).also { session.connection = it }

        session.notificationQueue.clear()
        session.notificationQueue.add(NotificationRequest(response, required = true))
        session.notificationQueue.add(NotificationRequest(fileData, required = true))
        session.batteryCharacteristic?.let {
            session.notificationQueue.add(NotificationRequest(it, required = false))
        }
        writeNextNotification(gatt, session)
    }

    override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
        val session = sessions[gatt.device.address] ?: return
        val char = descriptor.characteristic ?: return
        val request = session.notificationQueue.pollFirst()
        if (status != BluetoothGatt.GATT_SUCCESS) {
            if (request?.required == true) {
                failSession(gatt, session, SenseCraftVoiceError.ConnectionFailed("notification descriptor status=$status"))
                return
            }
            SdkLog.w("BLE optional notification failed for ${char.uuid}: status=$status")
            writeNextNotification(gatt, session)
            completeConnectionIfReady(session)
            return
        }
        when (char.uuid) {
            SenseCraftVoiceBleUuids.responseTxCharacteristic -> session.responseNotified = true
            SenseCraftVoiceBleUuids.fileDataCharacteristic -> session.fileDataNotified = true
            SenseCraftVoiceBleUuids.batteryLevelCharacteristic -> session.batteryNotified = true
        }
        session.notifiedCharacteristics += char.uuid
        writeNextNotification(gatt, session)
        completeConnectionIfReady(session)
    }

    private fun completeConnectionIfReady(session: PeripheralSession) {
        val connection = session.connection ?: return
        if (session.responseNotified &&
            session.fileDataNotified &&
            session.notificationQueue.isEmpty() &&
            session.connectDeferred?.isCompleted != true
        ) {
            session.connectDeferred?.complete(connection)
        }
    }

    override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        onCharacteristicChangedInternal(gatt, characteristic, value)
    }

    @Deprecated("Deprecated in Android API 33")
    override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        onCharacteristicChangedInternal(gatt, characteristic, characteristic.value ?: return)
    }

    private fun onCharacteristicChangedInternal(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ) {
        val session = sessions[gatt.device.address] ?: return
        when (characteristic.uuid) {
            SenseCraftVoiceBleUuids.responseTxCharacteristic -> session.connection?.publishResponse(value)
            SenseCraftVoiceBleUuids.fileDataCharacteristic -> session.connection?.publishFileData(value)
            SenseCraftVoiceBleUuids.batteryLevelCharacteristic -> session.connection?.publishBattery(value.firstOrNull()?.toInt()?.and(0xff) ?: 0)
        }
    }

    override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
        val session = sessions[gatt.device.address] ?: return
        if (status == BluetoothGatt.GATT_SUCCESS) {
            session.connection?.onWriteComplete()
        } else {
            session.connection?.onWriteComplete(SenseCraftVoiceError.ConnectionFailed("write status=$status"))
        }
    }

    private fun writeNextNotification(gatt: BluetoothGatt, session: PeripheralSession) {
        val request = session.notificationQueue.peekFirst() ?: return
        val characteristic = request.characteristic
        if (!gatt.setCharacteristicNotification(characteristic, true) && request.required) {
            failSession(gatt, session, SenseCraftVoiceError.ConnectionFailed("setCharacteristicNotification failed for ${characteristic.uuid}"))
            return
        }
        val descriptor = characteristic.getDescriptor(SenseCraftVoiceBleUuids.cccd)
        if (descriptor == null) {
            session.notificationQueue.pollFirst()
            if (request.required) {
                failSession(gatt, session, SenseCraftVoiceError.MissingCharacteristic("CCCD missing for ${characteristic.uuid}"))
                return
            }
            SdkLog.w("BLE optional CCCD missing for ${characteristic.uuid}")
            writeNextNotification(gatt, session)
            return
        }
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        if (!gatt.writeDescriptor(descriptor)) {
            session.notificationQueue.pollFirst()
            if (request.required) {
                failSession(gatt, session, SenseCraftVoiceError.ConnectionFailed("writeDescriptor returned false for ${characteristic.uuid}"))
                return
            }
            SdkLog.w("BLE optional writeDescriptor returned false for ${characteristic.uuid}")
            writeNextNotification(gatt, session)
        }
    }

    private fun failSession(gatt: BluetoothGatt, session: PeripheralSession, error: Throwable) {
        session.connectDeferred?.completeExceptionally(error)
        session.connectDeferred = null
        session.disconnectDeferred?.completeExceptionally(error)
        session.disconnectDeferred = null
        session.connection?.close()
        runCatching { gatt.close() }
        sessions.remove(gatt.device.address)
    }

    private fun bluetoothStateError(): SenseCraftVoiceError {
        val a = adapter
        return when {
            a == null -> SenseCraftVoiceError.BluetoothUnavailable("Bluetooth adapter unavailable")
            !a.isEnabled -> SenseCraftVoiceError.BluetoothUnavailable("Bluetooth is off")
            else -> SenseCraftVoiceError.BluetoothUnavailable("Bluetooth unavailable")
        }
    }
}
