import XCTest
@testable import AetherTransferCore

final class RecursiveTransferTests: XCTestCase, @unchecked Sendable {
    func testLocalWalkEnumeratesNestedFilesAndEmptyDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create structure:
        // tempDir/
        //   file1.txt
        //   sub1/
        //     file2.txt
        //     deep/
        //       file3.txt
        //   emptyDir/

        try "content1".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        let sub1 = tempDir.appendingPathComponent("sub1")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try "content2".write(to: sub1.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        let deep = sub1.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "content3".write(to: deep.appendingPathComponent("file3.txt"), atomically: true, encoding: .utf8)

        let emptyDir = tempDir.appendingPathComponent("emptyDir")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let items = try LocalFiles.walk(tempDir)
        let relativePaths = items.map(\.relativePath).sorted()

        XCTAssertTrue(relativePaths.contains("emptyDir"))
        XCTAssertTrue(relativePaths.contains("file1.txt"))
        XCTAssertTrue(relativePaths.contains("sub1"))
        XCTAssertTrue(relativePaths.contains("sub1/file2.txt"))
        XCTAssertTrue(relativePaths.contains("sub1/deep"))
        XCTAssertTrue(relativePaths.contains("sub1/deep/file3.txt"))

        let emptyItem = items.first(where: { $0.relativePath == "emptyDir" })
        XCTAssertTrue(emptyItem?.isDirectory == true)

        let fileItem = items.first(where: { $0.relativePath == "file1.txt" })
        XCTAssertTrue(fileItem?.isDirectory == false)
        XCTAssertEqual(fileItem?.size, 8)
    }
}
