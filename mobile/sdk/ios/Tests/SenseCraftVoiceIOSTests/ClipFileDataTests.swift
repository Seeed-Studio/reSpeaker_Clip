import XCTest
@testable import SenseCraftVoiceIOS

final class ClipFileDataTests: XCTestCase {
    func testParseFileStart() {
        let name = Array("a.opus".utf8)
        var bytes: [UInt8] = [kClipFrameFileStart, UInt8(name.count)]
        bytes.append(contentsOf: name)
        bytes.append(contentsOf: [0x34, 0x12, 0x00, 0x00])
        switch parseClipFileDataNotify(Data(bytes)) {
        case .fileStart(let filename, let size):
            XCTAssertEqual(filename, "a.opus")
            XCTAssertEqual(size, 0x1234)
        default:
            XCTFail("unexpected frame")
        }
    }
}

