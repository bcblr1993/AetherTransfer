import Foundation
import Darwin
import XCTest
@testable import AetherTransferCore

final class PreviewCacheTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-cache-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    func testActiveLeaseSurvivesAndReleasedLeaseIsReclaimed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var lease: PreviewCacheLease? = try PreviewCacheLease(parentURL: root)
        let directory = try XCTUnwrap(lease?.directory), payload = try XCTUnwrap(lease?.payload)
        try Data("verified preview".utf8).write(to: payload.appendingPathComponent(".lease"))
        let active = try await FilePreview.reclaimAbandoned(in: root)
        XCTAssertEqual(active.inUse, 1); XCTAssertEqual(active.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        lease = nil // Drops the kernel lock without cleanup, as an exited process would.
        let abandoned = try await FilePreview.reclaimAbandoned(in: root)
        XCTAssertEqual(abandoned.removed, 1); XCTAssertEqual(abandoned.failed, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testUnrecognizedRecordsAndHardLinksArePreserved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var invalid: PreviewCacheLease? = try PreviewCacheLease(parentURL: root)
        let invalidFolder = try XCTUnwrap(invalid?.directory); invalid = nil
        try Data("user-owned data".utf8).write(to: invalidFolder.appendingPathComponent(".lease"))
        var linked: PreviewCacheLease? = try PreviewCacheLease(parentURL: root)
        let linkedFolder = try XCTUnwrap(linked?.directory); linked = nil
        let outsideRecord = root.appendingPathComponent("user-file")
        XCTAssertEqual(link(linkedFolder.appendingPathComponent(".lease").path, outsideRecord.path), 0)
        let report = try await FilePreview.reclaimAbandoned(in: root)
        XCTAssertEqual(report.removed, 0); XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkedFolder.path))
        XCTAssertEqual(try Data(contentsOf: invalidFolder.appendingPathComponent(".lease")), Data("user-owned data".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideRecord.path))
    }
    func testRootEntryAndRecordSymlinksNeverReachTheirTargets() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let protected = outside.appendingPathComponent("file"); try Data("preserve".utf8).write(to: protected)
        let rootLink = root.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outside)
        do { _ = try await FilePreview.reclaimAbandoned(in: rootLink); XCTFail("A symlink root must reject") } catch { }
        let entryLink = cache.appendingPathComponent(PreviewCache.prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: entryLink, withDestinationURL: outside)
        var lease: PreviewCacheLease? = try PreviewCacheLease(parentURL: cache)
        let directory = try XCTUnwrap(lease?.directory); lease = nil
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".lease"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(".lease"), withDestinationURL: protected)
        let report = try await FilePreview.reclaimAbandoned(in: cache)
        XCTAssertEqual(report.removed, 0)
        XCTAssertEqual(try Data(contentsOf: protected), Data("preserve".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
    func testPayloadSymlinkIsUnlinkedWithoutDeletingOutsideFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appendingPathComponent("outside"); try Data("preserve".utf8).write(to: protected)
        var lease: PreviewCacheLease? = try PreviewCacheLease(parentURL: root)
        let payload = try XCTUnwrap(lease?.payload)
        try FileManager.default.createSymbolicLink(at: payload.appendingPathComponent("link"), withDestinationURL: protected)
        lease = nil
        async let first = FilePreview.reclaimAbandoned(in: root)
        async let second = FilePreview.reclaimAbandoned(in: root)
        let reports = try await [first, second]
        XCTAssertEqual(reports.reduce(0) { $0 + $1.removed }, 1)
        XCTAssertEqual(try Data(contentsOf: protected), Data("preserve".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["outside"])
    }
    func testFailedPayloadCleanupRetainsRecordAndCanRetry() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var lease: PreviewCacheLease? = try PreviewCacheLease(parentURL: root)
        let directory = try XCTUnwrap(lease?.directory), payload = try XCTUnwrap(lease?.payload)
        try Data("preview".utf8).write(to: payload.appendingPathComponent("file"))
        lease = nil
        XCTAssertEqual(chmod(payload.path, 0), 0)
        defer { _ = chmod(payload.path, 0o700) }
        let failed = try await FilePreview.reclaimAbandoned(in: root)
        XCTAssertEqual(failed.failed, 1); XCTAssertEqual(failed.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".lease").path))
        XCTAssertEqual(chmod(payload.path, 0o700), 0)
        let retry = try await FilePreview.reclaimAbandoned(in: root)
        XCTAssertEqual(retry.removed, 1); XCTAssertEqual(retry.failed, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testReplacedDirectoryPathRefusesToDeleteReplacement() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let lease = try PreviewCacheLease(parentURL: root)
        let original = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: lease.directory, to: original)
        try FileManager.default.createDirectory(at: lease.directory, withIntermediateDirectories: false)
        let replacement = lease.directory.appendingPathComponent("user-file")
        try Data("preserve replacement".utf8).write(to: replacement)
        do { try await lease.close(); XCTFail("Replaced directory must refuse cleanup") }
        catch PreviewCacheError.unsafe { }
        XCTAssertEqual(try Data(contentsOf: replacement), Data("preserve replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent(".lease").path))
    }
    func testCancelledReclamationLeavesAbandonedPayloadForLaterRetry() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var lease: PreviewCacheLease? = try PreviewCacheLease(parentURL: root)
        let directory = try XCTUnwrap(lease?.directory), payload = try XCTUnwrap(lease?.payload)
        let file = payload.appendingPathComponent("file"); try Data("preserve".utf8).write(to: file)
        lease = nil
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FilePreview.reclaimAbandoned(in: root)
        }
        do { _ = try await task.value; XCTFail("Cancelled reclamation must stop") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: file), Data("preserve".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".lease").path))
        let retry = try await FilePreview.reclaimAbandoned(in: root)
        XCTAssertEqual(retry.removed, 1)
    }
}
