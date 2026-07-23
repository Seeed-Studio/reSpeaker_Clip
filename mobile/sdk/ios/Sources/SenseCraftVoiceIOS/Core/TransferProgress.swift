import Foundation

public enum TransferProgress {
    public static func wifiAligned(
        framedMode: Bool,
        currentFileDeclaredSize: Int,
        bytesThisFile: Int,
        receivedSession: Int,
        expectedSession: Int?,
        filesCompleted: Int,
        deviceTotalFiles: Int,
        deviceSessionBytes: Int
    ) -> Double? {
        var ratio: Double?
        if let expectedSession, expectedSession > 0 {
            let uncapped = Double(receivedSession) / Double(expectedSession)
            if uncapped <= 1.05 || deviceTotalFiles <= 0 {
                ratio = clamp(uncapped, 0, 0.995)
            }
        }
        if ratio == nil && deviceTotalFiles > 0 && deviceSessionBytes > 0 {
            let filePart = Double(filesCompleted) / Double(deviceTotalFiles)
            let bytePart = clamp(Double(receivedSession) / Double(deviceSessionBytes), 0, 1)
            ratio = clamp(filePart + bytePart / Double(deviceTotalFiles), 0, 0.995)
        } else if ratio == nil && deviceTotalFiles > 0 {
            if framedMode && currentFileDeclaredSize > 0 {
                let inFlight = clamp(Double(bytesThisFile) / Double(currentFileDeclaredSize), 0, 1)
                let denom = max(deviceTotalFiles, filesCompleted + (inFlight > 0 ? 1 : 0))
                ratio = clamp(Double(filesCompleted) + inFlight, 0, Double(denom)) / Double(denom)
                ratio = clamp(ratio ?? 0, 0, 0.995)
            } else {
                ratio = clamp(Double(filesCompleted) / Double(deviceTotalFiles), 0, 0.995)
            }
        } else if ratio == nil && framedMode && currentFileDeclaredSize > 0 {
            ratio = clamp(Double(bytesThisFile) / Double(currentFileDeclaredSize), 0, 0.995)
        }
        return ratio
    }

    public static func uncappedRatio(
        framedMode: Bool,
        currentFileDeclaredSize: Int,
        bytesThisFile: Int,
        receivedSession: Int,
        expectedSession: Int?,
        filesCompleted: Int,
        deviceTotalFiles: Int,
        deviceSessionBytes: Int
    ) -> Double {
        if let expectedSession, expectedSession > 0 {
            return Double(receivedSession) / Double(expectedSession)
        }
        if deviceTotalFiles > 0 && deviceSessionBytes > 0 {
            let filePart = Double(filesCompleted) / Double(deviceTotalFiles)
            let bytePart = clamp(Double(receivedSession) / Double(deviceSessionBytes), 0, 1)
            return filePart + bytePart / Double(deviceTotalFiles)
        }
        if deviceTotalFiles > 0 {
            if framedMode && currentFileDeclaredSize > 0 {
                let inFlight = clamp(Double(bytesThisFile) / Double(currentFileDeclaredSize), 0, 1)
                let denom = max(deviceTotalFiles, filesCompleted + (inFlight > 0 ? 1 : 0))
                return (Double(filesCompleted) + inFlight) / Double(denom)
            }
            return Double(filesCompleted) / Double(deviceTotalFiles)
        }
        if framedMode && currentFileDeclaredSize > 0 {
            return Double(bytesThisFile) / Double(currentFileDeclaredSize)
        }
        return 0
    }

    public static func branchLabel(
        framedMode: Bool,
        currentFileDeclaredSize: Int,
        bytesThisFile: Int,
        receivedSession: Int,
        expectedSession: Int?,
        filesCompleted: Int,
        deviceTotalFiles: Int,
        deviceSessionBytes: Int
    ) -> String {
        if let expectedSession, expectedSession > 0 {
            let uncapped = Double(receivedSession) / Double(expectedSession)
            if uncapped <= 1.05 || deviceTotalFiles <= 0 {
                return "expectedSession"
            }
        }
        if deviceTotalFiles > 0 && deviceSessionBytes > 0 {
            return "files+sessionBytes"
        }
        if deviceTotalFiles > 0 {
            if framedMode && currentFileDeclaredSize > 0 {
                return "files+sliceBytes"
            }
            return "filesOnly"
        }
        if framedMode && currentFileDeclaredSize > 0 {
            return "sliceBytes"
        }
        return "null"
    }

    public static func sessionTransferBytesComplete(
        eventFileCount: Int,
        fileCompleteCount: Int,
        deviceTotalFilesFromDownload: Int
    ) -> Bool {
        if deviceTotalFilesFromDownload <= 0 { return false }
        return eventFileCount >= deviceTotalFilesFromDownload ||
            fileCompleteCount >= deviceTotalFilesFromDownload
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
