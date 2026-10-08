import XCTest
@testable import AetherTransferCore

private final class RenameProgressSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false
    let first: XCTestExpectation
    init(_ first: XCTestExpectation) { self.first = first }
    func record(_ count: Int) { lock.lock(); defer { lock.unlock() }; if count > 0 && !sent { sent = true; first.fulfill() } }
}

extension ProtocolIntegrationTests {
    func testBatchRenameAcrossSixFileServerProtocolsPreservesHiddenFilesAndFolderChildren() async throws {
        for kind in TransferProtocol.fileServerCases {
            let remote = try client(kind), root = "/rename-\(UUID()) 中文", local = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID())")
            let download = local.appendingPathExtension("download")
            defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: download) }
            let data = Data("unchanged 中文 +#% bytes".utf8); try data.write(to: local); try await remote.mkdir(root)
            for name in ["中文 +#%.txt", ".hidden"] { try await remote.upload(local, to: RemotePath.join(root, name)) }
            let folder = try RemotePath.join(root, "folder.ext"); try await remote.mkdir(folder); try await remote.upload(local, to: RemotePath.join(folder, "child"))
            let original = try await remote.list(root, includingHidden: true), snapshot = try await BatchRename.preview(original, client: remote)
            var rule = RenameRule(); rule.kind = .add; rule.prefix = "new-"; rule.suffix = "-end"
            let plan = try snapshot.plan(rule: rule); XCTAssertTrue(plan.canApply)
            let before = try await remote.list(root, includingHidden: true); XCTAssertEqual(before.count, 3)
            let result = await BatchRename.apply(plan, client: remote)
            XCTAssertNil(result.error, "\(kind): \(result.error ?? "")"); XCTAssertFalse(result.cancelled); XCTAssertEqual(result.completed, 3)
            for outcome in result.outcomes {
                let path = try RemotePath.join(root, outcome.currentName)
                let file = outcome.original.isDirectory ? try RemotePath.join(path, "child") : path
                try await remote.download(file, to: download, overwrite: true); XCTAssertEqual(try Data(contentsOf: download), data)
                try await remote.remove(file, directory: false)
                if outcome.original.isDirectory { try await remote.remove(path, directory: true) }
            }
            try await remote.remove(root, directory: true)
        }
    }
    func testBatchRenameExistingDestinationAndStaleSourceRejectAllWritesAcrossProtocols() async throws {
        for kind in TransferProtocol.fileServerCases {
            let remote = try client(kind), root = "/rename-stale-\(UUID())", local = FileManager.default.temporaryDirectory.appendingPathComponent("rename-stale-\(UUID())")
            let download = local.appendingPathExtension("download")
            defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: download) }
            let data = Data("original bytes".utf8); try data.write(to: local); try await remote.mkdir(root)
            for name in ["one", "two"] { try await remote.upload(local, to: RemotePath.join(root, name)) }
            var rule = RenameRule(); rule.kind = .add; rule.prefix = ".new-"
            var snapshot = try await BatchRename.preview(remote.list(root, includingHidden: true), client: remote)
            let destination = try RemotePath.join(root, ".new-one")
            try await remote.upload(local, to: destination)
            var result = await BatchRename.apply(try snapshot.plan(rule: rule), client: remote)
            XCTAssertEqual(result.completed, 0); XCTAssertNotNil(result.error)
            do { try await remote.rename(RemotePath.join(root, "one"), to: destination); XCTFail("No-overwrite rename must reject hidden destination") } catch TransferError.conflict { }
            try await remote.download(destination, to: download); XCTAssertEqual(try Data(contentsOf: download), data)
            try await remote.remove(destination, directory: false)
            snapshot = try await BatchRename.preview(remote.list(root, includingHidden: true), client: remote)
            try Data("longer changed source bytes".utf8).write(to: local); try await remote.upload(local, to: RemotePath.join(root, "two"), overwrite: true)
            result = await BatchRename.apply(try snapshot.plan(rule: rule), client: remote)
            XCTAssertEqual(result.completed, 0); XCTAssertNotNil(result.error)
            try await remote.download(RemotePath.join(root, "one"), to: download, overwrite: true); XCTAssertEqual(try Data(contentsOf: download), data)
            for name in ["one", "two"] { try await remote.remove(RemotePath.join(root, name), directory: false) }; try await remote.remove(root, directory: true)
        }
    }
    func testBatchRenameNumberingCycleAcrossProtocolsKeepsEveryOriginal() async throws {
        for kind in TransferProtocol.fileServerCases {
            let remote = try client(kind), root = "/rename-cycle-\(UUID())", local = FileManager.default.temporaryDirectory.appendingPathComponent("rename-cycle-\(UUID())")
            let download = local.appendingPathExtension("download")
            defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: download) }
            try await remote.mkdir(root)
            for number in 1...10 { let name = "file-\(number).txt"; try Data(name.utf8).write(to: local); try await remote.upload(local, to: RemotePath.join(root, name)) }
            let snapshot = try await BatchRename.preview(remote.list(root, includingHidden: true), client: remote)
            var rule = RenameRule(); rule.kind = .number; rule.base = "file"; rule.digits = 1
            let result = await BatchRename.apply(try snapshot.plan(rule: rule), client: remote)
            XCTAssertNil(result.error, "\(kind): \(result.error ?? "")"); XCTAssertEqual(result.completed, 9)
            for outcome in result.outcomes {
                let path = try RemotePath.join(root, outcome.currentName)
                try await remote.download(path, to: download, overwrite: true); XCTAssertEqual(try Data(contentsOf: download), Data(outcome.original.name.utf8))
                try await remote.remove(path, directory: false)
            }
            let empty = try await remote.list(root, includingHidden: true); XCTAssertTrue(empty.isEmpty); try await remote.remove(root, directory: true)
        }
    }
    func testBatchRenameCancellationReportsPossibleServerNamesAndStopsRemainingCommands() async throws {
        let remote = try client(.sftp), root = "/__aether_rename_slow__-\(UUID())", local = FileManager.default.temporaryDirectory.appendingPathComponent("rename-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: local) }
        try await remote.mkdir(root)
        for name in ["one", "two", "three", "four"] { try Data(name.utf8).write(to: local); try await remote.upload(local, to: RemotePath.join(root, name)) }
        let snapshot = try await BatchRename.preview(remote.list(root, includingHidden: true), client: remote)
        var rule = RenameRule(); rule.kind = .add; rule.prefix = "new-"
        let plan = try snapshot.plan(rule: rule), first = expectation(description: "First remote rename verified"), signal = RenameProgressSignal(first)
        let operation = Task { await BatchRename.apply(plan, client: remote, progress: signal.record) }
        await fulfillment(of: [first], timeout: 5); operation.cancel()
        let result = await operation.value
        XCTAssertTrue(result.cancelled); XCTAssertGreaterThanOrEqual(result.completed, 1); XCTAssertLessThan(result.completed, 4)
        try await Task.sleep(for: .milliseconds(350))
        let actual = try await remote.list(root, includingHidden: true); XCTAssertEqual(actual.count, 4)
        for outcome in result.outcomes {
            let candidates = [outcome.currentName, outcome.unconfirmedDestination].compactMap { $0 }
            let found = actual.filter { candidates.contains($0.name) }; XCTAssertEqual(found.count, 1)
            if let file = found.first {
                let download = local.appendingPathExtension("download"); defer { try? FileManager.default.removeItem(at: download) }
                try await remote.download(file.path, to: download); XCTAssertEqual(try Data(contentsOf: download), Data(outcome.original.name.utf8))
            }
        }
        for file in actual { try await remote.remove(file.path, directory: false) }; try await remote.remove(root, directory: true)
    }
}
