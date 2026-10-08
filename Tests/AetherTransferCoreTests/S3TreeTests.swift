import Foundation
import XCTest
@testable import AetherTransferCore

final class S3TreeTests: XCTestCase {
    private func object(_ name: String, prefix: Bool = false) -> S3Object {
        S3Object(key: "root/" + name + (prefix ? "/" : ""), name: name, isPrefix: prefix,
                 size: 0, modified: nil, etag: prefix ? nil : "\"etag\"")
    }
    func testRecursiveLocalMappingRejectsAliasesAndUnsafeComponents() throws {
        for names in [["File.txt", "file.txt"], ["café", "cafe\u{301}"], ["same", "same"]] {
            XCTAssertThrowsError(try S3TreeSnapshot.validateChildren(names.enumerated().map { object($0.element, prefix: $0.offset == 1) }))
        }
        for name in [".", "..", "", "/", "a/b", "nul\0"] {
            XCTAssertThrowsError(try S3TreeSnapshot.validateChildren([object(name)]))
        }
        XCTAssertNoThrow(try S3TreeSnapshot.validateChildren([object("中文 空格+#%?.txt"), object("..backup"), object(".hidden", prefix: true)]))
    }
    func testAlternativeDirectoryDoesNotFollowSymlinks() throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("aether-s3-alias-\(UUID())")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("folder")
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("folder (2)"), withDestinationURL: local)
        XCTAssertThrowsError(try S3TreeSnapshot.availableDirectory(source))
    }
    func testDirectoryMarkerCannotSilentlyDiscardPayload() throws {
        XCTAssertNoThrow(try S3TreeSnapshot.validateMarker(nil, name: "virtual"))
        XCTAssertNoThrow(try S3TreeSnapshot.validateMarker(RemoteFileVersion(size: 0, modified: nil, etag: "\"empty\""), name: "empty"))
        XCTAssertThrowsError(try S3TreeSnapshot.validateMarker(RemoteFileVersion(size: 12, modified: nil, etag: "\"data\""), name: "contains-data"))
    }
}
