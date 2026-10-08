import XCTest
import Darwin
@testable import AetherTransferCore

@MainActor final class FilePermissionPlanTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aether-permission-plan-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func entry(_ url: URL, directory: Bool = false) -> FileEntry {
        FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: directory)
    }
    private func file(_ url: URL) throws {
        try Data("same content\n中文".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
    func testRecursiveScopeIncludesHiddenAndEmptyFoldersDeduplicatesAndSkipsLinks() async throws {
        let dir = try root(), outside = try root()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        let sub = dir.appendingPathComponent("子目录"), empty = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let one = dir.appendingPathComponent("空格 +#%.txt"), hidden = sub.appendingPathComponent(".hidden")
        try file(one); try file(hidden)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("folder-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("file-link"), withDestinationURL: one)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("missing"))
        let basic = try await PermissionBatch.preview([entry(dir, directory: true)], client: nil, recursive: false,
                                                     limits: PermissionScanLimits(entries: 1))
        XCTAssertEqual(basic.targets.count, 1); XCTAssertEqual(basic.skippedSymbolicLinks, 0)
        let plan = try await PermissionBatch.preview([entry(sub, directory: true), entry(one), entry(dir, directory: true), entry(dir, directory: true)], client: nil, recursive: true)
        XCTAssertEqual(plan.fileCount, 2); XCTAssertEqual(plan.folderCount, 3); XCTAssertEqual(plan.skippedSymbolicLinks, 3)
        XCTAssertEqual(plan.targets.count, 5); XCTAssertNil(plan.commonMode)
        XCTAssertEqual(Set(plan.targets.map(\.path)), Set([dir.path, sub.path, empty.path, one.path, hidden.path]))
        XCTAssertEqual(plan.targets.last?.path, dir.path)
        let hiddenIndex = try XCTUnwrap(plan.targets.firstIndex { $0.path == hidden.path })
        let subIndex = try XCTUnwrap(plan.targets.firstIndex { $0.path == sub.path })
        XCTAssertLessThan(hiddenIndex, subIndex)
    }
    func testRecursiveApplyClosesFoldersLastAndPreservesContentAndModificationTime() async throws {
        let dir = try root(), sub = dir.appendingPathComponent("nested")
        defer {
            _ = chmod(dir.path, 0o700); _ = chmod(sub.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let leaf = sub.appendingPathComponent(".hidden"), one = dir.appendingPathComponent("one")
        try file(leaf); try file(one)
        let data = try Data(contentsOf: leaf), before = try LocalFilePermissions.read(leaf)
        let plan = try await PermissionBatch.preview([entry(dir, directory: true)], client: nil, recursive: true)
        let result = await PermissionBatch.apply(try UnixPermissions(0o600), plan: plan, client: nil)
        XCTAssertNil(result.error); XCTAssertEqual(result.completed, 4); XCTAssertFalse(result.cancelled)
        XCTAssertEqual(try LocalFilePermissions.read(dir).mode.rawValue, 0o600)
        XCTAssertEqual(chmod(dir.path, 0o700), 0)
        XCTAssertEqual(try LocalFilePermissions.read(sub).mode.rawValue, 0o600)
        XCTAssertEqual(chmod(sub.path, 0o700), 0)
        let after = try LocalFilePermissions.read(leaf)
        XCTAssertEqual(after.mode.rawValue, 0o600); XCTAssertEqual(try Data(contentsOf: leaf), data)
        XCTAssertEqual(after.modifiedSeconds, before.modifiedSeconds); XCTAssertEqual(after.modifiedNanoseconds, before.modifiedNanoseconds)
        XCTAssertEqual(try LocalFilePermissions.read(one).mode.rawValue, 0o600)
    }
    func testRecursiveHardLinksVerifyBothPathsWithoutRejectingOwnModeChange() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appendingPathComponent("one"), alias = dir.appendingPathComponent("alias")
        try file(one); XCTAssertEqual(link(one.path, alias.path), 0)
        let plan = try await PermissionBatch.preview([entry(dir, directory: true)], client: nil, recursive: true)
        let result = await PermissionBatch.apply(try UnixPermissions(0o750), plan: plan, client: nil)
        XCTAssertNil(result.error); XCTAssertEqual(result.completed, 3)
        XCTAssertEqual(try LocalFilePermissions.read(one).mode.rawValue, 0o750)
        XCTAssertEqual(try LocalFilePermissions.read(alias).mode.rawValue, 0o750)
        XCTAssertEqual(try Data(contentsOf: alias), try Data(contentsOf: one))
    }
    func testStaleRecursiveScopeRejectsAddDeleteModeReplacementAndTypeChangesBeforeWrites() async throws {
        for change in 0..<5 {
            let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
            let one = dir.appendingPathComponent("one"), two = dir.appendingPathComponent("two")
            try file(one); try file(two)
            let plan = try await PermissionBatch.preview([entry(dir, directory: true)], client: nil, recursive: true)
            switch change {
            case 0: try file(dir.appendingPathComponent(".new"))
            case 1: try FileManager.default.removeItem(at: two)
            case 2: XCTAssertEqual(chmod(two.path, 0o640), 0)
            case 3:
                let replacement = dir.appendingPathComponent("replacement"); try file(replacement)
                XCTAssertEqual(rename(replacement.path, two.path), 0)
            default:
                try FileManager.default.removeItem(at: two)
                try FileManager.default.createSymbolicLink(at: two, withDestinationURL: one)
            }
            let result = await PermissionBatch.apply(try UnixPermissions(0o700), plan: plan, client: nil)
            XCTAssertEqual(result.completed, 0, "Change \(change)"); XCTAssertNotNil(result.error)
            XCTAssertEqual(try LocalFilePermissions.read(one).mode.rawValue, 0o644)
            XCTAssertEqual(try LocalFilePermissions.read(dir).mode, plan.targets.last?.mode)
        }
    }
    func testScanCapacityDepthAndMetadataLimitsFailWithoutPermissionChanges() async throws {
        let dir = try root(), sub = dir.appendingPathComponent("sub")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let one = sub.appendingPathComponent("one"); try file(one)
        for limits in [PermissionScanLimits(entries: 2), PermissionScanLimits(depth: 0),
                       PermissionScanLimits(metadataBytes: 1), PermissionScanLimits(entries: 0),
                       PermissionScanLimits(depth: -1)] {
            do {
                _ = try await PermissionBatch.preview([entry(dir, directory: true)], client: nil, recursive: true, limits: limits)
                XCTFail("Scan limit must reject")
            } catch PermissionPlanError.capacity { }
        }
        XCTAssertEqual(try LocalFilePermissions.read(one).mode.rawValue, 0o644)
    }
    func testCancelledScanAndApplyLeaveTargetsUnchanged() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appendingPathComponent("one"); try file(one)
        let entries = [entry(dir, directory: true)]
        let scan = Task { try await PermissionBatch.preview(entries, client: nil, recursive: true) }
        scan.cancel()
        do { _ = try await scan.value; XCTFail("Cancelled scan must reject") } catch is CancellationError { }
        let plan = try await PermissionBatch.preview(entries, client: nil, recursive: true)
        let apply = Task { await PermissionBatch.apply(try UnixPermissions(0o700), plan: plan, client: nil) }
        apply.cancel(); let result = try await apply.value
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(try LocalFilePermissions.read(one).mode.rawValue, 0o644)
    }
}
