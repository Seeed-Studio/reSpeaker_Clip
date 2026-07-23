import Foundation

public struct RecordingStartInfo {
    public let sessionId: String
    public let mode: RecordingMode?
    public let raw: JSONObject

    public init(sessionId: String, mode: RecordingMode?, raw: JSONObject) {
        self.sessionId = sessionId
        self.mode = mode
        self.raw = raw
    }
}

public struct RecordingStopInfo {
    public let sessionId: String?
    public let durationSeconds: Int?
    public let fileCount: Int?
    public let raw: JSONObject

    public init(sessionId: String?, durationSeconds: Int?, fileCount: Int?, raw: JSONObject) {
        self.sessionId = sessionId
        self.durationSeconds = durationSeconds
        self.fileCount = fileCount
        self.raw = raw
    }
}

public struct RecordingControlInfo {
    public let sessionId: String?
    public let durationSeconds: Int?
    public let raw: JSONObject

    public init(sessionId: String?, durationSeconds: Int?, raw: JSONObject) {
        self.sessionId = sessionId
        self.durationSeconds = durationSeconds
        self.raw = raw
    }

    static func fromAtReply(_ resp: JSONObject) -> RecordingControlInfo {
        let data = (resp["data"] as? JSONObject) ?? [:]
        func string(_ value: Any?) -> String? {
            guard let value else { return nil }
            let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        func int(_ value: Any?) -> Int? {
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
        return RecordingControlInfo(
            sessionId: string(data["session"]) ?? string(resp["session"]) ?? string(data["session_id"]) ?? string(resp["session_id"]),
            durationSeconds: int(data["duration"]) ?? int(data["duration_s"]) ?? int(resp["duration"]) ?? int(resp["duration_s"]),
            raw: resp
        )
    }
}

public enum DownloadEvent {
    case started(sessionId: String, totalFiles: Int?, totalBytes: Int?)
    case fileStarted(filename: String, fileSize: Int)
    case fileProgress(filename: String, received: Int, total: Int)
    case fileCompleted(filename: String, bytes: Data, crc32: UInt32)
    case transferDone(sessionId: String, fileCount: Int)
}

public enum DownloadStartFailureKind: String {
    case sessionNotFound
    case transferBusy
    case other
}

public struct DownloadStartRetryPolicy {
    public let maxAttempts: Int
    public let retryDelay: TimeInterval
    public let retrySessionNotFound: Bool
    public let cancelBusyTransfer: Bool
    public let skipCancelWhenDeviceRecording: Bool
    public let cancelTimeout: TimeInterval
    public let cancelSettleDelay: TimeInterval
    public let statusTimeout: TimeInterval

    public init(
        maxAttempts: Int = 1,
        retryDelay: TimeInterval = 0.8,
        retrySessionNotFound: Bool = true,
        cancelBusyTransfer: Bool = false,
        skipCancelWhenDeviceRecording: Bool = true,
        cancelTimeout: TimeInterval = 5,
        cancelSettleDelay: TimeInterval = 1.2,
        statusTimeout: TimeInterval = 4
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
        self.retrySessionNotFound = retrySessionNotFound
        self.cancelBusyTransfer = cancelBusyTransfer
        self.skipCancelWhenDeviceRecording = skipCancelWhenDeviceRecording
        self.cancelTimeout = cancelTimeout
        self.cancelSettleDelay = cancelSettleDelay
        self.statusTimeout = statusTimeout
    }

    public static let resilient = DownloadStartRetryPolicy(
        maxAttempts: 4,
        cancelBusyTransfer: true
    )

    public func shouldRetry(_ kind: DownloadStartFailureKind) -> Bool {
        switch kind {
        case .sessionNotFound:
            return retrySessionNotFound
        case .transferBusy:
            return cancelBusyTransfer
        case .other:
            return false
        }
    }
}

public struct DownloadedFileArtifact {
    public let filename: String
    public let url: URL
    public let sizeBytes: Int
    public let crc32: UInt32
}

public struct DownloadSessionResult {
    public let sessionId: String
    public let directory: URL
    public let totalFiles: Int?
    public let totalBytes: Int?
    public let completedFiles: Int
    public let completedBytes: Int
    public let transferDone: (sessionId: String, fileCount: Int)?
    public let files: [DownloadedFileArtifact]

    public var isComplete: Bool {
        guard transferDone != nil else { return false }
        guard let totalFiles else { return true }
        return completedFiles >= totalFiles
    }
}

public struct DownloadMergeResult {
    public let download: DownloadSessionResult
    public let mergedUrl: URL
    public let mergedBytes: Int
    public let deletedRemoteSession: Bool
    public let deletedLocalParts: Bool
}

public struct DownloadFinalizeResult {
    public let merge: DownloadMergeResult
    public let bookmarks: [DeviceBookmarkMeta]
    public let bookmarksUrl: URL?
    public let bookmarksSaved: Bool
}

struct SessionResumeMarkers {
    let startFile: String?
    let resumeByteOffset: Int
    let resumeFileIndex: Int
}

@MainActor
public final class RecordingSession {
    public let connection: SenseCraftVoiceConnection
    public let at: AtTransport

    private var activeSessionId: String?
    private var lastDeviceTimeSyncAt: Date?

    public init(connection: SenseCraftVoiceConnection, at: AtTransport) {
        self.connection = connection
        self.at = at
    }

    public func deviceEvents() -> AsyncStream<DeviceEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { return }
                for await msg in self.at.jsonMessages() {
                    if let event = parseDeviceEvent(msg) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
        }
    }

    public func start(
        mode: RecordingMode = .normal,
        timeout: TimeInterval = 5
    ) async throws -> RecordingStartInfo {
        let cmd = mode == .enhanced ? "AT+START=enhanced" : "AT+START"
        let resp = try await at.send(cmd, timeout: timeout)
        guard bool(resp["ok"]) == true else {
            throw RecordingException("AT+START failed: \(errorDetail(resp))", raw: resp)
        }
        guard let sid = extractSession(resp), !sid.isEmpty else {
            throw RecordingException("AT+START did not return a session", raw: resp)
        }
        activeSessionId = sid
        let reportedMode = extractRecordingMode(resp) ?? mode
        return RecordingStartInfo(sessionId: sid, mode: reportedMode, raw: resp)
    }

    public func stop(timeout: TimeInterval = 8) async throws -> RecordingStopInfo {
        let resp = try await at.send("AT+STOP", timeout: timeout)
        let sid = extractSession(resp) ?? activeSessionId
        let data = (resp["data"] as? JSONObject) ?? [:]
        let dur = int(data["duration"])
        let fileCount = int(data["file_count"])
        activeSessionId = nil
        return RecordingStopInfo(sessionId: sid, durationSeconds: dur, fileCount: fileCount, raw: resp)
    }

    public func pause(timeout: TimeInterval = 5) async throws -> RecordingControlInfo {
        let resp = try await at.send("AT+PAUSE", timeout: timeout)
        try ensureSuccess(resp, command: "AT+PAUSE")
        return RecordingControlInfo.fromAtReply(resp)
    }

    public func resume(timeout: TimeInterval = 5) async throws -> RecordingControlInfo {
        let resp = try await at.send("AT+RESUME", timeout: timeout)
        try ensureSuccess(resp, command: "AT+RESUME")
        return RecordingControlInfo.fromAtReply(resp)
    }

    public func setRecordingMode(
        _ mode: RecordingMode,
        timeout: TimeInterval = 4
    ) async throws -> RecordingMode {
        let cmd = mode == .enhanced ? "AT+MODE=enhanced" : "AT+MODE=normal"
        let resp = try await at.send(cmd, timeout: timeout)
        try ensureSuccess(resp, command: "AT+MODE")
        return extractRecordingMode(resp) ?? mode
    }

    public func setDeviceTime(
        _ date: Date = Date(),
        timeout: TimeInterval = 4
    ) async throws -> JSONObject {
        let seconds = Int(date.timeIntervalSince1970.rounded())
        let resp = try await at.send("AT+TIME=\(seconds)", timeout: timeout)
        try ensureSuccess(resp, command: "AT+TIME")
        return resp
    }

    public func getDeviceTime(timeout: TimeInterval = 4) async throws -> DeviceTimeInfo {
        let resp = try await at.send("AT+TIME?", timeout: timeout)
        try ensureSuccess(resp, command: "AT+TIME?")
        return DeviceTimeInfo.fromAtReply(resp)
    }

    public func getPairingStatus(timeout: TimeInterval = 6) async throws -> PairingStatus {
        let resp = try await at.send("AT+PAIR?", timeout: timeout)
        try ensureSuccess(resp, command: "AT+PAIR?")
        return PairingStatus.fromAtReply(resp)
    }

    public func resetPairing(timeout: TimeInterval = 6) async throws -> JSONObject {
        let resp = try await at.send("AT+PAIR=reset", timeout: timeout)
        try ensureSuccess(resp, command: "AT+PAIR=reset")
        return resp
    }

    public func cancel() async {
        do {
            _ = try await at.send("AT+CANCEL", timeout: 4)
        } catch {
            SdkLog.w("RecordingSession.cancel: AT+CANCEL failed", error)
        }
        activeSessionId = nil
    }

    public func getStatus(timeout: TimeInterval = 5) async throws -> DeviceStatus {
        let resp = try await at.send("AT+GSTAT", timeout: timeout)
        guard bool(resp["ok"]) == true else {
            throw RecordingException("AT+GSTAT failed: \(errorDetail(resp))", raw: resp)
        }
        return DeviceStatus.fromAtReply(resp)
    }

    public func readRuntimeInfo(
        versionTimeout: TimeInterval = 5,
        timeTimeout: TimeInterval = 4,
        statusTimeout: TimeInterval = 4,
        pairTimeout: TimeInterval = 6
    ) async -> DeviceRuntimeInfo {
        var firmware: String?
        var rawDeviceTime: Any?
        var status: DeviceStatus?
        var pairStatus: String?
        var pairAddress: String?
        var versionReply: JSONObject?
        var timeReply: JSONObject?
        var statusReply: JSONObject?
        var pairReply: JSONObject?

        do {
            let resp = try await at.send("AT+VERSION", timeout: versionTimeout)
            versionReply = resp
            if bool(resp["ok"]) == true {
                firmware = extractRootOrDataString(resp, keys: ["firmware", "firmware_version", "version"])
            }
        } catch {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+VERSION failed", error)
        }

        do {
            let resp = try await at.send("AT+TIME?", timeout: timeTimeout)
            timeReply = resp
            if bool(resp["ok"]) == true {
                rawDeviceTime = extractRootOrDataValue(resp, keys: ["time", "timestamp", "ts"])
            }
        } catch {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+TIME? failed", error)
        }

        do {
            let resp = try await at.send("AT+GSTAT", timeout: statusTimeout)
            statusReply = resp
            if bool(resp["ok"]) == true {
                status = DeviceStatus.fromAtReply(resp)
                firmware = firmware ?? status?.firmwareVersion
            }
        } catch {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+GSTAT failed", error)
        }

        do {
            let resp = try await at.send("AT+PAIR?", timeout: pairTimeout)
            pairReply = resp
            if bool(resp["ok"]) == true {
                pairStatus = extractRootOrDataString(resp, keys: ["value", "status", "pair_status", "state"])
                pairAddress = extractRootOrDataString(resp, keys: ["addr", "address", "peer", "peer_addr"])
            }
        } catch {
            SdkLog.w("RecordingSession.readRuntimeInfo: AT+PAIR? failed", error)
        }

        return DeviceRuntimeInfo(
            firmwareVersion: firmware,
            rawDeviceTime: rawDeviceTime,
            deviceTime: parseTimestamp(rawDeviceTime),
            status: status,
            pairStatus: pairStatus,
            pairAddress: pairAddress,
            versionReply: versionReply,
            timeReply: timeReply,
            statusReply: statusReply,
            pairReply: pairReply
        )
    }

    public func syncDeviceTime(
        time: Date? = nil,
        timeout: TimeInterval = 4,
        minInterval: TimeInterval = 0,
        force: Bool = false
    ) async -> Bool {
        if !force,
           minInterval > 0,
           let last = lastDeviceTimeSyncAt,
           Date().timeIntervalSince(last) < minInterval {
            return false
        }
        do {
            _ = try await setDeviceTime(time ?? Date(), timeout: timeout)
            lastDeviceTimeSyncAt = Date()
            return true
        } catch {
            SdkLog.w("RecordingSession.syncDeviceTime failed", error)
            return false
        }
    }

    public static let userDeviceNameMaxBytes = 32
    public static let userDeviceNameClearToken = "CLEAR"

    public static func isValidUserDeviceName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard name.utf8.count <= userDeviceNameMaxBytes else { return false }
        for scalar in name.unicodeScalars where scalar.value < 0x20 {
            return false
        }
        return true
    }

    public func getUserDeviceName(timeout: TimeInterval = 5) async throws -> String {
        let resp = try await at.send("AT+NAME?", timeout: timeout)
        guard bool(resp["ok"]) == true else {
            throw RecordingException("AT+NAME? failed: \(errorDetail(resp))", raw: resp)
        }
        if let data = resp["data"] as? JSONObject {
            if let name = data["name"] as? String { return name }
            if let value = data["name"] {
                return String(describing: value)
            }
        }
        if let root = resp["name"] as? String { return root }
        if let root = resp["value"] {
            return String(describing: root)
        }
        return ""
    }

    public func setUserDeviceName(_ name: String?, timeout: TimeInterval = 5) async throws {
        let cmd: String
        if let name, !name.isEmpty {
            guard Self.isValidUserDeviceName(name) else {
                throw RecordingException("AT+NAME requires 1-32 UTF-8 chars without control characters.", raw: nil)
            }
            cmd = "AT+NAME=\(name)"
        } else {
            cmd = "AT+NAME=\(Self.userDeviceNameClearToken)"
        }
        let resp = try await at.send(cmd, timeout: timeout)
        guard bool(resp["ok"]) == true else {
            throw RecordingException("AT+NAME failed: \(errorDetail(resp))", raw: resp)
        }
    }

    public func mark(
        note: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> DeviceBookmarkMarkResult {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = (trimmedNote?.isEmpty == false) ? "AT+MARK=\(trimmedNote!)" : "AT+MARK"
        let resp = try await at.send(cmd, timeout: timeout)
        let data = (resp["data"] as? JSONObject) ?? [:]
        return DeviceBookmarkMarkResult(
            ok: bool(resp["ok"]) == true,
            sessionId: string(data["session"]) ?? string(data["session_id"]) ?? string(resp["session"]) ?? string(resp["session_id"]),
            markCount: int(data["mark_count"]) ?? int(resp["mark_count"]) ?? int(data["count"]) ?? int(resp["count"]),
            offsetSeconds: int(data["offset"]) ?? int(resp["offset"]),
            raw: resp
        )
    }

    public func listFiles(
        sessionId: String? = nil,
        timeout: TimeInterval = 8
    ) async throws -> [DeviceFileMeta] {
        let cmd = sessionId == nil ? "AT+LIST" : "AT+LIST=\(sessionId!)"
        let resp = try await at.send(cmd, timeout: timeout)
        guard bool(resp["ok"]) == true else {
            throw RecordingException("AT+LIST failed: \(errorDetail(resp))", raw: resp)
        }
        return parseFileList(resp)
    }

    public func listAllFiles(
        perPage: Int = 10,
        maxPages: Int = 100,
        timeout: TimeInterval = 8
    ) async throws -> [DeviceFileMeta] {
        var out: [DeviceFileMeta] = []
        for page in 1...max(1, maxPages) {
            let cmd = page == 1 ? "AT+LIST" : "AT+LIST?\(page)&\(perPage)"
            let resp = try await at.send(cmd, timeout: timeout)
            try ensureSuccess(resp, command: "AT+LIST")
            let items = parseFileList(resp)
            out.append(contentsOf: items)
            if items.isEmpty { break }
            if let total = extractListTotal(resp), out.count >= total { break }
        }
        return out
    }

    public func listBookmarks(
        sessionId: String,
        timeout: TimeInterval = 6,
        perPage: Int? = nil,
        maxPages: Int = 100
    ) async throws -> [DeviceBookmarkMeta] {
        guard let perPage, perPage > 0 else {
            let resp = try await at.send("AT+MARKS=\(sessionId)", timeout: timeout)
            try ensureSuccess(resp, command: "AT+MARKS")
            return parseBookmarkList(resp, defaultSessionId: sessionId)
        }

        var out: [DeviceBookmarkMeta] = []
        for page in 1...max(1, maxPages) {
            let resp = try await at.send("AT+MARKS=\(sessionId)?\(page)&\(perPage)", timeout: timeout)
            if bool(resp["ok"]) != true && page == 1 {
                let fallback = try await at.send("AT+MARKS=\(sessionId)", timeout: timeout)
                try ensureSuccess(fallback, command: "AT+MARKS")
                let items = parseBookmarkList(fallback, defaultSessionId: sessionId)
                out.append(contentsOf: items)
                if items.isEmpty { break }
                if let total = extractBookmarkTotal(fallback), out.count >= total { break }
                continue
            }
            try ensureSuccess(resp, command: "AT+MARKS")
            let items = parseBookmarkList(resp, defaultSessionId: sessionId)
            out.append(contentsOf: items)
            if items.isEmpty { break }
            if let total = extractBookmarkTotal(resp), out.count >= total { break }
        }
        return out
    }

    public func deleteSession(
        _ sessionId: String,
        timeout: TimeInterval = 8
    ) async throws -> JSONObject {
        let resp = try await at.send("AT+DELETE=\(sessionId)", timeout: timeout)
        try ensureSuccess(resp, command: "AT+DELETE")
        return resp
    }

    public func purgeSessions(timeout: TimeInterval = 10) async throws -> JSONObject {
        let resp = try await at.send("AT+PURGE", timeout: timeout)
        try ensureSuccess(resp, command: "AT+PURGE")
        return resp
    }

    public func factoryReset(timeout: TimeInterval = 10) async throws -> JSONObject {
        let resp = try await at.send("AT+FACTORY=confirm", timeout: timeout)
        try ensureSuccess(resp, command: "AT+FACTORY")
        return resp
    }

    public func download(
        sessionId: String,
        startFile: String? = nil,
        timeout: TimeInterval = 600,
        startCommandTimeout: TimeInterval = 10,
        retryPolicy: DownloadStartRetryPolicy = .resilient
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            var currentFile: String?
            var currentExpected = 0
            var currentBuffer = Data()
            let finishState = RecordingDownloadFinishState()

            func finish(_ error: Error? = nil) {
                guard finishState.finishIfNeeded() else { return }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }

            Task {
                for await bytes in connection.fileDataNotifyBytes() {
                    let frame = parseClipFileDataNotify(bytes)
                    switch frame {
                    case .fileStart(let filename, let fileSize):
                        currentFile = filename
                        currentExpected = fileSize
                        currentBuffer = Data()
                        continuation.yield(.fileStarted(filename: filename, fileSize: fileSize))
                    case .data(_, let payload):
                        guard let currentFile else { continue }
                        currentBuffer.append(payload)
                        continuation.yield(.fileProgress(filename: currentFile, received: currentBuffer.count, total: currentExpected))
                    case .fileEnd(let crc32):
                        let filename = currentFile ?? ""
                        continuation.yield(.fileCompleted(filename: filename, bytes: currentBuffer, crc32: crc32))
                        currentFile = nil
                        currentExpected = 0
                        currentBuffer = Data()
                    case .transferDone(let sid, let count):
                        continuation.yield(.transferDone(sessionId: sid, fileCount: count))
                        finish()
                        return
                    case .raw(let raw):
                        if currentFile != nil {
                            currentBuffer.append(raw)
                        }
                    case .invalid(let reason):
                        SdkLog.w("RecordingSession.download malformed file frame: \(reason)")
                    }
                }
                finish()
            }

            Task {
                do {
                    let cmd = (startFile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                        ? "AT+DOWNLOAD=\(sessionId):\(startFile!.trimmingCharacters(in: .whitespacesAndNewlines))"
                        : "AT+DOWNLOAD=\(sessionId)"
                    let resp = try await self.sendDownloadStartWithRetry(
                        cmd,
                        timeout: startCommandTimeout,
                        retryPolicy: retryPolicy
                    )
                    guard bool(resp["ok"]) == true else {
                        finish(RecordingException("AT+DOWNLOAD failed: \(errorDetail(resp))", raw: resp, code: Self.downloadFailureKind(from: resp).rawValue))
                        return
                    }
                    let data = (resp["data"] as? JSONObject) ?? [:]
                    continuation.yield(
                        .started(
                            sessionId: sessionId,
                            totalFiles: int(data["files"]) ?? int(data["file_count"]),
                            totalBytes: int(data["bytes"]) ?? int(data["size"])
                        )
                    )
                } catch {
                    finish(error)
                }
            }

            continuation.onTermination = { _ in
                finishState.markFinished()
            }
        }
    }

    public func downloadToDirectory(
        sessionId: String,
        directory: URL,
        startFile: String? = nil,
        timeout: TimeInterval = 600,
        startCommandTimeout: TimeInterval = 10,
        retryPolicy: DownloadStartRetryPolicy = .resilient,
        createDirectory: Bool = true,
        verifyCrc: Bool = true
    ) async throws -> DownloadSessionResult {
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var totalFiles: Int?
        var totalBytes: Int?
        var completedFiles = 0
        var completedBytes = 0
        var transferDone: (sessionId: String, fileCount: Int)?
        var files: [DownloadedFileArtifact] = []

        for try await event in download(
            sessionId: sessionId,
            startFile: startFile,
            timeout: timeout,
            startCommandTimeout: startCommandTimeout,
            retryPolicy: retryPolicy
        ) {
            switch event {
            case .started(_, let filesTotal, let bytesTotal):
                totalFiles = filesTotal
                totalBytes = bytesTotal
            case .fileStarted:
                continue
            case .fileProgress:
                continue
            case .fileCompleted(let filename, let bytes, let crc32):
                let safe = Self.safeDownloadFilename(filename, fallbackIndex: completedFiles + 1)
                let output = directory.appendingPathComponent(safe)
                if verifyCrc {
                    let localCrc = crc32IEEE(bytes)
                    guard localCrc == crc32 else {
                        try? FileManager.default.removeItem(at: output)
                        throw RecordingException(
                            "Downloaded file CRC mismatch for \(safe) (local=0x\(String(localCrc, radix: 16)), device=0x\(String(crc32, radix: 16)))",
                            raw: nil
                        )
                    }
                }
                try bytes.write(to: output, options: .atomic)
                files.append(DownloadedFileArtifact(
                    filename: safe,
                    url: output,
                    sizeBytes: bytes.count,
                    crc32: crc32
                ))
                completedFiles += 1
                completedBytes += bytes.count
            case .transferDone(let sid, let fileCount):
                transferDone = (sid, fileCount)
            }
        }

        return DownloadSessionResult(
            sessionId: sessionId,
            directory: directory,
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            completedFiles: completedFiles,
            completedBytes: completedBytes,
            transferDone: transferDone,
            files: files
        )
    }

    public func downloadToDirectoryWithResume(
        sessionId: String,
        directory: URL,
        startFile: String? = nil,
        dbReceivedBytes: Int = 0,
        maxAttempts: Int = 3,
        timeout: TimeInterval = 600,
        startCommandTimeout: TimeInterval = 10,
        retryPolicy: DownloadStartRetryPolicy = .resilient,
        createDirectory: Bool = true,
        verifyCrc: Bool = true,
        retryDelay: TimeInterval = 0.6
    ) async throws -> DownloadSessionResult {
        guard maxAttempts > 0 else {
            throw SenseCraftVoiceError.internalError("maxAttempts must be >= 1")
        }

        var lastResult: DownloadSessionResult?
        var lastError: Error?
        for attempt in 1...maxAttempts {
            let resumeStartFile = try Self.resolveSessionResumeStartFile(
                sessionDirectory: directory,
                preferredStartFile: startFile
            )
            _ = try Self.resolveSessionResumeMarkers(
                sessionDirectory: directory,
                startFile: resumeStartFile,
                dbReceivedBytes: dbReceivedBytes
            )
            do {
                let result = try await downloadToDirectory(
                    sessionId: sessionId,
                    directory: directory,
                    startFile: resumeStartFile,
                    timeout: timeout,
                    startCommandTimeout: startCommandTimeout,
                    retryPolicy: retryPolicy,
                    createDirectory: createDirectory,
                    verifyCrc: verifyCrc
                )
                lastResult = result
                if result.isComplete || attempt == maxAttempts {
                    return result
                }
                lastError = RecordingException("AT+DOWNLOAD finished without TRANSFER_DONE", raw: nil)
            } catch {
                lastError = error
                if attempt >= maxAttempts {
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: UInt64(max(0, retryDelay) * 1_000_000_000))
            await cancel()
        }

        if let lastResult { return lastResult }
        if let lastError { throw lastError }
        throw SenseCraftVoiceError.internalError("downloadToDirectoryWithResume failed")
    }

    public func downloadMergeAndMaybeDeleteSession(
        sessionId: String,
        directory: URL,
        startFile: String? = nil,
        dbReceivedBytes: Int = 0,
        maxAttempts: Int = 3,
        timeout: TimeInterval = 600,
        startCommandTimeout: TimeInterval = 10,
        retryPolicy: DownloadStartRetryPolicy = .resilient,
        createDirectory: Bool = true,
        verifyCrc: Bool = true,
        retryDelay: TimeInterval = 0.6,
        mergedUrl: URL? = nil,
        deleteRemoteSessionAfterMerge: Bool = false,
        deleteLocalPartsAfterMerge: Bool = false
    ) async throws -> DownloadMergeResult {
        let download = try await downloadToDirectoryWithResume(
            sessionId: sessionId,
            directory: directory,
            startFile: startFile,
            dbReceivedBytes: dbReceivedBytes,
            maxAttempts: maxAttempts,
            timeout: timeout,
            startCommandTimeout: startCommandTimeout,
            retryPolicy: retryPolicy,
            createDirectory: createDirectory,
            verifyCrc: verifyCrc,
            retryDelay: retryDelay
        )
        guard download.isComplete else {
            throw RecordingException("downloadMergeAndMaybeDeleteSession requires a complete download", raw: nil)
        }

        let target = mergedUrl ?? Self.defaultMergedUrl(directory: directory, sessionId: sessionId)
        try? FileManager.default.removeItem(at: target)
        guard let merged = try Self.mergeSessionOpusPartsInDirectory(directory: directory, mergedUrl: target) else {
            throw RecordingException("No session parts available to merge for \(sessionId)", raw: nil)
        }

        let mergedBytes = (try? Data(contentsOf: merged).count) ?? 0
        let deletedRemoteSession = deleteRemoteSessionAfterMerge
            ? (try await deleteSessionAfterLocalVerification(
                sessionId,
                mergedUrl: merged,
                expectedBytes: nil,
                verifiedBytes: download.totalBytes ?? mergedBytes
            ))
            : false

        let deletedLocalParts = deleteLocalPartsAfterMerge
            ? Self.deleteLocalSessionParts(directory: directory, keepUrl: merged)
            : false

        return DownloadMergeResult(
            download: download,
            mergedUrl: merged,
            mergedBytes: mergedBytes,
            deletedRemoteSession: deletedRemoteSession,
            deletedLocalParts: deletedLocalParts
        )
    }

    public func downloadMergeFetchBookmarksAndMaybeDeleteSession(
        sessionId: String,
        directory: URL,
        startFile: String? = nil,
        dbReceivedBytes: Int = 0,
        maxAttempts: Int = 3,
        timeout: TimeInterval = 600,
        startCommandTimeout: TimeInterval = 10,
        retryPolicy: DownloadStartRetryPolicy = .resilient,
        createDirectory: Bool = true,
        verifyCrc: Bool = true,
        retryDelay: TimeInterval = 0.6,
        mergedUrl: URL? = nil,
        deleteRemoteSessionAfterMerge: Bool = false,
        deleteLocalPartsAfterMerge: Bool = false,
        saveBookmarksJson: Bool = true,
        bookmarksUrl: URL? = nil,
        bookmarksTimeout: TimeInterval = 6,
        bookmarksPerPage: Int = 10,
        bookmarksMaxPages: Int = 100
    ) async throws -> DownloadFinalizeResult {
        let download = try await downloadToDirectoryWithResume(
            sessionId: sessionId,
            directory: directory,
            startFile: startFile,
            dbReceivedBytes: dbReceivedBytes,
            maxAttempts: maxAttempts,
            timeout: timeout,
            startCommandTimeout: startCommandTimeout,
            retryPolicy: retryPolicy,
            createDirectory: createDirectory,
            verifyCrc: verifyCrc,
            retryDelay: retryDelay
        )
        guard download.isComplete else {
            throw RecordingException("downloadMergeFetchBookmarksAndMaybeDeleteSession requires a complete download", raw: nil)
        }

        let target = mergedUrl ?? Self.defaultMergedUrl(directory: directory, sessionId: sessionId)
        try? FileManager.default.removeItem(at: target)
        guard let merged = try Self.mergeSessionOpusPartsInDirectory(directory: directory, mergedUrl: target) else {
            throw RecordingException("No session parts available to merge for \(sessionId)", raw: nil)
        }

        let mergedBytes = (try? Data(contentsOf: merged).count) ?? 0
        let bookmarks: [DeviceBookmarkMeta]
        do {
            bookmarks = try await listBookmarks(
                sessionId: sessionId,
                timeout: bookmarksTimeout,
                perPage: bookmarksPerPage,
                maxPages: bookmarksMaxPages
            )
        } catch {
            SdkLog.w("RecordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession: AT+MARKS failed (non-fatal)", error)
            bookmarks = []
        }

        var savedUrl: URL?
        var bookmarksSaved = false
        if saveBookmarksJson {
            let targetUrl = bookmarksUrl ?? Self.bookmarksSidecarUrl(forMergedUrl: merged)
            do {
                savedUrl = try Self.writeBookmarksJsonSidecar(url: targetUrl, bookmarks: bookmarks)
                bookmarksSaved = true
            } catch {
                SdkLog.w("RecordingSession.downloadMergeFetchBookmarksAndMaybeDeleteSession: save bookmarks json failed (non-fatal)", error)
            }
        }

        let deletedRemoteSession = deleteRemoteSessionAfterMerge
            ? (try await deleteSessionAfterLocalVerification(
                sessionId,
                mergedUrl: merged,
                expectedBytes: nil,
                verifiedBytes: download.totalBytes ?? mergedBytes
            ))
            : false
        let deletedLocalParts = deleteLocalPartsAfterMerge
            ? Self.deleteLocalSessionParts(directory: directory, keepUrl: merged)
            : false

        return DownloadFinalizeResult(
            merge: DownloadMergeResult(
                download: download,
                mergedUrl: merged,
                mergedBytes: mergedBytes,
                deletedRemoteSession: deletedRemoteSession,
                deletedLocalParts: deletedLocalParts
            ),
            bookmarks: bookmarks,
            bookmarksUrl: savedUrl,
            bookmarksSaved: bookmarksSaved
        )
    }

    public func deleteSessionAfterLocalVerification(
        _ sessionId: String,
        mergedUrl: URL,
        expectedBytes: Int? = nil,
        verifiedBytes: Int? = nil,
        timeout: TimeInterval = 8,
        statusTimeout: TimeInterval = 5,
        minCompletionRatio: Double = 0.95
    ) async throws -> Bool {
        do {
            let values = try mergedUrl.resourceValues(forKeys: [.fileSizeKey])
            let actualSize = values.fileSize ?? 0
            let expected = Self.canonicalTransferExpectedBytes(
                dbExpected: expectedBytes,
                transferredTotal: verifiedBytes ?? 0
            )
            guard Self.localMergedFileCompleteForDelete(
                actualSize: actualSize,
                expectedBytes: expected,
                verifiedBytes: verifiedBytes,
                minCompletionRatio: minCompletionRatio
            ) else {
                return false
            }

            let status = try await getStatus(timeout: statusTimeout)
            let activeRoot = Self.sessionRoot(status.sessionId)
            let ourRoot = Self.sessionRoot(sessionId)
            if (status.isRecording || status.state == "paused"),
               !activeRoot.isEmpty,
               activeRoot == ourRoot {
                return false
            }

            let resp = try await deleteSession(sessionId, timeout: timeout)
            return bool(resp["ok"]) == true
        } catch {
            SdkLog.w("RecordingSession.deleteSessionAfterLocalVerification failed", error)
            return false
        }
    }

    private func errorDetail(_ resp: JSONObject) -> String {
        if let msg = resp["error"] as? String, !msg.isEmpty { return msg }
        if let msg = resp["msg"] as? String, !msg.isEmpty { return msg }
        if let msg = resp["message"] as? String, !msg.isEmpty { return msg }
        if let data = resp["data"] as? JSONObject, let msg = data["msg"] as? String, !msg.isEmpty {
            return msg
        }
        return String(describing: resp)
    }

    private func extractSession(_ resp: JSONObject) -> String? {
        if let session = resp["session"] as? String, !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session
        }
        if let data = resp["data"] as? JSONObject {
            if let session = data["session"] as? String, !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return session
            }
        }
        return nil
    }

    private func extractRecordingMode(_ resp: JSONObject) -> RecordingMode? {
        guard let data = resp["data"] as? JSONObject,
              let mode = data["mode"] else { return nil }
        let s = String(describing: mode).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "enhanced" || s == "1" { return .enhanced }
        if s == "normal" || s == "0" { return .normal }
        return nil
    }

    private func parseFileList(_ resp: JSONObject) -> [DeviceFileMeta] {
        guard let data = resp["data"] as? JSONObject else { return [] }
        let items = data["items"] as? [Any] ?? data["files"] as? [Any] ?? []
        return items.compactMap { raw in
            guard let m = raw as? JSONObject else { return nil }
            let path = string(m["path"]) ?? string(m["file"]) ?? ""
            guard !path.isEmpty else { return nil }
            return DeviceFileMeta(
                deviceId: "",
                path: path,
                name: string(m["name"]) ?? path.split(separator: "/").last.map(String.init) ?? path,
                sizeBytes: int(m["size"]) ?? int(m["bytes"]) ?? 0,
                durationSeconds: int(m["duration"]) ?? 0,
                bookmarkCount: int(m["bookmark_count"]) ?? int(m["bookmarks"]) ?? 0,
                createdAt: parseTimestamp(m["created_at"] ?? m["mtime"])
            )
        }
    }

    private func parseBookmarkList(_ resp: JSONObject, defaultSessionId: String? = nil) -> [DeviceBookmarkMeta] {
        guard let data = resp["data"] as? JSONObject else { return [] }
        let items = data["items"] as? [Any] ?? data["bookmarks"] as? [Any] ?? data["marks"] as? [Any] ?? []
        return items.compactMap { raw in
            guard let m = raw as? JSONObject else { return nil }
            return DeviceBookmarkMeta.fromJson(m, defaultSessionId: defaultSessionId)
        }
    }

    private func parseTimestamp(_ value: Any?) -> Date? {
        switch value {
        case let value as Int:
            let ms = value > 4_102_444_800 ? value : value * 1000
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        case let value as NSNumber:
            let v = value.int64Value
            let ms = v > 4_102_444_800 ? v : v * 1000
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        case let value as String:
            if let date = ISO8601DateFormatter().date(from: value) {
                return date
            }
            if let n = Int(value) {
                let ms = n > 4_102_444_800 ? n : n * 1000
                return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            }
            return nil
        default:
            return nil
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

    private func ensureSuccess(_ resp: JSONObject, command: String) throws {
        guard bool(resp["ok"]) == true else {
            throw RecordingException("\(command) failed: \(errorDetail(resp))", raw: resp)
        }
    }

    private func extractRootOrDataValue(_ resp: JSONObject, keys: [String]) -> Any? {
        let data = (resp["data"] as? JSONObject) ?? [:]
        for key in keys {
            if let value = data[key] ?? resp[key] {
                return value
            }
        }
        return nil
    }

    private func extractRootOrDataString(_ resp: JSONObject, keys: [String]) -> String? {
        guard let value = extractRootOrDataValue(resp, keys: keys) else { return nil }
        let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func extractListTotal(_ resp: JSONObject) -> Int? {
        let data = (resp["data"] as? JSONObject) ?? [:]
        return int(data["total"]) ?? int(resp["total"]) ?? int(data["count"]) ?? int(resp["count"]) ?? int(data["files"]) ?? int(resp["files"])
    }

    private func extractBookmarkTotal(_ resp: JSONObject) -> Int? {
        let data = (resp["data"] as? JSONObject) ?? [:]
        return int(data["total"]) ?? int(resp["total"]) ?? int(data["count"]) ?? int(resp["count"])
    }

    private func sendDownloadStartWithRetry(
        _ command: String,
        timeout: TimeInterval,
        retryPolicy: DownloadStartRetryPolicy
    ) async throws -> JSONObject {
        guard retryPolicy.maxAttempts > 0 else {
            throw SenseCraftVoiceError.internalError("retryPolicy.maxAttempts must be >= 1")
        }

        var lastResp: JSONObject?
        for attempt in 1...retryPolicy.maxAttempts {
            if attempt > 1 {
                try await Task.sleep(nanoseconds: UInt64(max(0, retryPolicy.retryDelay) * 1_000_000_000))
            }

            let resp = try await at.send(command, timeout: timeout)
            lastResp = resp
            guard bool(resp["ok"]) != true else { return resp }

            let kind = Self.downloadFailureKind(from: resp)
            guard attempt < retryPolicy.maxAttempts, retryPolicy.shouldRetry(kind) else {
                return resp
            }

            if kind == .transferBusy {
                if retryPolicy.skipCancelWhenDeviceRecording, await deviceAppearsRecordingOrPaused(timeout: retryPolicy.statusTimeout) {
                    SdkLog.w("RecordingSession.download: device is recording/paused; skip AT+CANCEL and let caller retry later")
                    return resp
                }
                await cancelBusyTransferBeforeRetry(retryPolicy)
            }
        }

        return lastResp ?? ["ok": false, "error": "no reply"]
    }

    private func deviceAppearsRecordingOrPaused(timeout: TimeInterval) async -> Bool {
        do {
            let resp = try await at.send("AT+GSTAT", timeout: timeout)
            guard bool(resp["ok"]) == true else { return false }
            let status = DeviceStatus.fromAtReply(resp)
            return status.isRecording || status.state == "paused"
        } catch {
            SdkLog.w("RecordingSession.download: GSTAT before busy-cancel failed", error)
            return false
        }
    }

    private func cancelBusyTransferBeforeRetry(_ policy: DownloadStartRetryPolicy) async {
        do {
            SdkLog.w("RecordingSession.download: AT+DOWNLOAD busy; sending AT+CANCEL before retry")
            _ = try await at.send("AT+CANCEL", timeout: policy.cancelTimeout)
        } catch {
            SdkLog.w("RecordingSession.download: AT+CANCEL before retry failed", error)
        }
        try? await Task.sleep(nanoseconds: UInt64(max(0, policy.cancelSettleDelay) * 1_000_000_000))
    }

    private static func downloadFailureKind(from resp: JSONObject) -> DownloadStartFailureKind {
        let detail = errorDetail(from: resp).lowercased()
        if detail.contains("session not found") || detail.contains("file not found") || detail.contains("not found") {
            return .sessionNotFound
        }
        if detail.contains("transfer already in progress") || detail.contains("already in progress") || detail.contains("busy") {
            return .transferBusy
        }
        return .other
    }

    private static func errorDetail(from resp: JSONObject) -> String {
        if let msg = resp["error"] as? String, !msg.isEmpty { return msg }
        if let msg = resp["msg"] as? String, !msg.isEmpty { return msg }
        if let msg = resp["message"] as? String, !msg.isEmpty { return msg }
        if let data = resp["data"] as? JSONObject, let msg = data["msg"] as? String, !msg.isEmpty {
            return msg
        }
        return String(describing: resp)
    }

    static func canonicalTransferExpectedBytes(
        dbExpected: Int?,
        transferredTotal: Int
    ) -> Int? {
        guard transferredTotal > 0 else { return dbExpected }
        guard let dbExpected, dbExpected > 0 else { return transferredTotal }
        if dbExpected > Int((Double(transferredTotal) * 1.05).rounded()) {
            return transferredTotal
        }
        return dbExpected
    }

    static func localMergedFileCompleteForDelete(
        actualSize: Int,
        expectedBytes: Int? = nil,
        verifiedBytes: Int? = nil,
        minCompletionRatio: Double = 0.95
    ) -> Bool {
        guard actualSize > 0 else { return false }
        guard minCompletionRatio > 0, minCompletionRatio <= 1 else { return false }
        let expected = expectedBytes ?? 0
        if expected > 0 {
            return actualSize >= Int((Double(expected) * minCompletionRatio).rounded())
        }
        let verified = verifiedBytes ?? 0
        if verified > 0 {
            return actualSize >= Int((Double(verified) * minCompletionRatio).rounded())
        }
        return false
    }

    static func safeDownloadFilename(
        _ filename: String,
        fallbackIndex: Int
    ) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? String(format: "part_%04d.opus", fallbackIndex)
            : trimmed
        let withExt = name.lowercased().hasSuffix(".opus") ? name : "\(name).opus"
        return BleTransferFrameHandler.sanitizeFilename(withExt)
    }

    static func defaultMergedUrl(directory: URL, sessionId: String) -> URL {
        let safe = BleTransferFrameHandler.sanitizeFilename(sessionId)
        let stem = safe.lowercased().hasSuffix(".opus") ? safe : "\(safe).opus"
        return directory.appendingPathComponent(stem)
    }

    static func bookmarksSidecarUrl(forMergedUrl mergedUrl: URL) -> URL {
        let base = mergedUrl.deletingPathExtension().lastPathComponent
        return mergedUrl.deletingLastPathComponent().appendingPathComponent("\(base)_bookmarks.json")
    }

    static func writeBookmarksJsonSidecar(
        url: URL,
        bookmarks: [DeviceBookmarkMeta]
    ) throws -> URL {
        let items = bookmarks.map { bookmark -> JSONObject in
            var item = bookmark.raw
            if let sessionId = bookmark.sessionId {
                item["session"] = sessionId
            }
            if let markCount = bookmark.markCount {
                item["mark_count"] = markCount
            }
            if let offsetSeconds = bookmark.offsetSeconds {
                item["offset"] = offsetSeconds
            }
            if let note = bookmark.note {
                item["note"] = note
            }
            return item
        }
        let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func deleteLocalSessionParts(directory: URL, keepUrl: URL) -> Bool {
        let fm = FileManager.default
        let keep = keepUrl.resolvingSymlinksInPath().standardizedFileURL
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        var deletedAny = false
        for entry in entries {
            let lower = entry.lastPathComponent.lowercased()
            guard lower.hasSuffix(".opus") || lower.hasSuffix(".opus.part") else { continue }
            guard entry.resolvingSymlinksInPath().standardizedFileURL != keep else { continue }
            do {
                try fm.removeItem(at: entry)
                deletedAny = true
            } catch {
                SdkLog.w("RecordingSession.deleteLocalSessionParts failed", error)
            }
        }
        return deletedAny
    }

    static func sessionRoot(_ sessionId: String?) -> String {
        let trimmed = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let slash = trimmed.firstIndex(of: "/") {
            return String(trimmed[..<slash])
        }
        return trimmed
    }

    static func resolveSessionResumeStartFile(
        sessionDirectory: URL,
        preferredStartFile: String? = nil
    ) throws -> String? {
        if let preferredStartFile {
            let trimmed = preferredStartFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let parts = entries
            .filter { entry in
                let lower = entry.lastPathComponent.lowercased()
                return lower.hasSuffix(".opus") && !lower.hasSuffix(".opus.part")
            }
            .filter { entry in
                guard let values = try? entry.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize else {
                    return false
                }
                return size > 0
            }
        guard !parts.isEmpty else { return nil }

        let indices = parts.compactMap { entry -> Int? in
            let name = entry.lastPathComponent.lowercased()
            let canonical = name.hasSuffix(".opus.part") ? String(name.dropLast(".part".count)) : name
            return BleTransferFrameHandler.partNumberFromFilename(canonical)
        }.filter { $0 > 0 }
        guard let maxIndex = indices.max() else { return nil }
        let existing = Set(indices)
        for index in 1...maxIndex where !existing.contains(index) {
            return String(format: "%04d.opus", index)
        }
        return String(format: "%04d.opus", maxIndex + 1)
    }

    static func resolveSessionResumeMarkers(
        sessionDirectory: URL,
        startFile: String? = nil,
        dbReceivedBytes: Int = 0
    ) throws -> SessionResumeMarkers {
        let disk = try canonicalSessionCompleteBytes(sessionDirectory: sessionDirectory)
        let offset = max(max(dbReceivedBytes, 0), disk)
        let resumeIndex = resumeFileIndexFromStartFile(startFile)
        return SessionResumeMarkers(startFile: startFile, resumeByteOffset: offset, resumeFileIndex: resumeIndex)
    }

    private static func canonicalSessionCompleteBytes(sessionDirectory: URL) throws -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var total = 0
        for entry in entries {
            let lower = entry.lastPathComponent.lowercased()
            guard lower.hasSuffix(".opus"), !lower.hasSuffix(".opus.part") else { continue }
            if let values = try? entry.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize, size > 0 {
                total += size
            }
        }
        return total
    }

    private static func resumeFileIndexFromStartFile(_ startFile: String?) -> Int {
        guard let startFile else { return 0 }
        let trimmed = startFile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return 0 }
        let pattern = try? NSRegularExpression(pattern: #"^(\d{1,6})\.opus$"#)
        guard let pattern,
              let match = pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: trimmed),
              let n = Int(trimmed[range]),
              n > 1 else {
            return 0
        }
        return n - 1
    }

    private static func sessionPartNumber(from filename: String) -> Int? {
        let lower = filename.lowercased()
        let canonical = lower.hasSuffix(".opus.part") ? String(lower.dropLast(".part".count)) : lower
        return BleTransferFrameHandler.partNumberFromFilename(canonical)
    }

    static func mergeSessionOpusPartsInDirectory(
        directory: URL,
        mergedUrl: URL
    ) throws -> URL? {
        let fm = FileManager.default
        try? fm.removeItem(at: mergedUrl)
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        let parts = entries
            .filter { entry in
                let lower = entry.lastPathComponent.lowercased()
                return lower.hasSuffix(".opus") || lower.hasSuffix(".opus.part")
            }
            .sorted { lhs, rhs in
                let lp = sessionPartNumber(from: lhs.lastPathComponent) ?? Int.max
                let rp = sessionPartNumber(from: rhs.lastPathComponent) ?? Int.max
                if lp != rp { return lp < rp }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
        guard !parts.isEmpty else { return nil }

        fm.createFile(atPath: mergedUrl.path, contents: nil)
        let handle = try FileHandle(forWritingTo: mergedUrl)
        defer { try? handle.close() }

        var copiedAny = false
        for part in parts {
            let data = try Data(contentsOf: part)
            if !data.isEmpty {
                handle.write(data)
                copiedAny = true
            }
        }
        try handle.synchronize()
        return copiedAny ? mergedUrl : nil
    }
}

public struct RecordingException: Error, CustomStringConvertible {
    public let message: String
    public let raw: JSONObject?
    public let code: String?

    public init(_ message: String, raw: JSONObject?, code: String? = nil) {
        self.message = message
        self.raw = raw
        self.code = code
    }

    public var description: String {
        if let code {
            return "RecordingException(\(code)): \(message)"
        }
        return "RecordingException: \(message)"
    }
}

private final class RecordingDownloadFinishState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finishIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
