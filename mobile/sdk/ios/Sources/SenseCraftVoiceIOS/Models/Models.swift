import Foundation

public enum RecordingMode: String {
    case normal
    case enhanced
}

public struct Device {
    public let id: String
    public var name: String
    public var sn: String?
    public var model: String
    public var batteryPercent: Int?
    public var recordingMode: RecordingMode
    public var firmwareVersion: String?
    public var hasFirmwareUpdate: Bool
    public var isOnline: Bool
    public var lastSeen: Date?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        name: String,
        sn: String? = nil,
        model: String,
        batteryPercent: Int? = nil,
        recordingMode: RecordingMode = .normal,
        firmwareVersion: String? = nil,
        hasFirmwareUpdate: Bool = false,
        isOnline: Bool,
        lastSeen: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sn = sn
        self.model = model
        self.batteryPercent = batteryPercent
        self.recordingMode = recordingMode
        self.firmwareVersion = firmwareVersion
        self.hasFirmwareUpdate = hasFirmwareUpdate
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DeviceFileMeta {
    public let deviceId: String
    public let path: String
    public let name: String
    public let sizeBytes: Int
    public let durationSeconds: Int
    public let bookmarkCount: Int
    public let createdAt: Date?

    public init(
        deviceId: String,
        path: String,
        name: String,
        sizeBytes: Int,
        durationSeconds: Int,
        bookmarkCount: Int,
        createdAt: Date?
    ) {
        self.deviceId = deviceId
        self.path = path
        self.name = name
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.bookmarkCount = bookmarkCount
        self.createdAt = createdAt
    }

    public var recordingId: String {
        "\(deviceId)_\(path)"
    }
}

public struct WifiHotspotInfo {
    public let enabled: Bool
    public let ssid: String
    public let password: String
    public let ip: String
    public let port: Int
    public let channel: Int?

    public init(
        enabled: Bool,
        ssid: String,
        password: String,
        ip: String,
        port: Int,
        channel: Int? = nil
    ) {
        self.enabled = enabled
        self.ssid = ssid
        self.password = password
        self.ip = ip
        self.port = port
        self.channel = channel
    }

    public static func fromAtReply(_ resp: JSONObject) -> WifiHotspotInfo {
        let data = (resp["data"] as? JSONObject) ?? resp
        let enabled = boolValue(data["enabled"]) == true ||
            boolValue(data["running"]) == true ||
            boolValue(data["ap_running"]) == true
        var ip = string(data["ip"]) ?? "192.168.4.1"
        if ip.isEmpty || ip == "0.0.0.0" || ip == "::" || ip == "::0" {
            ip = "192.168.4.1"
        }
        let port = int(data["port"]).flatMap { $0 > 0 ? $0 : nil } ?? 8089
        return WifiHotspotInfo(
            enabled: enabled,
            ssid: string(data["ssid"]) ?? "",
            password: string(data["password"]) ?? "",
            ip: ip,
            port: port,
            channel: int(data["channel"])
        )
    }

    public var baseUrl: String {
        "http://\(ip):\(port)"
    }

    public var isValid: Bool {
        !ssid.isEmpty && !password.isEmpty && !ip.isEmpty
    }
}

public struct DeviceStatus {
    public let state: String
    public let isRecording: Bool
    public let sessionId: String?
    public let batteryPercent: Int?
    public let isCharging: Bool?
    public let freeSpaceBytes: Int?
    public let bitrate: Int?
    public let recordingMode: RecordingMode?
    public let recordingSeconds: Int?
    public let firmwareVersion: String?
    public let raw: JSONObject

    public init(
        state: String,
        isRecording: Bool,
        sessionId: String?,
        batteryPercent: Int?,
        isCharging: Bool?,
        freeSpaceBytes: Int?,
        bitrate: Int?,
        recordingMode: RecordingMode?,
        recordingSeconds: Int?,
        firmwareVersion: String?,
        raw: JSONObject
    ) {
        self.state = state
        self.isRecording = isRecording
        self.sessionId = sessionId
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.freeSpaceBytes = freeSpaceBytes
        self.bitrate = bitrate
        self.recordingMode = recordingMode
        self.recordingSeconds = recordingSeconds
        self.firmwareVersion = firmwareVersion
        self.raw = raw
    }

    public static func fromAtReply(_ resp: JSONObject) -> DeviceStatus {
        let data = (resp["data"] as? JSONObject) ?? [:]
        let state = string(data["state"])?.lowercased() ?? ""
        let isRecording: Bool = {
            if let value = data["recording"] as? Bool { return value }
            if let value = data["recording"] as? NSNumber { return value.boolValue }
            if let value = data["recording"] as? String {
                let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true", "1", "yes"].contains(lower) { return true }
                if ["false", "0", "no"].contains(lower) { return false }
            }
            return state == "recording"
        }()
        let sid = string(data["session"])
        let battery = int(data["battery"])
        let charging = boolValue(data["charging"])
        let free = int(data["free_space"])
        let bitrate = int(data["bitrate"])
        let mode = parseMode(data["mode"])
        let dur = int(data["duration"])
        let fwv = string(data["version"]) ?? string(data["firmware_version"])

        return DeviceStatus(
            state: state,
            isRecording: isRecording,
            sessionId: sid,
            batteryPercent: battery,
            isCharging: charging,
            freeSpaceBytes: free,
            bitrate: bitrate,
            recordingMode: mode,
            recordingSeconds: dur,
            firmwareVersion: fwv,
            raw: data
        )
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

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes"].contains(lower) { return true }
            if ["false", "0", "no"].contains(lower) { return false }
            return nil
        default:
            return nil
        }
    }

    private static func parseMode(_ value: Any?) -> RecordingMode? {
        guard let value else { return nil }
        let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return nil }
        if s == "enhanced" || s == "1" { return .enhanced }
        return .normal
    }
}

public struct DeviceRuntimeInfo {
    public let firmwareVersion: String?
    public let rawDeviceTime: Any?
    public let deviceTime: Date?
    public let status: DeviceStatus?
    public let pairStatus: String?
    public let pairAddress: String?
    public let versionReply: JSONObject?
    public let timeReply: JSONObject?
    public let statusReply: JSONObject?
    public let pairReply: JSONObject?

    public init(
        firmwareVersion: String?,
        rawDeviceTime: Any?,
        deviceTime: Date?,
        status: DeviceStatus?,
        pairStatus: String?,
        pairAddress: String?,
        versionReply: JSONObject?,
        timeReply: JSONObject?,
        statusReply: JSONObject?,
        pairReply: JSONObject?
    ) {
        self.firmwareVersion = firmwareVersion
        self.rawDeviceTime = rawDeviceTime
        self.deviceTime = deviceTime
        self.status = status
        self.pairStatus = pairStatus
        self.pairAddress = pairAddress
        self.versionReply = versionReply
        self.timeReply = timeReply
        self.statusReply = statusReply
        self.pairReply = pairReply
    }

    public var state: String? { status?.state }
    public var isRecording: Bool? { status?.isRecording }
    public var sessionId: String? { status?.sessionId }
    public var batteryPercent: Int? { status?.batteryPercent }

    public var formattedDeviceTime: String? {
        guard let deviceTime else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: deviceTime)
    }

    public var hasAnyData: Bool {
        firmwareVersion != nil ||
        rawDeviceTime != nil ||
        status != nil ||
        pairStatus != nil ||
        pairAddress != nil
    }
}

public struct DeviceBookmarkMarkResult {
    public let ok: Bool
    public let sessionId: String?
    public let markCount: Int?
    public let offsetSeconds: Int?
    public let raw: JSONObject

    public init(
        ok: Bool,
        sessionId: String?,
        markCount: Int?,
        offsetSeconds: Int?,
        raw: JSONObject
    ) {
        self.ok = ok
        self.sessionId = sessionId
        self.markCount = markCount
        self.offsetSeconds = offsetSeconds
        self.raw = raw
    }
}

public struct DeviceBookmarkMeta {
    public let sessionId: String?
    public let markCount: Int?
    public let offsetSeconds: Int?
    public let note: String?
    public let raw: JSONObject

    public init(
        sessionId: String?,
        markCount: Int?,
        offsetSeconds: Int?,
        note: String?,
        raw: JSONObject
    ) {
        self.sessionId = sessionId
        self.markCount = markCount
        self.offsetSeconds = offsetSeconds
        self.note = note
        self.raw = raw
    }

    public static func fromJson(_ raw: JSONObject, defaultSessionId: String? = nil) -> DeviceBookmarkMeta {
        let data = (raw["data"] as? JSONObject) ?? [:]
        return DeviceBookmarkMeta(
            sessionId: string(raw["session"]) ?? string(data["session"]) ?? defaultSessionId,
            markCount: int(raw["mark_count"]) ?? int(raw["count"]) ?? int(raw["marks"]) ?? int(raw["bookmarks"]) ??
                int(data["mark_count"]) ?? int(data["count"]) ?? int(data["marks"]) ?? int(data["bookmarks"]),
            offsetSeconds: int(raw["offset"]) ?? int(raw["offset_sec"]) ??
                int(data["offset"]) ?? int(data["offset_sec"]),
            note: string(raw["note"]) ?? string(data["note"]),
            raw: raw
        )
    }
}

public struct DeviceTimeInfo {
    public let unixSeconds: Int?
    public let date: Date?
    public let raw: JSONObject

    public init(unixSeconds: Int?, date: Date?, raw: JSONObject) {
        self.unixSeconds = unixSeconds
        self.date = date
        self.raw = raw
    }

    public static func fromAtReply(_ resp: JSONObject) -> DeviceTimeInfo {
        let data = (resp["data"] as? JSONObject) ?? [:]
        let rawValue = firstNonNil(
            resp["time"], resp["timestamp"], resp["ts"], resp["unix"], resp["seconds"],
            data["time"], data["timestamp"], data["ts"], data["unix"], data["seconds"]
        )
        let seconds = int(rawValue)
        let date = seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return DeviceTimeInfo(unixSeconds: seconds, date: date, raw: resp)
    }
}

public struct PairingStatus {
    public let isPaired: Bool?
    public let state: String?
    public let raw: JSONObject

    public init(isPaired: Bool?, state: String?, raw: JSONObject) {
        self.isPaired = isPaired
        self.state = state
        self.raw = raw
    }

    public static func fromAtReply(_ resp: JSONObject) -> PairingStatus {
        let data = (resp["data"] as? JSONObject) ?? [:]
        let state = string(resp["state"]) ?? string(resp["status"]) ?? string(data["state"]) ?? string(data["status"])
        let paired = boolValue(resp["paired"]) ?? boolValue(resp["bonded"]) ?? boolValue(resp["connected"]) ??
            boolValue(data["paired"]) ?? boolValue(data["bonded"]) ?? boolValue(data["connected"]) ??
            state.map { s in
                let lower = s.lowercased()
                return lower == "paired" || lower == "bonded" || lower == "connected" || lower == "ok"
            }
        return PairingStatus(isPaired: paired, state: state, raw: resp)
    }
}

public enum DeviceRecordingState: String {
    case idle
    case recording
    case paused
    case transmitting
    case wifiSync = "wifi_sync"
    case error
    case unknown

    public static func parse(_ raw: Any?) -> DeviceRecordingState {
        guard let raw else { return .unknown }
        let s = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return .unknown }
        switch s {
        case "idle":
            return .idle
        case "rec", "recording":
            return .recording
        case "paused", "pause":
            return .paused
        case "transmitting", "transfer", "transferring", "transfering":
            return .transmitting
        case "wifi_sync", "wifi-sync", "wifisync":
            return .wifiSync
        case "error", "err", "fault":
            return .error
        default:
            return .unknown
        }
    }
}

private func firstNonNil(_ values: Any?...) -> Any? {
    for value in values {
        if let value { return value }
    }
    return nil
}

private func string(_ value: Any?) -> String? {
    guard let value else { return nil }
    let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

private func int(_ value: Any?) -> Int? {
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

private func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    case let value as String:
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["true", "1", "yes"].contains(lower) { return true }
        if ["false", "0", "no"].contains(lower) { return false }
        return nil
    default:
        return nil
    }
}
