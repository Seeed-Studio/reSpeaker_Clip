package cc.seeed.voice

import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
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
