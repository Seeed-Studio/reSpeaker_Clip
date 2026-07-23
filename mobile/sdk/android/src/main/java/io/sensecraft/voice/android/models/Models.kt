package io.sensecraft.voice.android

import java.util.Date
import java.text.SimpleDateFormat
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

enum class RecordingMode { NORMAL, ENHANCED }

data class Device(
    val id: String,
    var name: String,
    var sn: String? = null,
    var model: String,
    var batteryPercent: Int? = null,
    var recordingMode: RecordingMode = RecordingMode.NORMAL,
    var firmwareVersion: String? = null,
    var hasFirmwareUpdate: Boolean = false,
    var isOnline: Boolean,
    var lastSeen: Date? = null,
    val createdAt: Date = Date(),
    val updatedAt: Date = Date(),
)

data class DeviceFileMeta(
    val deviceId: String,
    val path: String,
    val name: String,
    val sizeBytes: Int,
    val durationSeconds: Int,
    val bookmarkCount: Int,
    val createdAt: Date?,
) {
    val recordingId: String get() = "${deviceId}_$path"
}

data class WifiHotspotInfo(
    val enabled: Boolean,
    val ssid: String,
    val password: String,
    val ip: String,
    val port: Int,
    val channel: Int? = null,
) {
    val baseUrl: String get() = "http://$ip:$port"
    val isValid: Boolean get() = ssid.isNotEmpty() && password.isNotEmpty() && ip.isNotEmpty()

    companion object {
        fun fromAtReply(resp: JsonObject): WifiHotspotInfo {
            val data = resp.optJSONObject("data") ?: resp
            val enabled = data.optBoolOrNull("enabled") == true ||
                data.optBoolOrNull("running") == true ||
                data.optBoolOrNull("ap_running") == true
            var ip = data.optStringOrNull("ip") ?: "192.168.4.1"
            if (ip.isEmpty() || ip == "0.0.0.0" || ip == "::" || ip == "::0") {
                ip = "192.168.4.1"
            }
            val port = data.optIntOrNull("port")?.takeIf { it > 0 } ?: 8089
            return WifiHotspotInfo(
                enabled = enabled,
                ssid = data.optStringOrNull("ssid") ?: "",
                password = data.optStringOrNull("password") ?: "",
                ip = ip,
                port = port,
                channel = data.optIntOrNull("channel"),
            )
        }
    }
}

data class DeviceBookmarkMeta(
    val sessionId: String?,
    val markCount: Int?,
    val offsetSeconds: Int?,
    val note: String?,
    val raw: JsonObject,
) {
    fun toJson(): JsonObject {
        val out = JSONObject(raw.toString())
        sessionId?.let { out.put("session", it) }
        markCount?.let { out.put("mark_count", it) }
        offsetSeconds?.let { out.put("offset", it) }
        note?.let { out.put("note", it) }
        return out
    }

    companion object {
        fun fromJson(raw: JsonObject, defaultSessionId: String? = null): DeviceBookmarkMeta {
            val data = raw.optJSONObject("data") ?: JSONObject()
            return DeviceBookmarkMeta(
                sessionId = raw.optStringOrNull("session")
                    ?: data.optStringOrNull("session")
                    ?: defaultSessionId,
                markCount = raw.optIntOrNull("mark_count")
                    ?: raw.optIntOrNull("count")
                    ?: raw.optIntOrNull("marks")
                    ?: raw.optIntOrNull("bookmarks")
                    ?: data.optIntOrNull("mark_count")
                    ?: data.optIntOrNull("count")
                    ?: data.optIntOrNull("marks")
                    ?: data.optIntOrNull("bookmarks"),
                offsetSeconds = raw.optIntOrNull("offset")
                    ?: raw.optIntOrNull("offset_sec")
                    ?: data.optIntOrNull("offset")
                    ?: data.optIntOrNull("offset_sec"),
                note = raw.optStringOrNull("note")
                    ?: data.optStringOrNull("note"),
                raw = raw,
            )
        }
    }
}

data class DeviceTimeInfo(
    val unixSeconds: Int?,
    val date: Date?,
    val raw: JsonObject,
) {
    companion object {
        fun fromAtReply(resp: JsonObject): DeviceTimeInfo {
            val data = resp.optJSONObject("data") ?: JSONObject()
            val rawValue = firstNonNull(
                resp.opt("time"), resp.opt("timestamp"), resp.opt("ts"), resp.opt("unix"), resp.opt("seconds"),
                data.opt("time"), data.opt("timestamp"), data.opt("ts"), data.opt("unix"), data.opt("seconds"),
            )
            val seconds = rawValue?.let { optIntValue(it) }
            val date = seconds?.let { Date(it.toLong() * 1000L) }
            return DeviceTimeInfo(seconds, date, resp)
        }
    }
}

data class PairingStatus(
    val isPaired: Boolean?,
    val state: String?,
    val raw: JsonObject,
) {
    companion object {
        fun fromAtReply(resp: JsonObject): PairingStatus {
            val data = resp.optJSONObject("data") ?: JSONObject()
            val state = resp.optStringOrNull("state")
                ?: resp.optStringOrNull("status")
                ?: data.optStringOrNull("state")
                ?: data.optStringOrNull("status")
            val paired = resp.optBoolOrNull("paired")
                ?: resp.optBoolOrNull("bonded")
                ?: resp.optBoolOrNull("connected")
                ?: data.optBoolOrNull("paired")
                ?: data.optBoolOrNull("bonded")
                ?: data.optBoolOrNull("connected")
                ?: state?.lowercase()?.let {
                    it == "paired" || it == "bonded" || it == "connected" || it == "ok"
                }
            return PairingStatus(paired, state, resp)
        }
    }
}

data class DeviceStatus(
    val state: String,
    val isRecording: Boolean,
    val sessionId: String?,
    val batteryPercent: Int?,
    val isCharging: Boolean?,
    val freeSpaceBytes: Int?,
    val bitrate: Int?,
    val recordingMode: RecordingMode?,
    val recordingSeconds: Int?,
    val firmwareVersion: String?,
    val raw: JsonObject,
) {
    companion object {
        fun fromAtReply(resp: JsonObject): DeviceStatus {
            val data = resp.optJSONObject("data") ?: JSONObject()
            val state = data.optStringOrNull("state").orEmpty().lowercase()
            val isRecording = when (val rawRecording = data.opt("recording")) {
                is Boolean -> rawRecording
                is Number -> rawRecording.toInt() != 0
                is String -> when (rawRecording.trim().lowercase()) {
                    "true", "1", "yes" -> true
                    "false", "0", "no" -> false
                    else -> state == "recording"
                }
                else -> state == "recording"
            }
            return DeviceStatus(
                state = state,
                isRecording = isRecording,
                sessionId = data.optStringOrNull("session"),
                batteryPercent = data.optIntOrNull("battery"),
                isCharging = data.optBoolOrNull("charging"),
                freeSpaceBytes = data.optIntOrNull("free_space"),
                bitrate = data.optIntOrNull("bitrate"),
                recordingMode = parseMode(data.opt("mode")),
                recordingSeconds = data.optIntOrNull("duration"),
                firmwareVersion = data.optStringOrNull("version") ?: data.optStringOrNull("firmware_version"),
                raw = data,
            )
        }

        private fun parseMode(value: Any?): RecordingMode? {
            val s = value?.toString()?.trim()?.lowercase().orEmpty()
            if (s.isEmpty()) return null
            return if (s == "enhanced" || s == "1") RecordingMode.ENHANCED else RecordingMode.NORMAL
        }
    }
}

data class DeviceRuntimeInfo(
    val firmwareVersion: String?,
    val rawDeviceTime: Any?,
    val deviceTime: Date?,
    val status: DeviceStatus?,
    val pairStatus: String?,
    val pairAddress: String?,
    val versionReply: JsonObject?,
    val timeReply: JsonObject?,
    val statusReply: JsonObject?,
    val pairReply: JsonObject?,
) {
    val state: String? get() = status?.state
    val isRecording: Boolean? get() = status?.isRecording
    val sessionId: String? get() = status?.sessionId
    val batteryPercent: Int? get() = status?.batteryPercent
    val formattedDeviceTime: String? get() = deviceTime?.let {
        val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).apply {
            timeZone = java.util.TimeZone.getDefault()
        }
        fmt.format(it)
    }
    val hasAnyData: Boolean get() =
        firmwareVersion != null ||
            rawDeviceTime != null ||
            status != null ||
            pairStatus != null ||
            pairAddress != null
}

data class DeviceBookmarkMarkResult(
    val ok: Boolean,
    val sessionId: String?,
    val markCount: Int?,
    val offsetSeconds: Int?,
    val raw: JsonObject,
)

enum class DeviceRecordingState {
    IDLE,
    RECORDING,
    PAUSED,
    TRANSMITTING,
    WIFI_SYNC,
    ERROR,
    UNKNOWN;

    companion object {
        fun parse(raw: Any?): DeviceRecordingState {
            val s = raw?.toString()?.trim()?.lowercase().orEmpty()
            return when (s) {
                "idle" -> IDLE
                "rec", "recording" -> RECORDING
                "paused", "pause" -> PAUSED
                "transmitting", "transfer", "transferring", "transfering" -> TRANSMITTING
                "wifi_sync", "wifi-sync", "wifisync" -> WIFI_SYNC
                "error", "err", "fault" -> ERROR
                else -> UNKNOWN
            }
        }
    }
}

sealed class DeviceEvent(open val raw: JsonObject) {
    data class RecordingState(
        val state: DeviceRecordingState,
        val sessionId: String?,
        val durationSeconds: Int?,
        val mode: RecordingMode?,
        override val raw: JsonObject,
    ) : DeviceEvent(raw)

    data class Bookmark(
        val sessionId: String?,
        val markCount: Int?,
        val offsetSeconds: Int?,
        val note: String?,
        override val raw: JsonObject,
    ) : DeviceEvent(raw)

    data class BatteryLow(val level: Int?, override val raw: JsonObject) : DeviceEvent(raw)
    data class StorageLow(val freeMb: Int?, override val raw: JsonObject) : DeviceEvent(raw)
    data class Error(val code: Int?, val message: String?, override val raw: JsonObject) : DeviceEvent(raw)
    data class Connected(val address: String?, override val raw: JsonObject) : DeviceEvent(raw)
    data class Disconnected(val reason: String?, override val raw: JsonObject) : DeviceEvent(raw)
    data class Unknown(val name: String, override val raw: JsonObject) : DeviceEvent(raw)
}

fun parseDeviceEvent(msg: JsonObject): DeviceEvent? {
    val data = msg.optJSONObject("data") ?: JSONObject()
    val eventName = msg.optStringOrNull("event") ?: data.optStringOrNull("event") ?: return null

    fun readString(key: String): String? =
        msg.optStringOrNull(key) ?: data.optStringOrNull(key)

    fun readInt(key: String): Int? =
        msg.optIntOrNull(key) ?: data.optIntOrNull(key)

    return when (eventName.lowercase()) {
        "state", "state_change" -> DeviceEvent.RecordingState(
            state = DeviceRecordingState.parse(msg.opt("state") ?: data.opt("state") ?: msg.opt("new") ?: data.opt("new")),
            sessionId = readString("session") ?: readString("session_id"),
            durationSeconds = readInt("duration") ?: readInt("duration_s"),
            mode = when (val raw = msg.opt("mode") ?: data.opt("mode")) {
                null -> null
                else -> {
                    val s = raw.toString().trim().lowercase()
                    if (s == "enhanced" || s == "1") RecordingMode.ENHANCED else RecordingMode.NORMAL
                }
            },
            raw = msg,
        )
        "mark", "bookmark" -> DeviceEvent.Bookmark(
            sessionId = readString("session") ?: readString("session_id"),
            markCount = readInt("mark_count") ?: readInt("count") ?: readInt("marks") ?: readInt("bookmarks"),
            offsetSeconds = readInt("offset") ?: readInt("offset_sec"),
            note = readString("note"),
            raw = msg,
        )
        "battery_low", "low_battery" -> DeviceEvent.BatteryLow(
            level = readInt("level") ?: readInt("battery"),
            raw = msg,
        )
        "storage_low", "low_storage" -> DeviceEvent.StorageLow(
            freeMb = readInt("free_mb") ?: readInt("free"),
            raw = msg,
        )
        "error" -> DeviceEvent.Error(
            code = readInt("code") ?: readInt("error_code"),
            message = readString("error") ?: readString("message") ?: readString("msg"),
            raw = msg,
        )
        "connected" -> DeviceEvent.Connected(
            address = readString("addr") ?: readString("address"),
            raw = msg,
        )
        "disconnected" -> DeviceEvent.Disconnected(
            reason = readString("reason"),
            raw = msg,
        )
        else -> DeviceEvent.Unknown(eventName.lowercase(), msg)
    }
}

fun parseDeviceFileList(resp: JsonObject, deviceId: String): List<DeviceFileMeta> {
    val data = resp.optJSONObject("data") ?: return emptyList()
    val items = when {
        data.has("items") -> data.optJSONArray("items")
        data.has("files") -> data.optJSONArray("files")
        else -> null
    } ?: return emptyList()
    val out = ArrayList<DeviceFileMeta>(items.length())
    for (i in 0 until items.length()) {
        val raw = items.optJSONObject(i) ?: continue
        val path = raw.optStringOrNull("path") ?: raw.optStringOrNull("file") ?: continue
        out += DeviceFileMeta(
            deviceId = deviceId,
            path = path,
            name = raw.optStringOrNull("name") ?: path.substringAfterLast('/'),
            sizeBytes = raw.optIntOrNull("size") ?: raw.optIntOrNull("bytes") ?: 0,
            durationSeconds = raw.optIntOrNull("duration") ?: 0,
            bookmarkCount = raw.optIntOrNull("bookmark_count") ?: raw.optIntOrNull("bookmarks") ?: 0,
            createdAt = parseTimestamp(raw.opt("created_at") ?: raw.opt("mtime"))
        )
    }
    return out
}

internal fun parseTimestamp(value: Any?): java.util.Date? {
    return when (value) {
        is Int -> java.util.Date(if (value > 4_102_444_800) value.toLong() else value.toLong() * 1000)
        is Long -> java.util.Date(if (value > 4_102_444_800L) value else value * 1000L)
        is Number -> java.util.Date(if (value.toLong() > 4_102_444_800L) value.toLong() else value.toLong() * 1000L)
        is String -> value.trim().let {
            it.toLongOrNull()?.let { n ->
                java.util.Date(if (n > 4_102_444_800L) n else n * 1000L)
            } ?: parseIsoTimestamp(it)
        }
        else -> null
    }
}

private fun parseIsoTimestamp(value: String): Date? {
    val patterns = listOf(
        "yyyy-MM-dd'T'HH:mm:ss.SSSX",
        "yyyy-MM-dd'T'HH:mm:ssX",
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
    )
    for (pattern in patterns) {
        val format = SimpleDateFormat(pattern, Locale.US).apply {
            isLenient = true
            timeZone = java.util.TimeZone.getTimeZone("UTC")
        }
        try {
            return format.parse(value)
        } catch (_: Throwable) {
        }
    }
    return null
}

private fun firstNonNull(vararg values: Any?): Any? {
    for (value in values) {
        if (value != null) return value
    }
    return null
}

private fun optIntValue(value: Any?): Int? {
    return when (value) {
        is Int -> value
        is Long -> value.toInt()
        is Double -> value.toInt()
        is Number -> value.toInt()
        is String -> value.trim().toIntOrNull()
        else -> value?.toString()?.trim()?.toIntOrNull()
    }
}
