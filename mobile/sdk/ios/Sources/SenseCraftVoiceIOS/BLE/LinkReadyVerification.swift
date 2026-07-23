import Foundation

/// Retry settings used while proving that a newly-established GATT link can
/// carry AT commands. Values are normalized so callers cannot accidentally
/// disable the first probe or pass a negative delay/timeout.
public struct LinkReadyRetryPolicy: Equatable, Sendable {
    public let attempts: Int
    public let retryGap: TimeInterval
    public let timeout: TimeInterval

    public init(
        attempts: Int = 3,
        retryGap: TimeInterval = 0.45,
        timeout: TimeInterval = 4
    ) {
        self.attempts = max(1, attempts)
        self.retryGap = max(0, retryGap)
        self.timeout = max(0.1, timeout)
    }
}

/// Pure retry/response logic extracted from `SenseCraftVoiceClient` so link
/// readiness can be tested without a CoreBluetooth peripheral.
public enum LinkReadyVerification {
    public static func responseIsReady(_ response: JSONObject) -> Bool {
        switch response["ok"] {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            return ["true", "1", "yes"].contains(
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        default:
            return false
        }
    }

    public static func run(
        policy: LinkReadyRetryPolicy,
        probe: (TimeInterval) async -> Bool,
        sleep: (TimeInterval) async -> Void = { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async -> Bool {
        for attempt in 0..<policy.attempts {
            if await probe(policy.timeout) {
                return true
            }
            if attempt + 1 < policy.attempts {
                await sleep(policy.retryGap)
            }
        }
        return false
    }
}
