import Foundation
import XCTest
@testable import AetherTransferCore

@MainActor final class S3SyncTests: XCTestCase {
    private func client(region: String = "us-east-1") -> S3Client {
        S3Client(endpoint: S3Endpoint(host: "example.invalid", bucket: "sync-test", region: region),
                 credentials: S3Credentials(accessKey: "public-test-key", secretKey: "public-test-secret"))
    }
    func testRootsKeepByteExactPrefixesAndRejectOverlapsAcrossSigningRegions() async throws {
        let a = SyncRoot.s3(client(), "photos//./"), b = SyncRoot.s3(client(), "photos/./")
        XCTAssertEqual(a.path, "photos//./"); XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(SyncRoot.s3(client(), "é/").id, SyncRoot.s3(client(), "e\u{301}/").id)
        for prefix in ["", "photos//./", "photos//./nested/"] {
            do {
                _ = try await SyncEngine.preview(left: a, right: .s3(client(region: "eu-west-1"), prefix), options: SyncOptions())
                XCTFail("Overlapping bucket prefixes cannot bypass validation with a different signing region")
            } catch SyncError.overlappingRoots { }
        }
    }
    func testKeyMappingPreservesRootBytesAndPreflightsDirectoryDelimiter() throws {
        XCTAssertEqual(try S3Sync.key(prefix: "photos//./", relative: "中文 +#%?.txt"), "photos//./中文 +#%?.txt")
        XCTAssertThrowsError(try S3Sync.key(prefix: "", relative: "../file"))
        let prefix = String(repeating: "a", count: 1020) + "/"
        XCTAssertEqual(try S3Sync.key(prefix: prefix, relative: "abc").utf8.count, 1024)
        XCTAssertThrowsError(try S3Sync.key(prefix: prefix, relative: "abc", directory: true))
    }
    func testDestinationPreflightRejectsAliasesWithExistingUnselectedFiles() throws {
        let file = SyncRecord(kind: .file, size: 1)
        let snapshot = SyncSnapshot(rootID: "right", records: ["Folder": SyncRecord(kind: .directory), "Folder/A.txt": file])
        let item = SyncItem(path: "Folder/a.txt", operation: .copy(.leftToRight), left: file, right: nil, reason: .missingFile)
        XCTAssertThrowsError(try S3Sync.validateDestination(prefix: "", snapshot: snapshot, writes: [(item, item.operation)]))
    }
    func testVersionsGuardSnapshotsWithoutChangingComparisonRules() throws {
        let old = RemoteFileVersion(size: 3, modified: 1, etag: "\"old\""), new = RemoteFileVersion(size: 3, modified: 1, etag: "\"new\"")
        let a = SyncRecord(kind: .file, size: 3, modified: Date(timeIntervalSince1970: 1), remoteVersion: old)
        let b = SyncRecord(kind: .file, size: 3, modified: a.modified, remoteVersion: new)
        XCTAssertNotEqual(a, b)
        var options = SyncOptions(); options.comparison = .fileSize
        let plan = try SyncPlanner.plan(left: SyncSnapshot(rootID: "left", records: ["file": a]),
                                        right: SyncSnapshot(rootID: "right", records: ["file": b]), options: options)
        XCTAssertTrue(plan.items.isEmpty); XCTAssertEqual(plan.unchanged, 1)
    }
    func testExistingPlanExplainsBothLanguagesWithoutChangingPathsOrSelectionIdentity() throws {
        let record = SyncRecord(kind: .file, size: 3, digest: "old"), other = SyncRecord(kind: .file, size: 3, digest: "new")
        var options = SyncOptions(); options.comparison = .contents
        let plan = try SyncPlanner.plan(left: SyncSnapshot(rootID: "left", records: ["我的文件 %@.txt": record]),
                                        right: SyncSnapshot(rootID: "right", records: ["我的文件 %@.txt": other]), options: options)
        let item = try XCTUnwrap(plan.items.first), selection = Set([item.id])
        XCTAssertEqual(item.localizedExplanation(language: .simplifiedChinese), "覆盖右侧同名文件。")
        XCTAssertEqual(item.localizedExplanation(language: .english), "Replace the file with the same name on the right.")
        XCTAssertEqual(plan.items.first, item); XCTAssertTrue(selection.contains(item.id))
        XCTAssertEqual(item.path, "我的文件 %@.txt"); XCTAssertEqual(item.operation, .copy(.leftToRight))
        let blocked = SyncItem(path: item.path, operation: .blocked, left: nil, right: record, reason: .s3MirrorBlocked)
        XCTAssertTrue(blocked.localizedExplanation(language: .english).contains("cannot run"))
        XCTAssertTrue(blocked.localizedExplanation(language: .simplifiedChinese).contains("不会执行"))
        XCTAssertFalse(blocked.executable)
    }
}
