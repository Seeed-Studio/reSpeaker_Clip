import Network
import XCTest
@testable import SenseCraftVoiceIOS

@MainActor
final class P0ParityTests: XCTestCase {
    func testLinkReadyResponseParsing() {
        XCTAssertTrue(LinkReadyVerification.responseIsReady(["ok": true]))
        XCTAssertTrue(LinkReadyVerification.responseIsReady(["ok": "YES"]))
        XCTAssertTrue(LinkReadyVerification.responseIsReady(["ok": 1]))
        XCTAssertFalse(LinkReadyVerification.responseIsReady(["ok": false]))
        XCTAssertFalse(LinkReadyVerification.responseIsReady([:]))
    }

    func testLinkReadyRetryNormalizesAndStopsAfterSuccess() async {
        let policy = LinkReadyRetryPolicy(attempts: 0, retryGap: -1, timeout: 0)
        XCTAssertEqual(policy.attempts, 1)
        XCTAssertEqual(policy.retryGap, 0)
        XCTAssertEqual(policy.timeout, 0.1)

        var probes = 0
        var sleeps = 0
        let ready = await LinkReadyVerification.run(
            policy: LinkReadyRetryPolicy(attempts: 4, retryGap: 0.2, timeout: 2),
            probe: { timeout in
                XCTAssertEqual(timeout, 2)
                probes += 1
                return probes == 3
            },
            sleep: { gap in
                XCTAssertEqual(gap, 0.2)
                sleeps += 1
            }
        )

        XCTAssertTrue(ready)
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(sleeps, 2)
    }

    func testWifiBatchItemReplacementAndResultGetters() {
        let item = WifiBatchItem(
            recordingId: "recording-1",
            sessionId: "session-1",
            sessionDirectory: URL(fileURLWithPath: "/tmp/session-1"),
            expectedBytes: 123,
            startFile: "0002.opus",
            resumeByteOffset: 44
        )
        let replaced = item.replacing(
            sessionDirectory: URL(fileURLWithPath: "/tmp/session-2")
        )

        XCTAssertEqual(replaced.recordingId, "recording-1")
        XCTAssertEqual(replaced.sessionId, "session-1")
        XCTAssertEqual(replaced.sessionDirectory.path, "/tmp/session-2")
        XCTAssertEqual(replaced.expectedBytes, 123)
        XCTAssertEqual(replaced.startFile, "0002.opus")
        XCTAssertEqual(replaced.resumeByteOffset, 44)

        let success = WifiFastSyncBatchResult(succeeded: 2)
        XCTAssertTrue(success.isOverallSuccess)
        XCTAssertFalse(success.shouldFallBackToBle)

        let fallback = WifiFastSyncBatchResult(
            failed: 1,
            bleFallbackReason: .phoneWifiDisconnected
        )
        XCTAssertFalse(fallback.isOverallSuccess)
        XCTAssertTrue(fallback.shouldFallBackToBle)
    }

    func testWifiBatchFailureClassification() {
        XCTAssertEqual(
            WifiBatchFailureClassifier.fallbackReason(for: .networkUnreachable),
            .phoneWifiDisconnected
        )
        XCTAssertEqual(
            WifiBatchFailureClassifier.fallbackReason(for: .timedOut),
            .phoneOnOtherWifi
        )
        XCTAssertEqual(
            WifiBatchFailureClassifier.fallbackReason(
                for: WifiPingResult(ok: false, networkUnreachable: true)
            ),
            .phoneWifiDisconnected
        )
        XCTAssertEqual(
            WifiBatchFailureClassifier.finalFailureReason(
                succeeded: 0,
                failed: 1,
                userCancelled: false,
                abortedForRecording: false,
                finalProbe: WifiPingResult(ok: true, networkUnreachable: false)
            ),
            .transferFailed
        )
        XCTAssertNil(
            WifiBatchFailureClassifier.finalFailureReason(
                succeeded: 1,
                failed: 1,
                userCancelled: false,
                abortedForRecording: false,
                finalProbe: WifiPingResult(ok: true, networkUnreachable: false)
            )
        )
    }

    func testDeviceApUdpRoutePolicy() {
        let parameters = ClipUdpSyncClient.deviceApUdpParameters()
        #if os(iOS)
        XCTAssertEqual(parameters.requiredInterfaceType, .wifi)
        #endif
        XCTAssertTrue(parameters.prohibitedInterfaceTypes?.contains(.cellular) == true)
    }
}
