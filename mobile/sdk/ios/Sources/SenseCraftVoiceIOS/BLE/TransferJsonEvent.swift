import Foundation

public enum TransferJsonEvent {
    case fileComplete(filename: String, sessionId: String)
    case transferComplete(files: Int, sessionId: String)
    case other(event: String)
}

public enum TransferJsonEventParser {
    public static func parse(_ msg: JSONObject) -> TransferJsonEvent? {
        let data = (msg["data"] as? JSONObject) ?? [:]
        let event = string(msg["event"]) ?? string(data["event"]) ?? ""
        guard !event.isEmpty else { return nil }
        let sessionId = string(msg["session"]) ?? string(msg["session_id"]) ?? string(data["session"]) ?? string(data["session_id"]) ?? ""

        switch event {
        case "file_complete":
            let filename = string(msg["filename"]) ?? string(data["filename"]) ?? ""
            return .fileComplete(filename: filename, sessionId: sessionId)
        case "transfer_complete":
            let files = int(msg["files"]) ?? int(data["files"]) ?? 0
            return .transferComplete(files: files, sessionId: sessionId)
        default:
            return .other(event: event)
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}

public enum TransferJsonTransferCompletePolicy {
    public static func looksLikeSessionComplete(
        fileCompleteCount: Int,
        deviceTotalFiles: Int,
        receivedBytes: Int,
        deviceSessionBytes: Int
    ) -> Bool {
        let haveAllSlices = deviceTotalFiles > 0 && fileCompleteCount >= deviceTotalFiles
        let haveAllBytes = deviceSessionBytes > 0 &&
            receivedBytes >= max(0, deviceSessionBytes - 2048)
        return haveAllSlices || haveAllBytes
    }

    public static func shouldIgnoreEmptyTransferComplete(receivedBytes: Int, files: Int) -> Bool {
        receivedBytes == 0 && files == 0
    }
}

