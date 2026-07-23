import XCTest
@testable import SenseCraftVoiceIOS

final class TransferProgressTests: XCTestCase {
    func testSessionTransferCompletion() {
        XCTAssertTrue(
            TransferProgress.sessionTransferBytesComplete(
                eventFileCount: 2,
                fileCompleteCount: 1,
                deviceTotalFilesFromDownload: 2
            )
        )
        XCTAssertFalse(
            TransferProgress.sessionTransferBytesComplete(
                eventFileCount: 1,
                fileCompleteCount: 1,
                deviceTotalFilesFromDownload: 3
            )
        )
    }

    func testWifiAlignedProgress() {
        let ratio = TransferProgress.wifiAligned(
            framedMode: true,
            currentFileDeclaredSize: 100,
            bytesThisFile: 40,
            receivedSession: 240,
            expectedSession: 1000,
            filesCompleted: 2,
            deviceTotalFiles: 5,
            deviceSessionBytes: 1000
        )
        XCTAssertEqual(ratio ?? -1, 0.24, accuracy: 0.0001)
    }
}
