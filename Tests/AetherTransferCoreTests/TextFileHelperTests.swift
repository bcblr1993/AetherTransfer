import XCTest
@testable import AetherTransferCore

final class TextFileHelperTests: XCTestCase {
    func testTextFileDetection() {
        XCTAssertTrue(TextFileHelper.isTextFileName("config.json"))
        XCTAssertTrue(TextFileHelper.isTextFileName("README.md"))
        XCTAssertTrue(TextFileHelper.isTextFileName("server.sh"))
        XCTAssertTrue(TextFileHelper.isTextFileName("nginx.conf"))
        XCTAssertTrue(TextFileHelper.isTextFileName("code.swift"))

        XCTAssertFalse(TextFileHelper.isTextFileName("photo.jpg"))
        XCTAssertFalse(TextFileHelper.isTextFileName("archive.zip"))
        XCTAssertFalse(TextFileHelper.isTextFileName("binary.bin"))
    }

    func testBinaryDataDetection() {
        let textData = Data("Hello, world!\nLine 2".utf8)
        XCTAssertTrue(TextFileHelper.isProbablyTextData(textData))

        var binaryBytes = [UInt8](0..<255)
        binaryBytes[5] = 0 // null byte
        let binaryData = Data(binaryBytes)
        XCTAssertFalse(TextFileHelper.isProbablyTextData(binaryData))
    }
}
