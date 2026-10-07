import XCTest
@testable import AetherTransferCore

@MainActor final class SyncTests: XCTestCase {
    func folders() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-sync-test-\(UUID().uuidString)")
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        return (root, left, right)
    }
    func testPlannerPreservesExcludedItemsAndBlocksTypeConflicts() throws {
        let file = SyncRecord(kind: .file, size: 4, digest: "left"), directory = SyncRecord(kind: .directory)
        let a = SyncSnapshot(rootID: "left", records: ["new.txt": file, "same.txt": file, "folder": file,
                                                      "ignored/a.txt": file, ".hidden": file])
        let b = SyncSnapshot(rootID: "right", records: ["same.txt": file, "orphan": file, "folder": directory,
                                                       "folder/child": file, "link": SyncRecord(kind: .symbolicLink)])
        var options = SyncOptions(); options.comparison = .contents; options.mirror = true; options.excludedPaths = ["ignored"]
        let plan = try SyncPlanner.plan(left: a, right: b, options: options)
        XCTAssertEqual(plan.items.first { $0.path == "new.txt" }?.operation, .copy(.leftToRight))
        XCTAssertEqual(plan.items.first { $0.path == "orphan" }?.operation, .delete(.right))
        XCTAssertFalse(try XCTUnwrap(plan.items.first { $0.path == "orphan" }).selectedByDefault)
        XCTAssertEqual(plan.items.first { $0.path == "folder" }?.operation, .blocked)
        XCTAssertEqual(plan.items.first { $0.path == "link" }?.operation, .blocked)
        XCTAssertFalse(plan.items.contains { $0.path.hasPrefix("ignored") || $0.path == ".hidden" || $0.path == "folder/child" })
        XCTAssertEqual(plan.unchanged, 1)
        options.excludedPaths = ["../outside"]
        XCTAssertThrowsError(try SyncPlanner.plan(left: a, right: b, options: options))
    }
    func testLocalContentsPreviewSelectionAndBidirectionalResolution() async throws {
        let (root, left, right) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: left.appendingPathComponent("中文 目录"), withIntermediateDirectories: false)
        try Data("from left".utf8).write(to: left.appendingPathComponent("中文 目录/a #.txt"))
        try Data().write(to: left.appendingPathComponent("empty"))
        try Data("left".utf8).write(to: left.appendingPathComponent("conflict"))
        try Data("rght".utf8).write(to: right.appendingPathComponent("conflict"))
        try Data("from right".utf8).write(to: right.appendingPathComponent("right only"))
        var options = SyncOptions(); options.mode = .bidirectional; options.comparison = .contents
        let plan = try await SyncEngine.preview(left: .local(left), right: .local(right), options: options)
        XCTAssertEqual(plan.items.first { $0.path == "conflict" }?.operation, .conflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("中文 目录").path), "Preview cannot mutate folders")
        let all = Set(plan.items.filter(\.executable).map(\.id))
        do { _ = try await SyncEngine.execute(plan, left: .local(left), right: .local(right), selected: all); XCTFail("Conflict must require explicit resolution") }
        catch SyncError.unresolved { }
        XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("conflict")), Data("rght".utf8))
        let result = try await SyncEngine.execute(plan, left: .local(left), right: .local(right), selected: all, resolutions: ["conflict": .leftToRight])
        XCTAssertEqual(result.completed, 5)
        XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("中文 目录/a #.txt")), Data("from left".utf8))
        XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("empty")).count, 0)
        XCTAssertEqual(try Data(contentsOf: left.appendingPathComponent("right only")), Data("from right".utf8))
        XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("conflict")), Data("left".utf8))
        let finished = try await SyncEngine.preview(left: .local(left), right: .local(right), options: options)
        XCTAssertTrue(finished.items.isEmpty)
    }
    func testStaleContentWithIdenticalMetadataFailsBeforeWriting() async throws {
        let (root, left, right) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        let source = left.appendingPathComponent("same size"), destination = right.appendingPathComponent("same size")
        try Data("first".utf8).write(to: source); try Data("older".utf8).write(to: destination)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)
        let modified = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        var options = SyncOptions(); options.comparison = .contents
        let plan = try await SyncEngine.preview(left: .local(left), right: .local(right), options: options)
        try Data("later".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        XCTAssertEqual(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        do { _ = try await SyncEngine.execute(plan, left: .local(left), right: .local(right), selected: ["same size"]); XCTFail("Changed content must invalidate preview") }
        catch SyncError.changed { }
        XCTAssertEqual(try Data(contentsOf: destination), Data("older".utf8))
    }
    func testMissingParentAndExcludedDeleteChildrenCannotMutateDestination() async throws {
        let (root, left, right) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: left.appendingPathComponent("new"), withIntermediateDirectories: false)
        try Data("new".utf8).write(to: left.appendingPathComponent("new/file"))
        var options = SyncOptions(); options.comparison = .contents
        let plan = try await SyncEngine.preview(left: .local(left), right: .local(right), options: options)
        do { _ = try await SyncEngine.execute(plan, left: .local(left), right: .local(right), selected: ["new/file"]); XCTFail("Parent dependency must be explicit") }
        catch SyncError.dependency { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("new").path))
        try FileManager.default.createDirectory(at: right.appendingPathComponent("orphan"), withIntermediateDirectories: false)
        try Data("protected".utf8).write(to: right.appendingPathComponent("orphan/.hidden"))
        options.mirror = true
        let mirror = try await SyncEngine.preview(left: .local(left), right: .local(right), options: options)
        do { _ = try await SyncEngine.execute(mirror, left: .local(left), right: .local(right), selected: ["orphan"]); XCTFail("Excluded child cannot be deleted with its parent") }
        catch SyncError.dependency { }
        XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("orphan/.hidden")), Data("protected".utf8))
    }
    func testOverlappingRootsAndSymlinkTraversalAreRejected() async throws {
        let (root, left, right) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: right.appendingPathComponent("alias"), withDestinationURL: left)
        do { _ = try await SyncEngine.preview(left: .local(left), right: .local(right.appendingPathComponent("alias")), options: SyncOptions()); XCTFail("Aliases of the same root must reject") }
        catch SyncError.overlappingRoots { }
        do { _ = try await SyncEngine.preview(left: .local(root), right: .local(left), options: SyncOptions()); XCTFail("Nested roots must reject") }
        catch SyncError.overlappingRoots { }
        let plan = try await SyncEngine.preview(left: .local(left), right: .local(right), options: SyncOptions())
        XCTAssertEqual(plan.items.first { $0.path == "alias" }?.operation, .blocked)
    }
    func testPrepausedCancellationLeavesNoTemporaryOrFinalFiles() async throws {
        let (root, left, right) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 17, count: 1024 * 1024).write(to: left.appendingPathComponent("source"))
        var options = SyncOptions(); options.comparison = .contents
        let plan = try await SyncEngine.preview(left: .local(left), right: .local(right), options: options)
        let control = TransferControl(); control.pause()
        let task = Task { try await SyncEngine.execute(plan, left: .local(left), right: .local(right), selected: ["source"], control: control) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled synchronization must not commit files") }
        catch is CancellationError { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: right.path).isEmpty)
    }
    func testCancellationDuringLocalStagingPreservesDestination() async throws {
        let (root, left, right) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 17, count: 4 * 1024 * 1024).write(to: left.appendingPathComponent("source"))
        let original = Data("keep this destination".utf8)
        try original.write(to: right.appendingPathComponent("source"))
        var options = SyncOptions(); options.comparison = .contents
        let plan = try await SyncEngine.preview(left: .local(left), right: .local(right), options: options)
        let control = TransferControl(), probe = SyncStagingProbe()
        let task = Task {
            try await SyncEngine.execute(plan, left: .local(left), right: .local(right), selected: ["source"], control: control) { value in
                if value.completed > 0 { probe.pause(control) }
            }
        }
        for _ in 0..<100 {
            if probe.didPause { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(probe.didPause, "Cancellation must happen while a staging file is being written")
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled staging must not commit") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("source")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: right.path), ["source"])
    }
}

private final class SyncStagingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    var didPause: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    func pause(_ control: TransferControl) {
        lock.lock(); defer { lock.unlock() }
        if !paused { control.pause(); paused = true }
    }
}
