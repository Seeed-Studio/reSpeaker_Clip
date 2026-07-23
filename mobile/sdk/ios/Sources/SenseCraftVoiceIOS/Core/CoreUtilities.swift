import Foundation

public enum SdkLogLevel: String {
    case debug
    case info
    case warning
    case error
}

public typealias SdkLogHandler = (
    _ level: SdkLogLevel,
    _ message: String,
    _ error: Error?,
    _ stackTrace: String?
) -> Void

public enum SdkLog {
    private static let silent: SdkLogHandler = { _, _, _, _ in }
    private static var handler: SdkLogHandler = silent

    public static func bind(_ handler: SdkLogHandler?) {
        self.handler = handler ?? silent
    }

    public static func d(_ message: String, _ error: Error? = nil) {
        handler(.debug, message, error, nil)
    }

    public static func i(_ message: String, _ error: Error? = nil) {
        handler(.info, message, error, nil)
    }

    public static func w(_ message: String, _ error: Error? = nil) {
        handler(.warning, message, error, nil)
    }

    public static func e(_ message: String, _ error: Error? = nil) {
        handler(.error, message, error, nil)
    }
}

public enum SenseCraftVoiceError: Error, CustomStringConvertible {
    case timeout(String)
    case unsupported(String)
    case bluetoothUnavailable(String)
    case bluetoothUnauthorized
    case missingCharacteristic(String)
    case invalidResponse(String)
    case connectionFailed(String)
    case internalError(String)

    public var description: String {
        switch self {
        case .timeout(let s): return "Timeout: \(s)"
        case .unsupported(let s): return "Unsupported: \(s)"
        case .bluetoothUnavailable(let s): return "Bluetooth unavailable: \(s)"
        case .bluetoothUnauthorized: return "Bluetooth permission denied"
        case .missingCharacteristic(let s): return "Missing characteristic: \(s)"
        case .invalidResponse(let s): return "Invalid response: \(s)"
        case .connectionFailed(let s): return "Connection failed: \(s)"
        case .internalError(let s): return "Internal error: \(s)"
        }
    }
}

public func withTimeout<T>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
            throw SenseCraftVoiceError.timeout("operation timed out after \(seconds)s")
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

public final class SerialAsyncQueue {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T>(
        _ body: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

@MainActor
public final class BroadcastHub<Element> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func publish(_ value: Element) {
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }
}

public func crc32IEEE(_ data: Data, seed: UInt32 = 0) -> UInt32 {
    var crc = ~seed
    for byte in data {
        crc = _crc32Table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
    }
    return ~crc
}

private let _crc32Table: [UInt32] = (0..<256).map { i in
    var c = UInt32(i)
    for _ in 0..<8 {
        c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
    }
    return c
}
