import XCTest
@testable import SenseCraftVoiceIOS

@MainActor
final class RecordingSessionHelpersTests: XCTestCase {
    func testRetryPolicyResilientRetriesBusyAndMissingSession() {
        let policy = DownloadStartRetryPolicy.resilient
        XCTAssertTrue(policy.shouldRetry(.sessionNotFound))
        XCTAssertTrue(policy.shouldRetry(.transferBusy))
        XCTAssertFalse(policy.shouldRetry(.other))
    }

    func testCanonicalTransferExpectedBytes() {
        XCTAssertEqual(RecordingSession.canonicalTransferExpectedBytes(dbExpected: nil, transferredTotal: 120), 120)
        XCTAssertEqual(RecordingSession.canonicalTransferExpectedBytes(dbExpected: 200, transferredTotal: 120), 120)
        XCTAssertEqual(RecordingSession.canonicalTransferExpectedBytes(dbExpected: 100, transferredTotal: 120), 100)
    }

    func testLocalMergedFileCompleteForDelete() {
        XCTAssertTrue(RecordingSession.localMergedFileCompleteForDelete(actualSize: 95, expectedBytes: 100))
        XCTAssertFalse(RecordingSession.localMergedFileCompleteForDelete(actualSize: 80, expectedBytes: 100))
    }

    func testSafeDownloadFilenameAndSidecarPath() {
        XCTAssertEqual(RecordingSession.safeDownloadFilename("foo/bar", fallbackIndex: 3), "foo_bar.opus")

        let merged = URL(fileURLWithPath: "/tmp/session/0001.opus")
        let sidecar = RecordingSession.bookmarksSidecarUrl(forMergedUrl: merged)
        XCTAssertEqual(sidecar.lastPathComponent, "0001_bookmarks.json")
    }

    func testRuntimeInfoModel() {
        let date = Date(timeIntervalSince1970: 123)
        let status = DeviceStatus(
            state: "recording",
            isRecording: true,
            sessionId: "s1",
            batteryPercent: 88,
            isCharging: false,
            freeSpaceBytes: 1024,
            bitrate: 128000,
            recordingMode: .normal,
            recordingSeconds: 12,
            firmwareVersion: "1.0.0",
            raw: [:]
        )
        let info = DeviceRuntimeInfo(
            firmwareVersion: "1.0.0",
            rawDeviceTime: 123,
            deviceTime: date,
            status: status,
            pairStatus: "paired",
            pairAddress: "AA:BB",
            versionReply: nil,
            timeReply: nil,
            statusReply: nil,
            pairReply: nil
        )

        XCTAssertEqual(info.sessionId, "s1")
        XCTAssertEqual(info.state, "recording")
        XCTAssertTrue(info.formattedDeviceTime?.isEmpty == false)
        XCTAssertTrue(info.hasAnyData)
    }

    func testMergeAndResumeHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([0x01, 0x02]).write(to: root.appendingPathComponent("0001.opus"))
        try Data([0x03]).write(to: root.appendingPathComponent("0002.opus.part"))

        let resume = try RecordingSession.resolveSessionResumeStartFile(sessionDirectory: root)
        XCTAssertEqual(resume, "0002.opus")

        let markers = try RecordingSession.resolveSessionResumeMarkers(
            sessionDirectory: root,
            startFile: resume,
            dbReceivedBytes: 1
        )
        XCTAssertEqual(markers.startFile, "0002.opus")
        XCTAssertEqual(markers.resumeByteOffset, 2)
        XCTAssertEqual(markers.resumeFileIndex, 1)

        let merged = root.appendingPathComponent("merged.opus")
        let output = try RecordingSession.mergeSessionOpusPartsInDirectory(directory: root, mergedUrl: merged)
        XCTAssertEqual(output, merged)
        XCTAssertEqual(try Data(contentsOf: merged), Data([0x01, 0x02, 0x03]))
    }
}
