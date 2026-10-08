import Foundation
import Darwin
import XCTest
@testable import AetherTransferCore

final class FilePreviewTests: XCTestCase {
    func testS3SnapshotNamesStayWithinPrivatePayloadAndRetainUsefulExtensions() throws {
        let parent = URL(fileURLWithPath: "/private-preview/payload", isDirectory: true)
        for key in ["folder/..", "folder/.", "folder/", String(repeating: "中", count: 100) + ".png", String(repeating: "a", count: 900)] {
            let name = FilePreview.s3SnapshotName(key)
            let destination = parent.appendingPathComponent(name).standardizedFileURL
            XCTAssertEqual(destination.deletingLastPathComponent(), parent.standardizedFileURL)
            XCTAssertFalse(name.contains("/")); XCTAssertLessThanOrEqual(name.utf8.count, 240)
        }
        XCTAssertEqual(FilePreview.s3SnapshotName("files/中文 +#%?.txt"), "中文 +#%?.txt")
        XCTAssertEqual(FilePreview.s3SnapshotName("files/.lease"), ".lease")
        XCTAssertEqual(FilePreview.s3SnapshotName(String(repeating: "中", count: 100) + ".png"), "preview.png")
    }
    func testS3PreviewRejectsPrefixesBeforeRequestingOrCreatingCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-preview-test-\(UUID())")
        let client = S3Client(endpoint: S3Endpoint(host: "127.0.0.1", port: 1, bucket: "preview-test"),
                              credentials: S3Credentials(accessKey: "fixture", secretKey: "fixture"))
        for key in ["", "folder/"] {
            do { _ = try await FilePreview.open(.s3(client, key), temporaryParent: root); XCTFail("Prefixes cannot be previewed") }
            catch FilePreviewError.unsupportedFile { }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testLocalPreviewKeepsLargeFileInPlaceAndClosePreservesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-preview-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.mov")
        let descriptor = Darwin.open(file.path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(ftruncate(descriptor, 256 * 1024 * 1024), 0) // Sparse; no large payload is allocated.
        let preview = try await FilePreview.open(.local(file), temporaryParent: root)
        XCTAssertEqual(preview.url, file); XCTAssertNil(preview.directory)
        XCTAssertEqual(preview.byteCount, 256 * 1024 * 1024)
        try await preview.close(); try await preview.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["large.mov"])
    }
    func testRejectsLocalDirectorySymlinkAndFIFOWithoutReadingContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-preview-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link"), pipe = root.appendingPathComponent("pipe")
        try Data("original".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for url in [root, link, pipe] {
            do { _ = try await FilePreview.open(.local(url), temporaryParent: root); XCTFail("Non-regular preview must reject") }
            catch FilePreviewError.unsupportedFile { }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
    }
}
