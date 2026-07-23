import XCTest
@testable import SenseCraftVoiceIOS

final class BleTransferFrameHandlerTests: XCTestCase {
    func testHandleFileLifecycle() {
        let state = BleTransferFrameState()

        let startName = Array("0001.opus".utf8)
        var startBytes: [UInt8] = [kClipFrameFileStart, UInt8(startName.count)]
        startBytes.append(contentsOf: startName)
        startBytes.append(contentsOf: [0x03, 0x00, 0x00, 0x00])

        switch BleTransferFrameHandler.handle(bytes: Data(startBytes), state: state) {
        case .fileStart(let filename, let fileSize):
            XCTAssertEqual(filename, "0001.opus")
            XCTAssertEqual(fileSize, 3)
        default:
            XCTFail("unexpected start frame")
        }

        let payload = Data([0x01, 0x02, 0x03])
        let crc = crc32IEEE(payload)
        var dataBytes: [UInt8] = [kClipFrameData, 0x00, 0x00, 0x03, 0x00]
        dataBytes.append(contentsOf: payload)

        switch BleTransferFrameHandler.handle(bytes: Data(dataBytes), state: state) {
        case .data(let seq, let framePayload, let duplicateSeq, let seqJump, let orphanBeforeFileStart):
            XCTAssertEqual(seq, 0)
            XCTAssertEqual(framePayload, payload)
            XCTAssertFalse(duplicateSeq)
            XCTAssertFalse(seqJump)
            XCTAssertFalse(orphanBeforeFileStart)
        default:
            XCTFail("unexpected data frame")
        }

        let endBytes: [UInt8] = [
            kClipFrameFileEnd,
            UInt8(crc & 0xff),
            UInt8((crc >> 8) & 0xff),
            UInt8((crc >> 16) & 0xff),
            UInt8((crc >> 24) & 0xff),
        ]

        switch BleTransferFrameHandler.handle(bytes: Data(endBytes), state: state) {
        case .fileEndOk(let filename, let localCrc32, let deviceCrc32, let fileCompleteCount, let declaredFileSize, let bytesThisFile, let usedFraming):
            XCTAssertEqual(filename, "0001.opus")
            XCTAssertEqual(localCrc32, crc)
            XCTAssertEqual(deviceCrc32, crc)
            XCTAssertEqual(fileCompleteCount, 1)
            XCTAssertEqual(declaredFileSize, 3)
            XCTAssertEqual(bytesThisFile, 3)
            XCTAssertTrue(usedFraming)
        default:
            XCTFail("unexpected end frame")
        }
    }
}
