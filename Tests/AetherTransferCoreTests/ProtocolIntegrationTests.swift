import CryptoKit
import CTransfer
import Foundation
import Security
import XCTest
@testable import AetherTransferCore

private final class FixtureTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let anchorCertificate: SecCertificate

    init(caURL: URL) throws {
        let pem = try String(contentsOf: caURL, encoding: .utf8)
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let der = Data(base64Encoded: base64),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw TransferError.invalidConnection
        }
        self.anchorCertificate = cert
    }

    private func evaluateChallenge(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        SecTrustSetAnchorCertificates(trust, [anchorCertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = evaluateChallenge(challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = evaluateChallenge(challenge)
        completionHandler(disposition, credential)
    }
}

@MainActor final class ProtocolIntegrationTests: XCTestCase {
    private func envValue(_ key: String) throws -> String {
        guard let val = ProcessInfo.processInfo.environment[key], !val.isEmpty else {
            throw XCTSkip("Run scripts/test_protocols.sh for isolated loopback protocol servers (\(key) missing)")
        }
        return val
    }

    private func envPort(_ key: String) throws -> Int {
        let raw = try envValue(key)
        guard let port = Int(raw) else {
            throw XCTSkip("Invalid port for \(key): \(raw)")
        }
        return port
    }

    private func makeFixtureSession() throws -> URLSession {
        let caPath = try envValue("AT_FTPS_CA")
        let delegate = try FixtureTLSDelegate(caURL: URL(fileURLWithPath: caPath))
        return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDeterministicData(size: Int, seed: Int = 1) -> Data {
        Data((0..<size).map { UInt8(($0 * 17 + $0 / 251 + seed) % 256) })
    }

    private func client(
        _ kind: TransferProtocol,
        trusted: Bool = true,
        speedLimitBytesPerSec: Int64? = nil,
        httpSession: URLSession = .shared
    ) throws -> RemoteClient {
        switch kind {
        case .ftp:
            let port = try envPort("AT_FTP_PORT")
            return RemoteClient(
                profile: ServerProfile(host: "127.0.0.1", port: port, username: "fixture", protocolKind: .ftp),
                credentials: Credentials(password: "fixture-only"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .ftps:
            let port = try envPort("AT_FTPS_PORT")
            return RemoteClient(
                profile: ServerProfile(host: "127.0.0.1", port: port, username: "fixture", protocolKind: .ftps),
                credentials: Credentials(password: "fixture-only"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .ftpsExplicit:
            let port = try envPort("AT_FTPS_EXPLICIT_PORT")
            return RemoteClient(
                profile: ServerProfile(host: "127.0.0.1", port: port, username: "fixture", protocolKind: .ftpsExplicit),
                credentials: Credentials(password: "fixture-only"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .sftp:
            let port = try envPort("AT_SFTP_PORT")
            let key = try envValue("AT_SFTP_KEY")
            return RemoteClient(
                profile: ServerProfile(
                    host: "127.0.0.1",
                    port: port,
                    username: "fixture",
                    protocolKind: .sftp,
                    trustedHostKey: trusted ? key : nil
                ),
                credentials: Credentials(password: "fixture-only"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .webdav:
            let port = try envPort("AT_WEBDAV_PORT")
            return RemoteClient(
                profile: ServerProfile(host: "127.0.0.1", port: port, username: "fixture", protocolKind: .webdav),
                credentials: Credentials(password: "fixture-only"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .webdavs:
            let port = try envPort("AT_WEBDAVS_PORT")
            return RemoteClient(
                profile: ServerProfile(host: "127.0.0.1", port: port, username: "fixture", protocolKind: .webdavs),
                credentials: Credentials(password: "fixture-only"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .s3:
            let port = try envPort("AT_S3_PORT")
            return RemoteClient(
                profile: ServerProfile(
                    host: "127.0.0.1",
                    port: port,
                    username: "AKIAFIXTURE",
                    protocolKind: .s3,
                    s3Bucket: "test-bucket",
                    s3Region: "us-east-1",
                    s3PathStyle: true
                ),
                credentials: Credentials(password: "secret-fixture-key"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .b2:
            let port = try envPort("AT_B2_PORT")
            return RemoteClient(
                profile: ServerProfile(
                    host: "127.0.0.1",
                    port: port,
                    username: "b2-key-fixture",
                    protocolKind: .b2,
                    b2BucketName: "test-b2-bucket",
                    b2BucketId: "bkt-fixture-001"
                ),
                credentials: Credentials(password: "b2-secret-fixture"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .azureBlob:
            let port = try envPort("AT_AZURE_PORT")
            let sharedKey = try envValue("AT_AZURE_SHARED_KEY")
            return RemoteClient(
                profile: ServerProfile(
                    host: "127.0.0.1",
                    port: port,
                    protocolKind: .azureBlob,
                    azureAccountName: "fixtureacct",
                    azureContainer: "fixturecontainer",
                    azureUseSAS: false
                ),
                credentials: Credentials(password: sharedKey),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        case .openstackSwift:
            let port = try envPort("AT_SWIFT_PORT")
            return RemoteClient(
                profile: ServerProfile(
                    host: "127.0.0.1",
                    port: port,
                    username: "fixture",
                    protocolKind: .openstackSwift,
                    swiftAuthURL: "https://127.0.0.1:\(port)/v1.0",
                    swiftContainer: "fixture-container",
                    swiftTenantOrProject: "fixtureproj"
                ),
                credentials: Credentials(password: "fixture-only"),
                speedLimitBytesPerSec: speedLimitBytesPerSec,
                httpSession: httpSession
            )
        }
    }

    // MARK: - Core Round-Trip & Resumable Harness

    private func roundTrip(_ kind: TransferProtocol, httpSession: URLSession = .shared) async throws {
        let remote = try client(kind, httpSession: httpSession)
        let folder = try makeTempDir("aethertransfer-test-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let seedListing = try await remote.list("/")
        XCTAssertTrue(seedListing.contains(where: { $0.name == "中文 seed.txt" }), "\(kind.rawValue) root listing should include seed file")

        let source = folder.appendingPathComponent("source")
        let data = makeDeterministicData(size: 192 * 1024 + 137, seed: 3)
        try data.write(to: source)

        let path = "/\(kind.rawValue)-\(UUID().uuidString) 空格"
        try await remote.mkdir(path)
        let target = try RemotePath.join(path, "中文 # 文件.txt")
        try await remote.upload(source, to: target)

        let listing = try await remote.list(path)
        XCTAssertEqual(listing.count, 1)
        XCTAssertEqual(listing[0].name, "中文 # 文件.txt")
        XCTAssertEqual(listing[0].size, Int64(data.count))

        let download = folder.appendingPathComponent("download")
        try await remote.download(target, to: download)
        XCTAssertEqual(try Data(contentsOf: download), data)

        // Upload conflict must reject without clobbering existing remote file
        let altSource = folder.appendingPathComponent("alt")
        try Data("overwrite attempt".utf8).write(to: altSource)
        do {
            try await remote.upload(altSource, to: target, overwrite: false)
            XCTFail("Conflict must reject for \(kind.rawValue)")
        } catch TransferError.conflict {
        }
        let verifyPreserved = folder.appendingPathComponent("verify-preserved")
        try await remote.download(target, to: verifyPreserved)
        XCTAssertEqual(try Data(contentsOf: verifyPreserved), data)

        // Download conflict & missing-file failure must preserve existing local destination
        do {
            try await remote.download(target, to: download, overwrite: false)
            XCTFail("Local conflict must reject for \(kind.rawValue)")
        } catch TransferError.conflict {
        }
        XCTAssertEqual(try Data(contentsOf: download), data)

        let preserved = folder.appendingPathComponent("keep-existing")
        let keepData = Data("keep this intact".utf8)
        try keepData.write(to: preserved)
        do {
            try await remote.download(try RemotePath.join(path, "missing-\(UUID().uuidString).bin"), to: preserved, overwrite: true)
            XCTFail("Missing remote file must fail for \(kind.rawValue)")
        } catch {
            XCTAssertEqual(try Data(contentsOf: preserved), keepData)
        }

        // Range resume via ResumableTransfer
        let resumeDest = folder.appendingPathComponent("resumed.bin")
        let store = ResumeTransferStore(directory: folder.appendingPathComponent("journal"))
        let resumeTask = try ResumableTransfer(
            direction: .download,
            local: resumeDest,
            remote: target,
            profile: remote.profile,
            overwrite: true,
            store: store
        )
        try data.prefix(64 * 1024).write(to: resumeTask.stagingLocalURL)
        try await resumeTask.run(client: remote)
        XCTAssertEqual(try Data(contentsOf: resumeDest), data)
        let remainingRecords = try await store.records()
        XCTAssertTrue(remainingRecords.isEmpty)

        let renamed = try RemotePath.join(path, "renamed 空格.txt")
        try await remote.rename(target, to: renamed)
        let afterRename = try await remote.list(path)
        XCTAssertEqual(afterRename.map(\.name), ["renamed 空格.txt"])

        try await remote.remove(renamed, directory: false)
        let empty = try await remote.list(path)
        XCTAssertTrue(empty.isEmpty)
        try await remote.remove(path, directory: true)
    }

    private func verifyCancellation(_ kind: TransferProtocol, httpSession: URLSession = .shared) async throws {
        let remote = try client(kind, speedLimitBytesPerSec: 16 * 1024, httpSession: httpSession)
        let folder = try makeTempDir("aether-cancel-\(kind.rawValue)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let payload = makeDeterministicData(size: 256 * 1024, seed: 9)
        let localSource = folder.appendingPathComponent("slow-source.bin")
        try payload.write(to: localSource)
        let remotePath = "/cancel-\(kind.rawValue)-\(UUID().uuidString).bin"

        let uploadTask = Task {
            try await remote.upload(localSource, to: remotePath, overwrite: true)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        uploadTask.cancel()
        do {
            try await uploadTask.value
            XCTFail("Cancelled upload must throw CancellationError for \(kind.rawValue)")
        } catch is CancellationError {
        }
    }

    // MARK: - FTP & SFTP Tests

    func testFTPRoundTrip() async throws {
        try await roundTrip(.ftp)
        try await verifyCancellation(.ftp)
    }

    func testSFTPRoundTrip() async throws {
        try await roundTrip(.sftp)
        try await verifyCancellation(.sftp)
    }

    func testSFTPRejectsUntrustedAndChangedHostKey() async throws {
        let untrusted = try client(.sftp, trusted: false)
        do {
            _ = try await untrusted.list("/")
            XCTFail("Untrusted host must be rejected")
        } catch TransferError.hostKeyRequired(let key, let changed) {
            XCTAssertFalse(changed)
            XCTAssertFalse(key.isEmpty)
            XCTAssertEqual(key, ProcessInfo.processInfo.environment["AT_SFTP_KEY"])
        }
        var changed = untrusted.profile
        changed.trustedHostKey = "ZmFrZQ=="
        do {
            _ = try await RemoteClient(profile: changed, credentials: untrusted.credentials).list("/")
            XCTFail("Changed host must be rejected")
        } catch TransferError.hostKeyRequired(_, let changed) {
            XCTAssertTrue(changed)
        }
    }

    func testSFTPSymlinkAndChmod() async throws {
        let remote = try client(.sftp)
        let folder = try makeTempDir("aether-sftp-symlink")
        defer { try? FileManager.default.removeItem(at: folder) }

        let localFile = folder.appendingPathComponent("target.txt")
        try Data("symlink target body".utf8).write(to: localFile)

        let dir = "/sftp-sym-\(UUID().uuidString)"
        try await remote.mkdir(dir)
        let targetPath = try RemotePath.join(dir, "target.txt")
        let linkPath = try RemotePath.join(dir, "alias.txt")
        try await remote.upload(localFile, to: targetPath)
        try await remote.chmod(targetPath, permissions: POSIXPermissions(fromOctalString: "0640")!)
        try await remote.createSymlink(target: targetPath, at: linkPath)

        let listing = try await remote.list(dir)
        let targetEntry = try XCTUnwrap(listing.first(where: { $0.name == "target.txt" }))
        XCTAssertTrue(targetEntry.permissions.hasPrefix("-rw-r-----"), "Unexpected permissions: \(targetEntry.permissions)")
        let linkEntry = try XCTUnwrap(listing.first(where: { $0.name == "alias.txt" }))
        XCTAssertTrue(linkEntry.isSymbolicLink, "Symlink entry must report isSymbolicLink=true (mode: \(linkEntry.permissions))")

        // Removing the symlink must preserve the target file
        try await remote.remove(linkPath, directory: false)
        let remaining = try await remote.list(dir)
        XCTAssertEqual(remaining.map(\.name), ["target.txt"])

        try await remote.remove(targetPath, directory: false)
        try await remote.remove(dir, directory: true)
    }

    func testFailedDownloadPreservesExistingDestination() async throws {
        let remote = try client(.ftp)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let data = Data("keep this".utf8)
        try data.write(to: destination)
        do {
            try await remote.download("/missing-\(UUID().uuidString)", to: destination, overwrite: true)
            XCTFail("Missing download must fail")
        } catch {
            XCTAssertEqual(try Data(contentsOf: destination), data)
        }
    }

    func testRecursiveUploadAndDownloadSFTP() async throws {
        let remote = try client(.sftp)
        let localDir = try makeTempDir("aether-rec-src")
        let downloadDir = try makeTempDir("aether-rec-dst")
        defer {
            try? FileManager.default.removeItem(at: localDir)
            try? FileManager.default.removeItem(at: downloadDir)
        }
        try FileManager.default.createDirectory(at: localDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello from recursive".write(to: localDir.appendingPathComponent("sub/hello.txt"), atomically: true, encoding: .utf8)
        try "root data".write(to: localDir.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)

        let remoteBase = "/rec-\(UUID().uuidString)"
        try await remote.mkdir(remoteBase)

        let items = try LocalFiles.walk(localDir)
        for item in items {
            let targetRemotePath = RemotePath.normalize(remoteBase + "/" + item.relativePath)
            if item.isDirectory {
                try await remote.mkdirRecursive(targetRemotePath)
            } else {
                let parent = RemotePath.parent(targetRemotePath)
                try await remote.mkdirRecursive(parent)
                try await remote.upload(item.fileURL, to: targetRemotePath, overwrite: true)
            }
        }

        let remoteFiles = try await remote.listRecursive(remoteBase)
        let remoteNames = remoteFiles.map(\.name)
        XCTAssertTrue(remoteNames.contains("sub"))
        XCTAssertTrue(remoteNames.contains("hello.txt"))
        XCTAssertTrue(remoteNames.contains("root.txt"))

        for entry in remoteFiles {
            guard entry.path != remoteBase else { continue }
            var rel = String(entry.path.dropFirst(remoteBase.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            guard !rel.isEmpty else { continue }
            let localTarget = downloadDir.appendingPathComponent(rel)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: localTarget, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: localTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await remote.download(entry.path, to: localTarget, overwrite: true)
            }
        }

        XCTAssertEqual(try String(contentsOf: downloadDir.appendingPathComponent("sub/hello.txt"), encoding: .utf8), "hello from recursive")
        XCTAssertEqual(try String(contentsOf: downloadDir.appendingPathComponent("root.txt"), encoding: .utf8), "root data")

        try await remote.remove(RemotePath.normalize(remoteBase + "/sub/hello.txt"), directory: false)
        try await remote.remove(RemotePath.normalize(remoteBase + "/sub"), directory: true)
        try await remote.remove(RemotePath.normalize(remoteBase + "/root.txt"), directory: false)
        try await remote.remove(remoteBase, directory: true)
    }

    func testResumableDownloadFTPAndSFTP() async throws {
        for kind in [TransferProtocol.ftp, TransferProtocol.sftp] {
            let remote = try client(kind)
            let folder = try makeTempDir("aether-resume-dl")
            defer { try? FileManager.default.removeItem(at: folder) }

            let data = makeDeterministicData(size: 256 * 1024, seed: 1)
            let localSource = folder.appendingPathComponent("source.bin")
            try data.write(to: localSource)

            let remotePath = "/resumable-dl-\(kind.rawValue)-\(UUID().uuidString).bin"
            try await remote.upload(localSource, to: remotePath)

            let destination = folder.appendingPathComponent("downloaded.bin")
            let store = ResumeTransferStore(directory: folder.appendingPathComponent("journal"))
            let task = try ResumableTransfer(
                direction: .download,
                local: destination,
                remote: remotePath,
                profile: remote.profile,
                overwrite: true,
                store: store
            )
            try data.prefix(64 * 1024).write(to: task.stagingLocalURL)
            try await task.run(client: remote)

            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try Data(contentsOf: destination), data)
            let remaining = try await store.records()
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingLocalURL.path))

            let task2 = try ResumableTransfer(
                direction: .download,
                local: destination,
                remote: remotePath,
                profile: remote.profile,
                overwrite: true,
                store: store
            )
            var staleRecord = task2.checkpoint()
            staleRecord.expectedSize = Int64(data.count)
            staleRecord.sourceRemote = RemoteFileVersion(size: Int64(data.count), modified: 12345)
            try await store.save(staleRecord)

            let differentData = Data("tampered remote data".utf8)
            let tempSource = folder.appendingPathComponent("different.bin")
            try differentData.write(to: tempSource)
            try await remote.upload(tempSource, to: remotePath, overwrite: true)

            let restoringTask = ResumableTransfer(restoring: staleRecord, store: store)
            do {
                try await restoringTask.run(client: remote)
                XCTFail("Resuming against changed remote source must fail with sourceChanged")
            } catch ResumeTransferError.sourceChanged {
            }

            try await remote.remove(remotePath, directory: false)
        }
    }

    func testResumableUploadFTPAndSFTP() async throws {
        for kind in [TransferProtocol.ftp, TransferProtocol.sftp] {
            let remote = try client(kind)
            let folder = try makeTempDir("aether-resume-up")
            defer { try? FileManager.default.removeItem(at: folder) }

            let data = makeDeterministicData(size: 256 * 1024, seed: 5)
            let localSource = folder.appendingPathComponent("source-upload.bin")
            try data.write(to: localSource)

            let remoteDestination = "/resumable-up-\(kind.rawValue)-\(UUID().uuidString).bin"
            let store = ResumeTransferStore(directory: folder.appendingPathComponent("journal"))
            let task = try ResumableTransfer(
                direction: .upload,
                local: localSource,
                remote: remoteDestination,
                profile: remote.profile,
                overwrite: true,
                store: store
            )

            let partialFile = folder.appendingPathComponent("partial-slice.bin")
            try data.prefix(64 * 1024).write(to: partialFile)
            try await remote.upload(partialFile, to: task.stagingRemotePath)
            try await task.run(client: remote)

            let proof = folder.appendingPathComponent("proof.bin")
            try await remote.download(remoteDestination, to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), data)

            try await remote.remove(remoteDestination, directory: false)
        }
    }

    func testResumableTransfersIntoChosenSubdirectory() async throws {
        for kind in [TransferProtocol.ftp, .sftp] {
            let remote = try client(kind)
            let folder = try makeTempDir("aethertransfer-sub")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("drop target"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("拖放 源.bin")
            let data = makeDeterministicData(size: 256 * 1024, seed: 7)
            try data.write(to: source)

            let root = "/\(kind.rawValue)-drop-\(UUID().uuidString)"
            let sub = try RemotePath.join(root, "目标 文件夹")
            try await remote.mkdirRecursive(sub)
            let target = try RemotePath.join(sub, source.lastPathComponent)
            try await ResumableTransfer(direction: .upload, local: source, remote: target, profile: remote.profile, overwrite: false)
                .run(client: remote) { _ in }
            let existing = try await remote.list(sub).map(\.name)
            XCTAssertEqual(existing, [source.lastPathComponent])
            let rootListing = try await remote.list(root)
            XCTAssertTrue(rootListing.allSatisfy { $0.isDirectory })
            XCTAssertEqual(RemotePath.uniqueName(for: source.lastPathComponent, existingNames: existing), "拖放 源 (1).bin")

            let destination = folder.appendingPathComponent("drop target").appendingPathComponent(source.lastPathComponent)
            try await ResumableTransfer(direction: .download, local: destination, remote: target, profile: remote.profile, overwrite: false)
                .run(client: remote) { _ in }
            XCTAssertEqual(try Data(contentsOf: destination), data)

            try await remote.remove(target, directory: false)
            try await remote.remove(sub, directory: true)
            try await remote.remove(root, directory: true)
        }
    }

    // MARK: - FTPS Implicit & FTPS Explicit (AUTH TLS)

    private func verifyFTPSCTransferLifecycle(scheme: String, port: Int, explicit: Bool, caPath: String) async throws {
        let dir = try makeTempDir("aether-ftps-exp-\(scheme)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = makeDeterministicData(size: 192 * 1024 + 77, seed: 11)
        let source = dir.appendingPathComponent("source.bin")
        try bytes.write(to: source)
        let downloaded = dir.appendingPathComponent("downloaded.bin")
        let resumed = dir.appendingPathComponent("resumed.bin")
        let folderName = "ftps-\(UUID().uuidString) 空格"
        let folderPath = "/\(folderName)"
        let filePath = "\(folderPath)/中文 # 文件.bin"
        let renamedPath = "\(folderPath)/renamed.bin"

        try await Task.detached {
            func makeHandle(_ targetURL: String, trusted: Bool) throws -> OpaquePointer {
                let ptr = try XCTUnwrap(at_create(targetURL, "fixture", "fixture-only", "", "", ""))
                if explicit {
                    XCTAssertEqual(at_set_ftps_explicit(ptr, 1), 0)
                }
                if trusted {
                    XCTAssertEqual(at_set_ca_bundle(ptr, caPath), 0)
                }
                return ptr
            }

            // 1. Untrusted CA must be rejected with code 60
            let untrusted = try makeHandle("\(scheme)://127.0.0.1:\(port)//", trusted: false)
            defer { at_destroy(untrusted) }
            XCTAssertEqual(at_perform(untrusted, 0, "", "", nil, nil), 60)

            // 2. Trusted CA: list root
            let listRoot = try makeHandle("\(scheme)://127.0.0.1:\(port)//", trusted: true)
            defer { at_destroy(listRoot) }
            XCTAssertEqual(at_perform(listRoot, 0, "", "", nil, nil), 0, String(cString: at_error(listRoot)))
            let rootEntries = try DirectoryListing.parse(String(cString: at_result(listRoot)), parent: "/")
            XCTAssertTrue(rootEntries.contains(where: { $0.name == "中文 seed.txt" }))

            // 3. MKD + upload >128 KiB + list subfolder
            let mkd = try makeHandle("\(scheme)://127.0.0.1:\(port)//", trusted: true)
            defer { at_destroy(mkd) }
            XCTAssertEqual(at_perform(mkd, 3, "", "MKD \(folderPath)", nil, nil), 0, String(cString: at_error(mkd)))

            let encodedFile = try XCTUnwrap("\(scheme)://127.0.0.1:\(port)//\(folderName)/中文%20%23%20文件.bin"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
            let uploadURL = try ServerProfile(host: "127.0.0.1", port: port, username: "fixture", protocolKind: explicit ? .ftpsExplicit : .ftps)
                .url(path: filePath, directory: false)
            _ = encodedFile
            let up = try makeHandle(uploadURL, trusted: true)
            defer { at_destroy(up) }
            XCTAssertEqual(at_perform(up, 2, source.path, "", nil, nil), 0, String(cString: at_error(up)))

            let listSubURL = try ServerProfile(host: "127.0.0.1", port: port, username: "fixture", protocolKind: explicit ? .ftpsExplicit : .ftps)
                .url(path: folderPath, directory: true)
            let listSub = try makeHandle(listSubURL, trusted: true)
            defer { at_destroy(listSub) }
            XCTAssertEqual(at_perform(listSub, 0, "", "", nil, nil), 0, String(cString: at_error(listSub)))
            let subEntries = try DirectoryListing.parse(String(cString: at_result(listSub)), parent: folderPath)
            XCTAssertEqual(subEntries.map(\.name), ["中文 # 文件.bin"])
            XCTAssertEqual(subEntries.first?.size, Int64(bytes.count))

            // 4. Download full file & verify parity
            let dl = try makeHandle(uploadURL, trusted: true)
            defer { at_destroy(dl) }
            XCTAssertEqual(at_perform(dl, 1, downloaded.path, "", nil, nil), 0, String(cString: at_error(dl)))
            XCTAssertEqual(try Data(contentsOf: downloaded), bytes)

            // 5. Resume download from 64 KiB offset
            try bytes.prefix(64 * 1024).write(to: resumed)
            let resumeHandle = try makeHandle(uploadURL, trusted: true)
            defer { at_destroy(resumeHandle) }
            XCTAssertEqual(at_transfer_window(resumeHandle, 65_536, -1, Int64(bytes.count)), 0)
            XCTAssertEqual(at_perform(resumeHandle, 1, resumed.path, "", nil, nil), 0, String(cString: at_error(resumeHandle)))
            XCTAssertEqual(try Data(contentsOf: resumed), bytes)

            // 6. Rename + Remove file + RMD dir
            let cmds = try makeHandle("\(scheme)://127.0.0.1:\(port)//", trusted: true)
            defer { at_destroy(cmds) }
            XCTAssertEqual(at_perform(cmds, 3, "", "RNFR \(filePath)\nRNTO \(renamedPath)", nil, nil), 0, String(cString: at_error(cmds)))
            let cleanup = try makeHandle("\(scheme)://127.0.0.1:\(port)//", trusted: true)
            defer { at_destroy(cleanup) }
            XCTAssertEqual(at_perform(cleanup, 3, "", "DELE \(renamedPath)\nRMD \(folderPath)", nil, nil), 0, String(cString: at_error(cleanup)))
        }.value
    }

    func testFTPSImplicitAndExplicitFullLifecycle() async throws {
        let caPath = try envValue("AT_FTPS_CA")
        let implicitPort = try envPort("AT_FTPS_PORT")
        let explicitPort = try envPort("AT_FTPS_EXPLICIT_PORT")

        // Verify RemoteClient without CA bundle rejects untrusted Explicit FTPS
        let untrustedExplicit = try client(.ftpsExplicit)
        do {
            _ = try await untrustedExplicit.list("/")
            XCTFail("Untrusted Explicit FTPS must fail TLS verification")
        } catch {
        }

        try await verifyFTPSCTransferLifecycle(scheme: "ftps", port: implicitPort, explicit: false, caPath: caPath)
        try await verifyFTPSCTransferLifecycle(scheme: "ftp", port: explicitPort, explicit: true, caPath: caPath)
    }

    // MARK: - WebDAV & WebDAVS Tests

    func testHTTPSRejectsUntrustedFixtureServerWithoutDelegate() async throws {
        let port = try envPort("AT_WEBDAVS_PORT")
        let defaultSession = URLSession(configuration: .ephemeral)
        defer { defaultSession.invalidateAndCancel() }
        let remote = try client(.webdavs, httpSession: defaultSession)
        do {
            _ = try await remote.list("/")
            XCTFail("Default URLSession without fixture CA must reject self-signed TLS server")
        } catch {
        }
        _ = port
    }

    func testWebDAVAndWebDAVSRoundTripsAndMetadata() async throws {
        let session = try makeFixtureSession()
        defer { session.invalidateAndCancel() }

        for kind in [TransferProtocol.webdav, TransferProtocol.webdavs] {
            try await roundTrip(kind, httpSession: session)
            try await verifyCancellation(kind, httpSession: session)

            let remote = try client(kind, httpSession: session)
            let dir = try makeTempDir("aether-dav-meta")
            defer { try? FileManager.default.removeItem(at: dir) }

            let payload = makeDeterministicData(size: 140 * 1024, seed: 13)
            let src = dir.appendingPathComponent("meta.bin")
            try payload.write(to: src)
            let remoteDir = "/dav-meta-\(UUID().uuidString)"
            try await remote.mkdir(remoteDir)
            let remoteFile = "\(remoteDir)/spec.bin"
            try await remote.upload(src, to: remoteFile, overwrite: true)

            let meta = try await remote.statMetadata(remoteFile)
            XCTAssertEqual(meta.size, Int64(payload.count))
            XCTAssertNotNil(meta.etag)
            XCTAssertNotNil(meta.modified)

            try await remote.remove(remoteFile, directory: false)
            try await remote.remove(remoteDir, directory: true)
        }
    }

    // MARK: - Amazon S3 Tests

    func testS3RoundTripPaginationMultipartMetadataAndPresignedURL() async throws {
        let session = try makeFixtureSession()
        defer { session.invalidateAndCancel() }

        try await roundTrip(.s3, httpSession: session)
        try await verifyCancellation(.s3, httpSession: session)

        let remote = try client(.s3, httpSession: session)
        let dir = try makeTempDir("aether-s3-adv")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Pagination (>2 items in directory -> multiple ListObjectsV2 pages via NextContinuationToken)
        let folder = "/s3-page-\(UUID().uuidString)"
        try await remote.mkdir(folder)
        let subFolder = "\(folder)/子目录"
        try await remote.mkdir(subFolder)
        for idx in 1...3 {
            let f = dir.appendingPathComponent("item-\(idx).txt")
            try Data("payload-\(idx)".utf8).write(to: f)
            try await remote.upload(f, to: "\(folder)/文件 \(idx).txt", overwrite: true)
        }
        let entries = try await remote.list(folder)
        XCTAssertEqual(entries.map(\.name), ["子目录", "文件 1.txt", "文件 2.txt", "文件 3.txt"])

        // 2. Metadata read/update + presigned URL real HTTPS download
        let targetPath = "\(folder)/文件 1.txt"
        try await remote.updateMetadata(targetPath, metadata: RemoteObjectMetadata(
            contentType: "text/plain; charset=utf-8",
            cacheControl: "max-age=600",
            storageClass: "STANDARD_IA",
            acl: "private",
            customMetadata: ["owner": "qa-protocols"]
        ))
        let meta = try await remote.statMetadata(targetPath)
        XCTAssertEqual(meta.contentType, "text/plain; charset=utf-8")
        XCTAssertEqual(meta.cacheControl, "max-age=600")
        XCTAssertEqual(meta.storageClass, "STANDARD_IA")
        XCTAssertEqual(meta.customMetadata["owner"], "qa-protocols")

        let signedURL = try await remote.presignedURL(for: targetPath, expiresIn: 300)
        XCTAssertTrue(signedURL.absoluteString.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        XCTAssertTrue(signedURL.absoluteString.contains("X-Amz-Signature="))
        let (signedData, signedResp) = try await session.data(from: signedURL)
        XCTAssertEqual((signedResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(signedData, Data("payload-1".utf8))

        // 3. Real S3 Multipart Upload (>128 KiB across 3 parts over HTTPS)
        let s3Client = S3Client(
            profile: remote.profile,
            credentials: remote.credentials,
            session: session,
            multipartThreshold: 128 * 1024,
            multipartPartSize: 70 * 1024
        )
        let mpPayload = makeDeterministicData(size: 200 * 1024 + 55, seed: 21)
        let mpLocal = dir.appendingPathComponent("mp.bin")
        try mpPayload.write(to: mpLocal)
        let mpRemote = "\(folder)/multipart.bin"
        try await s3Client.upload(mpLocal, to: mpRemote, overwrite: true)

        let mpOut = dir.appendingPathComponent("mp-out.bin")
        try await s3Client.download(mpRemote, to: mpOut, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: mpOut), mpPayload)

        // Cleanup
        try await remote.remove(folder, directory: true)
        let afterDelete = try await remote.list("/")
        XCTAssertFalse(afterDelete.contains(where: { $0.path == folder }))
    }

    // MARK: - Backblaze B2 Tests

    func testB2RoundTripPaginationLargeFileMetadataAndPresignedURL() async throws {
        let session = try makeFixtureSession()
        defer { session.invalidateAndCancel() }

        try await roundTrip(.b2, httpSession: session)
        try await verifyCancellation(.b2, httpSession: session)

        let remote = try client(.b2, httpSession: session)
        let dir = try makeTempDir("aether-b2-adv")
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = "/b2-page-\(UUID().uuidString)"
        try await remote.mkdir(folder)
        for idx in 1...3 {
            let f = dir.appendingPathComponent("b2-\(idx).txt")
            try Data("b2-body-\(idx)".utf8).write(to: f)
            try await remote.upload(f, to: "\(folder)/文档 \(idx).txt", overwrite: true)
        }
        let entries = try await remote.list(folder)
        XCTAssertEqual(entries.map(\.name), ["文档 1.txt", "文档 2.txt", "文档 3.txt"])

        let target = "\(folder)/文档 1.txt"
        let meta = try await remote.statMetadata(target)
        XCTAssertEqual(meta.size, 9)
        XCTAssertNotNil(meta.etag)

        let signedURL = try await remote.presignedURL(for: target, expiresIn: 300)
        XCTAssertTrue(signedURL.absoluteString.contains("Authorization="))
        let (signedData, signedResp) = try await session.data(from: signedURL)
        XCTAssertEqual((signedResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(signedData, Data("b2-body-1".utf8))

        // B2 Large File upload across multiple SHA1-verified parts
        let b2Client = B2Client(
            profile: remote.profile,
            credentials: remote.credentials,
            session: session,
            largeFileThreshold: 128 * 1024,
            partSize: 70 * 1024
        )
        let largePayload = makeDeterministicData(size: 190 * 1024 + 19, seed: 31)
        let largeLocal = dir.appendingPathComponent("b2-large.bin")
        try largePayload.write(to: largeLocal)
        let largeRemote = "\(folder)/large.bin"
        try await b2Client.upload(largeLocal, to: largeRemote, overwrite: true)

        let largeOut = dir.appendingPathComponent("b2-large-out.bin")
        try await b2Client.download(largeRemote, to: largeOut, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: largeOut), largePayload)

        try await remote.remove(folder, directory: true)
    }

    // MARK: - Microsoft Azure Blob Tests

    func testAzureBlobRoundTripPaginationMetadataAndPresignedURL() async throws {
        let session = try makeFixtureSession()
        defer { session.invalidateAndCancel() }

        try await roundTrip(.azureBlob, httpSession: session)
        try await verifyCancellation(.azureBlob, httpSession: session)

        let remote = try client(.azureBlob, httpSession: session)
        let dir = try makeTempDir("aether-azure-adv")
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = "/az-page-\(UUID().uuidString)"
        try await remote.mkdir(folder)
        for idx in 1...3 {
            let f = dir.appendingPathComponent("az-\(idx).txt")
            try Data("azure-data-\(idx)".utf8).write(to: f)
            try await remote.upload(f, to: "\(folder)/对象 \(idx).txt", overwrite: true)
        }
        let entries = try await remote.list(folder)
        XCTAssertEqual(entries.map(\.name), ["对象 1.txt", "对象 2.txt", "对象 3.txt"])

        let target = "\(folder)/对象 2.txt"
        try await remote.updateMetadata(target, metadata: RemoteObjectMetadata(
            contentType: "text/markdown",
            cacheControl: "private, max-age=120",
            customMetadata: ["team": "storage"]
        ))
        let meta = try await remote.statMetadata(target)
        XCTAssertEqual(meta.contentType, "text/markdown")
        XCTAssertEqual(meta.cacheControl, "private, max-age=120")
        XCTAssertEqual(meta.customMetadata["team"], "storage")

        let sasURL = try await remote.presignedURL(for: target, expiresIn: 300)
        XCTAssertTrue(sasURL.absoluteString.contains("sig="))
        let (sasData, sasResp) = try await session.data(from: sasURL)
        XCTAssertEqual((sasResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(sasData, Data("azure-data-2".utf8))

        try await remote.remove(folder, directory: true)
    }

    // MARK: - OpenStack Swift Tests

    func testSwiftRoundTripAndMetadata() async throws {
        let session = try makeFixtureSession()
        defer { session.invalidateAndCancel() }

        try await roundTrip(.openstackSwift, httpSession: session)
        try await verifyCancellation(.openstackSwift, httpSession: session)

        let remote = try client(.openstackSwift, httpSession: session)
        let dir = try makeTempDir("aether-swift-adv")
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = makeDeterministicData(size: 150 * 1024 + 9, seed: 41)
        let local = dir.appendingPathComponent("swift-meta.bin")
        try payload.write(to: local)
        let remotePath = "/swift-meta-\(UUID().uuidString)/报告.bin"
        try await remote.mkdir(RemotePath.parent(remotePath))
        try await remote.upload(local, to: remotePath, overwrite: true)

        try await remote.updateMetadata(remotePath, metadata: RemoteObjectMetadata(
            contentType: "application/x-report",
            customMetadata: ["release": "v0.2"]
        ))
        let meta = try await remote.statMetadata(remotePath)
        XCTAssertEqual(meta.contentType, "application/x-report")
        XCTAssertEqual(meta.customMetadata["release"], "v0.2")
        XCTAssertEqual(meta.size, Int64(payload.count))

        try await remote.remove(RemotePath.parent(remotePath), directory: true)
    }
}
