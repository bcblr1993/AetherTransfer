import Foundation
import CryptoKit
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

private final class TreeProtocolProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [TransferProgress] = []
    func record(_ value: TransferProgress) { lock.lock(); defer { lock.unlock() }; samples.append(value) }
    func values() -> [TransferProgress] { lock.lock(); defer { lock.unlock() }; return samples }
}

private final class ManifestMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    let file: URL
    init(_ file: URL) { self.file = file }
    func apply(_ value: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        // The first known directory total is emitted after the manifest scan.
        // Display text is localized and must not control fault injection.
        if !changed && value.scope == .directory && value.totalItems != nil && value.completedItems == 0 {
            changed = true; try? Data("changed size".utf8).write(to: file)
        }
    }
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
                            certificateAuthority: kind.usesTLS ? env["AT_TLS_CA"].map { URL(fileURLWithPath: $0) } : nil)
    }
    func roundTrip(_ kind: TransferProtocol, rootPrefix: String? = nil) async throws {
        let remote = try client(kind)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        let data = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: source)
        let path = "/\(rootPrefix ?? kind.rawValue)-\(UUID().uuidString) 空格"
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
    func testSFTPEmptyFileHasVerifiableVersion() async throws {
        let remote = try client(.sftp)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-empty-\(UUID())")
        try Data().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let target = "/empty-version-\(UUID())"
        try await remote.upload(source, to: target)
        let version = try await remote.fileVersion(target)
        XCTAssertEqual(version.size, 0); XCTAssertNotNil(version.modified)
        let digest = try await remote.contentDigest(target, version: version)
        XCTAssertEqual(digest, Data(SHA256.hash(data: Data())))
        try await remote.remove(target, directory: false)
    }
    func testExplicitTLSRoundTrip() async throws { try await roundTrip(.ftpes) }
    func testImplicitTLSRoundTrip() async throws { try await roundTrip(.ftps) }
    func testWebDAVHTTPRoundTrip() async throws { try await roundTrip(.webdav) }
    func testWebDAVHTTPSDigestRoundTrip() async throws {
        for _ in 0..<20 { try await roundTrip(.webdavs) }
        try await roundTrip(.webdavs, rootPrefix: "__aether_fixture_close_auth__")
    }
    func testTLSRejectsUntrustedCertificatesHostMismatchAndPlaintextServer() async throws {
        for kind in [TransferProtocol.ftpes, .ftps, .webdavs] {
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
        for kind in [TransferProtocol.ftp, .sftp, .webdav, .webdavs] {
            let remote = try client(kind)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = Data(repeating: 91, count: 256 * 1024)
            let source = folder.appendingPathComponent("source"), target = "/pause-\(UUID().uuidString)"
            try data.write(to: source); try await remote.upload(source, to: target)
            let control = TransferControl()
            let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, control: control, rateLimit: 64 * 1024,
                                    certificateAuthority: remote.certificateAuthority)
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
            let cancelledClient = RemoteClient(profile: remote.profile, credentials: remote.credentials, control: cancelControl, rateLimit: 64 * 1024,
                                               certificateAuthority: remote.certificateAuthority)
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
        for kind in TransferProtocol.fileServerCases {
            let remote = try client(kind)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("source/子目录"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = Data(repeating: 0x71, count: 65536), second = Data(repeating: 0x91, count: 32768)
            try data.write(to: folder.appendingPathComponent("source/子目录/中文.txt"))
            try second.write(to: folder.appendingPathComponent("source/second.bin"))
            try Data().write(to: folder.appendingPathComponent("source/empty"))
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("source/空目录"), withIntermediateDirectories: false)
            let target = "/tree-\(UUID().uuidString)"
            let store = ResumeTransferStore(directory: folder.appendingPathComponent("journals")), uploads = TreeProtocolProgress(), downloads = TreeProtocolProgress()
            do { try await remote.uploadTree(folder.appendingPathComponent("source"), to: target, store: store) { uploads.record($0) } }
            catch {
                XCTFail("\(kind.rawValue) tree upload failed after \(uploads.values().last?.phase ?? "payload"): \(error)")
                throw error
            }
            let rootEntry = try await remote.list("/").first { $0.path == target }
            let entry = try XCTUnwrap(rootEntry)
            try await remote.downloadTree(entry, to: folder.appendingPathComponent("download"), store: store) { downloads.record($0) }
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("download/子目录/中文.txt")), data)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("download/empty")).count, 0)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("download/second.bin")), second)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("download/空目录").path))
            for log in [uploads, downloads] {
                let values = log.values(), last = try XCTUnwrap(values.last)
                XCTAssertEqual(last.completed, 98304); XCTAssertEqual(last.total, 98304)
                XCTAssertEqual(last.completedItems, 6); XCTAssertEqual(last.totalItems, 6); XCTAssertEqual(last.skippedItems, 0)
                XCTAssertTrue(values.allSatisfy { $0.scope == .directory })
                XCTAssertTrue(values.filter(\.hasKnownTotal).allSatisfy { $0.total == 98304 && $0.totalItems == 6 })
                XCTAssertEqual(values.map(\.completed), values.map(\.completed).sorted())
            }
            let remaining = try await store.records(); XCTAssertTrue(remaining.isEmpty)
            try await remote.uploadTree(folder.appendingPathComponent("source"), to: target, policy: .keepBoth, store: store)
            let parentListing = try await remote.list("/")
            XCTAssertTrue(parentListing.contains { $0.path == target + " (2)" })
            try await remote.downloadTree(entry, to: folder.appendingPathComponent("download"), policy: .keepBoth, store: store)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("download (2)/second.bin")), second)
            let file = try RemotePath.join(target, "empty")
            try await remote.uploadTree(folder.appendingPathComponent("source/empty"), to: file, policy: .keepBoth, store: store)
            let entries = try await remote.list(target)
            XCTAssertTrue(entries.contains { $0.name == "empty (2)" })
        }
    }
    func testDirectorySourceSizeChangeAfterScanRejectsBeforeFileWrite() async throws {
        let remote = try client(.sftp), folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-tree-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("source"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source/data"); try Data("old".utf8).write(to: source)
        let target = "/changed-tree-\(UUID())", mutation = ManifestMutation(source)
        let store = ResumeTransferStore(directory: folder.appendingPathComponent("journals"))
        do {
            try await remote.uploadTree(folder.appendingPathComponent("source"), to: target, store: store) { mutation.apply($0) }
            XCTFail("Changed manifest source must reject")
        } catch ResumeTransferError.sourceChanged { }
        let listing = try await remote.list(target), records = try await store.records()
        XCTAssertTrue(listing.isEmpty); XCTAssertTrue(records.isEmpty)
    }
    func testStaleTreeFileSizePreservesExistingDownload() async throws {
        let remote = try client(.sftp), folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-tree-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source"), destination = folder.appendingPathComponent("download")
        try Data("source".utf8).write(to: source); let previous = Data("keep original".utf8); try previous.write(to: destination)
        let target = "/stale-tree-file-\(UUID())"; try await remote.upload(source, to: target)
        let entry = FileEntry(name: URL(fileURLWithPath: target).lastPathComponent, path: target, isDirectory: false, size: 1)
        let store = ResumeTransferStore(directory: folder.appendingPathComponent("journals"))
        do { try await remote.downloadTree(entry, to: destination, policy: .overwrite, store: store); XCTFail("Stale expected size must reject") }
        catch ResumeTransferError.sourceChanged { }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        let records = try await store.records(); XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".aethertransfer-resume-") })
    }
    func testDirectoryCancellationCleansActiveLeafAndDoesNotReportCompletion() async throws {
        for kind in [TransferProtocol.ftp, .sftp, .ftpes, .ftps, .webdav, .webdavs] {
            let remote = try client(kind), folder = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-tree-\(UUID())")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("source"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let data = Data(repeating: 0x81, count: 1024 * 1024)
            try data.write(to: folder.appendingPathComponent("source/partial.bin"))
            let target = "/cancel-tree-\(UUID())", store = ResumeTransferStore(directory: folder.appendingPathComponent("journals"))
            try await remote.uploadTree(folder.appendingPathComponent("source"), to: target, store: store)
            let listing = try await remote.list("/"), entry = try XCTUnwrap(listing.first { $0.path == target })
            let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, rateLimit: 256 * 1024, certificateAuthority: remote.certificateAuthority)
            let started = expectation(description: "Directory payload started"), recorder = ProgressRecorder(started), log = TreeProtocolProgress()
            let task = Task {
                try await slow.downloadTree(entry, to: folder.appendingPathComponent("download"), store: store) {
                    log.record($0); if $0.phase == nil { recorder.record($0) }
                }
            }
            await fulfillment(of: [started], timeout: 8); task.cancel()
            do { try await task.value; XCTFail("Cancelled directory must not succeed") }
            catch is CancellationError { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("download/partial.bin").path))
            let records = try await store.records(); XCTAssertTrue(records.isEmpty)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("download").path).contains { $0.hasPrefix(".aethertransfer-resume-") })
            XCTAssertFalse(log.values().contains { $0.totalItems != nil && $0.completedItems == $0.totalItems })
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
