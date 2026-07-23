import XCTest
@testable import SenseCraftVoiceIOS

final class JsonObjectFramerTests: XCTestCase {
    func testFiresOneObjectAcrossChunks() {
        let framer = JsonObjectFramer()
        XCTAssertEqual(framer.feed("{\"ok\":"), [])
        XCTAssertEqual(framer.feed("true,\"a\":1}"), ["{\"ok\":true,\"a\":1}"])
    }
}

