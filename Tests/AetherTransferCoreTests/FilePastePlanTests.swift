import Darwin
import XCTest
@testable import AetherTransferCore

@MainActor final class FilePastePlanTests: XCTestCase {
    private func folders() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-paste-plan-\(UUID())")
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return (root, a, b)
    }
    private func input(_ folder: URL, _ name: String) -> FilePasteInput { FilePasteInput(root: .local(folder), name: name) }
    private func expectChanged(_ plan: FilePastePlan) async {
        do { try await FilePaste.validate(plan); XCTFail("Changed metadata must invalidate the plan") }
        catch FilePasteError.changed { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testReadOnlyTreeIncludesHiddenEmptyFilesAndFolders() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: a.appendingPathComponent("目录/empty"), withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: a.appendingPathComponent("目录/.hidden"))
        try Data().write(to: a.appendingPathComponent("目录/zero"))
        let plan = try await FilePaste.preview([input(a, "目录")], destination: .local(b))
        XCTAssertTrue(plan.canApply); XCTAssertEqual(plan.count, 4); XCTAssertEqual(plan.bytes, 6)
        XCTAssertEqual(plan.items[0].source.nodes.map(\.relative), ["", ".hidden", "empty", "zero"])
        try await FilePaste.validate(plan)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("目录/.hidden")), Data("hidden".utf8))
    }
    func testKeepBothReservesNamesAcrossSourcesAndHandlesExtensionsAndDotfiles() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        let c = root.appendingPathComponent("c"); try FileManager.default.createDirectory(at: c, withIntermediateDirectories: false)
        for (dir, name) in [(a, "a.txt"), (c, "a.txt"), (b, "a.txt"), (b, "a (2).txt"), (a, ".config"), (b, ".config")] {
            try Data("seed".utf8).write(to: dir.appendingPathComponent(name))
        }
        let plan = try await FilePaste.preview([input(a, "a.txt"), input(c, "a.txt"), input(a, ".config")], destination: .local(b), policy: .keepBoth)
        XCTAssertTrue(plan.canApply); XCTAssertEqual(plan.items.map(\.destinationName), ["a (3).txt", "a (4).txt", ".config (2)"])
        try await FilePaste.validate(plan)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: b.path)), ["a.txt", "a (2).txt", ".config"])
        let blocked = try await FilePaste.preview([input(a, "a.txt"), input(c, "a.txt")], destination: .local(b), policy: .overwrite)
        XCTAssertFalse(blocked.canApply); XCTAssertEqual(blocked.items[1].issue, .reserved)
        let excluded = try await FilePaste.preview([input(a, "a.txt"), input(c, "a.txt")], destination: .local(b), policy: .overwrite, excluded: [input(c, "a.txt").id])
        XCTAssertTrue(excluded.canApply); XCTAssertTrue(excluded.items[1].skipped)
    }
    func testDirectoryMergeCountsOnlyMappedFilesAndRetainsExtraTargets() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        for dir in [a, b] { try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: false) }
        try Data("source".utf8).write(to: a.appendingPathComponent("folder/same"))
        try Data().write(to: a.appendingPathComponent("folder/new"))
        try Data("target".utf8).write(to: b.appendingPathComponent("folder/same"))
        try Data("preserve".utf8).write(to: b.appendingPathComponent("folder/extra"))
        let plan = try await FilePaste.preview([input(a, "folder")], destination: .local(b), move: true, policy: .overwrite)
        XCTAssertTrue(plan.canApply); XCTAssertTrue(plan.move); XCTAssertEqual(plan.overwriteCount, 1)
        try await FilePaste.validate(plan)
        XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("folder/same")), Data("target".utf8))
        XCTAssertEqual(try Data(contentsOf: b.appendingPathComponent("folder/extra")), Data("preserve".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("folder").path))
    }
    func testInPlaceDuplicateAllowedAndSelfOrDescendantBlocked() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: a.appendingPathComponent("folder/sub"), withIntermediateDirectories: true)
        try Data("seed".utf8).write(to: a.appendingPathComponent("folder/file"))
        let duplicate = try await FilePaste.preview([input(a, "folder")], destination: .local(a), policy: .keepBoth)
        XCTAssertTrue(duplicate.canApply); XCTAssertEqual(duplicate.items[0].destinationName, "folder (2)")
        try await FilePaste.validate(duplicate)
        for target in [a, a.appendingPathComponent("folder"), a.appendingPathComponent("folder/sub")] {
            let plan = try await FilePaste.preview([input(a, "folder")], destination: .local(target), policy: .overwrite)
            XCTAssertFalse(plan.canApply); XCTAssertEqual(plan.items[0].issue, .overlap)
        }
        try FileManager.default.linkItem(at: a.appendingPathComponent("folder/file"), to: b.appendingPathComponent("file"))
        let hardLink = try await FilePaste.preview([input(a.appendingPathComponent("folder"), "file")], destination: .local(b), policy: .overwrite)
        XCTAssertFalse(hardLink.canApply); XCTAssertEqual(hardLink.items[0].issue, .overlap)
    }
    func testOverlappingSourceSelectionRejectedAndOriginalExclusionIDRetained() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: a.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try Data().write(to: a.appendingPathComponent("folder/file"))
        let selection = [input(a, "folder"), input(a.appendingPathComponent("folder"), "file")]
        do { _ = try await FilePaste.preview(selection, destination: .local(b)); XCTFail("Nested selections must be explicit") }
        catch FilePasteError.overlappingSelection { }
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        let item = input(alias, "folder")
        let excluded = try await FilePaste.preview([item], destination: .local(b), excluded: [item.id])
        XCTAssertTrue(excluded.items[0].skipped); XCTAssertEqual(excluded.count, 0); XCTAssertFalse(excluded.canApply)
    }
    func testSourceAtomicReplacementAndSameSizeEditWithRestoredMtimeInvalidate() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        let file = a.appendingPathComponent("file"); try Data("old".utf8).write(to: file)
        let initial = try await FilePaste.preview([input(a, "file")], destination: .local(b))
        try Data("new".utf8).write(to: file, options: .atomic)
        await expectChanged(initial)
        let second = try await FilePaste.preview([input(a, "file")], destination: .local(b))
        let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data("now".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        await expectChanged(second)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.path).isEmpty)
    }
    func testSourceChildAndDestinationHiddenSiblingChangesInvalidate() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: a.appendingPathComponent("folder"), withIntermediateDirectories: false)
        let first = try await FilePaste.preview([input(a, "folder")], destination: .local(b))
        try Data().write(to: a.appendingPathComponent("folder/.hidden")); await expectChanged(first)
        let second = try await FilePaste.preview([input(a, "folder")], destination: .local(b))
        try Data().write(to: b.appendingPathComponent(".added")); await expectChanged(second)
    }
    func testRootReplacementAndReboundSourceAliasInvalidate() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: a.appendingPathComponent("file"))
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        let first = try await FilePaste.preview([input(alias, "file")], destination: .local(b))
        try FileManager.default.removeItem(at: alias); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: b)
        await expectChanged(first)
        let second = try await FilePaste.preview([input(a, "file")], destination: .local(b))
        try FileManager.default.moveItem(at: b, to: root.appendingPathComponent("old-b"))
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
        await expectChanged(second)
    }
    func testSelectedSymlinksAndSpecialFilesRejectedWithoutFollowingThem() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("seed".utf8).write(to: a.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("alias"), withDestinationURL: b)
        XCTAssertEqual(mkfifo(a.appendingPathComponent("fifo").path, 0o600), 0)
        for name in ["alias", "fifo"] {
            do { _ = try await FilePaste.preview([input(a, name)], destination: .local(b)); XCTFail("Special files are unsupported") }
            catch FilePasteError.unsupported { }
        }
        let valid = try await FilePaste.preview([input(a, "file")], destination: .local(b))
        XCTAssertTrue(valid.canApply); try await FilePaste.validate(valid)
    }
    func testTargetTypeAndCaseAliasesBlockAndSkipDoesNotScanSelectedSymlink() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: a.appendingPathComponent("File"))
        try Data().write(to: b.appendingPathComponent("file"))
        let alias = try await FilePaste.preview([input(a, "File")], destination: .local(b), policy: .overwrite)
        XCTAssertFalse(alias.canApply); XCTAssertEqual(alias.items[0].issue, .occupied)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("FileDir"), withIntermediateDirectories: false)
        try Data().write(to: a.appendingPathComponent("FileDir"))
        let type = try await FilePaste.preview([input(a, "FileDir")], destination: .local(b), policy: .overwrite)
        XCTAssertEqual(type.items[0].issue, .typeConflict)
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("skipped"), withDestinationURL: b)
        try Data().write(to: b.appendingPathComponent("skipped"))
        let skipped = try await FilePaste.preview([input(a, "skipped")], destination: .local(b), policy: .skip)
        XCTAssertTrue(skipped.items[0].skipped); XCTAssertEqual(skipped.count, 0)
    }
    func testBoundedNodeMetadataDepthAndSelectionLimitsLeaveNoWrites() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: a.appendingPathComponent("folder/nested"), withIntermediateDirectories: true)
        for limits in [PasteLimits(nodes: 1), PasteLimits(metadata: 1), PasteLimits(depth: 0)] {
            do { _ = try await FilePaste.preview([input(a, "folder")], destination: .local(b), move: false, policy: .reject, excluded: [], limits: limits); XCTFail("Limit must reject") }
            catch FilePasteError.limit { }
        }
        do { _ = try await FilePaste.preview(Array(repeating: input(a, "folder"), count: 1001), destination: .local(b)); XCTFail("Selection limit must reject") }
        catch FilePasteError.limit { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.path).isEmpty)
    }
    func testCancelledPreviewLeavesBothSidesUnchanged() async throws {
        let (root, a, b) = try folders(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: a.appendingPathComponent("file"))
        let task = Task { try Task.checkCancellation(); return try await FilePaste.preview([input(a, "file")], destination: .local(b)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preview must fail") }
        catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.path), ["file"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: b.path).isEmpty)
    }
}
