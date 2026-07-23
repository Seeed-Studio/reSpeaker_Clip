package io.sensecraft.voice.android

import java.net.SocketException

object WifiNetworkErrors {
    private val wifiUdpStackMarkers = listOf(
        "udp_sync_client",
        "transfer_client",
        "wifi_transfer_controller",
        "hotspot_connector",
        "fast_sync_session",
        "ClipUdpSyncClient",
        "WifiTransferClient",
        "wifiStillReachable",
        "wifiReachabilityProbe",
        "wifiDownloadAndMergeOneItem",
    )

    fun isDeviceApNetworkUnreachable(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            if (current is SocketException) {
                val code = current.message?.lowercase().orEmpty()
                if (code.contains("network is unreachable") ||
                    code.contains("network is down") ||
                    code.contains("no route to host") ||
                    code.contains("host is down") ||
                    code.contains("machine is not on the network")
                ) {
                    return true
                }
            }
            current = current.cause
        }

        val s = error.toString().lowercase()
        return s.contains("network is unreachable") ||
            s.contains("network is down") ||
            s.contains("machine is not on the network") ||
            s.contains("errno = 101") ||
            s.contains("errno = 100") ||
            s.contains("errno = 64")
    }

    /** errno 9 / 49-class local socket races during Wi‑Fi AP UDP. */
    fun isWifiUdpTransientSocketError(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            val msg = current.toString().lowercase()
            if (msg.contains("bad file descriptor") ||
                msg.contains("can't assign requested address") ||
                msg.contains("cannot assign requested address") ||
                msg.contains("errno = 9") ||
                msg.contains("errno = 49") ||
                msg.contains("errno = 99") ||
                msg.contains("errno = 10049")
            ) {
                return true
            }
            current = current.cause
        }
        return false
    }

    fun isWifiApReachabilitySocketNoise(
        error: Throwable,
        stackTrace: String? = null,
    ): Boolean {
        if (!isDeviceApNetworkUnreachable(error) &&
            !isWifiUdpTransientSocketError(error)
        ) {
            return false
        }
        if (stackTrace.isNullOrEmpty()) {
            return error is SocketException ||
                error.toString().contains("SocketException")
        }
        return wifiUdpStackMarkers.any { stackTrace.contains(it) }
    }
}

fun isDeviceApNetworkUnreachable(error: Throwable): Boolean =
    WifiNetworkErrors.isDeviceApNetworkUnreachable(error)

fun isWifiUdpTransientSocketError(error: Throwable): Boolean =
    WifiNetworkErrors.isWifiUdpTransientSocketError(error)

fun isWifiApReachabilitySocketNoise(
    error: Throwable,
    stackTrace: String? = null,
): Boolean = WifiNetworkErrors.isWifiApReachabilitySocketNoise(error, stackTrace)
