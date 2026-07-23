@file:Suppress("DEPRECATION")

package io.sensecraft.voice.android

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.URL
import java.nio.charset.Charset
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.zip.ZipInputStream

data class OtaImage(
    val imageIndex: Int,
    val data: ByteArray,
    val fileName: String? = null,
)

class OtaFirmwareException(message: String) : Exception(message)

object OtaFirmwareProcessor {
    fun processFile(file: File): List<OtaImage> {
        val name = file.name.lowercase()
        val bytes = file.readBytes()
        return when {
            name.endsWith(".zip") -> processZip(bytes)
            name.endsWith(".bin") -> processBin(bytes)
            else -> throw OtaFirmwareException("Unsupported firmware format - expected .zip or .bin")
        }
    }

    fun processBin(data: ByteArray): List<OtaImage> {
        if (data.isEmpty()) throw OtaFirmwareException("Firmware BIN is empty")
        return listOf(OtaImage(imageIndex = 0, data = data))
    }

    fun processZip(data: ByteArray): List<OtaImage> {
        val entries = unzipEntries(data)
        val manifestBytes = entries["manifest.json"]
            ?: throw OtaFirmwareException("Firmware ZIP is missing manifest.json")
        val manifest = JSONObject(manifestBytes.toString(Charsets.UTF_8))
        val files = manifest.optJSONArray("files")
        if (files == null || files.length() == 0) {
            throw OtaFirmwareException("manifest.json contains no \"files\" entries")
        }

        val images = ArrayList<OtaImage>(files.length())
        for (i in 0 until files.length()) {
            val entry = files.optJSONObject(i)
                ?: throw OtaFirmwareException("manifest.json contains an invalid files[] entry")
            val fileName = entry.optStringOrNull("file").orEmpty()
            val imageData = entries[fileName]
                ?: throw OtaFirmwareException("Manifest references a missing binary: $fileName")
            validateManifestFileEntry(fileName, imageData, entry)
            images += OtaImage(
                imageIndex = entry.optIntOrNull("image_index") ?: 0,
                data = imageData,
                fileName = fileName,
            )
        }
        return images
    }

    fun validateManifestFileEntry(
        fileName: String,
        data: ByteArray,
        entry: JsonObject,
    ) {
        if (fileName.isBlank()) {
            throw OtaFirmwareException("manifest.json entry is missing \"file\" name")
        }
        val expectedSize = entry.optIntOrNull("size")
        if (expectedSize != null && expectedSize >= 0 && data.size != expectedSize) {
            throw OtaFirmwareException(
                "Firmware binary size mismatch for $fileName: expected $expectedSize bytes, got ${data.size}"
            )
        }
        val expectedSha256 = readDigest(entry, listOf("sha256", "hash"))
        if (expectedSha256 != null && digestHex("SHA-256", data) != expectedSha256) {
            throw OtaFirmwareException("Firmware binary SHA-256 mismatch for $fileName")
        }
        val expectedMd5 = readDigest(entry, listOf("md5"))
        if (expectedMd5 != null && digestHex("MD5", data) != expectedMd5) {
            throw OtaFirmwareException("Firmware binary MD5 mismatch for $fileName")
        }
    }

    private fun unzipEntries(data: ByteArray): Map<String, ByteArray> {
        val out = LinkedHashMap<String, ByteArray>()
        ZipInputStream(data.inputStream()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (!entry.isDirectory) {
                    out[entry.name] = zip.readBytes()
                }
                zip.closeEntry()
            }
        }
        return out
    }

    private fun readDigest(entry: JsonObject, keys: List<String>): String? {
        for (key in keys) {
            val value = entry.optStringOrNull(key)?.lowercase()
            if (!value.isNullOrBlank()) return value
        }
        return null
    }

    private fun digestHex(algorithm: String, data: ByteArray): String {
        val digest = MessageDigest.getInstance(algorithm).digest(data)
        return digest.joinToString("") { "%02x".format(it) }
    }
}

enum class OtaPhase {
    IDLE,
    PREPARING,
    UPLOADING,
    VALIDATING,
    RESETTING,
    SUCCESS,
    FAILED,
    CANCELLED,
}

data class OtaProgress(
    val phase: OtaPhase,
    val progress: Double,
    val bytesSent: Int,
    val totalBytes: Int,
    val message: String,
)

interface OtaUpgradeTransport {
    suspend fun upgrade(
        deviceId: String,
        images: List<OtaImage>,
        progress: suspend (OtaProgress) -> Unit,
    )

    suspend fun cancel()
}

class OtaSession(
    val deviceId: String,
    private val transport: OtaUpgradeTransport? = null,
) {
    private val progressEvents = MutableSharedFlow<OtaProgress>(extraBufferCapacity = 32)
    val events: Flow<OtaProgress> = progressEvents.asSharedFlow()

    var phase: OtaPhase = OtaPhase.IDLE
        private set
    var lastError: Throwable? = null
        private set

    suspend fun upgrade(file: File): Boolean {
        emit(OtaPhase.PREPARING, 0.0, 0, 0, "Parsing firmware...")
        val images = try {
            OtaFirmwareProcessor.processFile(file)
        } catch (t: Throwable) {
            fail(t, "Firmware parsing failed: $t")
            return false
        }
        return upgradeImages(images)
    }

    suspend fun upgrade(url: URL): Boolean = upgrade(File(url.toURI()))

    suspend fun upgradeImages(images: List<OtaImage>): Boolean {
        val totalBytes = images.sumOf { it.data.size }
        if (totalBytes <= 0) {
            fail(OtaFirmwareException("No firmware bytes to flash"), "No firmware bytes to flash")
            return false
        }
        val activeTransport = transport
        if (activeTransport == null) {
            fail(
                SenseCraftVoiceError.Unsupported("OTA SMP/mcumgr transfer is not linked in this native SDK yet"),
                "OTA transfer requires native mcumgr integration",
            )
            return false
        }
        return try {
            emit(OtaPhase.UPLOADING, 0.0, 0, totalBytes, "Uploading firmware...")
            activeTransport.upgrade(deviceId, images) { event ->
                emit(
                    event.phase,
                    event.progress,
                    event.bytesSent,
                    event.totalBytes.takeIf { it > 0 } ?: totalBytes,
                    event.message,
                )
            }
            emit(OtaPhase.SUCCESS, 1.0, totalBytes, totalBytes, "Upgrade complete")
            true
        } catch (t: Throwable) {
            fail(t, "Upgrade failed: $t")
            false
        }
    }

    suspend fun cancel() {
        transport?.cancel()
        emit(OtaPhase.CANCELLED, 0.0, 0, 0, "Cancelled")
    }

    private suspend fun emit(
        phase: OtaPhase,
        progress: Double,
        bytesSent: Int,
        totalBytes: Int,
        message: String,
    ) {
        this.phase = phase
        progressEvents.emit(OtaProgress(phase, progress, bytesSent, totalBytes, message))
    }

    private suspend fun fail(error: Throwable, message: String) {
        lastError = error
        emit(OtaPhase.FAILED, -1.0, 0, 0, message)
        SdkLog.w("OtaSession failed", error)
    }
}

data class WifiBatchItem(
    val recordingId: String,
    val sessionId: String,
    val sessionDirectory: File,
    val expectedBytes: Int? = null,
    val startFile: String? = null,
    val resumeByteOffset: Int = 0,
)

typealias WifiBatchResolveStartFile = suspend (recordingId: String, sessionId: String) -> String?

enum class WifiBleFallbackReason {
    PHONE_WIFI_DISCONNECTED,
    PHONE_ON_OTHER_WIFI,
    TRANSFER_FAILED,
}

enum class WifiVerifyFailureKind {
    NETWORK_UNREACHABLE,
    TIMED_OUT,
}

class WifiVerifyFailure(
    val kind: WifiVerifyFailureKind,
    val hotspot: WifiHotspotInfo,
) : Exception("Wi-Fi setup: ${kind.name.lowercase()}")

data class WifiFastSyncBatchResult(
    val succeeded: Int = 0,
    val failed: Int = 0,
    val userCancelled: Boolean = false,
    val abortedForRecording: Boolean = false,
    val bleFallbackReason: WifiBleFallbackReason? = null,
    val fallbackHotspot: WifiHotspotInfo? = null,
) {
    val shouldFallBackToBle: Boolean
        get() = bleFallbackReason != null
    val isOverallSuccess: Boolean
        get() = succeeded > 0 && failed == 0 && !userCancelled
}

class WifiFastSyncSession(
    val at: AtTransport,
    context: Context? = null,
) {
    companion object {
        const val FORCE_WIFI_KEEP_ALIVE_INTERVAL_MS: Long = 10_000
    }

    private val appContext = context?.applicationContext
    private var connector: WifiHotspotConnector? = null
    private var client: WifiTransferClient? = null
    private var forceWifiScope: CoroutineScope? = null
    private var forceWifiKeepAliveJob: Job? = null
    var hotspot: WifiHotspotInfo? = null
        private set

    val transferClient: WifiTransferClient?
        get() = client

    val hotspotConnector: WifiHotspotConnector?
        get() = connector

    val isPrepared: Boolean
        get() = hotspot != null && client != null

    val isForceWifiKeepAliveActive: Boolean
        get() = forceWifiKeepAliveJob?.isActive == true

    suspend fun enableHotspot(): WifiHotspotInfo {
        val activeConnector = connector ?: WifiHotspotConnector(at, appContext).also { connector = it }
        SdkLog.i("[WiFi] WifiFastSyncSession: enable AP")
        val info = activeConnector.enable()
        hotspot = info
        client = WifiTransferClient(info)
        return info
    }

    suspend fun prepare(
        joinPhone: Boolean = true,
        requirePhoneJoin: Boolean = false,
    ): WifiHotspotInfo {
        val info = enableHotspot()
        if (joinPhone) {
            val joined = connectPhone()
            if (!joined) {
                val message = "Phone failed to join device AP ${info.ssid}"
                if (requirePhoneJoin) {
                    throw SenseCraftVoiceError.ConnectionFailed(message)
                }
                SdkLog.w("[WiFi] $message; UDP may still work if the phone is already on the AP")
            }
        }
        startForceWifiKeepAlive()
        return info
    }

    suspend fun connectPhone(): Boolean {
        val info = hotspot ?: throw IllegalStateException("Call enableHotspot() before connectPhone()")
        val activeConnector = connector ?: throw IllegalStateException("Wi-Fi hotspot connector is unavailable")
        val joined = activeConnector.connectToHotspot(info)
        if (joined) startForceWifiKeepAlive()
        return joined
    }

    fun forceWifiUsage(force: Boolean): Boolean = connector?.forceWifiUsage(force) == true

    private fun startForceWifiKeepAlive() {
        stopForceWifiKeepAlive()
        forceWifiUsage(true)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        forceWifiScope = scope
        forceWifiKeepAliveJob = scope.launch {
            while (isActive) {
                delay(FORCE_WIFI_KEEP_ALIVE_INTERVAL_MS)
                forceWifiUsage(true)
            }
        }
    }

    private fun stopForceWifiKeepAlive() {
        forceWifiKeepAliveJob?.cancel()
        forceWifiKeepAliveJob = null
        forceWifiScope?.cancel()
        forceWifiScope = null
    }

    suspend fun teardown(disconnectPhone: Boolean = true, disableHotspot: Boolean = true) {
        stopForceWifiKeepAlive()
        forceWifiUsage(false)
        val info = hotspot
        client?.dispose()
        client = null
        if (info != null) {
            if (disconnectPhone) {
                runCatching { connector?.disconnectFromHotspot(info) }
                    .onFailure { SdkLog.w("[WiFi] Failed to disconnect phone during teardown", it) }
            } else {
                connector?.releaseNetworkBinding()
            }
        }
        if (disableHotspot) {
            runCatching { connector?.disable() }
                .onFailure { SdkLog.w("[WiFi] Failed to disable hotspot during teardown", it) }
        }
        connector = null
        hotspot = null
    }

    suspend fun downloadBatch(
        items: List<WifiBatchItem>,
        resolveStartFile: WifiBatchResolveStartFile? = null,
        shouldCancel: (() -> Boolean)? = null,
        joinPhone: Boolean = true,
        requirePhoneJoin: Boolean = false,
        disconnectPhoneAfter: Boolean = true,
        disableHotspotAfter: Boolean = true,
    ): WifiFastSyncBatchResult {
        if (items.isEmpty()) return WifiFastSyncBatchResult()

        var succeeded = 0
        var failed = 0
        var userCancelled = false
        var abortedForRecording = false
        var fallbackReason: WifiBleFallbackReason? = null
        var batchHotspot: WifiHotspotInfo? = null
        try {
            batchHotspot = enableHotspot()
            var joinOk = true
            if (joinPhone) {
                joinOk = connectPhone()
                if (!joinOk && requirePhoneJoin) {
                    throw SenseCraftVoiceError.ConnectionFailed(
                        "Phone failed to join device AP ${batchHotspot.ssid}"
                    )
                }
            }
            startForceWifiKeepAlive()
            val activeClient = client
                ?: throw SenseCraftVoiceError.ConnectionFailed("Wi-Fi transfer client was not created")

            val maxPingAttempts = if (joinOk) 10 else 20
            var pingOk = false
            var unreachable = false
            for (attempt in 0 until maxPingAttempts) {
                if (shouldCancel?.invoke() == true) {
                    userCancelled = true
                    break
                }
                if (attempt > 0) {
                    delay(2_000)
                    forceWifiUsage(true)
                }
                val ping = activeClient.pingDetailed()
                pingOk = ping.ok
                unreachable = ping.networkUnreachable
                if (pingOk || unreachable) break
            }
            if (!pingOk && !userCancelled) {
                throw WifiVerifyFailure(
                    if (unreachable) WifiVerifyFailureKind.NETWORK_UNREACHABLE
                    else WifiVerifyFailureKind.TIMED_OUT,
                    batchHotspot,
                )
            }

            for (item in items) {
                if (shouldCancel?.invoke() == true) {
                    userCancelled = true
                    break
                }
                if (deviceIsRecordingOrPaused()) {
                    abortedForRecording = true
                    break
                }
                val resolvedStartFile = item.startFile
                    ?: resolveStartFile?.invoke(item.recordingId, item.sessionId)
                try {
                    activeClient.downloadSession(
                        sessionId = item.sessionId,
                        sessionDirectory = item.sessionDirectory,
                        startFile = resolvedStartFile,
                        shouldCancel = shouldCancel,
                    )
                    if (shouldCancel?.invoke() == true) {
                        userCancelled = true
                        break
                    }
                    succeeded++
                } catch (error: Throwable) {
                    failed++
                    val probe = wifiReachabilityProbe()
                    if (!probe.ok) {
                        fallbackReason = if (probe.networkUnreachable) {
                            WifiBleFallbackReason.PHONE_WIFI_DISCONNECTED
                        } else {
                            WifiBleFallbackReason.PHONE_ON_OTHER_WIFI
                        }
                        break
                    }
                }
            }

            if (fallbackReason == null && succeeded == 0 && failed > 0 &&
                !userCancelled && !abortedForRecording
            ) {
                val probe = wifiReachabilityProbe()
                fallbackReason = when {
                    probe.ok -> WifiBleFallbackReason.TRANSFER_FAILED
                    probe.networkUnreachable -> WifiBleFallbackReason.PHONE_WIFI_DISCONNECTED
                    else -> WifiBleFallbackReason.PHONE_ON_OTHER_WIFI
                }
            }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (error is WifiVerifyFailure) {
                fallbackReason = if (error.kind == WifiVerifyFailureKind.NETWORK_UNREACHABLE) {
                    WifiBleFallbackReason.PHONE_WIFI_DISCONNECTED
                } else {
                    WifiBleFallbackReason.PHONE_ON_OTHER_WIFI
                }
            }
            if (succeeded == 0 && failed == 0) failed = 1
            SdkLog.w("[WiFi] Fast sync batch failed", error)
        } finally {
            teardown(
                disconnectPhone = disconnectPhoneAfter,
                disableHotspot = disableHotspotAfter,
            )
        }
        return WifiFastSyncBatchResult(
            succeeded = succeeded,
            failed = failed,
            userCancelled = userCancelled,
            abortedForRecording = abortedForRecording,
            bleFallbackReason = fallbackReason,
            fallbackHotspot = batchHotspot,
        )
    }

    private suspend fun wifiReachabilityProbe(): WifiPingResult {
        val activeClient = client ?: return WifiPingResult(ok = false, networkUnreachable = false)
        return try {
            val first = activeClient.pingDetailed()
            if (first.ok || first.networkUnreachable) return first
            forceWifiUsage(true)
            activeClient.pingDetailed()
        } catch (error: Throwable) {
            WifiPingResult(ok = false, networkUnreachable = isDeviceApNetworkUnreachable(error))
        }
    }

    private suspend fun deviceIsRecordingOrPaused(): Boolean {
        return try {
            val response = at.send("AT+GSTAT", 4_000)
            if (response.optBoolean("ok") != true) return false
            val status = DeviceStatus.fromAtReply(response)
            status.isRecording || status.state == "paused"
        } catch (_: Throwable) {
            false
        }
    }

    suspend fun downloadSession(
        sessionId: String,
        sessionDirectory: File,
        startFile: String? = null,
        shouldCancel: (() -> Boolean)? = null,
        joinPhone: Boolean = true,
        requirePhoneJoin: Boolean = false,
        disconnectPhoneAfter: Boolean = true,
        disableHotspotAfter: Boolean = true,
        onOverallProgress: ((Double?) -> Unit)? = null,
        onProgress: WifiTransferProgress? = null,
    ): Int {
        return try {
            prepare(joinPhone = joinPhone, requirePhoneJoin = requirePhoneJoin)
            val activeClient = client ?: throw SenseCraftVoiceError.ConnectionFailed("Wi-Fi transfer client was not created")
            SdkLog.i("[WiFi] WifiFastSyncSession: UDP download session=$sessionId")
            val bytes = activeClient.downloadSession(
                sessionId = sessionId,
                sessionDirectory = sessionDirectory,
                startFile = startFile,
                shouldCancel = shouldCancel,
                onOverallProgress = onOverallProgress,
                onProgress = onProgress,
            )
            SdkLog.i("[WiFi] WifiFastSyncSession: done bytes=$bytes")
            teardown(disconnectPhone = disconnectPhoneAfter, disableHotspot = disableHotspotAfter)
            bytes
        } catch (t: Throwable) {
            teardown(disconnectPhone = disconnectPhoneAfter, disableHotspot = disableHotspotAfter)
            throw t
        }
    }

    suspend fun run() {
        prepare(joinPhone = true)
    }
}

class WifiHotspotConnector(
    private val at: AtTransport,
    context: Context? = null,
) {
    private val appContext = context?.applicationContext
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var boundNetwork: Network? = null

    suspend fun queryStatus(timeoutMs: Long = 5_000): WifiHotspotInfo {
        val resp = at.send("AT+WIFI?", timeoutMs)
        ensureWifiSuccess(resp, "AT+WIFI?")
        return WifiHotspotInfo.fromAtReply(resp)
    }

    suspend fun enable(): WifiHotspotInfo {
        val prior = runCatching { queryStatus() }.getOrNull()
        if (prior != null && prior.enabled && prior.isValid) return prior

        var resp = sendWifiOnPair()
        if (resp.optBoolean("ok") != true) {
            val detail = wifiFailureDetail(resp)
            if (wifiOnFailureMayBeStaleState(detail)) {
                turnOffDeviceWifiAp()
                waitGstatLeavesWifiSync(22_000)
                resp = sendWifiOnPair()
            }
        }
        ensureWifiSuccess(resp, "AT+WIFI=ON")
        return hotspotInfoAfterOn(resp)
    }

    suspend fun disable() {
        var lastError: Throwable? = null
        for (command in listOf("AT+WIFI=OFF", "AT+WIFI=off")) {
            try {
                val resp = at.send(command, 8_000)
                if (resp.optBoolean("ok") == true) return
                lastError = SenseCraftVoiceError.InvalidResponse("$command failed: ${wifiFailureDetail(resp)}")
            } catch (t: Throwable) {
                lastError = t
            }
        }
        lastError?.let { throw it }
    }

    suspend fun connectToHotspot(info: WifiHotspotInfo, timeoutMs: Long = 25_000): Boolean {
        if (!info.isValid) {
            SdkLog.w("[WiFi] Cannot join invalid hotspot info")
            return false
        }
        val context = appContext
        if (context == null) {
            SdkLog.w("[WiFi] Android hotspot join requires Context; construct WifiHotspotConnector(at, context)")
            return false
        }
        delay(2_000)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            connectWithNetworkSpecifier(context, info, timeoutMs)
        } else {
            connectWithWifiConfiguration(context, info)
        }
    }

    suspend fun disconnectFromHotspot(info: WifiHotspotInfo) {
        val context = appContext ?: return
        releaseNetworkBinding()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            wifi?.configuredNetworks?.firstOrNull { it.SSID == quoteSsid(info.ssid) }?.let {
                @Suppress("DEPRECATION")
                runCatching { wifi.removeNetwork(it.networkId) }
            }
        }
    }

    /** Releases the process binding and NetworkCallback without removing legacy saved Wi-Fi config. */
    fun releaseNetworkBinding() {
        val context = appContext ?: return
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        networkCallback?.let { callback ->
            runCatching { cm?.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            runCatching { cm?.bindProcessToNetwork(null) }
        } else {
            @Suppress("DEPRECATION")
            ConnectivityManager.setProcessDefaultNetwork(null)
        }
        boundNetwork = null
    }

    fun forceWifiUsage(force: Boolean): Boolean {
        val context = appContext ?: return false
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        return if (force) {
            val network = boundNetwork ?: return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                cm.bindProcessToNetwork(network)
            } else {
                @Suppress("DEPRECATION")
                ConnectivityManager.setProcessDefaultNetwork(network)
            }
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                cm.bindProcessToNetwork(null)
            } else {
                @Suppress("DEPRECATION")
                ConnectivityManager.setProcessDefaultNetwork(null)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private suspend fun connectWithNetworkSpecifier(
        context: Context,
        info: WifiHotspotInfo,
        timeoutMs: Long,
    ): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        disconnectFromHotspot(info)
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(info.ssid)
            .setWpa2Passphrase(info.password)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val joined = CompletableDeferred<Boolean>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                boundNetwork = network
                val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    cm.bindProcessToNetwork(network)
                } else {
                    @Suppress("DEPRECATION")
                    ConnectivityManager.setProcessDefaultNetwork(network)
                }
                if (!joined.isCompleted) joined.complete(ok)
            }

            override fun onUnavailable() {
                if (!joined.isCompleted) joined.complete(false)
            }

            override fun onLost(network: Network) {
                if (boundNetwork == network) boundNetwork = null
            }
        }
        networkCallback = callback
        return try {
            cm.requestNetwork(request, callback)
            val ok = withTimeoutOrNull(timeoutMs) { joined.await() } == true
            SdkLog.i("[WiFi] Android WifiNetworkSpecifier joined=$ok ssid=${info.ssid}")
            ok
        } catch (t: Throwable) {
            SdkLog.w("[WiFi] Android hotspot join failed", t)
            false
        }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun connectWithWifiConfiguration(context: Context, info: WifiHotspotInfo): Boolean {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return false
        if (!wifi.isWifiEnabled) {
            wifi.isWifiEnabled = true
        }
        val config = WifiConfiguration().apply {
            SSID = quoteSsid(info.ssid)
            preSharedKey = quoteSsid(info.password)
            allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
        }
        val existing = wifi.configuredNetworks?.firstOrNull { it.SSID == config.SSID }
        val networkId = existing?.networkId ?: wifi.addNetwork(config)
        if (networkId == -1) return false
        wifi.disconnect()
        val enabled = wifi.enableNetwork(networkId, true)
        val reconnected = wifi.reconnect()
        SdkLog.i("[WiFi] Android WifiConfiguration enabled=$enabled reconnected=$reconnected ssid=${info.ssid}")
        return enabled && reconnected
    }

    private suspend fun sendWifiOnPair(): JsonObject {
        var firstError: Throwable? = null
        for (command in listOf("AT+WIFI=ON", "AT+WIFI=on")) {
            try {
                val resp = at.send(command, 12_000)
                if (resp.optBoolean("ok") == true) return resp
                firstError = SenseCraftVoiceError.InvalidResponse("$command failed: ${wifiFailureDetail(resp)}")
                if (command == "AT+WIFI=ON" && wifiOnFailureMayBeStaleState(wifiFailureDetail(resp))) {
                    return resp
                }
            } catch (t: Throwable) {
                firstError = t
            }
        }
        firstError?.let { throw it }
        throw SenseCraftVoiceError.InvalidResponse("AT+WIFI=ON failed")
    }

    private suspend fun hotspotInfoAfterOn(onResp: JsonObject): WifiHotspotInfo {
        val fromOn = WifiHotspotInfo.fromAtReply(onResp)
        delay(800)
        var lastError: Throwable? = null
        repeat(3) {
            try {
                val queried = queryStatus(12_000)
                if (queried.isValid) return queried
                if (fromOn.isValid) return fromOn
                lastError = SenseCraftVoiceError.InvalidResponse("AT+WIFI? missing hotspot credentials")
            } catch (t: Throwable) {
                lastError = t
            }
            delay(600)
        }
        if (fromOn.isValid) return fromOn
        lastError?.let { throw it }
        throw SenseCraftVoiceError.InvalidResponse("AT+WIFI? after ON failed")
    }

    private suspend fun turnOffDeviceWifiAp() {
        for (command in listOf("AT+WIFI=OFF", "AT+WIFI=off")) {
            runCatching { at.send(command, 8_000) }
        }
        delay(500)
    }

    private suspend fun waitGstatLeavesWifiSync(timeoutMs: Long) {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            try {
                val resp = at.send("AT+GSTAT", 4_000)
                val data = resp.optJSONObject("data") ?: JsonObject()
                val state = data.optStringOrNull("state")?.uppercase().orEmpty()
                if (resp.optBoolean("ok") == true && state != "WIFI_SYNC") return
            } catch (t: Throwable) {
                SdkLog.w("WifiHotspotConnector GSTAT poll failed", t)
            }
            delay(400)
        }
    }

    private fun ensureWifiSuccess(resp: JsonObject, command: String) {
        if (resp.optBoolean("ok") != true) {
            throw SenseCraftVoiceError.InvalidResponse("$command failed: ${wifiFailureDetail(resp)}")
        }
    }

    private fun wifiFailureDetail(resp: JsonObject): String {
        return resp.optStringOrNull("msg")
            ?: resp.optStringOrNull("message")
            ?: resp.optStringOrNull("error")
            ?: resp.optJSONObject("data")?.optStringOrNull("msg")
            ?: resp.optJSONObject("data")?.optStringOrNull("message")
            ?: resp.optJSONObject("data")?.optStringOrNull("error")
            ?: resp.toString()
    }

    private fun wifiOnFailureMayBeStaleState(detail: String): Boolean {
        val lower = detail.lowercase()
        return lower.contains("cannot start wifi") ||
            lower.contains("current state") ||
            lower.contains("invalid transition") ||
            lower.contains("wifi_sync")
    }

    private fun quoteSsid(value: String): String {
        val escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
        return "\"$escaped\""
    }
}

typealias WifiTransferProgress = (
    currentFile: String,
    filesDone: Int,
    totalFiles: Int,
    receivedBytes: Int,
    totalBytes: Int?,
) -> Unit

data class WifiPingResult(
    val ok: Boolean,
    val networkUnreachable: Boolean,
)

class WifiTransferClient(val hotspot: WifiHotspotInfo) {
    private var udp: ClipUdpSyncClient? = null

    suspend fun ping(): Boolean {
        return pingDetailed().ok
    }

    suspend fun pingDetailed(): WifiPingResult {
        return try {
            ensureConnected()
            val ok = udp?.ping() == true
            if (ok) {
                WifiPingResult(ok = true, networkUnreachable = false)
            } else {
                resetUdp()
                WifiPingResult(ok = false, networkUnreachable = false)
            }
        } catch (t: Throwable) {
            val unreachable = isDeviceApNetworkUnreachable(t)
            SdkLog.w("WifiTransferClient ping failed", t)
            resetUdp()
            WifiPingResult(ok = false, networkUnreachable = unreachable)
        }
    }

    suspend fun downloadSession(
        sessionId: String,
        sessionDirectory: File,
        startFile: String? = null,
        shouldCancel: (() -> Boolean)? = null,
        onOverallProgress: ((Double?) -> Unit)? = null,
        onProgress: WifiTransferProgress? = null,
    ): Int {
        ensureConnected()
        val client = udp ?: throw SenseCraftVoiceError.ConnectionFailed("UDP client is not connected")
        return client.downloadSession(
            sessionId = sessionId,
            sessionDirectory = sessionDirectory,
            startFile = startFile,
            shouldCancel = shouldCancel,
            onOverallProgress = onOverallProgress,
            onProgress = onProgress,
        )
    }

    fun dispose() = resetUdp()

    private suspend fun ensureConnected() {
        val existing = udp
        if (existing != null && existing.isConnected) return
        val client = ClipUdpSyncClient(receiveTimeoutMs = 8_000)
        client.connect(hotspot.ip, hotspot.port)
        udp = client
    }

    private fun resetUdp() {
        udp?.dispose()
        udp = null
    }
}

class ClipUdpSyncClient(
    private val receiveTimeoutMs: Long = 5_000,
) {
    companion object {
        const val FRAME_DATA: Int = 0x01
        const val FRAME_FILE_ACK: Int = 0x03
        const val FRAME_FILE_START: Int = 0x10
        const val FRAME_FILE_END: Int = 0x11
        const val FRAME_TRANSFER_DONE: Int = 0x12
        const val FRAME_AT_RESP: Int = 0x20
        const val FRAME_HEARTBEAT: Int = 0x30
        private const val DATA_HEADER_SIZE = 9
        private val UTF8: Charset = Charsets.UTF_8

        private fun normalizeAtCommand(command: String): String {
            var line = command.trim()
            if (line.isNotEmpty() && !line.uppercase().startsWith("AT")) line = "AT+$line"
            return line
        }

        private fun isFileTransferFrame(data: ByteArray): Boolean {
            if (data.isEmpty()) return false
            return when (data[0].toInt() and 0xff) {
                FRAME_DATA, FRAME_FILE_START, FRAME_FILE_END, FRAME_TRANSFER_DONE -> true
                else -> false
            }
        }

        private fun looksBusy(resp: JsonObject): Boolean {
            val lower = errorDetail(resp).lowercase()
            return lower.contains("already in progress") ||
                lower.contains("busy") ||
                lower.contains("in progress") ||
                lower.contains("transfer already")
        }

        private fun errorDetail(resp: JsonObject): String {
            return resp.optStringOrNull("error")
                ?: resp.optStringOrNull("msg")
                ?: resp.optStringOrNull("message")
                ?: resp.optJSONObject("data")?.optStringOrNull("error")
                ?: resp.optJSONObject("data")?.optStringOrNull("msg")
                ?: resp.optJSONObject("data")?.optStringOrNull("message")
                ?: resp.toString()
        }
    }

    private var socket: DatagramSocket? = null
    private var host: InetAddress? = null
    private var port: Int = 8089
    private val rx = Channel<ByteArray>(Channel.UNLIMITED)
    private val earlyReplay = ArrayDeque<ByteArray>()
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var readerJob: Job? = null
    private var heartbeatJob: Job? = null

    @Volatile
    var isConnected: Boolean = false
        private set

    suspend fun connect(host: String, port: Int) = withContext(Dispatchers.IO) {
        if (isConnected) return@withContext
        dispose()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        this@ClipUdpSyncClient.host = InetAddress.getByName(host)
        this@ClipUdpSyncClient.port = port
        val s = DatagramSocket()
        s.connect(this@ClipUdpSyncClient.host, port)
        s.receiveBufferSize = 4 * 1024 * 1024
        socket = s
        isConnected = true
        startReader(s)
        send(byteArrayOf(0x0a))
        startHeartbeat()
    }

    fun dispose() {
        isConnected = false
        heartbeatJob?.cancel()
        heartbeatJob = null
        readerJob?.cancel()
        readerJob = null
        socket?.close()
        socket = null
        scope.cancel()
        earlyReplay.clear()
        while (rx.tryReceive().isSuccess) {
            // drain
        }
    }

    suspend fun sendAtCommand(
        command: String,
        timeoutMs: Long = receiveTimeoutMs,
        maxSkips: Int = 64,
    ): JsonObject {
        val line = normalizeAtCommand(command)
        if (!send("$line\n".toByteArray(UTF8))) {
            return JSONObject().put("ok", false).put("error", "UDP send failed")
        }

        val deadline = System.currentTimeMillis() + timeoutMs
        var skips = 0
        while (System.currentTimeMillis() < deadline && skips < maxSkips) {
            val data = recvOne(deadline) ?: continue
            if (data.isEmpty()) continue
            when (data[0].toInt() and 0xff) {
                FRAME_HEARTBEAT -> {
                    skips++
                    continue
                }
                FRAME_AT_RESP -> {
                    if (data.size >= 3) {
                        val len = data.u16LE(1)
                        if (data.size >= 3 + len) {
                            val text = data.copyOfRange(3, 3 + len).toString(UTF8)
                            return try {
                                JSONObject(text)
                            } catch (_: Throwable) {
                                JSONObject().put("ok", true).put("raw", text)
                            }
                        }
                    }
                }
                else -> {
                    if (isFileTransferFrame(data)) {
                        earlyReplay.addLast(data)
                    }
                    skips++
                }
            }
        }
        return JSONObject().put("ok", false).put("error", "No UDP AT response")
    }

    suspend fun ping(): Boolean {
        val resp = sendAtCommand("AT+GSTAT", timeoutMs = 3_000)
        return resp.optBoolean("ok") == true
    }

    suspend fun downloadSession(
        sessionId: String,
        sessionDirectory: File,
        startFile: String? = null,
        shouldCancel: (() -> Boolean)? = null,
        onOverallProgress: ((Double?) -> Unit)? = null,
        onProgress: WifiTransferProgress? = null,
    ): Int = withContext(Dispatchers.IO) {
        if (!sessionDirectory.exists()) {
            sessionDirectory.mkdirs()
        }

        var totalFiles = 0
        var totalBytes = 0
        val infoResp = sendAtCommand("AT+LIST=$sessionId", timeoutMs = 8_000)
        if (infoResp.optBoolean("ok") == true) {
            val data = infoResp.optJSONObject("data") ?: JSONObject()
            totalFiles = data.optIntOrNull("files") ?: data.optIntOrNull("total") ?: 0
            totalBytes = data.optIntOrNull("size") ?: 0
        }

        val cmd = if (!startFile.isNullOrBlank()) {
            "AT+DOWNLOAD=$sessionId:${startFile.trim()}"
        } else {
            "AT+DOWNLOAD=$sessionId"
        }
        SdkLog.i("ClipUdpSync: send $cmd")
        var dlResp = sendAtCommand(cmd, timeoutMs = 15_000)
        if (dlResp.optBoolean("ok") != true && looksBusy(dlResp)) {
            SdkLog.w("ClipUdpSync: DOWNLOAD busy, sending AT+CANCEL and retrying once")
            sendAtCommand("AT+CANCEL", timeoutMs = 3_000)
            delay(600)
            dlResp = sendAtCommand(cmd, timeoutMs = 15_000)
        }
        if (dlResp.optBoolean("ok") != true) {
            throw SenseCraftVoiceError.InvalidResponse("AT+DOWNLOAD failed: ${errorDetail(dlResp)}")
        }
        dlResp.optJSONObject("data")?.let { data ->
            (data.optIntOrNull("files") ?: data.optIntOrNull("total"))?.takeIf { it > 0 }?.let { totalFiles = it }
            (data.optIntOrNull("bytes") ?: data.optIntOrNull("size"))?.takeIf { it > 0 }?.let { totalBytes = it }
        }

        pauseHeartbeat()
        try {
            var currentName: String? = null
            var declaredFileSize = 0
            var maxDataSeqInclusive = 0
            val currentData = ByteArrayOutputStream()
            var fileCrc = 0L
            var nextExpectedSeq = 0
            val pendingDataBySeq = HashMap<Int, ByteArray>()
            var filesReceived = 0
            var receivedBytes = 0
            var lastProgressAt = System.currentTimeMillis()
            var lastNackFile: String? = null
            var consecutiveFileNacks = 0
            val maxConsecutiveFileNacks = 4

            fun emitOverallProgress() {
                val ratio = TransferProgress.wifiAligned(
                    framedMode = currentName != null,
                    currentFileDeclaredSize = declaredFileSize,
                    bytesThisFile = currentData.size(),
                    receivedSession = receivedBytes,
                    expectedSession = totalBytes.takeIf { it > 0 },
                    filesCompleted = filesReceived,
                    deviceTotalFiles = totalFiles,
                    deviceSessionBytes = totalBytes,
                )
                onOverallProgress?.invoke(ratio)
            }

            fun resetAssembly() {
                nextExpectedSeq = 0
                pendingDataBySeq.clear()
            }

            fun appendPayload(payload: ByteArray) {
                currentData.write(payload)
                fileCrc = crc32Ieee(payload, fileCrc)
                receivedBytes += payload.size
                emitOverallProgress()
            }

            fun ingestDataFrame(data: ByteArray) {
                val name = currentName ?: return
                if (data.size < DATA_HEADER_SIZE) return
                val dataLen = data.u16LE(3)
                if (data.size < DATA_HEADER_SIZE + dataLen) return
                val receivedCrc = data.u32LE(5)
                val payload = data.copyOfRange(DATA_HEADER_SIZE, DATA_HEADER_SIZE + dataLen)
                if (crc32Ieee(payload) != receivedCrc) {
                    SdkLog.w("ClipUdpSync: DATA crc mismatch")
                    return
                }
                val seq = data.u16LE(1)
                if (seq > maxDataSeqInclusive || seq < nextExpectedSeq) {
                    lastProgressAt = System.currentTimeMillis()
                    return
                }
                if (seq > nextExpectedSeq) {
                    pendingDataBySeq[seq] = payload
                    lastProgressAt = System.currentTimeMillis()
                    return
                }
                appendPayload(payload)
                nextExpectedSeq++
                while (pendingDataBySeq.containsKey(nextExpectedSeq)) {
                    val pending = pendingDataBySeq.remove(nextExpectedSeq) ?: break
                    appendPayload(pending)
                    nextExpectedSeq++
                }
                lastProgressAt = System.currentTimeMillis()
                onProgress?.invoke(name, filesReceived, totalFiles, receivedBytes, totalBytes.takeIf { it > 0 })
            }

            while (true) {
                if (shouldCancel?.invoke() == true) {
                    sendAtCommand("AT+CANCEL", timeoutMs = 2_000)
                    return@withContext receivedBytes
                }

                val data = recvOne(System.currentTimeMillis() + receiveTimeoutMs)
                if (data == null || data.isEmpty()) {
                    if (System.currentTimeMillis() - lastProgressAt > 60_000) {
                        throw SenseCraftVoiceError.Timeout("UDP download stalled")
                    }
                    continue
                }

                when (data[0].toInt() and 0xff) {
                    FRAME_HEARTBEAT, FRAME_AT_RESP -> continue
                    FRAME_FILE_START -> {
                        if (data.size < 3) continue
                        val nameLen = data[1].toInt() and 0xff
                        if (data.size < 2 + nameLen + 4) continue
                        val name = data.copyOfRange(2, 2 + nameLen).toString(UTF8)
                        val fileSize = data.u32LE(2 + nameLen).toInt()
                        currentName = name
                        declaredFileSize = fileSize
                        maxDataSeqInclusive = if (fileSize == 0) 8 else ((fileSize + 1023) / 1024) + 47
                        currentData.reset()
                        fileCrc = 0
                        resetAssembly()
                        lastProgressAt = System.currentTimeMillis()
                        onProgress?.invoke(name, filesReceived, totalFiles, receivedBytes, totalBytes.takeIf { it > 0 })
                        emitOverallProgress()
                        SdkLog.i("ClipUdpSync FILE_START $name ($fileSize bytes)")
                    }
                    FRAME_DATA -> ingestDataFrame(data)
                    FRAME_FILE_END -> {
                        if (data.size < 5) continue
                        val serverCrc = data.u32LE(1)
                        val crcOk = fileCrc == serverCrc
                        val filename = currentName
                        SdkLog.i(
                            "ClipUdpSync FILE_END ${filename.orEmpty()} crcOk=$crcOk " +
                                "assembled=${currentData.size()}/$declaredFileSize"
                        )
                        if (crcOk && filename != null && currentData.size() > 0) {
                            sendFileAck(true)
                            val output = File(sessionDirectory, File(filename).name)
                            output.writeBytes(currentData.toByteArray())
                            if (filename.lowercase().endsWith(".opus")) filesReceived++
                            consecutiveFileNacks = 0
                            lastNackFile = null
                        } else {
                            sendFileAck(false)
                            if (filename == lastNackFile) {
                                consecutiveFileNacks++
                            } else {
                                consecutiveFileNacks = 1
                                lastNackFile = filename
                            }
                            if (consecutiveFileNacks >= maxConsecutiveFileNacks) {
                                sendAtCommand("AT+CANCEL", timeoutMs = 2_000)
                                throw SenseCraftVoiceError.ConnectionFailed("UDP file transfer failed repeatedly")
                            }
                        }
                        currentName = null
                        currentData.reset()
                        fileCrc = 0
                        resetAssembly()
                        lastProgressAt = System.currentTimeMillis()
                        emitOverallProgress()
                    }
                    FRAME_TRANSFER_DONE -> {
                        val done = parseTransferDone(data)
                        if (!done.first.isNullOrBlank() && done.first != sessionId) {
                            SdkLog.w("ClipUdpSync TRANSFER_DONE session mismatch fw=${done.first} expected=$sessionId")
                        }
                        SdkLog.i(
                            "ClipUdpSync TRANSFER_DONE session=${done.first.orEmpty()} " +
                                "files=${done.second ?: -1} payloadBytes=$receivedBytes"
                        )
                        emitOverallProgress()
                        return@withContext receivedBytes
                    }
                }
            }
        } finally {
            resumeHeartbeat()
        }
        0
    }

    private fun startReader(s: DatagramSocket) {
        readerJob?.cancel()
        readerJob = scope.launch {
            val buf = ByteArray(65_535)
            while (isActive && !s.isClosed) {
                try {
                    val packet = DatagramPacket(buf, buf.size)
                    s.receive(packet)
                    if (packet.length > 0) {
                        rx.trySend(packet.data.copyOfRange(packet.offset, packet.offset + packet.length))
                    }
                } catch (_: Throwable) {
                    if (!s.isClosed) isConnected = false
                    break
                }
            }
        }
    }

    private suspend fun recvOne(deadlineMs: Long): ByteArray? {
        if (earlyReplay.isNotEmpty()) return earlyReplay.removeFirst()
        val remaining = deadlineMs - System.currentTimeMillis()
        if (remaining <= 0) return null
        return withTimeoutOrNull(remaining) { rx.receive() }
    }

    private suspend fun send(data: ByteArray): Boolean = withContext(Dispatchers.IO) {
        val s = socket ?: return@withContext false
        return@withContext try {
            s.send(DatagramPacket(data, data.size))
            true
        } catch (t: Throwable) {
            SdkLog.w("ClipUdpSync UDP send failed", t)
            isConnected = false
            false
        }
    }

    private suspend fun sendFileAck(ok: Boolean) {
        send(byteArrayOf(FRAME_FILE_ACK.toByte(), if (ok) 0x00 else 0x01))
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(5_000)
                if (!isConnected) continue
                val ts = (System.currentTimeMillis() and 0xffffffffL).toLong()
                val data = byteArrayOf(
                    FRAME_HEARTBEAT.toByte(),
                    (ts and 0xff).toByte(),
                    ((ts ushr 8) and 0xff).toByte(),
                    ((ts ushr 16) and 0xff).toByte(),
                    ((ts ushr 24) and 0xff).toByte(),
                )
                send(data)
            }
        }
    }

    private fun pauseHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
    }

    private fun resumeHeartbeat() {
        if (isConnected) startHeartbeat()
    }

    private fun parseTransferDone(data: ByteArray): Pair<String?, Int?> {
        if (data.size < 2) return null to null
        val sidLen = data[1].toInt() and 0xff
        if (data.size < 2 + sidLen + 4) return null to null
        val sid = if (sidLen > 0) data.copyOfRange(2, 2 + sidLen).toString(UTF8).trim() else ""
        return sid to data.u32LE(2 + sidLen).toInt()
    }
}

private fun ByteArray.u16LE(offset: Int): Int {
    if (size < offset + 2) return 0
    return (this[offset].toInt() and 0xff) or ((this[offset + 1].toInt() and 0xff) shl 8)
}

private fun ByteArray.u32LE(offset: Int): Long {
    if (size < offset + 4) return 0
    return (this[offset].toLong() and 0xffL) or
        ((this[offset + 1].toLong() and 0xffL) shl 8) or
        ((this[offset + 2].toLong() and 0xffL) shl 16) or
        ((this[offset + 3].toLong() and 0xffL) shl 24)
}
