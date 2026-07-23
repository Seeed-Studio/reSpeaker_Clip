package io.sensecraft.voice.android

import android.content.Context

object SenseCraftVoiceBlePermissions {
    fun requiredPermissions(includeWifi: Boolean = false): Array<String> {
        return SenseCraftVoicePermissions.requiredPermissions(includeWifi = includeWifi)
    }

    fun hasPermissions(context: Context, includeWifi: Boolean = false): Boolean {
        return SenseCraftVoicePermissions.hasPermissions(context, includeWifi = includeWifi)
    }

    fun ensureGranted(context: Context, includeWifi: Boolean = false): Boolean {
        return hasPermissions(context, includeWifi = includeWifi)
    }
}
