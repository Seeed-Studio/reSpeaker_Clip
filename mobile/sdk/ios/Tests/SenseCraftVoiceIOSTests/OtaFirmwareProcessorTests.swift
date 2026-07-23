import XCTest
@testable import SenseCraftVoiceIOS

final class OtaFirmwareProcessorTests: XCTestCase {
    func testValidateManifestSizeAndSha256() throws {
        let data = Data([1, 2, 3, 4, 5])
        try OtaFirmwareProcessor.validateManifestFileEntry(
            fileName: "clip.signed.bin",
            data: data,
            entry: [
                "file": "clip.signed.bin",
                "size": 5,
                "sha256": "74f81fe167d99b4cb41d6d0ccda82278caee9f3e2f25d5e5a3936ff3dcec60d0",
            ]
        )
    }

    func testValidateManifestThrowsOnSizeMismatch() {
        let data = Data([1, 2, 3, 4, 5])
        XCTAssertThrowsError(
            try OtaFirmwareProcessor.validateManifestFileEntry(
                fileName: "clip.signed.bin",
                data: data,
                entry: ["file": "clip.signed.bin", "size": 6]
            )
        )
    }
}
