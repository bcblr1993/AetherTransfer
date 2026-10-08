import XCTest
@testable import AetherTransferCore

private final class PermissionProgressSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    let first: XCTestExpectation
    init(_ first: XCTestExpectation) { self.first = first }
    func record(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        if count > 0 && !signalled { signalled = true; first.fulfill() }
    }
}

extension ProtocolIntegrationTests {
    func testPermissionCancellationRetainsVerifiedCountAndStopsRemainingItems() async throws {
        let remote = try client(.sftp), root = "/__aether_permission_slow__-\(UUID())"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("permission-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("same bytes".utf8).write(to: local); try await remote.mkdir(root)
        for name in ["one", "two", "three", "four"] { try await remote.upload(local, to: RemotePath.join(root, name)) }
        let entries = try await remote.list(root)
        let initial = try await PermissionBatch.prepare(entries, client: remote)
        let mode = try UnixPermissions(0o700)
        let first = expectation(description: "First chmod verified"), signal = PermissionProgressSignal(first)
        let operation = Task { await PermissionBatch.apply(mode, targets: initial, client: remote, progress: { signal.record($0) }) }
        await fulfillment(of: [first], timeout: 5)
        operation.cancel(); let result = await operation.value
        XCTAssertTrue(result.cancelled); XCTAssertGreaterThanOrEqual(result.completed, 1); XCTAssertLessThan(result.completed, entries.count)
        // The server may already have accepted one command when the client cancels.
        try await Task.sleep(for: .milliseconds(350))
        let after = try await PermissionBatch.prepare(entries, client: remote)
        let changed = after.filter { $0.mode == mode }.count
        XCTAssertGreaterThanOrEqual(changed, result.completed)
        XCTAssertLessThanOrEqual(changed, result.completed + 1)
        XCTAssertLessThan(changed, entries.count)
        for entry in entries { try await remote.remove(entry.path, directory: false) }
        try await remote.remove(root, directory: true)
    }
    func testUnixPermissionsAcrossFTPAndSFTPKeepBytesAndChildren() async throws {
        for kind in [TransferProtocol.ftp, .sftp, .ftpes, .ftps] {
            let remote = try client(kind)
            let root = "/permissions-\(UUID()) 中文"
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-\(UUID())")
            defer { try? FileManager.default.removeItem(at: local) }
            let data = Data("same bytes\n中文".utf8); try data.write(to: local)
            try await remote.mkdir(root)
            let path = try RemotePath.join(root, "空格 +#%.txt")
            try await remote.upload(local, to: path)
            let initial = try await remote.readPermissions(path)
            try await remote.setPermissions(try UnixPermissions(0o640), for: initial)
            let current = try await remote.readPermissions(path)
            XCTAssertEqual(current.mode.rawValue, 0o640)
            XCTAssertEqual(current.entry.size, initial.entry.size); XCTAssertEqual(current.entry.modified, initial.entry.modified)
            let folder = try await remote.readPermissions(root)
            try await remote.setPermissions(try UnixPermissions(0o750), for: folder)
            let child = try await remote.readPermissions(path)
            XCTAssertEqual(child.mode.rawValue, 0o640)
            let download = local.appendingPathExtension("download"); defer { try? FileManager.default.removeItem(at: download) }
            try await remote.download(path, to: download)
            XCTAssertEqual(try Data(contentsOf: download), data)
            try await remote.remove(path, directory: false); try await remote.remove(root, directory: true)
        }
    }
    func testRemotePermissionBatchPreflightAndStaleModeRefuseWrites() async throws {
        for kind in [TransferProtocol.ftp, .sftp] {
            let remote = try client(kind), root = "/permissions-stale-\(UUID())"
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("permissions-stale-\(UUID())")
            defer { try? FileManager.default.removeItem(at: local) }
            try Data("source".utf8).write(to: local); try await remote.mkdir(root)
            let one = try RemotePath.join(root, "one"), two = try RemotePath.join(root, "two")
            try await remote.upload(local, to: one); try await remote.upload(local, to: two)
            let targets = try await PermissionBatch.prepare(remote.list(root), client: remote)
            let changed = try await remote.readPermissions(two)
            try await remote.setPermissions(try UnixPermissions(changed.mode.rawValue == 0o600 ? 0o640 : 0o600), for: changed)
            let unchanged = try await remote.readPermissions(one)
            let result = await PermissionBatch.apply(try UnixPermissions(0o700), targets: targets, client: remote)
            XCTAssertEqual(result.completed, 0); XCTAssertNotNil(result.error)
            let after = try await remote.readPermissions(one)
            XCTAssertEqual(after.mode, unchanged.mode)
            do { try await remote.setPermissions(try UnixPermissions(0o700), for: changed); XCTFail("Old mode must not overwrite a change") }
            catch FilePermissionError.changed { }
            try await remote.remove(one, directory: false); try await remote.remove(two, directory: false); try await remote.remove(root, directory: true)
        }
    }
}
