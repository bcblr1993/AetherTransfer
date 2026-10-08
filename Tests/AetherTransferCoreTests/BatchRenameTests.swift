import XCTest
import Darwin
@testable import AetherTransferCore

final class BatchRenameTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch-rename-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func entries(_ root: URL, _ names: [String]) throws -> [FileEntry] {
        try names.map { name in
            let url = root.appendingPathComponent(name); try Data(name.utf8).write(to: url)
            return FileEntry(name: name, path: url.path, isDirectory: false)
        }
    }
    func testLiteralRulesKeepExtensionsUnicodeHiddenNamesAndNumbering() throws {
        let file = FileEntry(name: "中文 +#%.tar.gz", path: "/中文 +#%.tar.gz", isDirectory: false)
        var rule = RenameRule(); rule.find = "+#%"; rule.replacement = "测试"
        XCTAssertEqual(try rule.name(for: file, index: 0), "中文 测试.tar.gz")
        rule.kind = .add; rule.prefix = "new-"; rule.suffix = "-end"
        XCTAssertEqual(try rule.name(for: file, index: 0), "new-中文 +#%.tar-end.gz")
        rule.includeExtension = true; XCTAssertEqual(try rule.name(for: file, index: 0), "new-中文 +#%.tar.gz-end")
        rule.includeExtension = false
        XCTAssertEqual(try rule.name(for: FileEntry(name: ".env", path: "/.env", isDirectory: false), index: 0), "new-.env-end")
        XCTAssertEqual(try rule.name(for: FileEntry(name: "folder.txt", path: "/folder.txt", isDirectory: true), index: 0), "new-folder.txt-end")
        rule.kind = .number; rule.base = "照片"; rule.start = 0; rule.increment = 2; rule.digits = 4
        XCTAssertEqual(try rule.name(for: file, index: 2), "照片-0004.gz")
        rule.increment = 0; XCTAssertThrowsError(try rule.name(for: file, index: 0))
        rule.increment = 1; XCTAssertThrowsError(try rule.name(for: file, index: Int.max))
    }
    func testPreviewIsReadOnlyAndApplyPreservesBytesAndMode() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try entries(root, ["a 中文.txt", ".hidden"])
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: original[0].path)
        let snapshot = try await BatchRename.preview(original, client: nil)
        var rule = RenameRule(); rule.kind = .add; rule.prefix = "new-"
        let plan = try snapshot.plan(rule: rule)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(original.map(\.name)))
        let result = await BatchRename.apply(plan, client: nil)
        XCTAssertNil(result.error); XCTAssertFalse(result.cancelled); XCTAssertEqual(result.completed, 2)
        for outcome in result.outcomes {
            let url = root.appendingPathComponent(outcome.currentName)
            XCTAssertEqual(try Data(contentsOf: url), Data(outcome.original.name.utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.original.path))
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("new-a 中文.txt").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }
    func testDependenciesAndNumberingCycleKeepAllOriginalData() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try entries(root, (1...10).map { "file-\($0).txt" })
        let snapshot = try await BatchRename.preview(original.reversed(), client: nil)
        var rule = RenameRule(); rule.kind = .number; rule.base = "file"; rule.digits = 1
        let plan = try snapshot.plan(rule: rule), result = await BatchRename.apply(plan, client: nil)
        XCTAssertNil(result.error); XCTAssertEqual(result.completed, 9)
        for outcome in result.outcomes { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(outcome.currentName)), Data(outcome.original.name.utf8)) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".aethertransfer-rename-") })
    }
    func testCaseOnlyRenameAndSymlinkDoNotModifyTheirTargets() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try entries(root, ["a.txt"])[0], link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("a.txt"))
        let snapshot = try await BatchRename.preview([original], client: nil)
        var rule = RenameRule(); rule.find = "a"; rule.replacement = "A"
        let result = await BatchRename.apply(try snapshot.plan(rule: rule), client: nil)
        XCTAssertNil(result.error); XCTAssertEqual(result.completed, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("A.txt"))
        let linkEntry = FileEntry(name: "link", path: link.path, isDirectory: false, isSymbolicLink: true)
        let links = try await BatchRename.preview([linkEntry], client: nil)
        rule.kind = .add; rule.prefix = "new-"
        let changed = await BatchRename.apply(try links.plan(rule: rule), client: nil)
        XCTAssertNil(changed.error); XCTAssertEqual(changed.completed, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("new-link").path), root.appendingPathComponent("a.txt").path)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("A.txt")), Data("a.txt".utf8))
    }
    func testDuplicateExistingHiddenAndCanonicalNamesBlockUntilExclusion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try entries(root, ["a.txt", "b.txt", ".hidden"])
        let snapshot = try await BatchRename.preview(Array(originals.prefix(2)), client: nil)
        var rule = RenameRule(); rule.find = "a"; rule.replacement = "b"
        var plan = try snapshot.plan(rule: rule); XCTAssertFalse(plan.canApply); XCTAssertNotNil(plan.items[0].issue)
        let refused = await BatchRename.apply(plan, client: nil); XCTAssertEqual(refused.completed, 0); XCTAssertNotNil(refused.error)
        rule.kind = .number; rule.base = "same"; rule.separator = ""; rule.includeExtension = true
        plan = try snapshot.plan(rule: rule, excluded: [snapshot.entries[0].name.data(using: .utf8)!.base64EncodedString()])
        XCTAssertEqual(plan.items[1].proposedName, "same002"); XCTAssertEqual(plan.count, 1); XCTAssertTrue(plan.canApply)
        var hiddenRule = RenameRule(); hiddenRule.find = "a.txt"; hiddenRule.replacement = ".hidden"; hiddenRule.includeExtension = true
        XCTAssertFalse(try snapshot.plan(rule: hiddenRule).canApply)
        let upper = try entries(root, ["B-new.txt"])
        let newer = try await BatchRename.preview([originals[1]], client: nil)
        var add = RenameRule(); add.kind = .add; add.suffix = "-new"
        XCTAssertFalse(try newer.plan(rule: add).canApply); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: upper[0].path)), Data(upper[0].name.utf8))
    }
    func testChangedSourceNewDestinationAndReplacedParentRejectBeforeWrites() async throws {
        let root = try directory(), moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
        let originals = try entries(root, ["one", "two"])
        var rule = RenameRule(); rule.kind = .add; rule.prefix = "new-"
        var snapshot = try await BatchRename.preview(originals, client: nil)
        try Data("different size".utf8).write(to: URL(fileURLWithPath: originals[1].path))
        var result = await BatchRename.apply(try snapshot.plan(rule: rule), client: nil)
        XCTAssertNotNil(result.error); XCTAssertEqual(result.completed, 0); XCTAssertTrue(FileManager.default.fileExists(atPath: originals[0].path))
        snapshot = try await BatchRename.preview(originals, client: nil)
        try Data("occupant".utf8).write(to: root.appendingPathComponent("new-one"))
        result = await BatchRename.apply(try snapshot.plan(rule: rule), client: nil)
        XCTAssertNotNil(result.error); XCTAssertEqual(result.completed, 0); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new-one")), Data("occupant".utf8))
        try FileManager.default.removeItem(at: root.appendingPathComponent("new-one")); snapshot = try await BatchRename.preview(originals, client: nil)
        try FileManager.default.moveItem(at: root, to: moved); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try entries(root, ["one", "two"])
        result = await BatchRename.apply(try snapshot.plan(rule: rule), client: nil)
        XCTAssertNotNil(result.error); XCTAssertEqual(result.completed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("new-one").path))
    }
    func testCancellationInCycleReportsStagingAndPreservesEveryOriginal() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try entries(root, (1...10).map { "file-\($0).txt" }), snapshot = try await BatchRename.preview(originals, client: nil)
        var rule = RenameRule(); rule.kind = .number; rule.base = "file"; rule.digits = 1
        let plan = try snapshot.plan(rule: rule), first = expectation(description: "First final rename verified"), gate = DispatchSemaphore(value: 0)
        let operation = Task { await BatchRename.apply(plan, client: nil) { count in if count == 1 { first.fulfill(); _ = gate.wait(timeout: .now() + 5) } } }
        await fulfillment(of: [first], timeout: 5); operation.cancel(); gate.signal()
        let result = await operation.value
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.completed, 1); XCTAssertTrue(result.outcomes.contains(where: \.staged))
        for outcome in result.outcomes { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(outcome.currentName)), Data(outcome.original.name.utf8)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10)
    }
    func testInvalidNamesMixedParentsSpecialFilesLimitsAndPrecancelledPreview() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try entries(root, ["one"]), snapshot = try await BatchRename.preview(original, client: nil)
        var rule = RenameRule(); rule.kind = .add; rule.prefix = "bad/"
        XCTAssertFalse(try snapshot.plan(rule: rule).canApply)
        rule.prefix = String(repeating: "界", count: 100); XCTAssertFalse(try snapshot.plan(rule: rule).canApply)
        do { _ = try await BatchRename.preview(original + [FileEntry(name: "other", path: "/other", isDirectory: false)], client: nil); XCTFail() } catch BatchRenameError.unavailable { }
        do { _ = try await BatchRename.preview(Array(repeating: original[0], count: 1001), client: nil); XCTFail() } catch BatchRenameError.limit { }
        let fifo = root.appendingPathComponent("pipe"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        do { _ = try await BatchRename.preview([FileEntry(name: "pipe", path: fifo.path, isDirectory: false)], client: nil); XCTFail() } catch BatchRenameError.changed { }
        let operation = Task { try await Task.sleep(for: .milliseconds(50)); return try await BatchRename.preview(original, client: nil) }
        operation.cancel(); do { _ = try await operation.value; XCTFail() } catch is CancellationError { }
    }
    func testDestinationAppearingDuringBatchStopsWithoutOverwriting() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try entries(root, ["one", "two"]), snapshot = try await BatchRename.preview(originals, client: nil)
        var rule = RenameRule(); rule.kind = .add; rule.prefix = "new-"
        let plan = try snapshot.plan(rule: rule), occupant = root.appendingPathComponent("new-two"), bytes = Data("other client bytes".utf8)
        let result = await BatchRename.apply(plan, client: nil) { count in if count == 1 { try? bytes.write(to: occupant) } }
        XCTAssertNotNil(result.error); XCTAssertEqual(result.completed, 1); XCTAssertFalse(result.cancelled)
        XCTAssertEqual(try Data(contentsOf: occupant), bytes); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("two")), Data("two".utf8))
    }
    func testDirectoryEntryLimitStopsPreviewAndKeepsEveryFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = try entries(root, ["selected"])
        for index in 0..<10_000 { XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent("item-\(index)").path, contents: Data())) }
        do { _ = try await BatchRename.preview(originals, client: nil); XCTFail("Oversized directory must not produce a truncated plan") } catch BatchRenameError.limit { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10_001)
    }
}
