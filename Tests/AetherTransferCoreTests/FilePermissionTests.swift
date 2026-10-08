import XCTest
import Darwin
@testable import AetherTransferCore

@MainActor final class FilePermissionTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aether-permission-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testModeRoundTripsSpecialBitsAndRejectsMalformedInputs() throws {
        for value in UInt16(0)...UInt16(0o7777) {
            let mode = try UnixPermissions(value)
            XCTAssertEqual(try UnixPermissions(octal: mode.octal), mode)
            XCTAssertEqual(try UnixPermissions(listing: "-" + mode.symbolic), mode)
        }
        XCTAssertEqual(try UnixPermissions(listing: "drwsr-Sr-T+").octal, "7744")
        for input in ["", "64", "10000", "-644", "0o644", " 644", "644\n", "0888", "６４４"] {
            XCTAssertThrowsError(try UnixPermissions(octal: input))
        }
        for input in ["rwxrwxrwx", "-abcdefghi", "-rwxrwxrwtfoo", "-rwtrw-r--", "-rwxrwsr-s"] {
            XCTAssertThrowsError(try UnixPermissions(listing: input))
        }
        XCTAssertThrowsError(try UnixPermissions(0o10000))
    }
    func testLocalChangesPreserveBytesTimeAndChildrenAndRepairUnreadableFiles() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("中文 # + 文件.txt")
        let data = Data("private content".utf8); try data.write(to: file)
        let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let entries = [FileEntry(name: file.lastPathComponent, path: file.path, isDirectory: false)]
        let targets = try await PermissionBatch.prepare(entries, client: nil)
        XCTAssertEqual(targets[0].mode.rawValue, 0)
        let result = await PermissionBatch.apply(try UnixPermissions(0o640), targets: targets, client: nil)
        XCTAssertNil(result.error); XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        XCTAssertEqual(try LocalFilePermissions.read(file).mode.rawValue, 0o640)
        let parentTargets = try await PermissionBatch.prepare([FileEntry(name: dir.lastPathComponent, path: dir.path, isDirectory: true)], client: nil)
        let folderResult = await PermissionBatch.apply(try UnixPermissions(0o750), targets: parentTargets, client: nil)
        XCTAssertNil(folderResult.error); XCTAssertEqual(folderResult.completed, 1)
        XCTAssertEqual(try LocalFilePermissions.read(file).mode.rawValue, 0o640)
        XCTAssertEqual(try LocalFilePermissions.read(dir).mode.rawValue, 0o750)
    }
    func testLocalSymlinkAndSpecialFileRefusalDoesNotChangeTarget() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("original"), link = dir.appendingPathComponent("link"), fifo = dir.appendingPathComponent("fifo")
        try Data().write(to: file); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let before = try LocalFilePermissions.read(file).mode
        XCTAssertThrowsError(try LocalFilePermissions.read(link)) { XCTAssertEqual($0 as? FilePermissionError, .symbolicLink) }
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try LocalFilePermissions.read(fifo))
        do { _ = try await PermissionBatch.prepare([FileEntry(name: "link", path: link.path, isDirectory: false, isSymbolicLink: true)], client: nil); XCTFail("Known links must reject") }
        catch FilePermissionError.symbolicLink { }
        XCTAssertEqual(try LocalFilePermissions.read(file).mode, before)
    }
    func testLocalReplacementAndPermissionChangesRejectBeforeMutation() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file"), replacement = dir.appendingPathComponent("replacement")
        try Data("old".utf8).write(to: file)
        let expected = try LocalFilePermissions.read(file)
        try Data("new".utf8).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, file.path), 0)
        let before = try LocalFilePermissions.read(file).mode
        XCTAssertThrowsError(try LocalFilePermissions.apply(try UnixPermissions(0o700), to: expected)) { XCTAssertEqual($0 as? FilePermissionError, .changed) }
        XCTAssertEqual(try LocalFilePermissions.read(file).mode, before)
        let current = try LocalFilePermissions.read(file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalFilePermissions.apply(try UnixPermissions(0o700), to: current))
        XCTAssertEqual(try LocalFilePermissions.read(file).mode.rawValue, 0o600)
    }
    func testBatchPreflightAndCancellationDoNotApplyUnverifiedTargets() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let files = [dir.appendingPathComponent("one"), dir.appendingPathComponent("two")]
        for file in files { try Data().write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let entries = files.map { FileEntry(name: $0.lastPathComponent, path: $0.path, isDirectory: false) }
        let targets = try await PermissionBatch.prepare(entries, client: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files[1].path)
        let result = await PermissionBatch.apply(try UnixPermissions(0o700), targets: targets, client: nil)
        XCTAssertEqual(result.completed, 0); XCTAssertNotNil(result.error)
        XCTAssertEqual(try LocalFilePermissions.read(files[0]).mode.rawValue, 0o644)
        let current = try await PermissionBatch.prepare(entries, client: nil)
        let task = Task { await PermissionBatch.apply(try UnixPermissions(0o700), targets: current, client: nil) }
        task.cancel(); let cancelled = try await task.value
        XCTAssertTrue(cancelled.cancelled); XCTAssertEqual(cancelled.completed, 0)
        XCTAssertEqual(try LocalFilePermissions.read(files[0]).mode.rawValue, 0o644)
    }
    func testUnsupportedConnectionsAndUnsafePathsRejectWithoutNetwork() async throws {
        for kind in [TransferProtocol.webdav, .webdavs, .s3] {
            let client = RemoteClient(profile: ServerProfile(host: "127.0.0.1", port: 1, username: "fixture", protocolKind: kind), credentials: Credentials())
            do { _ = try await client.readPermissions("/file"); XCTFail("Unsupported protocol must reject") }
            catch FilePermissionError.unsupported { }
        }
        let client = RemoteClient(profile: ServerProfile(host: "127.0.0.1", port: 1, username: "fixture", protocolKind: .ftp), credentials: Credentials())
        do { _ = try await client.readPermissions("/file\nSITE CHMOD 0777 /other"); XCTFail("Command injection must reject") }
        catch TransferError.invalidPath { }
    }
}
