package io.sensecraft.voice.android

import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

data class RecordingStartInfo(
    val sessionId: String,
    val mode: RecordingMode?,
    val raw: JsonObject,
)

data class RecordingStopInfo(
    val sessionId: String?,
    val durationSeconds: Int?,
    val fileCount: Int?,
    val raw: JsonObject,
)

data class RecordingControlInfo(
    val sessionId: String?,
    val durationSeconds: Int?,
    val raw: JsonObject,
) {
    companion object {
        fun fromAtReply(resp: JsonObject): RecordingControlInfo {
            val data = resp.optJSONObject("data") ?: JSONObject()
            fun string(value: Any?): String? {
                val text = value?.toString()?.trim().orEmpty()
                return text.takeIf { it.isNotEmpty() }
            }
            return RecordingControlInfo(
                sessionId = string(data.opt("session"))
                    ?: string(resp.opt("session"))
                    ?: string(data.opt("session_id"))
                    ?: string(resp.opt("session_id")),
                durationSeconds = data.optIntOrNull("duration")
                    ?: data.optIntOrNull("duration_s")
                    ?: resp.optIntOrNull("duration")
                    ?: resp.optIntOrNull("duration_s"),
                raw = resp,
            )
        }
    }
}

sealed class DownloadEvent {
    data class Started(val sessionId: String, val totalFiles: Int?, val totalBytes: Int?) : DownloadEvent()
    data class FileStarted(val filename: String, val fileSize: Int) : DownloadEvent()
    data class FileProgress(val filename: String, val received: Int, val total: Int) : DownloadEvent()
    data class FileCompleted(val filename: String, val bytes: ByteArray, val crc32: Long) : DownloadEvent()
    data class TransferDone(val sessionId: String, val fileCount: Int) : DownloadEvent()
}

enum class DownloadStartFailureKind {
    SESSION_NOT_FOUND,
    TRANSFER_BUSY,
    OTHER;

    companion object {
        fun fromAtReply(resp: JsonObject): DownloadStartFailureKind {
            val detail = listOf(
                resp.optStringOrNull("error"),
                resp.optStringOrNull("msg"),
                resp.optStringOrNull("message"),
                resp.optJSONObject("data")?.optStringOrNull("msg"),
            ).firstOrNull { !it.isNullOrBlank() }?.lowercase().orEmpty()
            return when {
                detail.contains("session not found") || detail.contains("file not found") || detail.contains("not found") ->
                    SESSION_NOT_FOUND
                detail.contains("transfer already in progress") || detail.contains("already in progress") || detail.contains("busy") ->
                    TRANSFER_BUSY
                else -> OTHER
            }
        }
    }
}

data class DownloadStartRetryPolicy(
    val maxAttempts: Int = 1,
    val retryDelayMs: Long = 800,
    val retrySessionNotFound: Boolean = true,
    val cancelBusyTransfer: Boolean = false,
    val skipCancelWhenDeviceRecording: Boolean = true,
    val cancelTimeoutMs: Long = 5_000,
    val cancelSettleDelayMs: Long = 1_200,
    val statusTimeoutMs: Long = 4_000,
) {
    fun shouldRetry(kind: DownloadStartFailureKind): Boolean = when (kind) {
        DownloadStartFailureKind.SESSION_NOT_FOUND -> retrySessionNotFound
        DownloadStartFailureKind.TRANSFER_BUSY -> cancelBusyTransfer
        DownloadStartFailureKind.OTHER -> false
    }

    companion object {
        fun resilient(): DownloadStartRetryPolicy = DownloadStartRetryPolicy(
            maxAttempts = 4,
            cancelBusyTransfer = true,
        )
    }
}

data class DownloadTransferDone(
    val sessionId: String,
    val fileCount: Int,
)

data class DownloadedFileArtifact(
    val filename: String,
    val file: File,
    val sizeBytes: Int,
    val crc32: Long,
)

data class DownloadSessionResult(
    val sessionId: String,
    val directory: File,
    val totalFiles: Int?,
    val totalBytes: Int?,
    val completedFiles: Int,
    val completedBytes: Int,
    val transferDone: DownloadTransferDone?,
    val files: List<DownloadedFileArtifact>,
) {
    val isComplete: Boolean
        get() = transferDone != null && (totalFiles?.let { completedFiles >= it } ?: true)
}

data class DownloadMergeResult(
    val download: DownloadSessionResult,
    val mergedFile: File,
    val mergedBytes: Int,
    val deletedRemoteSession: Boolean,
    val deletedLocalParts: Boolean,
)

data class DownloadFinalizeResult(
    val merge: DownloadMergeResult,
    val bookmarks: List<DeviceBookmarkMeta>,
    val bookmarksFile: File?,
    val bookmarksSaved: Boolean,
)

class RecordingSession(
    val connection: SenseCraftVoiceConnection,
    val at: AtTransport,
) {
    private var activeSessionId: String? = null
    private var lastDeviceTimeSyncAt: java.util.Date? = null

    val deviceEvents: Flow<DeviceEvent> = at.jsonMessages.mapNotNull(::parseDeviceEvent)

    suspend fun start(mode: RecordingMode = RecordingMode.NORMAL, timeoutMs: Long = 5_000): RecordingStartInfo {
        val cmd = if (mode == RecordingMode.ENHANCED) "AT+START=enhanced" else "AT+START"
        val resp = at.send(cmd, timeoutMs)
        if (resp.optBoolean("ok") != true) {
            throw RecordingException("AT+START failed: ${errorDetail(resp)}", resp)
        }
        val sid = extractSession(resp) ?: throw RecordingException("AT+START did not return a session", resp)
        activeSessionId = sid
        return RecordingStartInfo(sid, extractMode(resp) ?: mode, resp)
    }

    suspend fun stop(timeoutMs: Long = 8_000): RecordingStopInfo {
        val resp = at.send("AT+STOP", timeoutMs)
        val sid = extractSession(resp) ?: activeSessionId
        val data = resp.optJSONObject("data") ?: JSONObject()
        activeSessionId = null
        return RecordingStopInfo(
            sessionId = sid,
            durationSeconds = data.optIntOrNull("duration"),
            fileCount = data.optIntOrNull("file_count"),
            raw = resp,
        )
    }

    suspend fun pause(timeoutMs: Long = 5_000): RecordingControlInfo {
        val resp = at.send("AT+PAUSE", timeoutMs)
        ensureSuccess(resp, "AT+PAUSE")
        return RecordingControlInfo.fromAtReply(resp)
    }

    suspend fun resume(timeoutMs: Long = 5_000): RecordingControlInfo {
        val resp = at.send("AT+RESUME", timeoutMs)
        ensureSuccess(resp, "AT+RESUME")
        return RecordingControlInfo.fromAtReply(resp)
    }

    suspend fun setRecordingMode(mode: RecordingMode, timeoutMs: Long = 4_000): RecordingMode {
        val cmd = if (mode == RecordingMode.ENHANCED) "AT+MODE=enhanced" else "AT+MODE=normal"
        val resp = at.send(cmd, timeoutMs)
        ensureSuccess(resp, "AT+MODE")
        return extractMode(resp) ?: mode
    }

    suspend fun setDeviceTime(date: java.util.Date = java.util.Date(), timeoutMs: Long = 4_000): JsonObject {
        val seconds = (date.time / 1000L).toInt()
        val resp = at.send("AT+TIME=$seconds", timeoutMs)
        ensureSuccess(resp, "AT+TIME")
        return resp
    }

    suspend fun getDeviceTime(timeoutMs: Long = 4_000): DeviceTimeInfo {
        val resp = at.send("AT+TIME?", timeoutMs)
        ensureSuccess(resp, "AT+TIME?")
        return DeviceTimeInfo.fromAtReply(resp)
    }

    suspend fun getPairingStatus(timeoutMs: Long = 6_000): PairingStatus {
        val resp = at.send("AT+PAIR?", timeoutMs)
        ensureSuccess(resp, "AT+PAIR?")
        return PairingStatus.fromAtReply(resp)
    }

    suspend fun resetPairing(timeoutMs: Long = 6_000): JsonObject {
        val resp = at.send("AT+PAIR=reset", timeoutMs)
        ensureSuccess(resp, "AT+PAIR=reset")
        return resp
    }

    suspend fun cancel() {
        try {
            at.send("AT+CANCEL", 4_000)
        } catch (_: Throwable) {
            SdkLog.w("RecordingSession.cancel: AT+CANCEL failed")
        }
        activeSessionId = null
    }

    suspend fun getStatus(timeoutMs: Long = 5_000): DeviceStatus {
        val resp = at.send("AT+GSTAT", timeoutMs)
        if (resp.optBoolean("ok") != true) {
            throw RecordingException("AT+GSTAT failed: ${errorDetail(resp)}", resp)
        }
        return DeviceStatus.fromAtReply(resp)
    }

    suspend fun readRuntimeInfo(
        versionTimeoutMs: Long = 5_000,
        timeTimeoutMs: Long = 4_000,
        statusTimeoutMs: Long = 4_000,
        pairTimeoutMs: Long = 6_000,
    ): DeviceRuntimeInfo = withContext(Dispatchers.IO) {
        var firmware: String? = null
        var rawDeviceTime: Any? = null
        var status: DeviceStatus? = null
        var pairStatus: String? = null
        var pairAddress: String? = null
        var versionReply: JsonObject? = null
        var timeReply: JsonObject? = null
        var statusReply: JsonObject? = null
        var pairReply: JsonObject? = null

        try {
            val resp = at.send("AT+VERSION", versionTimeoutMs)
            versionReply = resp
            if (resp.optBoolean("ok") == true) {
                firmware = extractRootOrDataString(resp, listOf("firmware", "firmware_version", "version"))
            }
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+VERSION failed", e)
        }

        try {
            val resp = at.send("AT+TIME?", timeTimeoutMs)
            timeReply = resp
            if (resp.optBoolean("ok") == true) {
                rawDeviceTime = extractRootOrDataValue(resp, listOf("time", "timestamp", "ts"))
            }
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+TIME? failed", e)
        }

        try {
            val resp = at.send("AT+GSTAT", statusTimeoutMs)
            statusReply = resp
            if (resp.optBoolean("ok") == true) {
                status = DeviceStatus.fromAtReply(resp)
                firmware = firmware ?: status?.firmwareVersion
            }
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+GSTAT failed", e)
        }

        try {
            val resp = at.send("AT+PAIR?", pairTimeoutMs)
            pairReply = resp
            if (resp.optBoolean("ok") == true) {
                pairStatus = extractRootOrDataString(resp, listOf("value", "status", "pair_status", "state"))
                pairAddress = extractRootOrDataString(resp, listOf("addr", "address", "peer", "peer_addr"))
            }
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+PAIR? failed", e)
        }

        DeviceRuntimeInfo(
            firmwareVersion = firmware,
            rawDeviceTime = rawDeviceTime,
            deviceTime = parseTimestamp(rawDeviceTime),
            status = status,
            pairStatus = pairStatus,
            pairAddress = pairAddress,
            versionReply = versionReply,
            timeReply = timeReply,
            statusReply = statusReply,
            pairReply = pairReply,
        )
    }

    suspend fun syncDeviceTime(
        time: java.util.Date? = null,
        timeoutMs: Long = 4_000,
        minIntervalMs: Long = 0,
        force: Boolean = false,
    ): Boolean {
        if (!force && minIntervalMs > 0 && lastDeviceTimeSyncAt != null) {
            val elapsed = System.currentTimeMillis() - lastDeviceTimeSyncAt!!.time
            if (elapsed < minIntervalMs) return false
        }
        return try {
            setDeviceTime(time ?: java.util.Date(), timeoutMs)
            lastDeviceTimeSyncAt = java.util.Date()
            true
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.syncDeviceTime failed", e)
            false
        }
    }

    suspend fun getUserDeviceName(timeoutMs: Long = 5_000): String {
        val resp = at.send("AT+NAME?", timeoutMs)
        if (resp.optBoolean("ok") != true) {
            throw RecordingException("AT+NAME? failed: ${errorDetail(resp)}", resp)
        }
        val data = resp.optJSONObject("data")
        return data?.optStringOrNull("name")
            ?: resp.optStringOrNull("name")
            ?: resp.optStringOrNull("value")
            ?: ""
    }

    suspend fun setUserDeviceName(name: String?, timeoutMs: Long = 5_000) {
        val cmd = when {
            name.isNullOrBlank() -> "AT+NAME=CLEAR"
            !isValidUserDeviceName(name) -> throw RecordingException(
                "AT+NAME requires 1-32 UTF-8 chars without control characters.",
                null
            )
            else -> "AT+NAME=$name"
        }
        val resp = at.send(cmd, timeoutMs)
        if (resp.optBoolean("ok") != true) {
            throw RecordingException("AT+NAME failed: ${errorDetail(resp)}", resp)
        }
    }

    suspend fun mark(
        note: String? = null,
        timeoutMs: Long = 10_000,
    ): DeviceBookmarkMarkResult {
        val trimmed = note?.trim()
        val cmd = if (trimmed.isNullOrEmpty()) {
            "AT+MARK"
        } else {
            "AT+MARK=$trimmed"
        }
        val resp = at.send(cmd, timeoutMs)
        val data = resp.optJSONObject("data") ?: JSONObject()
        return DeviceBookmarkMarkResult(
            ok = resp.optBoolean("ok") == true,
            sessionId = extractRootOrDataString(resp, listOf("session", "session_id")),
            markCount = resp.optIntOrNull("mark_count")
                ?: resp.optIntOrNull("count")
                ?: data.optIntOrNull("mark_count")
                ?: data.optIntOrNull("count"),
            offsetSeconds = resp.optIntOrNull("offset")
                ?: data.optIntOrNull("offset"),
            raw = resp,
        )
    }

    suspend fun listFiles(sessionId: String? = null, timeoutMs: Long = 8_000): List<DeviceFileMeta> {
        val cmd = sessionId?.let { "AT+LIST=$it" } ?: "AT+LIST"
        val resp = at.send(cmd, timeoutMs)
        if (resp.optBoolean("ok") != true) {
            throw RecordingException("AT+LIST failed: ${errorDetail(resp)}", resp)
        }
        return parseDeviceFileList(resp, connection.device.address)
    }

    suspend fun listAllFiles(
        perPage: Int = 10,
        maxPages: Int = 100,
        timeoutMs: Long = 8_000,
    ): List<DeviceFileMeta> = withContext(Dispatchers.IO) {
        val out = ArrayList<DeviceFileMeta>()
        for (page in 1..maxPages.coerceAtLeast(1)) {
            val cmd = if (page == 1) "AT+LIST" else "AT+LIST?$page&$perPage"
            val resp = at.send(cmd, timeoutMs)
            if (resp.optBoolean("ok") != true) {
                throw RecordingException("AT+LIST failed: ${errorDetail(resp)}", resp)
            }
            val items = parseDeviceFileList(resp, connection.device.address)
            out.addAll(items)
            val total = extractListTotal(resp)
            if (items.isEmpty() || (total != null && out.size >= total)) break
        }
        out
    }

    suspend fun listBookmarks(
        sessionId: String,
        timeoutMs: Long = 6_000,
        perPage: Int? = null,
        maxPages: Int = 100,
    ): List<DeviceBookmarkMeta> {
        if (perPage == null || perPage <= 0) {
            val resp = at.send("AT+MARKS=$sessionId", timeoutMs)
            ensureSuccess(resp, "AT+MARKS")
            return parseDeviceBookmarkList(resp, sessionId)
        }

        val out = ArrayList<DeviceBookmarkMeta>()
        val pageLimit = maxPages.coerceAtLeast(1)
        for (page in 1..pageLimit) {
            val resp = at.send("AT+MARKS=$sessionId?$page&$perPage", timeoutMs)
            if (resp.optBoolean("ok") != true && page == 1) {
                val fallback = at.send("AT+MARKS=$sessionId", timeoutMs)
                ensureSuccess(fallback, "AT+MARKS")
                val items = parseDeviceBookmarkList(fallback, sessionId)
                out.addAll(items)
                val total = extractBookmarkTotal(fallback)
                if (items.isEmpty() || (total != null && out.size >= total)) break
                continue
            }
            ensureSuccess(resp, "AT+MARKS")
            val items = parseDeviceBookmarkList(resp, sessionId)
            out.addAll(items)
            val total = extractBookmarkTotal(resp)
            if (items.isEmpty() || (total != null && out.size >= total)) break
        }
        return out
    }

    suspend fun deleteSession(sessionId: String, timeoutMs: Long = 8_000): JsonObject {
        val resp = at.send("AT+DELETE=$sessionId", timeoutMs)
        ensureSuccess(resp, "AT+DELETE")
        return resp
    }

    suspend fun purgeSessions(timeoutMs: Long = 10_000): JsonObject {
        val resp = at.send("AT+PURGE", timeoutMs)
        ensureSuccess(resp, "AT+PURGE")
        return resp
    }

    suspend fun factoryReset(timeoutMs: Long = 10_000): JsonObject {
        val resp = at.send("AT+FACTORY=confirm", timeoutMs)
        ensureSuccess(resp, "AT+FACTORY")
        return resp
    }

    fun download(
        sessionId: String,
        startFile: String? = null,
        timeoutMs: Long = 600_000,
        startCommandTimeoutMs: Long = 10_000,
        retryPolicy: DownloadStartRetryPolicy = DownloadStartRetryPolicy.resilient(),
    ): Flow<DownloadEvent> = channelFlow {
        var currentFile: String? = null
        var currentExpected = 0
        val fileBuf = ByteArrayOutputStream()

        val collectorJob = launch {
            connection.fileDataNotifyBytes().collect { bytes ->
                when (val frame = parseClipFileDataNotify(bytes)) {
                    is ClipFileDataParsed.FileStart -> {
                        currentFile = frame.filename
                        currentExpected = frame.fileSize
                        fileBuf.reset()
                        send(DownloadEvent.FileStarted(frame.filename, frame.fileSize))
                    }
                    is ClipFileDataParsed.Data -> {
                        val file = currentFile ?: return@collect
                        fileBuf.write(frame.payload)
                        send(DownloadEvent.FileProgress(file, fileBuf.size(), currentExpected))
                    }
                    is ClipFileDataParsed.FileEnd -> {
                        val filename = currentFile.orEmpty()
                        send(DownloadEvent.FileCompleted(filename, fileBuf.toByteArray(), frame.crc32))
                        currentFile = null
                        currentExpected = 0
                        fileBuf.reset()
                    }
                    is ClipFileDataParsed.TransferDone -> {
                        send(DownloadEvent.TransferDone(frame.sessionId, frame.fileCount))
                        close()
                    }
                    is ClipFileDataParsed.Raw -> if (currentFile != null) {
                        fileBuf.write(frame.bytes)
                    }
                    is ClipFileDataParsed.Invalid -> {
                        SdkLog.w("RecordingSession.download malformed file frame: ${frame.reason}")
                    }
                }
            }
        }

        val timeoutJob = launch {
            delay(timeoutMs)
            close(CancellationException("Download stalled"))
        }

        try {
            val cmd = if (!startFile.isNullOrBlank()) {
                "AT+DOWNLOAD=$sessionId:${startFile.trim()}"
            } else {
                "AT+DOWNLOAD=$sessionId"
            }
            val resp = sendDownloadStartWithRetry(cmd, startCommandTimeoutMs, retryPolicy)
            if (resp.optBoolean("ok") != true) {
                close(RecordingException("AT+DOWNLOAD failed: ${downloadFailureDetail(resp)}", resp, downloadFailureKind(resp).name))
                return@channelFlow
            }
            val data = resp.optJSONObject("data") ?: JSONObject()
            send(
                DownloadEvent.Started(
                    sessionId = sessionId,
                    totalFiles = data.optIntOrNull("files") ?: data.optIntOrNull("file_count"),
                    totalBytes = data.optIntOrNull("bytes") ?: data.optIntOrNull("size"),
                )
            )
        } catch (e: Throwable) {
            close(e)
        }

        awaitClose {
            collectorJob.cancel()
            timeoutJob.cancel()
        }
    }

    suspend fun downloadToDirectory(
        sessionId: String,
        directory: File,
        startFile: String? = null,
        timeoutMs: Long = 600_000,
        startCommandTimeoutMs: Long = 10_000,
        retryPolicy: DownloadStartRetryPolicy = DownloadStartRetryPolicy.resilient(),
        createDirectory: Boolean = true,
        verifyCrc: Boolean = true,
    ): DownloadSessionResult = withContext(Dispatchers.IO) {
        if (createDirectory && !directory.exists()) {
            directory.mkdirs()
        }

        var totalFiles: Int? = null
        var totalBytes: Int? = null
        var completedFiles = 0
        var completedBytes = 0
        var transferDone: DownloadTransferDone? = null
        val files = ArrayList<DownloadedFileArtifact>()

        download(
            sessionId = sessionId,
            startFile = startFile,
            timeoutMs = timeoutMs,
            startCommandTimeoutMs = startCommandTimeoutMs,
            retryPolicy = retryPolicy,
        ).collect { event ->
            when (event) {
                is DownloadEvent.Started -> {
                    totalFiles = event.totalFiles
                    totalBytes = event.totalBytes
                }
                is DownloadEvent.FileStarted,
                is DownloadEvent.FileProgress -> Unit
                is DownloadEvent.FileCompleted -> {
                    val safe = safeDownloadFilename(event.filename, completedFiles + 1)
                    val output = File(directory, safe)
                    if (verifyCrc) {
                        val localCrc = crc32Ieee(event.bytes)
                        if (localCrc != event.crc32) {
                            output.delete()
                            throw RecordingException(
                                "Downloaded file CRC mismatch for $safe (local=0x${localCrc.toString(16)}, device=0x${event.crc32.toString(16)})",
                                null,
                                "crc_mismatch",
                            )
                        }
                    }
                    output.writeBytes(event.bytes)
                    files += DownloadedFileArtifact(
                        filename = safe,
                        file = output,
                        sizeBytes = event.bytes.size,
                        crc32 = event.crc32,
                    )
                    completedFiles += 1
                    completedBytes += event.bytes.size
                }
                is DownloadEvent.TransferDone -> {
                    transferDone = DownloadTransferDone(event.sessionId, event.fileCount)
                }
            }
        }

        DownloadSessionResult(
            sessionId = sessionId,
            directory = directory,
            totalFiles = totalFiles,
            totalBytes = totalBytes,
            completedFiles = completedFiles,
            completedBytes = completedBytes,
            transferDone = transferDone,
            files = files,
        )
    }

    suspend fun downloadToDirectoryWithResume(
        sessionId: String,
        directory: File,
        startFile: String? = null,
        dbReceivedBytes: Int = 0,
        maxAttempts: Int = 3,
        timeoutMs: Long = 600_000,
        startCommandTimeoutMs: Long = 10_000,
        retryPolicy: DownloadStartRetryPolicy = DownloadStartRetryPolicy.resilient(),
        createDirectory: Boolean = true,
        verifyCrc: Boolean = true,
        retryDelayMs: Long = 600,
    ): DownloadSessionResult {
        require(maxAttempts > 0) { "maxAttempts must be >= 1" }

        var lastResult: DownloadSessionResult? = null
        var lastError: Throwable? = null
        for (attempt in 1..maxAttempts) {
            val resumeStartFile = resolveSessionResumeStartFile(directory, startFile)
            resolveSessionResumeMarkers(
                sessionDirectory = directory,
                startFile = resumeStartFile,
                dbReceivedBytes = dbReceivedBytes,
            )
            try {
                val result = downloadToDirectory(
                    sessionId = sessionId,
                    directory = directory,
                    startFile = resumeStartFile,
                    timeoutMs = timeoutMs,
                    startCommandTimeoutMs = startCommandTimeoutMs,
                    retryPolicy = retryPolicy,
                    createDirectory = createDirectory,
                    verifyCrc = verifyCrc,
                )
                lastResult = result
                if (result.isComplete || attempt == maxAttempts) return result
                lastError = RecordingException("AT+DOWNLOAD finished without TRANSFER_DONE", null, "incomplete")
            } catch (e: Throwable) {
                lastError = e
                if (attempt >= maxAttempts) throw e
            }
            delay(retryDelayMs.coerceAtLeast(0))
            cancel()
        }

        lastResult?.let { return it }
        throw (lastError ?: RecordingException("downloadToDirectoryWithResume failed", null, "internal"))
    }

    suspend fun downloadMergeAndMaybeDeleteSession(
        sessionId: String,
        directory: File,
        startFile: String? = null,
        dbReceivedBytes: Int = 0,
        maxAttempts: Int = 3,
        timeoutMs: Long = 600_000,
        startCommandTimeoutMs: Long = 10_000,
        retryPolicy: DownloadStartRetryPolicy = DownloadStartRetryPolicy.resilient(),
        createDirectory: Boolean = true,
        verifyCrc: Boolean = true,
        retryDelayMs: Long = 600,
        mergedFile: File? = null,
        deleteRemoteSessionAfterMerge: Boolean = false,
        deleteLocalPartsAfterMerge: Boolean = false,
    ): DownloadMergeResult {
        val download = downloadToDirectoryWithResume(
            sessionId = sessionId,
            directory = directory,
            startFile = startFile,
            dbReceivedBytes = dbReceivedBytes,
            maxAttempts = maxAttempts,
            timeoutMs = timeoutMs,
            startCommandTimeoutMs = startCommandTimeoutMs,
            retryPolicy = retryPolicy,
            createDirectory = createDirectory,
            verifyCrc = verifyCrc,
            retryDelayMs = retryDelayMs,
        )
        require(download.isComplete) { "downloadMergeAndMaybeDeleteSession requires a complete download" }

        val target = mergedFile ?: defaultMergedFile(directory, sessionId)
        target.delete()
        val merged = mergeSessionOpusPartsInDirectory(directory, target)
            ?: throw RecordingException("No session parts available to merge for $sessionId", null, "no_parts")

        val mergedBytes = merged.takeIf { it.exists() }?.length()?.toInt() ?: 0
        val deletedRemoteSession = if (deleteRemoteSessionAfterMerge) {
            deleteSessionAfterLocalVerification(
                sessionId = sessionId,
                mergedFile = merged,
                expectedBytes = null,
                verifiedBytes = download.totalBytes ?: mergedBytes,
            )
        } else {
            false
        }
        val deletedLocalParts = if (deleteLocalPartsAfterMerge) {
            deleteLocalSessionParts(directory, merged)
        } else {
            false
        }

        return DownloadMergeResult(
            download = download,
            mergedFile = merged,
            mergedBytes = mergedBytes,
            deletedRemoteSession = deletedRemoteSession,
            deletedLocalParts = deletedLocalParts,
        )
    }

    suspend fun downloadMergeFetchBookmarksAndMaybeDeleteSession(
        sessionId: String,
        directory: File,
        startFile: String? = null,
        dbReceivedBytes: Int = 0,
        maxAttempts: Int = 3,
        timeoutMs: Long = 600_000,
        startCommandTimeoutMs: Long = 10_000,
        retryPolicy: DownloadStartRetryPolicy = DownloadStartRetryPolicy.resilient(),
        createDirectory: Boolean = true,
        verifyCrc: Boolean = true,
        retryDelayMs: Long = 600,
        mergedFile: File? = null,
        deleteRemoteSessionAfterMerge: Boolean = false,
        deleteLocalPartsAfterMerge: Boolean = false,
        saveBookmarksJson: Boolean = true,
        bookmarksFile: File? = null,
        bookmarksTimeoutMs: Long = 6_000,
        bookmarksPerPage: Int = 10,
        bookmarksMaxPages: Int = 100,
    ): DownloadFinalizeResult {
        val download = downloadToDirectoryWithResume(
            sessionId = sessionId,
            directory = directory,
            startFile = startFile,
            dbReceivedBytes = dbReceivedBytes,
            maxAttempts = maxAttempts,
            timeoutMs = timeoutMs,
            startCommandTimeoutMs = startCommandTimeoutMs,
            retryPolicy = retryPolicy,
            createDirectory = createDirectory,
            verifyCrc = verifyCrc,
            retryDelayMs = retryDelayMs,
        )
        require(download.isComplete) { "downloadMergeFetchBookmarksAndMaybeDeleteSession requires a complete download" }

        val target = mergedFile ?: defaultMergedFile(directory, sessionId)
        target.delete()
        val merged = mergeSessionOpusPartsInDirectory(directory, target)
            ?: throw RecordingException("No session parts available to merge for $sessionId", null, "no_parts")

        val mergedBytes = merged.takeIf { it.exists() }?.length()?.toInt() ?: 0
        val bookmarks = try {
            listBookmarks(
                sessionId = sessionId,
                timeoutMs = bookmarksTimeoutMs,
                perPage = bookmarksPerPage,
                maxPages = bookmarksMaxPages,
            )
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession: AT+MARKS failed (non-fatal)", e)
            emptyList()
        }

        var savedBookmarksFile: File? = null
        var bookmarksSaved = false
        if (saveBookmarksJson) {
            val targetFile = bookmarksFile ?: bookmarksSidecarFileForMergedFile(merged)
            try {
                savedBookmarksFile = writeBookmarksJsonSidecar(targetFile, bookmarks)
                bookmarksSaved = true
            } catch (e: Throwable) {
                SdkLog.w("RecordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession: save bookmarks json failed (non-fatal)", e)
            }
        }

        val deletedRemoteSession = if (deleteRemoteSessionAfterMerge) {
            deleteSessionAfterLocalVerification(
                sessionId = sessionId,
                mergedFile = merged,
                expectedBytes = null,
                verifiedBytes = download.totalBytes ?: mergedBytes,
            )
        } else {
            false
        }
        val deletedLocalParts = if (deleteLocalPartsAfterMerge) {
            deleteLocalSessionParts(directory, merged)
        } else {
            false
        }

        return DownloadFinalizeResult(
            merge = DownloadMergeResult(
                download = download,
                mergedFile = merged,
                mergedBytes = mergedBytes,
                deletedRemoteSession = deletedRemoteSession,
                deletedLocalParts = deletedLocalParts,
            ),
            bookmarks = bookmarks,
            bookmarksFile = savedBookmarksFile,
            bookmarksSaved = bookmarksSaved,
        )
    }

    private suspend fun sendDownloadStartWithRetry(
        command: String,
        timeoutMs: Long,
        retryPolicy: DownloadStartRetryPolicy,
    ): JsonObject {
        require(retryPolicy.maxAttempts > 0) { "retryPolicy.maxAttempts must be >= 1" }

        var lastResp: JsonObject? = null
        for (attempt in 1..retryPolicy.maxAttempts) {
            if (attempt > 1) {
                delay(retryPolicy.retryDelayMs.coerceAtLeast(0))
            }

            val resp = at.send(command, timeoutMs)
            lastResp = resp
            if (resp.optBoolean("ok") == true) return resp

            val kind = DownloadStartFailureKind.fromAtReply(resp)
            if (attempt >= retryPolicy.maxAttempts || !retryPolicy.shouldRetry(kind)) {
                return resp
            }

            if (kind == DownloadStartFailureKind.TRANSFER_BUSY) {
                if (retryPolicy.skipCancelWhenDeviceRecording && deviceAppearsRecordingOrPaused(retryPolicy.statusTimeoutMs)) {
                    SdkLog.w("RecordingSession.download: device is recording/paused; skip AT+CANCEL and let caller retry later")
                    return resp
                }
                cancelBusyTransferBeforeRetry(retryPolicy)
            }
        }

        return lastResp ?: JSONObject().put("ok", false).put("error", "no reply")
    }

    private suspend fun deviceAppearsRecordingOrPaused(timeoutMs: Long): Boolean {
        return try {
            val resp = at.send("AT+GSTAT", timeoutMs)
            if (resp.optBoolean("ok") != true) return false
            val status = DeviceStatus.fromAtReply(resp)
            status.isRecording || status.state == "paused"
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.download: GSTAT before busy-cancel failed", e)
            false
        }
    }

    private suspend fun cancelBusyTransferBeforeRetry(policy: DownloadStartRetryPolicy) {
        try {
            SdkLog.w("RecordingSession.download: AT+DOWNLOAD busy; sending AT+CANCEL before retry")
            at.send("AT+CANCEL", policy.cancelTimeoutMs)
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.download: AT+CANCEL before retry failed", e)
        }
        delay(policy.cancelSettleDelayMs.coerceAtLeast(0))
    }

    private fun downloadFailureDetail(resp: JsonObject): String = errorDetail(resp)

    private fun downloadFailureKind(resp: JsonObject): DownloadStartFailureKind =
        DownloadStartFailureKind.fromAtReply(resp)

    private fun safeDownloadFilename(filename: String, fallbackIndex: Int): String {
        val trimmed = filename.trim()
        val name = if (trimmed.isEmpty()) {
            "part_${fallbackIndex.toString().padStart(4, '0')}.opus"
        } else {
            trimmed
        }
        val withExt = if (name.lowercase().endsWith(".opus")) name else "$name.opus"
        return BleTransferFrameHandler.sanitizeFilename(withExt)
    }

    private fun defaultMergedFile(directory: File, sessionId: String): File {
        val safe = BleTransferFrameHandler.sanitizeFilename(sessionId)
        val stem = if (safe.lowercase().endsWith(".opus")) safe else "$safe.opus"
        return File(directory, stem)
    }

    private fun bookmarksSidecarFileForMergedFile(mergedFile: File): File {
        val base = mergedFile.nameWithoutExtension
        return File(mergedFile.parentFile, "${base}_bookmarks.json")
    }

    private fun writeBookmarksJsonSidecar(file: File, bookmarks: List<DeviceBookmarkMeta>): File {
        file.parentFile?.mkdirs()
        val array = JSONArray()
        bookmarks.forEach { array.put(it.toJson()) }
        file.writeText(array.toString(2), Charsets.UTF_8)
        return file
    }

    private fun deleteLocalSessionParts(directory: File, keepFile: File): Boolean {
        val keepPath = keepFile.absoluteFile.normalize().path
        val entries = directory.listFiles()?.toList().orEmpty()
        var deletedAny = false
        for (entry in entries) {
            val lower = entry.name.lowercase()
            if (!lower.endsWith(".opus") && !lower.endsWith(".opus.part")) continue
            if (entry.absoluteFile.normalize().path == keepPath) continue
            try {
                if (entry.delete()) deletedAny = true
            } catch (e: Throwable) {
                SdkLog.w("RecordingSession.deleteLocalSessionParts failed", e)
            }
        }
        return deletedAny
    }

    private fun sessionRoot(sessionId: String?): String {
        val trimmed = sessionId?.trim().orEmpty()
        if (trimmed.isEmpty()) return ""
        return trimmed.substringBefore("/")
    }

    suspend fun deleteSessionAfterLocalVerification(
        sessionId: String,
        mergedFile: File,
        expectedBytes: Int? = null,
        verifiedBytes: Int? = null,
        timeoutMs: Long = 8_000,
        statusTimeoutMs: Long = 5_000,
        minCompletionRatio: Double = 0.95,
    ): Boolean {
        return try {
            val actualSize = if (mergedFile.exists()) mergedFile.length() else 0L
            val canonicalExpected = canonicalTransferExpectedBytes(expectedBytes, verifiedBytes ?: 0)
            val sizeOk = localMergedFileCompleteForDelete(
                actualSize = actualSize,
                expectedBytes = canonicalExpected,
                verifiedBytes = verifiedBytes,
                minCompletionRatio = minCompletionRatio,
            )
            if (!(mergedFile.exists() && sizeOk && actualSize > 0)) return false

            val status = getStatus(statusTimeoutMs)
            val activeRoot = sessionRoot(status.sessionId)
            val ourRoot = sessionRoot(sessionId)
            if ((status.isRecording || status.state == "paused") && activeRoot.isNotEmpty() && activeRoot == ourRoot) {
                return false
            }

            deleteSession(sessionId, timeoutMs).optBoolean("ok") == true
        } catch (e: Throwable) {
            SdkLog.w("RecordingSession.deleteSessionAfterLocalVerification failed", e)
            false
        }
    }

    private fun errorDetail(resp: JsonObject): String {
        return resp.optStringOrNull("error")
            ?: resp.optStringOrNull("msg")
            ?: resp.optStringOrNull("message")
            ?: resp.optJSONObject("data")?.optStringOrNull("msg")
            ?: resp.toString()
    }

    private fun extractSession(resp: JsonObject): String? {
        return resp.optStringOrNull("session")
            ?: resp.optJSONObject("data")?.optStringOrNull("session")
    }

    private fun extractMode(resp: JsonObject): RecordingMode? {
        val mode = resp.optJSONObject("data")?.optStringOrNull("mode")?.lowercase().orEmpty()
        if (mode.isEmpty()) return null
        return if (mode == "enhanced" || mode == "1") RecordingMode.ENHANCED else RecordingMode.NORMAL
    }

    private fun parseDeviceBookmarkList(resp: JsonObject, defaultSessionId: String? = null): List<DeviceBookmarkMeta> {
        val data = resp.optJSONObject("data") ?: return emptyList()
        val items = when {
            data.has("items") -> data.optJSONArray("items")
            data.has("bookmarks") -> data.optJSONArray("bookmarks")
            data.has("marks") -> data.optJSONArray("marks")
            else -> null
        } ?: return emptyList()
        val out = ArrayList<DeviceBookmarkMeta>(items.length())
        for (i in 0 until items.length()) {
            val raw = items.optJSONObject(i) ?: continue
            out += DeviceBookmarkMeta.fromJson(raw, defaultSessionId)
        }
        return out
    }

    private fun ensureSuccess(resp: JsonObject, command: String) {
        if (resp.optBoolean("ok") != true) {
            throw RecordingException("$command failed: ${errorDetail(resp)}", resp)
        }
    }

    private fun extractRootOrDataValue(resp: JsonObject, keys: List<String>): Any? {
        val data = resp.optJSONObject("data") ?: JSONObject()
        for (key in keys) {
            if (data.has(key) && !data.isNull(key)) return data.opt(key)
            if (resp.has(key) && !resp.isNull(key)) return resp.opt(key)
        }
        return null
    }

    private fun extractRootOrDataString(resp: JsonObject, keys: List<String>): String? {
        return extractRootOrDataValue(resp, keys)?.toString()?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun extractListTotal(resp: JsonObject): Int? {
        val data = resp.optJSONObject("data") ?: JSONObject()
        return data.optIntOrNull("total")
            ?: resp.optIntOrNull("total")
            ?: data.optIntOrNull("count")
            ?: resp.optIntOrNull("count")
            ?: data.optIntOrNull("files")
            ?: resp.optIntOrNull("files")
    }

    private fun extractBookmarkTotal(resp: JsonObject): Int? {
        val data = resp.optJSONObject("data") ?: JSONObject()
        return data.optIntOrNull("total")
            ?: resp.optIntOrNull("total")
            ?: data.optIntOrNull("count")
            ?: resp.optIntOrNull("count")
    }

    companion object {
        const val userDeviceNameMaxBytes = 32
        const val userDeviceNameClearToken = "CLEAR"

        fun isValidUserDeviceName(name: String): Boolean {
            if (name.isEmpty()) return false
            if (name.toByteArray(Charsets.UTF_8).size > userDeviceNameMaxBytes) return false
            return name.all { it.code >= 0x20 }
        }
    }
}

class RecordingException(
    override val message: String,
    val raw: JsonObject?,
    val code: String? = null,
) : Exception(message)
