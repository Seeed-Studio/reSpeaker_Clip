import Foundation
import Darwin

public enum WifiNetworkErrors {
    private static let wifiUdpStackMarkers = [
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
    ]

    public static func isDeviceApNetworkUnreachable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            let unreachableCodes: Set<Int> = [
                Int(ENETDOWN),
                Int(ENETUNREACH),
                Int(EHOSTUNREACH),
                Int(ENOTCONN),
            ]
            if unreachableCodes.contains(nsError.code) { return true }
        }

        let message = "\(error) \(nsError.localizedDescription)".lowercased()
        return message.contains("network is unreachable") ||
            message.contains("network is down") ||
            message.contains("no route to host") ||
            message.contains("host is down") ||
            message.contains("machine is not on the network") ||
            message.contains("errno = 101") ||
            message.contains("errno = 100") ||
            message.contains("errno = 64")
    }

    /// errno 9 / 49-class local socket races during Wi‑Fi AP UDP.
    public static func isWifiUdpTransientSocketError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            let transientCodes: Set<Int> = [
                Int(EBADF),
                Int(EADDRNOTAVAIL),
            ]
            if transientCodes.contains(nsError.code) { return true }
        }

        let message = "\(error) \(nsError.localizedDescription)".lowercased()
        return message.contains("bad file descriptor") ||
            message.contains("can't assign requested address") ||
            message.contains("cannot assign requested address") ||
            message.contains("errno = 9") ||
            message.contains("errno = 49") ||
            message.contains("errno = 99") ||
            message.contains("errno = 10049")
    }

    public static func isWifiApReachabilitySocketNoise(
        _ error: Error,
        stackTrace: String? = nil
    ) -> Bool {
        guard isDeviceApNetworkUnreachable(error) ||
            isWifiUdpTransientSocketError(error)
        else { return false }
        guard let stackTrace, !stackTrace.isEmpty else {
            return "\(error)".contains("SocketException") ||
                (error as NSError).domain == NSPOSIXErrorDomain
        }
        return stackLooksLikeWifiUdpProbe(stackTrace)
    }

    private static func stackLooksLikeWifiUdpProbe(_ trace: String) -> Bool {
        wifiUdpStackMarkers.contains { trace.contains($0) }
    }
}

public func isDeviceApNetworkUnreachable(_ error: Error) -> Bool {
    WifiNetworkErrors.isDeviceApNetworkUnreachable(error)
}

public func isWifiUdpTransientSocketError(_ error: Error) -> Bool {
    WifiNetworkErrors.isWifiUdpTransientSocketError(error)
}

public func isWifiApReachabilitySocketNoise(
    _ error: Error,
    stackTrace: String? = nil
) -> Bool {
    WifiNetworkErrors.isWifiApReachabilitySocketNoise(error, stackTrace: stackTrace)
}
