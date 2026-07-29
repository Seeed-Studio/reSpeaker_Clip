package cc.seeed.voice

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    // Wi‑Fi network monitor: streams onAvailable/onLost to Flutter so the Fast
    // Sync controller can re-bind to the (no-internet) device AP immediately when
    // an OEM ROM tears down / switches the Wi‑Fi mid-transfer.
    private var wifiEventSink: EventChannel.EventSink? = null
    private var wifiNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cc.seeed.voice/oauth_ui")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bringToFront" -> {
                        bringAppTaskToForeground()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cc.seeed.voice/config")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Huawei/Honor: ExoPlayer often mis-handles Ogg Opus; Flutter skips remux and decodes to WAV
                    "shouldSkipOggOpusPlayback" -> {
                        val m = Build.MANUFACTURER.lowercase(Locale.US)
                        val b = Build.BRAND.lowercase(Locale.US)
                        val model = Build.MODEL.lowercase(Locale.US)
                        val fp = Build.FINGERPRINT.lowercase(Locale.US)
                        val skip = m.contains("huawei") ||
                            m.contains("honor") ||
                            b.contains("huawei") ||
                            b.contains("honor") ||
                            model.contains("huawei") ||
                            fp.contains("huawei") ||
                            fp.contains("/honor/")
                        result.success(skip)
                    }

                    else -> result.notImplemented()
                }
            }

        // Wi‑Fi network events (onAvailable / onLost) for event-driven re-bind.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "cc.seeed.voice/wifi_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    wifiEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    wifiEventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cc.seeed.voice/wifi_monitor")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startWifiNetworkMonitor()
                        result.success(acquireWifiPerformanceLock())
                    }
                    "stop" -> {
                        stopWifiNetworkMonitor()
                        releaseWifiPerformanceLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Share file via system chooser; on Huawei/Honor use OEM chooser to avoid direct-share errors
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cc.seeed.voice/share")
            .setMethodCallHandler { call, result ->
                if (call.method == "shareFile") {
                    val path = call.argument<String>("path") ?: run {
                        result.error("INVALID_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        shareFile(path)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message ?: "Share failed", null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * Register a [ConnectivityManager.NetworkCallback] for Wi‑Fi so Flutter is
     * notified the instant a Wi‑Fi network becomes available or is lost. Used by
     * Fast Sync to re-bind to the device AP faster than its periodic poll.
     */
    private fun startWifiNetworkMonitor() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        stopWifiNetworkMonitor()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                emitWifiEvent("available")
            }

            override fun onLost(network: Network) {
                emitWifiEvent("lost")
            }
        }
        wifiNetworkCallback = cb
        try {
            cm.registerNetworkCallback(request, cb)
        } catch (_: Exception) {
            wifiNetworkCallback = null
        }
    }

    private fun stopWifiNetworkMonitor() {
        val cb = wifiNetworkCallback ?: return
        wifiNetworkCallback = null
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            cm?.unregisterNetworkCallback(cb)
        } catch (_: Exception) {
        }
    }

    private fun emitWifiEvent(event: String) {
        mainHandler.post {
            val sink = wifiEventSink ?: return@post
            sink.success(hashMapOf<String, Any?>("event" to event))
        }
    }

    /**
     * Hold a Wi‑Fi lock for the duration of a Fast Sync transfer.
     *
     * The device AP has no internet, so the phone treats the link as idle and
     * lets the radio drop into power save between our UDP bursts. The AP then
     * has to buffer unicast DATA frames for a sleeping station, and on some
     * OEM ROMs those frames are silently dropped — which looks like UDP loss
     * with a full-strength signal.
     *
     * Returns a short status string for the Flutter log. Note that `isHeld`
     * only proves we hold *a* lock: LOW_LATENCY is silently downgraded by the
     * framework when the app is not foreground with the screen on, and that is
     * indistinguishable from success here.
     */
    private fun acquireWifiPerformanceLock(): String {
        if (wifiLock != null) return "already-held"
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return "unavailable(no WifiManager)"
        // API 34 redirects HIGH_PERF to LOW_LATENCY anyway; ask for it directly where available.
        val useLowLatency = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        val mode = if (useLowLatency) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        val modeName = if (useLowLatency) "FULL_LOW_LATENCY" else "FULL_HIGH_PERF"
        return try {
            val lock = wm.createWifiLock(mode, "respeaker:fast-sync").apply {
                setReferenceCounted(false)
                acquire()
            }
            wifiLock = lock
            "$modeName held=${lock.isHeld}"
        } catch (e: Exception) {
            wifiLock = null
            "failed($modeName): ${e.message}"
        }
    }

    private fun releaseWifiPerformanceLock() {
        val lock = wifiLock ?: return
        wifiLock = null
        try {
            if (lock.isHeld) lock.release()
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        stopWifiNetworkMonitor()
        releaseWifiPerformanceLock()
        super.onDestroy()
    }

    /**
     * Bring the app UI to the foreground after OAuth in an external browser task.
     * [ActivityManager.moveTaskToFront] alone is not enough on some Huawei/Honor ROMs.
     */
    private fun bringAppTaskToForeground() {
        try {
            val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                am.moveTaskToFront(taskId, ActivityManager.MOVE_TASK_NO_USER_ACTION)
            } else {
                @Suppress("DEPRECATION")
                am.moveTaskToFront(taskId, 0)
            }
        } catch (_: Exception) {
            // Fall through to startActivity.
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
            )
        }
        startActivity(intent)
    }

    private fun shareFile(filePath: String) {
        val file = File(filePath)
        if (!file.exists()) throw IllegalArgumentException("File not found: $filePath")
        val authority = "${applicationContext.packageName}.fileprovider"
        val uri: Uri = FileProvider.getUriForFile(applicationContext, authority, file)
        val mimeType = mimeTypeForPath(filePath)
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            // Do not combine EXTRA_TEXT with EXTRA_STREAM: Huawei/Honor saves
            // the caption as a separate tiny text file.
        }
        val chooserIntent = Intent.createChooser(sendIntent, null).apply {
            getAvailableOemChooser()?.let { action = it.action }
        }
        startActivity(chooserIntent)
    }

    private fun mimeTypeForPath(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        // Use before MimeTypeMap: API 29+ often maps opus -> audio/opus; many players expect Ogg container (RFC 7845).
        if (ext == "opus") return "audio/ogg"
        val fromMap = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        if (!fromMap.isNullOrBlank()) return fromMap
        return when (ext) {
            "caf" -> "audio/x-caf"
            "wav" -> "audio/wav"
            "mp3" -> "audio/mpeg"
            "txt" -> "text/plain"
            "md" -> "text/markdown"
            "pdf" -> "application/pdf"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            else -> "application/octet-stream"
        }
    }

    private enum class OemChooser(val action: String, val packageName: String) {
        HUAWEI("com.huawei.intent.action.hwCHOOSER", "com.huawei.android.internal.app"),
        HIHONOR("com.hihonor.intent.action.hwCHOOSER", "com.hihonor.android.internal.app")
    }

    private fun getAvailableOemChooser(): OemChooser? =
        OemChooser.values().firstOrNull {
            val resolveInfo = applicationContext.packageManager.resolveActivity(
                Intent(it.action),
                PackageManager.MATCH_DEFAULT_ONLY
            )
            resolveInfo?.activityInfo?.packageName == it.packageName
        }
}
