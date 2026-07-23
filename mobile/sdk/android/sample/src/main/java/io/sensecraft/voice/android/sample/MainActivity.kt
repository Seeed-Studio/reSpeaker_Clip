package io.sensecraft.voice.android.sample

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.text.method.ScrollingMovementMethod
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.sensecraft.voice.android.AtTransport
import io.sensecraft.voice.android.BleTransferFrameHandler
import io.sensecraft.voice.android.BleTransferFrameResult
import io.sensecraft.voice.android.BleTransferFrameState
import io.sensecraft.voice.android.DeviceEvent
import io.sensecraft.voice.android.DeviceFileMeta
import io.sensecraft.voice.android.DeviceRuntimeInfo
import io.sensecraft.voice.android.JsonObjectFramer
import io.sensecraft.voice.android.NordicMcuMgrOtaTransport
import io.sensecraft.voice.android.OtaSession
import io.sensecraft.voice.android.RecordingSession
import io.sensecraft.voice.android.SenseCraftVoiceBlePermissions
import io.sensecraft.voice.android.SenseCraftVoiceClient
import io.sensecraft.voice.android.SenseCraftVoiceConnection
import io.sensecraft.voice.android.SenseCraftVoiceScanResult
import io.sensecraft.voice.android.TransferProgress
import io.sensecraft.voice.android.WifiFastSyncSession
import io.sensecraft.voice.android.kClipFrameFileStart
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class MainActivity : Activity() {
    companion object {
        private const val OTA_FILE_REQUEST = 2001
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val timestampFormat = SimpleDateFormat("HH:mm:ss", Locale.US)

    private lateinit var client: SenseCraftVoiceClient
    private lateinit var logView: TextView
    private lateinit var statusView: TextView
    private lateinit var runtimeView: TextView
    private lateinit var filesView: TextView
    private lateinit var deviceView: TextView
    private lateinit var scanResultsContainer: LinearLayout
    private lateinit var deviceIdInput: EditText
    private lateinit var sessionIdInput: EditText
    private lateinit var startFileInput: EditText
    private lateinit var noteInput: EditText
    private lateinit var deviceNameInput: EditText

    private var connection: SenseCraftVoiceConnection? = null
    private var at: AtTransport? = null
    private var recordingSession: RecordingSession? = null
    private var wifiSession: WifiFastSyncSession? = null
    private var deviceEventJob: Job? = null
    private var recordingModeIsEnhanced: Boolean = false
    private var recordingModeSummary: String = "unknown"
    private var deviceNameSummary: String = "not read"
    private var deviceTimeSummary: String = "not read"
    private var pairingSummary: String = "not read"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        client = SenseCraftVoiceClient(this)
        setContentView(buildUi())
        bindClientStreams()
        append("Adapter: ${client.getCurrentAdapterState()}")
        append("Required permissions: ${SenseCraftVoiceBlePermissions.requiredPermissions(includeWifi = true).joinToString()}")
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.launch {
            disconnectCurrent()
            client.close()
            scope.cancel()
        }
    }

    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
        }

        root.addView(TextView(this).apply {
            text = "SenseCraft Voice Android Verify"
            textSize = 20f
        })

        statusView = label("Connection: not connected")
        runtimeView = label("Runtime: not read")
        filesView = label("Files: not listed")
        deviceView = label("Device: not read")
        root.addView(statusView)
        root.addView(runtimeView)
        root.addView(filesView)
        root.addView(deviceView)

        deviceIdInput = field("Android BLE address, e.g. AA:BB:CC:DD:EE:FF")
        sessionIdInput = field("Recording session id")
        startFileInput = field("Start file (optional)")
        noteInput = field("Mark note (optional)")
        deviceNameInput = field("Device name (optional)")
        root.addView(deviceIdInput)
        root.addView(sessionIdInput)
        root.addView(startFileInput)
        root.addView(noteInput)
        root.addView(deviceNameInput)

        root.addView(button("Request permissions") { requestSdkPermissions() })
        root.addView(button("Run local smoke") { runLocalSmoke() })
        root.addView(button("Scan Clip 12s") { scanForDevices() })
        root.addView(button("Connect + Status") { connectAndQueryStatus() })
        root.addView(button("Disconnect") { scope.launch { disconnectCurrent() } })
        root.addView(button("Read Runtime") { readRuntimeInfo() })
        root.addView(button("Sync Time") { syncDeviceTime() })
        root.addView(button("Read Device Time") { readDeviceTime() })
        root.addView(button("Read Pairing") { readPairingStatus() })
        root.addView(button("Read Name") { readUserDeviceName() })
        root.addView(button("Set Name") { setUserDeviceName() })
        root.addView(button("Reset Pairing") { resetPairing() })
        root.addView(button("Start Recording") { startRecording() })
        root.addView(button("Stop Recording") { stopRecording() })
        root.addView(button("Pause Recording") { pauseRecording() })
        root.addView(button("Resume Recording") { resumeRecording() })
        root.addView(button("Toggle Mode") { setRecordingMode() })
        root.addView(button("Mark") { markBookmark() })
        root.addView(button("List Files") { listAllFiles() })
        root.addView(button("List Bookmarks") { listBookmarks() })
        root.addView(button("BLE Download + Merge") { bleDownloadMerge() })
        root.addView(button("BLE Download + Finalize") { bleDownloadFinalize() })
        root.addView(button("WiFi Prepare") { prepareWifi() })
        root.addView(button("WiFi Ping") { pingWifi() })
        root.addView(button("WiFi Download") { wifiDownload() })
        root.addView(button("WiFi Teardown") { teardownWifi() })
        root.addView(button("Choose Firmware + OTA") { chooseFirmwareForOta() })

        root.addView(section("Scan Results"))
        scanResultsContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(scanResultsContainer)

        root.addView(section("Logs"))
        logView = TextView(this).apply {
            movementMethod = ScrollingMovementMethod()
            textSize = 13f
        }
        root.addView(logView, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ))

        return ScrollView(this).apply {
            addView(root)
        }
    }

    private fun field(hintText: String): EditText {
        return EditText(this).apply {
            hint = hintText
            setSingleLine(true)
        }
    }

    private fun label(textValue: String): TextView {
        return TextView(this).apply {
            text = textValue
            textSize = 14f
        }
    }

    private fun section(textValue: String): TextView {
        return TextView(this).apply {
            text = textValue
            textSize = 16f
            setPadding(0, 24, 0, 8)
        }
    }

    private fun button(label: String, action: () -> Unit): Button {
        return Button(this).apply {
            text = label
            setOnClickListener { action() }
        }
    }

    private fun bindClientStreams() {
        scope.launch {
            client.adapterState.collect {
                append("Adapter state: $it")
            }
        }
        scope.launch {
            client.scanResults.collect { results ->
                renderScanResults(results)
            }
        }
    }

    private fun renderScanResults(results: List<SenseCraftVoiceScanResult>) {
        val clipResults = results.filter(::isClipResult)
        scanResultsContainer.removeAllViews()
        if (clipResults.isEmpty()) {
            scanResultsContainer.addView(label("No Clip devices yet."))
            return
        }
        clipResults.take(12).forEach { result ->
            scanResultsContainer.addView(button("${result.name}  ${result.id}  rssi=${result.rssi}") {
                deviceIdInput.setText(result.id)
                connectToDevice(result.id)
            })
        }
    }

    private fun isClipResult(result: SenseCraftVoiceScanResult): Boolean =
        result.name.contains("Clip", ignoreCase = true)

    private fun requestSdkPermissions(): Boolean {
        val permissions = SenseCraftVoiceBlePermissions.requiredPermissions(includeWifi = true)
            .filter { permission ->
                if (Build.VERSION.SDK_INT < 31 &&
                    (permission == Manifest.permission.BLUETOOTH_SCAN ||
                        permission == Manifest.permission.BLUETOOTH_CONNECT)
                ) {
                    false
                } else if (Build.VERSION.SDK_INT < 33 && permission == Manifest.permission.NEARBY_WIFI_DEVICES) {
                    false
                } else {
                    checkSelfPermission(permission) != android.content.pm.PackageManager.PERMISSION_GRANTED
                }
            }
            .toTypedArray()
        if (permissions.isEmpty()) {
            append("Permissions already granted.")
            return true
        }
        requestPermissions(permissions, 1001)
        append("Grant permissions, then tap the action again.")
        return false
    }

    private fun runLocalSmoke() {
        val framer = JsonObjectFramer()
        val json = framer.feed("{\"ok\":") + framer.feed("true}")
        check(json.size == 1)

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
        check(ratio != null && kotlin.math.abs(ratio - 0.24) < 0.0001)

        val name = "0001.opus".toByteArray()
        val frame = byteArrayOf(kClipFrameFileStart.toByte(), name.size.toByte()) +
            name +
            byteArrayOf(0x03, 0x00, 0x00, 0x00)
        val parsed = BleTransferFrameHandler.handle(frame, BleTransferFrameState())
        check(parsed is BleTransferFrameResult.FileStart && parsed.filename == "0001.opus")

        append("PASS: local SDK smoke checks passed.")
    }

    private fun scanForDevices() {
        if (!requestSdkPermissions()) return
        scope.launch {
            runCatching {
                append("Scanning nearby BLE devices for Clip recorders...")
                client.startScan(timeoutMs = 12_000, filterByService = false)
                withTimeoutOrNull(13_000) {
                    client.scanResults
                        .map { results -> results.filter(::isClipResult) }
                        .first { it.isNotEmpty() }
                }?.let { clipResults ->
                    append("Found ${clipResults.size} Clip device(s). Tap a result to connect.")
                    deviceIdInput.setText(clipResults.first().id)
                } ?: append("No Clip devices found.")
            }.onFailure {
                client.stopScan()
                append("Scan failed: ${it.message}")
            }
        }
    }

    private fun connectAndQueryStatus() {
        val deviceId = deviceIdInput.text.toString().trim()
        if (deviceId.isEmpty()) {
            append("Enter a BLE address or scan first.")
            return
        }
        connectToDevice(deviceId)
    }

    private fun connectToDevice(deviceId: String) {
        if (!requestSdkPermissions()) return
        scope.launch {
            runCatching {
                append("Connecting to $deviceId ...")
                disconnectCurrent()
                val conn = client.connectByDeviceId(deviceId) ?: error("Device not found")
                connection = conn
                val transport = AtTransport(conn)
                at = transport
                val session = RecordingSession(conn, transport)
                recordingSession = session
                bindDeviceEvents(session)
                val status = session.getStatus()
                recordingModeIsEnhanced = status.recordingMode == io.sensecraft.voice.android.RecordingMode.ENHANCED
                recordingModeSummary = status.recordingMode?.name?.lowercase() ?: "unknown"
                statusView.text = "Connection: $deviceId  ${status.state}"
                status.sessionId?.let { sessionIdInput.setText(it) }
                updateDeviceSummary()
                append("PASS: AT+GSTAT -> state=${status.state} recording=${status.isRecording} battery=${status.batteryPercent ?: -1}")
            }.onFailure {
                statusView.text = "Connection: failed"
                append("Connect/status failed: ${it.message}")
            }
        }
    }

    private suspend fun disconnectCurrent() {
        wifiSession?.teardown()
        wifiSession = null
        deviceEventJob?.cancel()
        deviceEventJob = null
        at?.close()
        at = null
        recordingSession = null
        val conn = connection
        connection = null
        if (conn == null) {
            statusView.text = "Connection: not connected"
            return
        }
        runCatching {
            append("Disconnecting ${conn.device.address} ...")
            client.disconnect(conn)
        }.onFailure {
            append("Disconnect failed: ${it.message}")
        }
        statusView.text = "Connection: not connected"
        runtimeView.text = "Runtime: not read"
        filesView.text = "Files: not listed"
        recordingModeIsEnhanced = false
        recordingModeSummary = "unknown"
        deviceNameSummary = "not read"
        deviceTimeSummary = "not read"
        pairingSummary = "not read"
        updateDeviceSummary()
        append("Disconnected.")
    }

    private fun startRecording() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val info = session.start(
                    if (recordingModeIsEnhanced) {
                        io.sensecraft.voice.android.RecordingMode.ENHANCED
                    } else {
                        io.sensecraft.voice.android.RecordingMode.NORMAL
                    }
                )
                sessionIdInput.setText(info.sessionId)
                append("Start -> session=${info.sessionId} mode=${info.mode?.name?.lowercase() ?: "unknown"}")
            }.onFailure {
                append("Start failed: ${it.message}")
            }
        }
    }

    private fun stopRecording() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val info = session.stop()
                info.sessionId?.takeIf { it.isNotBlank() }?.let { sessionIdInput.setText(it) }
                append("Stop -> session=${info.sessionId ?: "-"} duration=${info.durationSeconds ?: -1}")
            }.onFailure {
                append("Stop failed: ${it.message}")
            }
        }
    }

    private fun bindDeviceEvents(session: RecordingSession) {
        deviceEventJob?.cancel()
        deviceEventJob = scope.launch {
            session.deviceEvents.collect {
                append(describe(it))
            }
        }
    }

    private fun readRuntimeInfo() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            val info = session.readRuntimeInfo()
            val summary = describe(info)
            runtimeView.text = "Runtime: $summary"
            info.formattedDeviceTime?.let { deviceTimeSummary = it }
            info.pairStatus?.let {
                pairingSummary = if (info.pairAddress.isNullOrBlank()) it else "$it ${info.pairAddress}"
            }
            info.status?.recordingMode?.let {
                recordingModeIsEnhanced = it == io.sensecraft.voice.android.RecordingMode.ENHANCED
                recordingModeSummary = it.name.lowercase()
            }
            updateDeviceSummary()
            append("Runtime -> $summary")
        }
    }

    private fun syncDeviceTime() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            append("Syncing device time...")
            val ok = session.syncDeviceTime(force = true)
            append(if (ok) "Device time synced." else "Device time sync skipped or failed.")
            readRuntimeInfo()
        }
    }

    private fun readDeviceTime() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val info = session.getDeviceTime()
                deviceTimeSummary = describe(info)
                updateDeviceSummary()
                append("Device time -> ${describe(info)}")
            }.onFailure {
                append("Read device time failed: ${it.message}")
            }
        }
    }

    private fun readPairingStatus() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val info = session.getPairingStatus()
                pairingSummary = describe(info)
                updateDeviceSummary()
                append("Pairing -> ${describe(info)}")
            }.onFailure {
                append("Read pairing status failed: ${it.message}")
            }
        }
    }

    private fun readUserDeviceName() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val name = session.getUserDeviceName()
                deviceNameInput.setText(name)
                deviceNameSummary = if (name.isBlank()) "empty" else name
                updateDeviceSummary()
                append("Device name -> ${if (name.isBlank()) "<empty>" else name}")
            }.onFailure {
                append("Read device name failed: ${it.message}")
            }
        }
    }

    private fun setUserDeviceName() {
        val session = recordingSession ?: return append("Connect first.")
        val name = deviceNameInput.text.toString().trim()
        scope.launch {
            runCatching {
                session.setUserDeviceName(name.ifEmpty { null })
                deviceNameSummary = if (name.isBlank()) "cleared" else name
                if (name.isBlank()) {
                    deviceNameInput.setText("")
                }
                updateDeviceSummary()
                append(if (name.isBlank()) "Device name cleared." else "Device name set to $name")
            }.onFailure {
                append("Set device name failed: ${it.message}")
            }
        }
    }

    private fun resetPairing() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                session.resetPairing()
                pairingSummary = "reset"
                updateDeviceSummary()
                append("Pairing reset.")
            }.onFailure {
                append("Reset pairing failed: ${it.message}")
            }
        }
    }

    private fun pauseRecording() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val info = session.pause()
                info.sessionId?.takeIf { it.isNotBlank() }?.let {
                    sessionIdInput.setText(it)
                }
                append("Pause -> session=${info.sessionId ?: "-"} duration=${info.durationSeconds ?: -1}")
            }.onFailure {
                append("Pause failed: ${it.message}")
            }
        }
    }

    private fun resumeRecording() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val info = session.resume()
                info.sessionId?.takeIf { it.isNotBlank() }?.let {
                    sessionIdInput.setText(it)
                }
                append("Resume -> session=${info.sessionId ?: "-"} duration=${info.durationSeconds ?: -1}")
            }.onFailure {
                append("Resume failed: ${it.message}")
            }
        }
    }

    private fun setRecordingMode() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val target = if (recordingModeIsEnhanced) {
                    io.sensecraft.voice.android.RecordingMode.NORMAL
                } else {
                    io.sensecraft.voice.android.RecordingMode.ENHANCED
                }
                val applied = session.setRecordingMode(target)
                recordingModeIsEnhanced = applied == io.sensecraft.voice.android.RecordingMode.ENHANCED
                recordingModeSummary = applied.name.lowercase()
                append("Mode -> ${applied.name.lowercase()}")
            }.onFailure {
                append("Set mode failed: ${it.message}")
            }
        }
    }

    private fun markBookmark() {
        val session = recordingSession ?: return append("Connect first.")
        val note = noteInput.text.toString().trim().ifEmpty { null }
        scope.launch {
            runCatching {
                val result = session.mark(note = note)
                result.sessionId?.let { sessionIdInput.setText(it) }
                append("Mark -> ok=${result.ok} session=${result.sessionId ?: "-"} count=${result.markCount ?: -1} offset=${result.offsetSeconds ?: -1}")
            }.onFailure {
                append("Mark failed: ${it.message}")
            }
        }
    }

    private fun listAllFiles() {
        val session = recordingSession ?: return append("Connect first.")
        scope.launch {
            runCatching {
                val files = session.listAllFiles(perPage = 10, maxPages = 100)
                filesView.text = "Files: ${describeFileSummary(files)}"
                if (sessionIdInput.text.toString().trim().isEmpty()) {
                    inferSessionId(files.firstOrNull()?.path)?.let { sessionIdInput.setText(it) }
                }
                append("Files -> ${describeFileSummary(files)}")
                files.take(8).forEach { append("File ${describe(it)}") }
            }.onFailure {
                filesView.text = "Files: failed"
                append("List files failed: ${it.message}")
            }
        }
    }

    private fun listBookmarks() {
        val session = recordingSession ?: return append("Connect first.")
        val sessionId = sessionIdInput.text.toString().trim()
        if (sessionId.isEmpty()) return append("Enter a session id first.")
        scope.launch {
            runCatching {
                val bookmarks = session.listBookmarks(sessionId = sessionId, perPage = 10)
                append("Bookmarks $sessionId -> ${bookmarks.size}")
                bookmarks.take(8).forEach {
                    append("Bookmark session=${it.sessionId ?: "-"} count=${it.markCount ?: -1} offset=${it.offsetSeconds ?: -1} note=${it.note ?: "-"}")
                }
            }.onFailure {
                append("List bookmarks failed: ${it.message}")
            }
        }
    }

    private fun updateDeviceSummary() {
        deviceView.text = "Device: mode=$recordingModeSummary  name=$deviceNameSummary  time=$deviceTimeSummary  pair=$pairingSummary"
    }

    private fun bleDownloadMerge() {
        val session = recordingSession ?: return append("Connect first.")
        val sessionId = sessionIdInput.text.toString().trim()
        if (sessionId.isEmpty()) return append("Enter a session id first.")
        val startFile = startFileInput.text.toString().trim().ifEmpty { null }
        val directory = File(downloadRoot(), "$sessionId-ble")
        scope.launch {
            runCatching {
                append("BLE download+merge $sessionId -> ${directory.absolutePath}")
                val result = session.downloadMergeAndMaybeDeleteSession(
                    sessionId = sessionId,
                    directory = directory,
                    startFile = startFile,
                )
                append("BLE merge done: files=${result.download.completedFiles} bytes=${result.download.completedBytes} merged=${result.mergedFile.absolutePath} mergedBytes=${result.mergedBytes}")
            }.onFailure {
                append("BLE merge failed: ${it.message}")
            }
        }
    }

    private fun bleDownloadFinalize() {
        val session = recordingSession ?: return append("Connect first.")
        val sessionId = sessionIdInput.text.toString().trim()
        if (sessionId.isEmpty()) return append("Enter a session id first.")
        val startFile = startFileInput.text.toString().trim().ifEmpty { null }
        val directory = File(downloadRoot(), "$sessionId-finalize")
        scope.launch {
            runCatching {
                append("BLE download+finalize $sessionId -> ${directory.absolutePath}")
                val result = session.downloadMergeFetchBookmarksAndMaybeDeleteSession(
                    sessionId = sessionId,
                    directory = directory,
                    startFile = startFile,
                )
                append("BLE finalize done: files=${result.merge.download.completedFiles} merged=${result.merge.mergedFile.absolutePath} bookmarks=${result.bookmarks.size} saved=${result.bookmarksSaved}")
            }.onFailure {
                append("BLE finalize failed: ${it.message}")
            }
        }
    }

    private fun prepareWifi() {
        val transport = at ?: return append("Connect first.")
        if (!requestSdkPermissions()) return
        scope.launch {
            runCatching {
                wifiSession?.teardown()
                val session = WifiFastSyncSession(transport, this@MainActivity)
                wifiSession = session
                val hotspot = session.prepare(joinPhone = true, requirePhoneJoin = true)
                append("WiFi prepared: ssid=${hotspot.ssid} ${hotspot.ip}:${hotspot.port}")
            }.onFailure {
                wifiSession = null
                append("WiFi prepare failed: ${it.message}")
            }
        }
    }

    private fun pingWifi() {
        val session = wifiSession ?: return append("Prepare WiFi first.")
        scope.launch {
            runCatching {
                val result = session.transferClient?.pingDetailed()
                    ?: error("WiFi transfer client is unavailable")
                append("WiFi ping -> ok=${result.ok} networkUnreachable=${result.networkUnreachable}")
            }.onFailure {
                append("WiFi ping failed: ${it.message}")
            }
        }
    }

    private fun wifiDownload() {
        val session = wifiSession ?: return append("Prepare WiFi first.")
        val sessionId = sessionIdInput.text.toString().trim()
        if (sessionId.isEmpty()) return append("Enter a session id first.")
        val startFile = startFileInput.text.toString().trim().ifEmpty { null }
        val directory = File(downloadRoot(), "$sessionId-wifi")
        scope.launch {
            runCatching {
                append("WiFi download $sessionId -> ${directory.absolutePath}")
                val bytes = session.transferClient?.downloadSession(
                    sessionId = sessionId,
                    sessionDirectory = directory,
                    startFile = startFile,
                    onOverallProgress = { progress ->
                        progress?.let {
                            runOnUiThread { append("WiFi progress ${(it * 100).toInt()}%") }
                        }
                    },
                ) ?: error("WiFi transfer client is unavailable")
                append("WiFi download done: bytes=$bytes")
            }.onFailure {
                append("WiFi download failed: ${it.message}")
            }
        }
    }

    private fun teardownWifi() {
        val session = wifiSession ?: return append("WiFi is not prepared.")
        scope.launch {
            runCatching { session.teardown() }
                .onSuccess {
                    wifiSession = null
                    append("WiFi torn down.")
                }
                .onFailure { append("WiFi teardown failed: ${it.message}") }
        }
    }

    private fun chooseFirmwareForOta() {
        if (connection == null) return append("Connect first.")
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/octet-stream"))
            },
            OTA_FILE_REQUEST,
        )
    }

    @Deprecated("Kept for the sample's broad Android API compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != OTA_FILE_REQUEST || resultCode != RESULT_OK) return
        val uri = data?.data ?: return append("No firmware file selected.")
        val conn = connection ?: return append("Reconnect before starting OTA.")
        scope.launch {
            runCatching {
                val displayName = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    }
                    ?: "firmware.bin"
                require(displayName.endsWith(".zip", true) || displayName.endsWith(".bin", true)) {
                    "Choose a .zip or .bin firmware file"
                }
                val firmware = File(cacheDir, displayName.substringAfterLast('/'))
                contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Unable to open firmware file" }
                    firmware.outputStream().use { output -> input.copyTo(output) }
                }
                append("OTA selected: ${firmware.name} (${firmware.length()} bytes)")
                val ota = OtaSession(
                    deviceId = conn.device.address,
                    transport = NordicMcuMgrOtaTransport(this@MainActivity, conn.device),
                )
                val eventJob = launch {
                    ota.events.collect { event ->
                        append("OTA ${event.phase}: ${(event.progress * 100).toInt()}% ${event.message}")
                    }
                }
                val ok = ota.upgrade(firmware)
                eventJob.cancel()
                append(if (ok) "OTA completed." else "OTA failed: ${ota.lastError?.message ?: "unknown error"}")
            }.onFailure {
                append("OTA failed: ${it.message}")
            }
        }
    }

    private fun downloadRoot(): File {
        return File(getExternalFilesDir(null) ?: filesDir, "SenseCraftDownloads").also {
            it.mkdirs()
        }
    }

    private fun describe(info: DeviceRuntimeInfo): String {
        val parts = ArrayList<String>()
        info.firmwareVersion?.let { parts += "fw=$it" }
        info.state?.takeIf { it.isNotEmpty() }?.let { parts += "state=$it" }
        info.isRecording?.let { parts += "recording=$it" }
        info.sessionId?.let { parts += "session=$it" }
        info.batteryPercent?.let { parts += "battery=$it%" }
        info.formattedDeviceTime?.let { parts += "time=$it" }
        info.pairStatus?.let { parts += "pair=$it" }
        info.pairAddress?.let { parts += "peer=$it" }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" ") ?: "no runtime fields"
    }

    private fun describe(info: io.sensecraft.voice.android.DeviceTimeInfo): String {
        info.date?.let { return "time=${timestampFormat.format(it)} unix=${info.unixSeconds ?: -1}" }
        info.unixSeconds?.let { return "time=unix($it)" }
        return "time=unknown"
    }

    private fun describe(info: io.sensecraft.voice.android.PairingStatus): String {
        val parts = ArrayList<String>()
        info.isPaired?.let { parts += "paired=$it" }
        info.state?.takeIf { it.isNotEmpty() }?.let { parts += "state=$it" }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" ") ?: "pairing=unknown"
    }

    private fun describeFileSummary(files: List<DeviceFileMeta>): String {
        return "${files.size} file(s), ${files.sumOf { it.sizeBytes }} bytes"
    }

    private fun describe(file: DeviceFileMeta): String {
        val created = file.createdAt?.let { SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(it) } ?: "-"
        return "${file.path} size=${file.sizeBytes} duration=${file.durationSeconds} bookmarks=${file.bookmarkCount} created=$created"
    }

    private fun describe(event: DeviceEvent): String {
        return when (event) {
            is DeviceEvent.RecordingState -> "EVENT state=${event.state} session=${event.sessionId ?: "-"} duration=${event.durationSeconds ?: -1}"
            is DeviceEvent.Bookmark -> "EVENT bookmark session=${event.sessionId ?: "-"} count=${event.markCount ?: -1} offset=${event.offsetSeconds ?: -1}"
            is DeviceEvent.BatteryLow -> "EVENT battery_low level=${event.level ?: -1}"
            is DeviceEvent.StorageLow -> "EVENT storage_low freeMb=${event.freeMb ?: -1}"
            is DeviceEvent.Error -> "EVENT error code=${event.code ?: -1} message=${event.message ?: "-"}"
            is DeviceEvent.Connected -> "EVENT connected ${event.address ?: "-"}"
            is DeviceEvent.Disconnected -> "EVENT disconnected ${event.reason ?: "-"}"
            is DeviceEvent.Unknown -> "EVENT ${event.name}"
        }
    }

    private fun inferSessionId(path: String?): String? {
        val clean = path?.trim()?.trim('/') ?: return null
        if (clean.isEmpty()) return null
        return if (clean.contains('/')) {
            clean.substringBefore('/')
        } else {
            clean.substringBefore('.')
        }.takeIf { it.isNotEmpty() }
    }

    private fun append(message: String) {
        logView.append("${timestampFormat.format(Date())}  $message\n")
    }
}
