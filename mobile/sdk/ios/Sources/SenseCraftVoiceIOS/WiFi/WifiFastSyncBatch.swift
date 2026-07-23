import Foundation

/// One device recording to download while a single AP session stays active.
public struct WifiBatchItem: Sendable {
    public let recordingId: String
    public let sessionId: String
    public let sessionDirectory: URL
    public let expectedBytes: Int?
    public let startFile: String?
    public let resumeByteOffset: Int

    public init(
        recordingId: String,
        sessionId: String,
        sessionDirectory: URL,
        expectedBytes: Int? = nil,
        startFile: String? = nil,
        resumeByteOffset: Int = 0
    ) {
        self.recordingId = recordingId
        self.sessionId = sessionId
        self.sessionDirectory = sessionDirectory
        self.expectedBytes = expectedBytes
        self.startFile = startFile
        self.resumeByteOffset = max(0, resumeByteOffset)
    }

    public func replacing(
        recordingId: String? = nil,
        sessionId: String? = nil,
        sessionDirectory: URL? = nil,
        expectedBytes: Int? = nil,
        startFile: String? = nil,
        resumeByteOffset: Int? = nil
    ) -> WifiBatchItem {
        WifiBatchItem(
            recordingId: recordingId ?? self.recordingId,
            sessionId: sessionId ?? self.sessionId,
            sessionDirectory: sessionDirectory ?? self.sessionDirectory,
            expectedBytes: expectedBytes ?? self.expectedBytes,
            startFile: startFile ?? self.startFile,
            resumeByteOffset: resumeByteOffset ?? self.resumeByteOffset
        )
    }
}

public typealias WifiBatchResolveStartFile = (
    _ recordingId: String,
    _ sessionId: String
) async -> String?

public enum WifiBleFallbackReason: String, Equatable, Sendable {
    case phoneWifiDisconnected
    case phoneOnOtherWifi
    case transferFailed
}

public enum WifiVerifyFailureKind: String, Equatable, Sendable {
    case networkUnreachable
    case timedOut
}

public struct WifiVerifyFailure: Error, CustomStringConvertible {
    public let kind: WifiVerifyFailureKind
    public let hotspot: WifiHotspotInfo

    public init(_ kind: WifiVerifyFailureKind, hotspot: WifiHotspotInfo) {
        self.kind = kind
        self.hotspot = hotspot
    }

    public var description: String {
        "Wi-Fi setup: \(kind.rawValue)"
    }
}

public struct WifiFastSyncBatchResult {
    public let succeeded: Int
    public let failed: Int
    public let userCancelled: Bool
    public let abortedForRecording: Bool
    public let bleFallbackReason: WifiBleFallbackReason?
    public let fallbackHotspot: WifiHotspotInfo?

    public init(
        succeeded: Int = 0,
        failed: Int = 0,
        userCancelled: Bool = false,
        abortedForRecording: Bool = false,
        bleFallbackReason: WifiBleFallbackReason? = nil,
        fallbackHotspot: WifiHotspotInfo? = nil
    ) {
        self.succeeded = max(0, succeeded)
        self.failed = max(0, failed)
        self.userCancelled = userCancelled
        self.abortedForRecording = abortedForRecording
        self.bleFallbackReason = bleFallbackReason
        self.fallbackHotspot = fallbackHotspot
    }

    public var shouldFallBackToBle: Bool {
        bleFallbackReason != nil
    }

    public var isOverallSuccess: Bool {
        succeeded > 0 && failed == 0 && !userCancelled
    }
}

/// Pure mapping shared by setup verification and per-item transfer failures.
public enum WifiBatchFailureClassifier {
    public static func fallbackReason(
        for verifyFailure: WifiVerifyFailureKind
    ) -> WifiBleFallbackReason {
        verifyFailure == .networkUnreachable
            ? .phoneWifiDisconnected
            : .phoneOnOtherWifi
    }

    public static func fallbackReason(
        for probe: WifiPingResult
    ) -> WifiBleFallbackReason? {
        guard !probe.ok else { return nil }
        return probe.networkUnreachable
            ? .phoneWifiDisconnected
            : .phoneOnOtherWifi
    }

    public static func finalFailureReason(
        succeeded: Int,
        failed: Int,
        userCancelled: Bool,
        abortedForRecording: Bool,
        finalProbe: WifiPingResult
    ) -> WifiBleFallbackReason? {
        guard succeeded == 0,
              failed > 0,
              !userCancelled,
              !abortedForRecording else {
            return nil
        }
        return fallbackReason(for: finalProbe) ?? .transferFailed
    }
}

public extension WifiFastSyncSession {
    /// Download multiple sessions over one device-hotspot lifecycle.
    ///
    /// This mirrors the Flutter SDK orchestration but deliberately excludes app
    /// database, merge, notification, playback and audio-processing concerns.
    func downloadBatch(
        items: [WifiBatchItem],
        resolveStartFile: WifiBatchResolveStartFile? = nil,
        joinPhone: Bool = true,
        requirePhoneJoin: Bool = false,
        disconnectPhoneAfter: Bool = true,
        disableHotspotAfter: Bool = true
    ) async -> WifiFastSyncBatchResult {
        guard !items.isEmpty else { return WifiFastSyncBatchResult() }

        var succeeded = 0
        var failed = 0
        let userCancelled = false
        var abortedForRecording = false
        var fallbackReason: WifiBleFallbackReason?
        var batchHotspot: WifiHotspotInfo?

        do {
            let info = try await enableHotspot()
            batchHotspot = info

            var joined = true
            if joinPhone {
                joined = await hotspotConnector?.connectToHotspot(info) == true
                if !joined, requirePhoneJoin {
                    throw SenseCraftVoiceError.connectionFailed(
                        "Phone failed to join device AP \(info.ssid)"
                    )
                }
            }

            guard let udpClient = transferClient else {
                throw SenseCraftVoiceError.connectionFailed("Wi-Fi transfer client unavailable")
            }

            #if os(iOS)
            let maximumPingAttempts = joined ? 18 : 32
            let pingGap: TimeInterval = 3
            #else
            let maximumPingAttempts = joined ? 10 : 20
            let pingGap: TimeInterval = 2
            #endif

            var pingResult = WifiPingResult(ok: false, networkUnreachable: false)
            for attempt in 0..<maximumPingAttempts {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(pingGap * 1_000_000_000))
                    await hotspotConnector?.forceWifiUsage(true)
                }
                pingResult = await udpClient.pingDetailed()
                if pingResult.ok || pingResult.networkUnreachable { break }
            }
            guard pingResult.ok else {
                throw WifiVerifyFailure(
                    pingResult.networkUnreachable ? .networkUnreachable : .timedOut,
                    hotspot: info
                )
            }

            for item in items {
                if await deviceIsRecordingOrPausedForBatch() {
                    abortedForRecording = true
                    break
                }

                var startFile = item.startFile
                if startFile == nil, let resolveStartFile {
                    startFile = await resolveStartFile(item.recordingId, item.sessionId)
                }

                do {
                    _ = try await udpClient.downloadSession(
                        sessionId: item.sessionId,
                        sessionDirectory: item.sessionDirectory,
                        startFile: startFile
                    )
                    succeeded += 1
                } catch {
                    failed += 1
                    let probe = await udpClient.pingDetailed()
                    if let classified = WifiBatchFailureClassifier.fallbackReason(for: probe) {
                        fallbackReason = classified
                        break
                    }
                }
            }

            if fallbackReason == nil, succeeded == 0, failed > 0,
               !userCancelled, !abortedForRecording {
                let probe = await udpClient.pingDetailed()
                fallbackReason = WifiBatchFailureClassifier.finalFailureReason(
                    succeeded: succeeded,
                    failed: failed,
                    userCancelled: userCancelled,
                    abortedForRecording: abortedForRecording,
                    finalProbe: probe
                )
            }
        } catch let verifyFailure as WifiVerifyFailure {
            failed += succeeded == 0 ? 1 : 0
            fallbackReason = WifiBatchFailureClassifier.fallbackReason(for: verifyFailure.kind)
        } catch {
            failed += succeeded == 0 ? 1 : 0
            SdkLog.w("WifiFastSyncSession.downloadBatch setup failed", error)
        }

        try? await teardown(
            disconnectPhone: disconnectPhoneAfter,
            disableHotspot: disableHotspotAfter
        )
        return WifiFastSyncBatchResult(
            succeeded: succeeded,
            failed: failed,
            userCancelled: userCancelled,
            abortedForRecording: abortedForRecording,
            bleFallbackReason: fallbackReason,
            fallbackHotspot: batchHotspot
        )
    }

    private func deviceIsRecordingOrPausedForBatch() async -> Bool {
        do {
            let response = try await at.send("AT+GSTAT", timeout: 4)
            guard LinkReadyVerification.responseIsReady(response) else { return false }
            let status = DeviceStatus.fromAtReply(response)
            return status.isRecording || status.state == "paused"
        } catch {
            return false
        }
    }
}
