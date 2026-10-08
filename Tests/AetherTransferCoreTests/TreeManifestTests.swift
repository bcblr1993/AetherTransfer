import Foundation
import XCTest
@testable import AetherTransferCore

private final class TreeSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [TransferProgress] = []
    func record(_ value: TransferProgress) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
    func values() -> [TransferProgress] { lock.lock(); defer { lock.unlock() }; return samples }
}

@MainActor final class TreeManifestTests: XCTestCase {
    func testLocalManifestIncludesHiddenAndEmptyDirectoriesAndExactBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-tree-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: false)
        try Data(repeating: 0x91, count: 32768).write(to: root.appendingPathComponent("子目录/中文.txt"))
        try Data().write(to: root.appendingPathComponent("empty"))
        let manifest = try await TreeManifest.local(root, control: nil) { _ in }
        XCTAssertEqual(manifest.bytes, 32768)
        XCTAssertEqual(Set(manifest.items.map(\.relative)), ["", "子目录", "子目录/中文.txt", ".hidden", "empty"])
        for (index, item) in manifest.items.enumerated() where !item.relative.isEmpty {
            XCTAssertTrue(manifest.items[..<index].contains { $0.relative == item.parent && $0.entry.isDirectory })
        }
    }
    func testManifestRejectsCapacityDepthDuplicatesSymlinksAndOverflow() throws {
        let root = FileEntry(name: "root", path: "/root", isDirectory: true)
        let child = FileEntry(name: "file", path: "/root/file", isDirectory: false, size: 1)
        var limited = TreeManifest(entryLimit: 1)
        try limited.append(root, relative: "", depth: 0)
        XCTAssertThrowsError(try limited.append(child, relative: "file", depth: 1))
        XCTAssertEqual(limited.items.count, 1)
        var deep = TreeManifest(depthLimit: 1)
        XCTAssertThrowsError(try deep.append(child, relative: "a/file", depth: 2))
        var small = TreeManifest(metadataLimit: 1)
        XCTAssertThrowsError(try small.append(root, relative: "", depth: 0))
        var duplicate = TreeManifest()
        try duplicate.append(root, relative: "", depth: 0)
        XCTAssertThrowsError(try duplicate.append(root, relative: "", depth: 0))
        var links = TreeManifest()
        XCTAssertThrowsError(try links.append(FileEntry(name: "link", path: "/link", isDirectory: false, isSymbolicLink: true), relative: "link", depth: 1))
        var huge = TreeManifest()
        try huge.append(FileEntry(name: "huge", path: "/huge", isDirectory: false, size: .max), relative: "huge", depth: 1)
        XCTAssertThrowsError(try huge.append(child, relative: "file", depth: 1))
        XCTAssertEqual(huge.bytes, .max); XCTAssertEqual(huge.items.count, 1)
    }
    func testZeroByteProgressCountsCommittedAndSkippedItems() {
        var counter = TreeProgress(total: 0, totalItems: 3)
        let root = TreeManifest.Item(relative: "", entry: FileEntry(name: "root", path: "/root", isDirectory: true))
        let empty = TreeManifest.Item(relative: "empty", entry: FileEntry(name: "empty", path: "/root/empty", isDirectory: false))
        XCTAssertTrue(counter.event().hasKnownTotal)
        counter.finish(root)
        XCTAssertEqual(counter.event().fraction, 1.0 / 3.0)
        counter.finish(empty, skipped: true); counter.finish(empty)
        XCTAssertEqual(counter.event().fraction, 1)
        XCTAssertEqual(counter.event().completed, 0)
        XCTAssertEqual(counter.event().skippedItems, 1)
    }
    func testAuthenticationResetDoesNotRegressWholeDirectoryProgress() {
        var counter = TreeProgress(total: 30, totalItems: 2)
        counter.finish(TreeManifest.Item(relative: "first", entry: FileEntry(name: "first", path: "/first", isDirectory: false, size: 10)))
        let samples = TreeSamples()
        let reporter = TreeFileProgress(base: counter, size: 20) { samples.record($0) }
        for bytes: Int64 in [0, 12, 0, 8, 20, 100] { reporter.receive(TransferProgress(completed: bytes, total: 20)) }
        XCTAssertEqual(samples.values().map(\.completed), [10, 22, 22, 22, 30, 30])
        XCTAssertTrue(samples.values().allSatisfy { $0.completedItems == 1 && $0.totalItems == 2 })
    }
    func testPausedLocalScanCanBeCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-tree-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let control = TransferControl(); control.pause()
        let task = Task { try await TreeManifest.local(root, control: control) { _ in } }
        try await Task.sleep(for: .milliseconds(80)); task.cancel()
        do { _ = try await task.value; XCTFail("Paused scan must remain cancellable") }
        catch is CancellationError { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
