import Foundation

public enum DeviceEvent {
    case recordingState(state: DeviceRecordingState, sessionId: String?, durationSeconds: Int?, mode: RecordingMode?, raw: JSONObject)
    case bookmark(sessionId: String?, markCount: Int?, offsetSeconds: Int?, note: String?, raw: JSONObject)
    case batteryLow(level: Int?, raw: JSONObject)
    case storageLow(freeMb: Int?, raw: JSONObject)
    case error(code: Int?, message: String?, raw: JSONObject)
    case connected(address: String?, raw: JSONObject)
    case disconnected(reason: String?, raw: JSONObject)
    case unknown(name: String, raw: JSONObject)
}

public func parseDeviceEvent(_ msg: JSONObject) -> DeviceEvent? {
    let data = (msg["data"] as? JSONObject) ?? [:]
    let eventName = string(msg["event"]) ?? string(data["event"]) ?? ""
    guard !eventName.isEmpty else { return nil }

    func read(_ key: String) -> Any? {
        if let value = msg[key] { return value }
        return data[key]
    }

    func readString(_ key: String) -> String? {
        guard let value = read(key) else { return nil }
        let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    func readInt(_ key: String) -> Int? {
        switch read(key) {
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

    switch eventName.lowercased() {
    case "state", "state_change":
        let stateRaw = msg["state"] ?? data["state"] ?? msg["new"] ?? data["new"]
        let modeRaw = msg["mode"] ?? data["mode"]
        let mode: RecordingMode?
        if let modeRaw {
            let s = String(describing: modeRaw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == "enhanced" || s == "1" {
                mode = .enhanced
            } else if s == "normal" || s == "0" || !s.isEmpty {
                mode = .normal
            } else {
                mode = nil
            }
        } else {
            mode = nil
        }
        return .recordingState(
            state: DeviceRecordingState.parse(stateRaw),
            sessionId: readString("session") ?? readString("session_id"),
            durationSeconds: readInt("duration") ?? readInt("duration_s"),
            mode: mode,
            raw: msg
        )

    case "mark", "bookmark":
        return .bookmark(
            sessionId: readString("session") ?? readString("session_id"),
            markCount: readInt("mark_count") ?? readInt("count") ?? readInt("marks") ?? readInt("bookmarks"),
            offsetSeconds: readInt("offset") ?? readInt("offset_sec"),
            note: readString("note"),
            raw: msg
        )

    case "battery_low", "low_battery":
        return .batteryLow(level: readInt("level") ?? readInt("battery"), raw: msg)

    case "storage_low", "low_storage":
        return .storageLow(freeMb: readInt("free_mb") ?? readInt("free"), raw: msg)

    case "error":
        return .error(
            code: readInt("code") ?? readInt("error_code"),
            message: readString("error") ?? readString("message") ?? readString("msg"),
            raw: msg
        )

    case "connected":
        return .connected(address: readString("addr") ?? readString("address"), raw: msg)

    case "disconnected":
        return .disconnected(reason: readString("reason"), raw: msg)

    default:
        return .unknown(name: eventName.lowercased(), raw: msg)
    }
}

private func string(_ value: Any?) -> String? {
    guard let value else { return nil }
    let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

