import Foundation
import CoreBluetooth

@MainActor
public final class AtTransport {
    public let connection: SenseCraftVoiceConnection

    private let messageHub = BroadcastHub<JSONObject>()
    private let pumpTask: Task<Void, Never>
    private let sendQueue = SerialAsyncQueue()

    public init(connection: SenseCraftVoiceConnection) {
        self.connection = connection
        let hub = messageHub
        let stream = connection.responseNotifyBytes()
        let framer = JsonObjectFramer()
        self.pumpTask = Task {
            for await chunk in stream {
                let text = String(decoding: chunk, as: UTF8.self)
                for json in framer.feed(text) {
                    if let msg = Self.decodeJsonObject(json) {
                        hub.publish(msg)
                    }
                }
            }
            hub.finish()
        }
    }

    deinit {
        pumpTask.cancel()
    }

    public func jsonMessages() -> AsyncStream<JSONObject> {
        messageHub.stream()
    }

    public func send(
        _ atCommand: String,
        timeout: TimeInterval = 5,
        withoutResponse: Bool = false,
        interChunkDelay: TimeInterval = 0.016
    ) async throws -> JSONObject {
        try await sendQueue.run {
            try await self.sendOnce(
                atCommand,
                timeout: timeout,
                withoutResponse: withoutResponse,
                interChunkDelay: interChunkDelay
            )
        }
    }

    public func writeCommandOnly(
        _ atCommand: String,
        withoutResponse: Bool = false,
        interChunkDelay: TimeInterval = 0.016
    ) async throws {
        try await connection.writeCommand(
            atCommand,
            withoutResponse: withoutResponse,
            interChunkDelay: interChunkDelay
        )
    }

    private func sendOnce(
        _ atCommand: String,
        timeout: TimeInterval,
        withoutResponse: Bool,
        interChunkDelay: TimeInterval
    ) async throws -> JSONObject {
        let stream = messageHub.stream()
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            var matcherTask: Task<Void, Never>?

            matcherTask = Task { [weak self] in
                guard let self else { return }
                for await msg in stream {
                    guard !completed else { return }
                    if self.shouldAccept(msg, for: atCommand) {
                        completed = true
                        continuation.resume(returning: msg)
                        return
                    }
                }
                if !completed {
                    completed = true
                    continuation.resume(throwing: SenseCraftVoiceError.invalidResponse("AT reply stream ended"))
                }
            }

            let timeoutTask = Task { [timeout] in
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !completed else { return }
                completed = true
                matcherTask?.cancel()
                continuation.resume(throwing: SenseCraftVoiceError.timeout("AT command timeout: \(atCommand)"))
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.connection.writeCommand(
                        atCommand,
                        withoutResponse: withoutResponse,
                        interChunkDelay: interChunkDelay
                    )
                } catch {
                    guard !completed else { return }
                    completed = true
                    timeoutTask.cancel()
                    matcherTask?.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func decodeJsonObject(_ json: String) -> JSONObject? {
        guard let data = json.data(using: .utf8) else {
            return ["ok": false, "error": "JSON encode failed", "raw": json]
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let dict = obj as? JSONObject {
                return dict
            }
            return ["ok": false, "error": "JSON root is not object", "raw": json]
        } catch {
            return ["ok": false, "error": "JSON decode failed", "raw": json]
        }
    }

    private func shouldAccept(_ msg: JSONObject, for atCommand: String) -> Bool {
        if isSyntheticFramerFailure(msg) { return false }
        if isCancelCommand(atCommand), !isCancelReply(msg) { return false }
        if isEventMessage(msg) { return false }
        let upper = atCommand.uppercased()
        if upper.hasPrefix("AT+START"), looksLikeGstatOkReply(msg) { return false }
        if upper.hasPrefix("AT+DOWNLOAD"), looksLikeGstatOkReply(msg) { return false }
        if upper.hasPrefix("AT+PAUSE"), looksLikeGstatOkReply(msg) { return false }
        if upper.hasPrefix("AT+RESUME"), looksLikeGstatOkReply(msg) { return false }
        if upper.hasPrefix("AT+GSTAT"), !looksLikeGstatOkReply(msg) { return false }
        if upper.hasPrefix("AT+STOP") {
            if !hasSession(msg) && !isStopFailureReply(msg) { return false }
            if bool(msg["ok"]) == true, hasSession(msg), !isStopAckShape(msg) { return false }
        }
        return true
    }

    private func isSyntheticFramerFailure(_ msg: JSONObject) -> Bool {
        if bool(msg["ok"]) != false { return false }
        let error = string(msg["error"]) ?? ""
        return error.contains("JSON decode failed")
    }

    private func isEventMessage(_ msg: JSONObject) -> Bool {
        if let event = string(msg["event"]), !event.isEmpty {
            return true
        }
        if let data = msg["data"] as? JSONObject, let event = string(data["event"]), !event.isEmpty {
            return true
        }
        return false
    }

    private func looksLikeGstatOkReply(_ msg: JSONObject) -> Bool {
        guard bool(msg["ok"]) == true else { return false }
        guard let data = msg["data"] as? JSONObject else { return false }
        return data["state"] != nil || data["recording"] != nil || data["battery"] != nil
    }

    private func hasSession(_ msg: JSONObject) -> Bool {
        if let session = string(msg["session"]), !session.isEmpty { return true }
        if let data = msg["data"] as? JSONObject, let session = string(data["session"]), !session.isEmpty { return true }
        return false
    }

    private func isStopFailureReply(_ msg: JSONObject) -> Bool {
        guard bool(msg["ok"]) == false else { return false }
        let error = string(msg["error"]) ?? ""
        return error.lowercased().contains("stop")
    }

    private func isStopAckShape(_ msg: JSONObject) -> Bool {
        hasSession(msg) && bool(msg["ok"]) == true
    }

    private func isCancelCommand(_ atCommand: String) -> Bool {
        atCommand.uppercased().hasPrefix("AT+CANCEL")
    }

    private func isCancelReply(_ msg: JSONObject) -> Bool {
        if let error = string(msg["error"])?.lowercased(), error.contains("cancel") {
            return true
        }
        if let data = msg["data"] as? JSONObject {
            if data["canceled"] != nil { return true }
            if let message = string(data["msg"])?.lowercased(), message.contains("cancel") {
                return true
            }
        }
        return false
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
