package io.sensecraft.voice.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

object SenseCraftVoicePermissions {
    fun requiredPermissions(includeWifi: Boolean = true): Array<String> {
        val perms = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            perms += Manifest.permission.BLUETOOTH_SCAN
            perms += Manifest.permission.BLUETOOTH_CONNECT
        } else {
            perms += Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (includeWifi) {
            if (Build.VERSION.SDK_INT >= 33) {
                perms += Manifest.permission.NEARBY_WIFI_DEVICES
            } else {
                // Wi-Fi scan/join APIs require location through Android 12L.
                perms += Manifest.permission.ACCESS_FINE_LOCATION
            }
            perms += Manifest.permission.ACCESS_WIFI_STATE
            perms += Manifest.permission.CHANGE_WIFI_STATE
            perms += Manifest.permission.ACCESS_NETWORK_STATE
            perms += Manifest.permission.CHANGE_NETWORK_STATE
            perms += Manifest.permission.INTERNET
        }
        return perms.distinct().toTypedArray()
    }

    fun hasPermissions(context: Context, includeWifi: Boolean = true): Boolean {
        return requiredPermissions(includeWifi).all {
            context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
    }
}

