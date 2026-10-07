import Foundation
import XCTest
@testable import AetherTransferCore

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    private var announced = false
    let started: XCTestExpectation
    init(_ started: XCTestExpectation) { self.started = started }
    func record(_ progress: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        value = progress.completed
        if value > 0 && !announced { announced = true; started.fulfill() }
    }
    func snapshot() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class ProtocolIntegrationTests: XCTestCase {
    func client(_ kind: TransferProtocol, trusted: Bool = true) throws -> RemoteClient {
        let env = ProcessInfo.processInfo.environment
        let variable = "AT_\(kind.rawValue.uppercased())_PORT"
        guard let port = env[variable], let number = Int(port) else {
            throw XCTSkip("Run scripts/test_protocols.sh for isolated real protocol servers")
        }
        return RemoteClient(profile: ServerProfile(host: "127.0.0.1", port: number, username: "fixture", protocolKind: kind,
                                                  trustedHostKey: trusted && kind == .sftp ? env["AT_SFTP_KEY"] : nil),
                            credentials: Credentials(password: "fixture-only"),
                            certificateAuthority: (kind == .ftps || kind == .ftpes) ? env["AT_TLS_CA"].map { URL(fileURLWithPath: $0) } : nil)
    }
    func roundTrip(_ kind: TransferProtocol) async throws {
        let remote = try client(kind)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        let data = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: source)
        let path = "/\(kind.rawValue)-\(UUID().uuidString) 空格"
        try await remote.mkdir(path)
        let target = try RemotePath.join(path, "中文 # 文件.txt")
        try await remote.upload(source, to: target)
        let listing = try await remote.list(path)
        XCTAssertEqual(listing.count, 1); XCTAssertEqual(listing[0].name, "中文 # 文件.txt")
        XCTAssertEqual(listing[0].size, Int64(data.count))
        let download = folder.appendingPathComponent("download")
        try await remote.download(target, to: download)
        XCTAssertEqual(try Data(contentsOf: download), data)
        do { try await remote.upload(source, to: target); XCTFail("Conflict must reject") }
        catch TransferError.conflict { }
        let replacement = Data("replacement contents".utf8)
        try replacement.write(to: source)
        try await remote.upload(source, to: target, overwrite: true)
        try await remote.download(target, to: download, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: download), replacement)
        let renamed = try RemotePath.join(path, "renamed.txt")
        try await remote.rename(target, to: renamed)
        try await remote.remove(renamed, directory: false)
        let empty = try await remote.list(path)
        XCTAssertTrue(empty.isEmpty)
        try await remote.remove(path, directory: true)
    }
    func testFTPRoundTrip() async throws { try await roundTrip(.ftp) }
    func testSFTPRoundTrip() async throws { try await roundTrip(.sftp) }
    func testExplicitTLSRoundTrip() async throws { try await roundTrip(.ftpes) }
    func testImplicitTLSRoundTrip() async throws { try await roundTrip(.ftps) }
    func testTLSRejectsUntrustedCertificatesHostMismatchAndPlaintextServer() async throws {
        for kind in [TransferProtocol.ftpes, .ftps] {
            let trusted = try client(kind)
            let untrusted = RemoteClient(profile: trusted.profile, credentials: trusted.credentials)
            do { _ = try await untrusted.list("/"); XCTFail("Untrusted certificate must fail") }
            catch TransferError.remote { }
            var wrongHost = trusted.profile; wrongHost.host = "localhost"
            let mismatched = RemoteClient(profile: wrongHost, credentials: trusted.credentials, certificateAuthority: trusted.certificateAuthority)
            do { _ = try await mismatched.list("/"); XCTFail("Certificate hostname must be checked") }
            catch TransferError.remote { }
        }
        let plain = try client(.ftp)
        var profile = plain.profile; profile.protocolKind = .ftpes
        do { _ = try await RemoteClient(profile: profile, credentials: plain.credentials).list("/"); XCTFail("TLS must never downgrade to plaintext") }
        catch TransferError.remote { }
    }
    func testEncryptedSSHPrivateKeyAuthentication() async throws {
        let passwordClient = try client(.sftp)
        let env = ProcessInfo.processInfo.environment
        let privateKey = try XCTUnwrap(env["AT_SFTP_PRIVATE_KEY"])
        var profile = passwordClient.profile; profile.privateKeyPath = privateKey
        let keyClient = RemoteClient(profile: profile, credentials: Credentials(passphrase: "fixture-passphrase"))
        let listing = try await keyClient.list("/")
        XCTAssertTrue(listing.contains { $0.name == "中文 seed.txt" })
        let wrongPassphrase = RemoteClient(profile: profile, credentials: Credentials(passphrase: "incorrect"))
        do { _ = try await wrongPassphrase.list("/"); XCTFail("Wrong passphrase must fail") }
        catch TransferError.remote { }
    }
    func testPauseResumeAndCancellationPreserveFiles() async throws {
        for kind in [TransferProtocol.ftp, .sftp] {
            let remote = try client(kind)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = Data(repeating: 91, count: 256 * 1024)
            let source = folder.appendingPathComponent("source"), target = "/pause-\(UUID().uuidString)"
            try data.write(to: source); try await remote.upload(source, to: target)
            let control = TransferControl()
            let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, control: control, rateLimit: 64 * 1024)
            let started = expectation(description: "\(kind) transfer started"), recorder = ProgressRecorder(started)
            let destination = folder.appendingPathComponent("download")
            let operation = Task { try await slow.download(target, to: destination, progress: { recorder.record($0) }) }
            await fulfillment(of: [started], timeout: 3)
            control.pause()
            try await Task.sleep(for: .milliseconds(300))
            let paused = recorder.snapshot()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(recorder.snapshot(), paused, "Paused transfer must stop advancing")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Partial download cannot become the final file")
            control.resume(); try await operation.value
            XCTAssertEqual(try Data(contentsOf: destination), data)
            let cancelControl = TransferControl(); cancelControl.pause()
            let cancelledClient = RemoteClient(profile: remote.profile, credentials: remote.credentials, control: cancelControl, rateLimit: 64 * 1024)
            let missing = folder.appendingPathComponent("cancelled")
            let cancelled = Task { try await cancelledClient.download(target, to: missing) }
            try await Task.sleep(for: .milliseconds(150)); cancelled.cancel()
            do { try await cancelled.value; XCTFail("Cancelled operation must not succeed") }
            catch is CancellationError { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".part") }
            XCTAssertTrue(leftovers.isEmpty)
        }
    }
    func testRecursiveTransfersAndKeepBoth() async throws {
        for kind in [TransferProtocol.ftp, .sftp] {
            let remote = try client(kind)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("source/子目录"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = Data("recursive fixture".utf8)
            try data.write(to: folder.appendingPathComponent("source/子目录/中文.txt"))
            try Data().write(to: folder.appendingPathComponent("source/empty"))
            let target = "/tree-\(UUID().uuidString)"
            try await remote.uploadTree(folder.appendingPathComponent("source"), to: target)
            let rootEntry = try await remote.list("/").first { $0.path == target }
            let entry = try XCTUnwrap(rootEntry)
            try await remote.downloadTree(entry, to: folder.appendingPathComponent("download"))
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("download/子目录/中文.txt")), data)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("download/empty")).count, 0)
            let file = try RemotePath.join(target, "empty")
            try await remote.uploadTree(folder.appendingPathComponent("source/empty"), to: file, policy: .keepBoth)
            let entries = try await remote.list(target)
            XCTAssertTrue(entries.contains { $0.name == "empty (2)" })
        }
    }
    func testSFTPRejectsUntrustedAndChangedHostKey() async throws {
        let untrusted = try client(.sftp, trusted: false)
        do { _ = try await untrusted.list("/"); XCTFail("Untrusted host must be rejected") }
        catch TransferError.hostKeyRequired(let key, let changed) {
            XCTAssertFalse(changed); XCTAssertFalse(key.isEmpty)
            XCTAssertEqual(key, ProcessInfo.processInfo.environment["AT_SFTP_KEY"])
        }
        var changed = untrusted.profile; changed.trustedHostKey = "ZmFrZQ=="
        do { _ = try await RemoteClient(profile: changed, credentials: untrusted.credentials).list("/"); XCTFail("Changed host must be rejected") }
        catch TransferError.hostKeyRequired(_, let changed) { XCTAssertTrue(changed) }
    }
    func testFailedDownloadPreservesExistingDestination() async throws {
        let remote = try client(.ftp)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let data = Data("keep this".utf8); try data.write(to: destination)
        do { try await remote.download("/missing-\(UUID().uuidString)", to: destination, overwrite: true); XCTFail("Missing download must fail") }
        catch { XCTAssertEqual(try Data(contentsOf: destination), data) }
    }
}
