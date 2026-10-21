import XCTest
@testable import AetherTransferCore

final class ArchiveTests: XCTestCase {
    func testCreateZipArchiveFromLocalFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-archive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)

        let zipURL = tempDir.appendingPathComponent("archive.zip")
        try ArchiveHelper.createZip(from: [file1, file2], destinationZipURL: zipURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let size = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 0)
    }
}
