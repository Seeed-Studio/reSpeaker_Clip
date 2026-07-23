import Foundation
import Network
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Compression)
import Compression
#endif
#if canImport(NetworkExtension)
import NetworkExtension
#endif

public struct OtaImage {
    public let imageIndex: Int
    public let data: Data
    public let fileName: String?

    public init(imageIndex: Int, data: Data, fileName: String? = nil) {
        self.imageIndex = imageIndex
        self.data = data
        self.fileName = fileName
    }
}

public enum OtaFirmwareException: Error, CustomStringConvertible {
    case invalidFirmware(String)

    public var description: String {
        switch self {
        case .invalidFirmware(let message):
            return "OtaFirmwareException: \(message)"
        }
    }
}

public final class OtaFirmwareProcessor {
    public init() {}

    public static func processFile(_ url: URL) throws -> [OtaImage] {
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") {
            return try processZip(data)
        }
        if name.hasSuffix(".bin") {
            return try processBin(data)
        }
        throw OtaFirmwareException.invalidFirmware("Unsupported firmware format - expected .zip or .bin")
    }

    public static func processBin(_ data: Data) throws -> [OtaImage] {
        guard !data.isEmpty else {
            throw OtaFirmwareException.invalidFirmware("Firmware BIN is empty")
        }
        return [OtaImage(imageIndex: 0, data: data)]
    }

    public static func processZip(_ data: Data) throws -> [OtaImage] {
        let entries = try ZipArchiveReader.entries(in: data)
        guard let manifestData = entries["manifest.json"] else {
            throw OtaFirmwareException.invalidFirmware("Firmware ZIP is missing manifest.json")
        }
        let manifestAny = try JSONSerialization.jsonObject(with: manifestData)
        guard let manifest = manifestAny as? JSONObject,
              let files = manifest["files"] as? [Any],
              !files.isEmpty else {
            throw OtaFirmwareException.invalidFirmware("manifest.json contains no \"files\" entries")
        }

        var images: [OtaImage] = []
        for item in files {
            guard let entry = item as? JSONObject else {
                throw OtaFirmwareException.invalidFirmware("manifest.json contains an invalid files[] entry")
            }
            let fileName = string(entry["file"]) ?? ""
            guard let imageData = entries[fileName] else {
                throw OtaFirmwareException.invalidFirmware("Manifest references a missing binary: \(fileName)")
            }
            try validateManifestFileEntry(fileName: fileName, data: imageData, entry: entry)
            let imageIndex = int(entry["image_index"]) ?? 0
            images.append(OtaImage(imageIndex: imageIndex, data: imageData, fileName: fileName))
        }
        return images
    }

    public static func validateManifestFileEntry(
        fileName: String,
        data: Data,
        entry: JSONObject
    ) throws {
        if fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OtaFirmwareException.invalidFirmware("manifest.json entry is missing \"file\" name")
        }
        if let expectedSize = int(entry["size"]), expectedSize >= 0, data.count != expectedSize {
            throw OtaFirmwareException.invalidFirmware(
                "Firmware binary size mismatch for \(fileName): expected \(expectedSize) bytes, got \(data.count)"
            )
        }
        if let expectedSha256 = digest(entry, keys: ["sha256", "hash"]) {
            let actual = sha256Hex(data)
            if actual != expectedSha256 {
                throw OtaFirmwareException.invalidFirmware("Firmware binary SHA-256 mismatch for \(fileName)")
            }
        }
        if let expectedMd5 = digest(entry, keys: ["md5"]) {
            let actual = md5Hex(data)
            if actual != expectedMd5 {
                throw OtaFirmwareException.invalidFirmware("Firmware binary MD5 mismatch for \(fileName)")
            }
        }
    }

    private static func digest(_ entry: JSONObject, keys: [String]) -> String? {
        for key in keys {
            guard let value = string(entry[key])?.lowercased(), !value.isEmpty else { continue }
            return value
        }
        return nil
    }
}

public enum OtaPhase: String {
    case idle
    case preparing
    case uploading
    case validating
    case resetting
    case success
    case failed
    case cancelled
}

public struct OtaProgress {
    public let phase: OtaPhase
    public let progress: Double
    public let bytesSent: Int
    public let totalBytes: Int
    public let message: String

    public init(phase: OtaPhase, progress: Double, bytesSent: Int, totalBytes: Int, message: String) {
        self.phase = phase
        self.progress = progress
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
        self.message = message
    }
}

public protocol OtaUpgradeTransport {
    func upgrade(
        deviceId: String,
        images: [OtaImage],
        progress: @escaping (OtaProgress) -> Void
    ) async throws

    func cancel() async
}

public final class OtaSession {
    public let deviceId: String
    private let transport: OtaUpgradeTransport?
    private var continuations: [UUID: AsyncStream<OtaProgress>.Continuation] = [:]
    public private(set) var phase: OtaPhase = .idle
    public private(set) var lastError: Error?

    public init(deviceId: String, transport: OtaUpgradeTransport? = nil) {
        self.deviceId = deviceId
        self.transport = transport
    }

    public var events: AsyncStream<OtaProgress> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.continuations.removeValue(forKey: id)
            }
        }
    }

    public func upgrade(_ url: URL) async -> Bool {
        emit(.preparing, progress: 0, bytesSent: 0, totalBytes: 0, message: "Parsing firmware...")
        do {
            let images = try OtaFirmwareProcessor.processFile(url)
            return await upgradeImages(images)
        } catch {
            fail(error, message: "Firmware parsing failed: \(error)")
            return false
        }
    }

    public func upgradeImages(_ images: [OtaImage]) async -> Bool {
        let totalBytes = images.reduce(0) { $0 + $1.data.count }
        guard totalBytes > 0 else {
            fail(OtaFirmwareException.invalidFirmware("No firmware bytes to flash"), message: "No firmware bytes to flash")
            return false
        }
        guard let transport else {
            fail(
                SenseCraftVoiceError.unsupported("OTA SMP/mcumgr transfer is not linked in this native SDK yet"),
                message: "OTA transfer requires native mcumgr integration"
            )
            return false
        }
        do {
            emit(.uploading, progress: 0, bytesSent: 0, totalBytes: totalBytes, message: "Uploading firmware...")
            try await transport.upgrade(deviceId: deviceId, images: images) { [weak self] event in
                self?.emit(
                    event.phase,
                    progress: event.progress,
                    bytesSent: event.bytesSent,
                    totalBytes: event.totalBytes == 0 ? totalBytes : event.totalBytes,
                    message: event.message
                )
            }
            emit(.success, progress: 1, bytesSent: totalBytes, totalBytes: totalBytes, message: "Upgrade complete")
            return true
        } catch {
            fail(error, message: "Upgrade failed: \(error)")
            return false
        }
    }

    public func cancel() async {
        await transport?.cancel()
        emit(.cancelled, progress: 0, bytesSent: 0, totalBytes: 0, message: "Cancelled")
    }

    public func dispose() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func emit(_ phase: OtaPhase, progress: Double, bytesSent: Int, totalBytes: Int, message: String) {
        self.phase = phase
        let event = OtaProgress(phase: phase, progress: progress, bytesSent: bytesSent, totalBytes: totalBytes, message: message)
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func fail(_ error: Error, message: String) {
        lastError = error
        emit(.failed, progress: -1, bytesSent: 0, totalBytes: 0, message: message)
        SdkLog.w("OtaSession failed", error)
    }
}

public final class WifiFastSyncSession {
    public let at: AtTransport

    private var connector: WifiHotspotConnector?
    private var client: WifiTransferClient?
    public private(set) var hotspot: WifiHotspotInfo?

    public init(at: AtTransport) {
        self.at = at
    }

    public var transferClient: WifiTransferClient? {
        client
    }

    public var hotspotConnector: WifiHotspotConnector? {
        connector
    }

    public var isPrepared: Bool {
        hotspot != nil && client != nil
    }

    @discardableResult
    public func enableHotspot() async throws -> WifiHotspotInfo {
        let activeConnector = connector ?? WifiHotspotConnector(at: at)
        connector = activeConnector
        SdkLog.i("[WiFi] WifiFastSyncSession: enable AP")
        let info = try await activeConnector.enable()
        hotspot = info
        client = WifiTransferClient(hotspot: info)
        return info
    }

    @discardableResult
    public func prepare(
        joinPhone: Bool = true,
        requirePhoneJoin: Bool = false
    ) async throws -> WifiHotspotInfo {
        let info = try await enableHotspot()
        if joinPhone {
            let joined = await connector?.connectToHotspot(info) == true
            if !joined {
                let message = "Phone failed to join device AP \(info.ssid)"
                if requirePhoneJoin {
                    throw SenseCraftVoiceError.connectionFailed(message)
                }
                SdkLog.w("[WiFi] \(message); UDP may still work if the phone is already on the AP")
            }
        }
        return info
    }

    public func teardown(disconnectPhone: Bool = true, disableHotspot: Bool = true) async throws {
        let info = hotspot
        client?.dispose()
        client = nil
        if let info, disconnectPhone {
            await connector?.disconnectFromHotspot(info)
        }
        if disableHotspot {
            try await connector?.disable()
        }
        connector = nil
        hotspot = nil
    }

    @discardableResult
    public func downloadSession(
        sessionId: String,
        sessionDirectory: URL,
        startFile: String? = nil,
        shouldCancel: (() -> Bool)? = nil,
        joinPhone: Bool = true,
        requirePhoneJoin: Bool = false,
        disconnectPhoneAfter: Bool = true,
        disableHotspotAfter: Bool = true,
        onOverallProgress: ((Double?) -> Void)? = nil,
        onProgress: WifiTransferProgress? = nil
    ) async throws -> Int {
        do {
            _ = try await prepare(joinPhone: joinPhone, requirePhoneJoin: requirePhoneJoin)
            guard let client else {
                throw SenseCraftVoiceError.connectionFailed("Wi-Fi transfer client was not created")
            }
            SdkLog.i("[WiFi] WifiFastSyncSession: UDP download session=\(sessionId)")
            let bytes = try await client.downloadSession(
                sessionId: sessionId,
                sessionDirectory: sessionDirectory,
                startFile: startFile,
                shouldCancel: shouldCancel,
                onOverallProgress: onOverallProgress,
                onProgress: onProgress
            )
            SdkLog.i("[WiFi] WifiFastSyncSession: done bytes=\(bytes)")
            try await teardown(disconnectPhone: disconnectPhoneAfter, disableHotspot: disableHotspotAfter)
            return bytes
        } catch {
            try await teardown(disconnectPhone: disconnectPhoneAfter, disableHotspot: disableHotspotAfter)
            throw error
        }
    }

    public func run() async throws {
        _ = try await prepare(joinPhone: true)
    }
}

public final class WifiHotspotConnector {
    private let at: AtTransport

    public init(at: AtTransport) {
        self.at = at
    }

    public func queryStatus(timeout: TimeInterval = 5) async throws -> WifiHotspotInfo {
        let resp = try await at.send("AT+WIFI?", timeout: timeout)
        try ensureWifiSuccess(resp, command: "AT+WIFI?")
        return WifiHotspotInfo.fromAtReply(resp)
    }

    public func enable() async throws -> WifiHotspotInfo {
        if let prior = try? await queryStatus(), prior.enabled && prior.isValid {
            return prior
        }

        var resp = try await sendWifiOnPair()
        if bool(resp["ok"]) != true {
            let detail = wifiFailureDetail(resp)
            if Self.wifiOnFailureMayBeStaleState(detail) {
                try await turnOffDeviceWifiAp()
                try await waitGstatLeavesWifiSync(timeout: 22)
                resp = try await sendWifiOnPair()
            }
        }
        try ensureWifiSuccess(resp, command: "AT+WIFI=ON")
        return try await hotspotInfoAfterOn(resp)
    }

    public func disable() async throws {
        var lastError: Error?
        for command in ["AT+WIFI=OFF", "AT+WIFI=off"] {
            do {
                let resp = try await at.send(command, timeout: 8)
                if bool(resp["ok"]) == true { return }
                lastError = SenseCraftVoiceError.invalidResponse("\(command) failed: \(wifiFailureDetail(resp))")
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
    }

    public func connectToHotspot(_ info: WifiHotspotInfo) async -> Bool {
        guard info.isValid else {
            SdkLog.w("[WiFi] Cannot join invalid hotspot info")
            return false
        }

        #if os(iOS) && canImport(NetworkExtension)
        SdkLog.i("[WiFi] Phone -> join AP \"\(info.ssid)\" (iOS NEHotspotConfiguration)")
        do {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let config = NEHotspotConfiguration(ssid: info.ssid, passphrase: info.password, isWEP: false)
            config.joinOnce = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    if let error = error as NSError? {
                        if error.domain == NEHotspotConfigurationErrorDomain,
                           error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error)
                        }
                    } else {
                        continuation.resume()
                    }
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
            SdkLog.i("[WiFi] Phone associated with \"\(info.ssid)\"")
            return true
        } catch {
            SdkLog.w("[WiFi] iOS hotspot join failed", error)
            return false
        }
        #else
        SdkLog.w("[WiFi] Native phone Wi-Fi association is only available on iOS")
        return false
        #endif
    }

    public func disconnectFromHotspot(_ info: WifiHotspotInfo) async {
        #if os(iOS) && canImport(NetworkExtension)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: info.ssid)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #else
        _ = info
        #endif
    }

    public func forceWifiUsage(_ force: Bool) async {
        _ = force
    }

    private func sendWifiOnPair() async throws -> JSONObject {
        var firstError: Error?
        for command in ["AT+WIFI=ON", "AT+WIFI=on"] {
            do {
                let resp = try await at.send(command, timeout: 12)
                if bool(resp["ok"]) == true { return resp }
                firstError = SenseCraftVoiceError.invalidResponse("\(command) failed: \(wifiFailureDetail(resp))")
                if command == "AT+WIFI=ON", Self.wifiOnFailureMayBeStaleState(wifiFailureDetail(resp)) {
                    return resp
                }
            } catch {
                firstError = error
            }
        }
        if let firstError { throw firstError }
        throw SenseCraftVoiceError.invalidResponse("AT+WIFI=ON failed")
    }

    private func hotspotInfoAfterOn(_ onResp: JSONObject) async throws -> WifiHotspotInfo {
        let fromOn = WifiHotspotInfo.fromAtReply(onResp)
        try await sleep(milliseconds: 800)
        var lastError: Error?
        for _ in 0..<3 {
            do {
                let queried = try await queryStatus(timeout: 12)
                if queried.isValid { return queried }
                if fromOn.isValid { return fromOn }
                lastError = SenseCraftVoiceError.invalidResponse("AT+WIFI? missing hotspot credentials")
            } catch {
                lastError = error
            }
            try await sleep(milliseconds: 600)
        }
        if fromOn.isValid { return fromOn }
        if let lastError { throw lastError }
        throw SenseCraftVoiceError.invalidResponse("AT+WIFI? after ON failed")
    }

    private func turnOffDeviceWifiAp() async throws {
        for command in ["AT+WIFI=OFF", "AT+WIFI=off"] {
            _ = try? await at.send(command, timeout: 8)
        }
        try await sleep(milliseconds: 500)
    }

    private func waitGstatLeavesWifiSync(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let resp = try await at.send("AT+GSTAT", timeout: 4)
                let data = (resp["data"] as? JSONObject) ?? [:]
                let state = string(data["state"])?.uppercased() ?? ""
                if bool(resp["ok"]) == true && state != "WIFI_SYNC" {
                    return
                }
            } catch {
                SdkLog.w("WifiHotspotConnector GSTAT poll failed", error)
            }
            try await sleep(milliseconds: 400)
        }
    }

    private func ensureWifiSuccess(_ resp: JSONObject, command: String) throws {
        guard bool(resp["ok"]) == true else {
            throw SenseCraftVoiceError.invalidResponse("\(command) failed: \(wifiFailureDetail(resp))")
        }
    }

    private func wifiFailureDetail(_ resp: JSONObject) -> String {
        if let msg = string(resp["msg"]) ?? string(resp["message"]) ?? string(resp["error"]) {
            return msg
        }
        if let data = resp["data"] as? JSONObject,
           let msg = string(data["msg"]) ?? string(data["message"]) ?? string(data["error"]) {
            return msg
        }
        return String(describing: resp)
    }

    private static func wifiOnFailureMayBeStaleState(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("cannot start wifi") ||
            lower.contains("current state") ||
            lower.contains("invalid transition") ||
            lower.contains("wifi_sync")
    }

    private func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func bool(_ value: Any?) -> Bool? {
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
}

public typealias WifiTransferProgress = (
    _ currentFile: String,
    _ filesDone: Int,
    _ totalFiles: Int,
    _ receivedBytes: Int,
    _ totalBytes: Int?
) -> Void

public struct WifiPingResult {
    public let ok: Bool
    public let networkUnreachable: Bool

    public init(ok: Bool, networkUnreachable: Bool) {
        self.ok = ok
        self.networkUnreachable = networkUnreachable
    }
}

public final class WifiTransferClient {
    public let hotspot: WifiHotspotInfo
    private var udp: ClipUdpSyncClient?

    public init(hotspot: WifiHotspotInfo) {
        self.hotspot = hotspot
    }

    public func ping() async -> Bool {
        await pingDetailed().ok
    }

    public func pingDetailed() async -> WifiPingResult {
        do {
            try await ensureConnected()
            let ok = await udp?.ping() == true
            if ok {
                return WifiPingResult(ok: true, networkUnreachable: false)
            }
            resetUdp()
            return WifiPingResult(ok: false, networkUnreachable: false)
        } catch {
            let unreachable = isDeviceApNetworkUnreachable(error)
            SdkLog.w("WifiTransferClient ping failed", error)
            resetUdp()
            return WifiPingResult(ok: false, networkUnreachable: unreachable)
        }
    }

    @discardableResult
    public func downloadSession(
        sessionId: String,
        sessionDirectory: URL,
        startFile: String? = nil,
        shouldCancel: (() -> Bool)? = nil,
        onOverallProgress: ((Double?) -> Void)? = nil,
        onProgress: WifiTransferProgress? = nil
    ) async throws -> Int {
        try await ensureConnected()
        guard let udp else {
            throw SenseCraftVoiceError.connectionFailed("UDP client is not connected")
        }
        return try await udp.downloadSession(
            sessionId: sessionId,
            sessionDirectory: sessionDirectory,
            startFile: startFile,
            shouldCancel: shouldCancel,
            onOverallProgress: onOverallProgress,
            onProgress: onProgress
        )
    }

    public func dispose() {
        resetUdp()
    }

    private func ensureConnected() async throws {
        if let udp, udp.isConnected { return }
        let client = ClipUdpSyncClient(receiveTimeout: 8)
        try await client.connect(host: hotspot.ip, port: hotspot.port)
        udp = client
    }

    private func resetUdp() {
        udp?.dispose()
        udp = nil
    }
}

public final class ClipUdpSyncClient {
    public static let frameData: UInt8 = 0x01
    public static let frameFileAck: UInt8 = 0x03
    public static let frameFileStart: UInt8 = 0x10
    public static let frameFileEnd: UInt8 = 0x11
    public static let frameTransferDone: UInt8 = 0x12
    public static let frameAtResp: UInt8 = 0x20
    public static let frameHeartbeat: UInt8 = 0x30

    private static let dataHeaderSize = 9

    public let receiveTimeout: TimeInterval
    private var connection: NWConnection?
    private var rxQueue: [Data] = []
    private var earlyReplay: [Data] = []
    private var heartbeatTask: Task<Void, Never>?
    private var connected = false

    public init(receiveTimeout: TimeInterval = 5) {
        self.receiveTimeout = receiveTimeout
    }

    public var isConnected: Bool {
        connected
    }

    public func connect(host: String, port: Int) async throws {
        if connected { return }
        dispose()

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw SenseCraftVoiceError.invalidResponse("Invalid UDP port \(port)")
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: Self.deviceApUdpParameters()
        )
        connection = conn
        rxQueue.removeAll()
        earlyReplay.removeAll()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready = OneShotThrowingContinuation(continuation)
            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.connected = true
                        self?.receiveLoop()
                        ready.resume()
                    case .failed(let error):
                        self?.connected = false
                        ready.resume(throwing: error)
                    case .cancelled:
                        self?.connected = false
                        ready.resume(throwing: SenseCraftVoiceError.connectionFailed("UDP connection cancelled"))
                    default:
                        break
                    }
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        _ = await send(Data([0x0a]))
        startHeartbeat()
    }

    /// Device APs intentionally have no internet route. On iOS, requiring a
    /// Wi-Fi path prevents Network.framework from satisfying the UDP endpoint
    /// over cellular while the AP is associated. macOS keeps its normal route
    /// selection (USB/Ethernet test rigs remain usable) but still excludes a
    /// cellular interface when one is present.
    static func deviceApUdpParameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        #if os(iOS)
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitedInterfaceTypes = [.cellular]
        #elseif os(macOS)
        parameters.prohibitedInterfaceTypes = [.cellular]
        #endif
        return parameters
    }

    public func dispose() {
        connected = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connection?.cancel()
        connection = nil
        rxQueue.removeAll()
        earlyReplay.removeAll()
    }

    public func sendAtCommand(
        _ command: String,
        timeout: TimeInterval? = nil,
        maxSkips: Int = 64
    ) async -> JSONObject {
        let line = Self.normalizeAtCommand(command)
        guard await send(Data("\(line)\n".utf8)) else {
            return ["ok": false, "error": "UDP send failed"]
        }

        let deadline = Date().addingTimeInterval(timeout ?? receiveTimeout)
        var skips = 0
        while Date() < deadline && skips < maxSkips {
            guard let data = await recvOne(until: deadline), !data.isEmpty else { continue }
            let frameType = data[0]
            if frameType == Self.frameHeartbeat {
                skips += 1
                continue
            }
            if frameType == Self.frameAtResp, data.count >= 3 {
                let len = Int(data[1]) | (Int(data[2]) << 8)
                if data.count >= 3 + len {
                    let body = data.subdata(in: 3..<(3 + len))
                    if let json = try? JSONSerialization.jsonObject(with: body),
                       let obj = json as? JSONObject {
                        return obj
                    }
                    let text = String(data: body, encoding: .utf8) ?? ""
                    return ["ok": true, "raw": text]
                }
            }
            if Self.isFileTransferFrame(data) {
                earlyReplay.append(data)
                skips += 1
                continue
            }
            skips += 1
        }
        return ["ok": false, "error": "No UDP AT response"]
    }

    public func ping() async -> Bool {
        let resp = await sendAtCommand("AT+GSTAT", timeout: 3)
        return bool(resp["ok"]) == true
    }

    @discardableResult
    public func downloadSession(
        sessionId: String,
        sessionDirectory: URL,
        startFile: String? = nil,
        shouldCancel: (() -> Bool)? = nil,
        onOverallProgress: ((Double?) -> Void)? = nil,
        onProgress: WifiTransferProgress? = nil
    ) async throws -> Int {
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        var totalFiles = 0
        var totalBytes = 0
        let infoResp = await sendAtCommand("AT+LIST=\(sessionId)", timeout: 8)
        if bool(infoResp["ok"]) == true, let data = infoResp["data"] as? JSONObject {
            totalFiles = int(data["files"]) ?? int(data["total"]) ?? 0
            totalBytes = int(data["size"]) ?? 0
        }

        let trimmedStart = startFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (trimmedStart?.isEmpty == false)
            ? "AT+DOWNLOAD=\(sessionId):\(trimmedStart!)"
            : "AT+DOWNLOAD=\(sessionId)"
        SdkLog.i("ClipUdpSync: send \(command)")
        var dlResp = await sendAtCommand(command, timeout: 15)
        if bool(dlResp["ok"]) != true, Self.looksBusy(dlResp) {
            SdkLog.w("ClipUdpSync: DOWNLOAD busy, sending AT+CANCEL and retrying once")
            _ = await sendAtCommand("AT+CANCEL", timeout: 3)
            try await Task.sleep(nanoseconds: 600_000_000)
            dlResp = await sendAtCommand(command, timeout: 15)
        }
        guard bool(dlResp["ok"]) == true else {
            throw SenseCraftVoiceError.invalidResponse("AT+DOWNLOAD failed: \(Self.errorDetail(dlResp))")
        }

        if let data = dlResp["data"] as? JSONObject {
            if let files = int(data["files"]) ?? int(data["total"]), files > 0 { totalFiles = files }
            if let bytes = int(data["bytes"]) ?? int(data["size"]), bytes > 0 { totalBytes = bytes }
        }

        pauseHeartbeat()
        defer { resumeHeartbeat() }

        var currentName: String?
        var declaredFileSize = 0
        var maxDataSeqInclusive = 0
        var currentData = Data()
        var fileCrc: UInt32 = 0
        var nextExpectedSeq = 0
        var pendingDataBySeq: [Int: Data] = [:]
        var filesReceived = 0
        var receivedBytes = 0
        var lastProgressAt = Date()
        var lastNackFile: String?
        var consecutiveFileNacks = 0
        let maxConsecutiveFileNacks = 4

        func emitOverallProgress() {
            let ratio = TransferProgress.wifiAligned(
                framedMode: currentName != nil,
                currentFileDeclaredSize: declaredFileSize,
                bytesThisFile: currentData.count,
                receivedSession: receivedBytes,
                expectedSession: totalBytes > 0 ? totalBytes : nil,
                filesCompleted: filesReceived,
                deviceTotalFiles: totalFiles,
                deviceSessionBytes: totalBytes
            )
            onOverallProgress?(ratio)
        }

        func resetAssembly() {
            nextExpectedSeq = 0
            pendingDataBySeq.removeAll()
        }

        func appendPayload(_ payload: Data) {
            currentData.append(payload)
            fileCrc = crc32IEEE(payload, seed: fileCrc)
            receivedBytes += payload.count
            emitOverallProgress()
        }

        func ingestDataFrame(_ data: Data) {
            guard currentName != nil, data.count >= Self.dataHeaderSize else { return }
            let dataLen = Int(data[3]) | (Int(data[4]) << 8)
            guard data.count >= Self.dataHeaderSize + dataLen else { return }
            let receivedCrc = data.uint32LE(at: 5) ?? 0
            let payload = data.subdata(in: Self.dataHeaderSize..<(Self.dataHeaderSize + dataLen))
            guard crc32IEEE(payload) == receivedCrc else {
                SdkLog.w("ClipUdpSync: DATA crc mismatch")
                return
            }
            let seq = (Int(data[1]) | (Int(data[2]) << 8)) & 0xffff
            if seq > maxDataSeqInclusive || seq < nextExpectedSeq {
                lastProgressAt = Date()
                return
            }
            if seq > nextExpectedSeq {
                pendingDataBySeq[seq] = payload
                lastProgressAt = Date()
                return
            }
            appendPayload(payload)
            nextExpectedSeq += 1
            while let pending = pendingDataBySeq.removeValue(forKey: nextExpectedSeq) {
                appendPayload(pending)
                nextExpectedSeq += 1
            }
            lastProgressAt = Date()
            if let currentName {
                onProgress?(currentName, filesReceived, totalFiles, receivedBytes, totalBytes > 0 ? totalBytes : nil)
            }
        }

        while true {
            if shouldCancel?() == true {
                _ = await sendAtCommand("AT+CANCEL", timeout: 2)
                return receivedBytes
            }

            guard let data = await recvOne(until: Date().addingTimeInterval(receiveTimeout)), !data.isEmpty else {
                if Date().timeIntervalSince(lastProgressAt) > 60 {
                    throw SenseCraftVoiceError.timeout("UDP download stalled")
                }
                continue
            }

            switch data[0] {
            case Self.frameHeartbeat:
                continue
            case Self.frameAtResp:
                continue
            case Self.frameFileStart:
                guard data.count >= 3 else { continue }
                let nameLen = Int(data[1])
                guard data.count >= 2 + nameLen + 4 else { continue }
                let nameData = data.subdata(in: 2..<(2 + nameLen))
                let name = String(data: nameData, encoding: .utf8) ?? ""
                let fileSize = Int(data.uint32LE(at: 2 + nameLen) ?? 0)
                currentName = name
                declaredFileSize = fileSize
                maxDataSeqInclusive = fileSize == 0 ? 8 : ((fileSize + 1023) / 1024) + 47
                currentData.removeAll(keepingCapacity: true)
                fileCrc = 0
                resetAssembly()
                lastProgressAt = Date()
                onProgress?(name, filesReceived, totalFiles, receivedBytes, totalBytes > 0 ? totalBytes : nil)
                emitOverallProgress()
                SdkLog.i("ClipUdpSync FILE_START \(name) (\(fileSize) bytes)")
            case Self.frameData:
                ingestDataFrame(data)
            case Self.frameFileEnd:
                guard data.count >= 5 else { continue }
                let serverCrc = data.uint32LE(at: 1) ?? 0
                let crcOk = fileCrc == serverCrc
                let filename = currentName
                SdkLog.i("ClipUdpSync FILE_END \(filename ?? "") crcOk=\(crcOk) assembled=\(currentData.count)/\(declaredFileSize)")
                if crcOk, let filename, !currentData.isEmpty {
                    sendFileAck(true)
                    let bytes = currentData
                    let output = sessionDirectory.appendingPathComponent((filename as NSString).lastPathComponent)
                    try bytes.write(to: output, options: .atomic)
                    if filename.lowercased().hasSuffix(".opus") {
                        filesReceived += 1
                    }
                    consecutiveFileNacks = 0
                    lastNackFile = nil
                } else {
                    sendFileAck(false)
                    if filename == lastNackFile {
                        consecutiveFileNacks += 1
                    } else {
                        consecutiveFileNacks = 1
                        lastNackFile = filename
                    }
                    if consecutiveFileNacks >= maxConsecutiveFileNacks {
                        _ = await sendAtCommand("AT+CANCEL", timeout: 2)
                        throw SenseCraftVoiceError.connectionFailed("UDP file transfer failed repeatedly")
                    }
                }
                currentName = nil
                currentData.removeAll(keepingCapacity: true)
                fileCrc = 0
                resetAssembly()
                lastProgressAt = Date()
                emitOverallProgress()
            case Self.frameTransferDone:
                let done = Self.parseTransferDone(data)
                if let doneSid = done.sessionId, !doneSid.isEmpty, doneSid != sessionId {
                    SdkLog.w("ClipUdpSync TRANSFER_DONE session mismatch fw=\(doneSid) expected=\(sessionId)")
                }
                SdkLog.i("ClipUdpSync TRANSFER_DONE session=\(done.sessionId ?? "") files=\(done.fileCount ?? -1) payloadBytes=\(receivedBytes)")
                emitOverallProgress()
                return receivedBytes
            default:
                continue
            }
        }
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] content, _, _, error in
            Task { @MainActor in
                guard let self, self.connected else { return }
                if let content, !content.isEmpty {
                    self.enqueue(content)
                }
                if let error {
                    SdkLog.w("ClipUdpSync receive failed", error)
                    self.connected = false
                    return
                }
                self.receiveLoop()
            }
        }
    }

    private func enqueue(_ data: Data) {
        rxQueue.append(data)
    }

    private func recvOne(until deadline: Date) async -> Data? {
        if !earlyReplay.isEmpty {
            return earlyReplay.removeFirst()
        }
        if !rxQueue.isEmpty {
            return rxQueue.removeFirst()
        }
        while deadline.timeIntervalSinceNow > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !earlyReplay.isEmpty {
                return earlyReplay.removeFirst()
            }
            if !rxQueue.isEmpty {
                return rxQueue.removeFirst()
            }
        }
        return nil
    }

    private func send(_ data: Data) async -> Bool {
        guard let connection, connected else { return false }
        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    SdkLog.w("ClipUdpSync UDP send failed", error)
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            })
        }
    }

    private func sendFileAck(_ ok: Bool) {
        Task { @MainActor in
            _ = await send(Data([Self.frameFileAck, ok ? 0x00 : 0x01]))
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        guard connected else { return }
        var data = Data([Self.frameHeartbeat])
        var ts = UInt32(Date().timeIntervalSince1970) & 0xffffffff
        data.append(Data(bytes: &ts, count: 4))
        _ = await send(data)
    }

    private func pauseHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func resumeHeartbeat() {
        if connected { startHeartbeat() }
    }

    private static func normalizeAtCommand(_ command: String) -> String {
        var line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.uppercased().hasPrefix("AT") && !line.isEmpty {
            line = "AT+\(line)"
        }
        return line
    }

    private static func isFileTransferFrame(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        return first == frameData || first == frameFileStart || first == frameFileEnd || first == frameTransferDone
    }

    private static func looksBusy(_ resp: JSONObject) -> Bool {
        let lower = errorDetail(resp).lowercased()
        return lower.contains("already in progress") ||
            lower.contains("busy") ||
            lower.contains("in progress") ||
            lower.contains("transfer already")
    }

    private static func errorDetail(_ resp: JSONObject) -> String {
        if let msg = resp["error"] as? String, !msg.isEmpty { return msg }
        if let msg = resp["msg"] as? String, !msg.isEmpty { return msg }
        if let msg = resp["message"] as? String, !msg.isEmpty { return msg }
        if let data = resp["data"] as? JSONObject {
            if let msg = data["error"] as? String, !msg.isEmpty { return msg }
            if let msg = data["msg"] as? String, !msg.isEmpty { return msg }
            if let msg = data["message"] as? String, !msg.isEmpty { return msg }
        }
        return String(describing: resp)
    }

    private static func parseTransferDone(_ data: Data) -> (sessionId: String?, fileCount: Int?) {
        guard data.count >= 2 else { return (nil, nil) }
        let sidLen = Int(data[1])
        guard data.count >= 2 + sidLen + 4 else { return (nil, nil) }
        let sid = sidLen > 0 ? String(data: data.subdata(in: 2..<(2 + sidLen)), encoding: .utf8) : ""
        let count = data.uint32LE(at: 2 + sidLen).map(Int.init)
        return (sid?.trimmingCharacters(in: .whitespacesAndNewlines), count)
    }

    private func bool(_ value: Any?) -> Bool? {
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
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, count >= offset + 2 else { return nil }
        return UInt16(self[offset]) |
            (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}

private enum ZipArchiveReader {
    static func entries(in archive: Data) throws -> [String: Data] {
        guard let eocd = findEndOfCentralDirectory(in: archive) else {
            throw OtaFirmwareException.invalidFirmware("Firmware ZIP is invalid: missing central directory")
        }
        let entryCount = Int(archive.uint16LE(at: eocd + 10) ?? 0)
        let centralOffset = Int(archive.uint32LE(at: eocd + 16) ?? 0)
        var offset = centralOffset
        var out: [String: Data] = [:]

        for _ in 0..<entryCount {
            guard archive.uint32LE(at: offset) == 0x02014b50 else {
                throw OtaFirmwareException.invalidFirmware("Firmware ZIP is invalid: bad central directory header")
            }
            let method = Int(archive.uint16LE(at: offset + 10) ?? 0)
            let compressedSize = Int(archive.uint32LE(at: offset + 20) ?? 0)
            let uncompressedSize = Int(archive.uint32LE(at: offset + 24) ?? 0)
            let nameLen = Int(archive.uint16LE(at: offset + 28) ?? 0)
            let extraLen = Int(archive.uint16LE(at: offset + 30) ?? 0)
            let commentLen = Int(archive.uint16LE(at: offset + 32) ?? 0)
            let localOffset = Int(archive.uint32LE(at: offset + 42) ?? 0)
            let nameStart = offset + 46
            guard archive.count >= nameStart + nameLen else {
                throw OtaFirmwareException.invalidFirmware("Firmware ZIP is invalid: truncated file name")
            }
            let name = String(data: archive.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) ?? ""
            if !name.hasSuffix("/") {
                out[name] = try readLocalEntry(
                    archive: archive,
                    localOffset: localOffset,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            }
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return out
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minOffset = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= minOffset {
            if data.uint32LE(at: offset) == 0x06054b50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    private static func readLocalEntry(
        archive: Data,
        localOffset: Int,
        method: Int,
        compressedSize: Int,
        uncompressedSize: Int
    ) throws -> Data {
        guard archive.uint32LE(at: localOffset) == 0x04034b50 else {
            throw OtaFirmwareException.invalidFirmware("Firmware ZIP is invalid: bad local header")
        }
        let nameLen = Int(archive.uint16LE(at: localOffset + 26) ?? 0)
        let extraLen = Int(archive.uint16LE(at: localOffset + 28) ?? 0)
        let dataStart = localOffset + 30 + nameLen + extraLen
        guard archive.count >= dataStart + compressedSize else {
            throw OtaFirmwareException.invalidFirmware("Firmware ZIP is invalid: truncated file data")
        }
        let payload = archive.subdata(in: dataStart..<(dataStart + compressedSize))
        switch method {
        case 0:
            return payload
        case 8:
            return try inflate(payload, expectedSize: uncompressedSize)
        default:
            throw OtaFirmwareException.invalidFirmware("Firmware ZIP uses unsupported compression method \(method)")
        }
    }

    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        #if canImport(Compression)
        let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dummySrc = UnsafePointer(dummyDst)
        defer { dummyDst.deallocate() }
        var stream = compression_stream(
            dst_ptr: dummyDst,
            dst_size: 0,
            src_ptr: dummySrc,
            src_size: 0,
            state: nil
        )
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw OtaFirmwareException.invalidFirmware("Firmware ZIP inflate init failed")
        }
        defer { compression_stream_destroy(&stream) }

        let dstSize = max(expectedSize, 64 * 1024)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: dstSize)
        let bufferCount = buffer.count
        return try data.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.src_ptr = src
            stream.src_size = data.count
            repeat {
                try buffer.withUnsafeMutableBytes { dstRaw in
                    guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                        throw OtaFirmwareException.invalidFirmware("Firmware ZIP inflate buffer failed")
                    }
                    stream.dst_ptr = dst
                    stream.dst_size = bufferCount
                    status = compression_stream_process(&stream, 0)
                    let produced = bufferCount - stream.dst_size
                    if produced > 0 {
                        output.append(dst, count: produced)
                    }
                }
            } while status == COMPRESSION_STATUS_OK
            guard status == COMPRESSION_STATUS_END else {
                throw OtaFirmwareException.invalidFirmware("Firmware ZIP inflate failed")
            }
            return output
        }
        #else
        _ = data
        _ = expectedSize
        throw OtaFirmwareException.invalidFirmware("Firmware ZIP deflate is unavailable on this platform")
        #endif
    }
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

private func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    _ = data
    return ""
    #endif
}

private func md5Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    _ = data
    return ""
    #endif
}

private final class OneShotThrowingContinuation {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        take()?.resume()
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
