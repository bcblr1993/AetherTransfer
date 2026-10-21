import Foundation
import XCTest
@testable import AetherTransferCore

@MainActor final class ProtocolIntegrationTests: XCTestCase {
    func client(_ kind: TransferProtocol, trusted: Bool = true) throws -> RemoteClient {
        let env = ProcessInfo.processInfo.environment
        guard let port = env[kind == .ftp ? "AT_FTP_PORT" : "AT_SFTP_PORT"], let number = Int(port) else {
            throw XCTSkip("Run scripts/test_protocols.sh for isolated real FTP/SFTP servers")
        }
        return RemoteClient(profile: ServerProfile(host: "127.0.0.1", port: number, username: "fixture", protocolKind: kind,
                                                  trustedHostKey: trusted && kind == .sftp ? env["AT_SFTP_KEY"] : nil),
                            credentials: Credentials(password: "fixture-only"))
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
        let renamed = try RemotePath.join(path, "renamed.txt")
        try await remote.rename(target, to: renamed)
        try await remote.remove(renamed, directory: false)
        let empty = try await remote.list(path)
        XCTAssertTrue(empty.isEmpty)
        try await remote.remove(path, directory: true)
    }
    func testFTPRoundTrip() async throws { try await roundTrip(.ftp) }
    func testSFTPRoundTrip() async throws { try await roundTrip(.sftp) }
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
    func testRecursiveUploadAndDownloadSFTP() async throws {
        let remote = try client(.sftp)
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-rec-src-\(UUID().uuidString)")
        let downloadDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-rec-dst-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: localDir)
            try? FileManager.default.removeItem(at: downloadDir)
        }
        try FileManager.default.createDirectory(at: localDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello from recursive".write(to: localDir.appendingPathComponent("sub/hello.txt"), atomically: true, encoding: .utf8)
        try "root data".write(to: localDir.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)

        let remoteBase = "/rec-\(UUID().uuidString)"
        try await remote.mkdir(remoteBase)

        // Upload directory
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

        // Verify remote tree
        let remoteFiles = try await remote.listRecursive(remoteBase)
        let remoteNames = remoteFiles.map(\.name)
        XCTAssertTrue(remoteNames.contains("sub"))
        XCTAssertTrue(remoteNames.contains("hello.txt"))
        XCTAssertTrue(remoteNames.contains("root.txt"))

        // Download directory
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
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

        // Cleanup remote
        try await remote.remove(RemotePath.normalize(remoteBase + "/sub/hello.txt"), directory: false)
        try await remote.remove(RemotePath.normalize(remoteBase + "/sub"), directory: true)
        try await remote.remove(RemotePath.normalize(remoteBase + "/root.txt"), directory: false)
        try await remote.remove(remoteBase, directory: true)
    }

    func testResumableDownloadFTPAndSFTP() async throws {
        for kind in [TransferProtocol.ftp, TransferProtocol.sftp] {
            let remote = try client(kind)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aether-resume-dl-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            var data = Data(count: 256 * 1024)
            for i in 0..<data.count { data[i] = UInt8((i * 17 + i / 251) % 256) }

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

            // Simulate partial download: write first 64 KiB to staging
            let partialData = data.prefix(64 * 1024)
            try partialData.write(to: task.stagingLocalURL)

            // Run resume
            try await task.run(client: remote)

            // Verify final destination matches full data
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try Data(contentsOf: destination), data)

            // Verify journal cleared
            let remaining = try await store.records()
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: task.stagingLocalURL.path))

            // Safety check: if remote source file changes, resume must reject
            let task2 = try ResumableTransfer(
                direction: .download,
                local: destination,
                remote: remotePath,
                profile: remote.profile,
                overwrite: true,
                store: store
            )
            // Save initial checkpoint
            var staleRecord = task2.checkpoint()
            staleRecord.expectedSize = Int64(data.count)
            staleRecord.sourceRemote = RemoteFileVersion(size: Int64(data.count), modified: 12345)
            try await store.save(staleRecord)

            // Overwrite remote with different file
            let differentData = Data("tampered remote data".utf8)
            let tempSource = folder.appendingPathComponent("different.bin")
            try differentData.write(to: tempSource)
            try await remote.upload(tempSource, to: remotePath, overwrite: true)

            let restoringTask = ResumableTransfer(restoring: staleRecord, store: store)
            do {
                try await restoringTask.run(client: remote)
                XCTFail("Resuming against changed remote source must fail with sourceChanged")
            } catch ResumeTransferError.sourceChanged {
                // Expected safety protection!
            }

            // Cleanup remote
            try await remote.remove(remotePath, directory: false)
        }
    }

    func testResumableUploadFTPAndSFTP() async throws {
        for kind in [TransferProtocol.ftp, TransferProtocol.sftp] {
            let remote = try client(kind)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aether-resume-up-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            var data = Data(count: 256 * 1024)
            for i in 0..<data.count { data[i] = UInt8((i * 31 + i / 127) % 256) }

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

            // Simulate partial remote file: upload first 64 KiB to staging remote path
            let partialFile = folder.appendingPathComponent("partial-slice.bin")
            try data.prefix(64 * 1024).write(to: partialFile)
            try await remote.upload(partialFile, to: task.stagingRemotePath)

            // Run resume upload
            try await task.run(client: remote)

            // Download back from remote destination to verify full match
            let proof = folder.appendingPathComponent("proof.bin")
            try await remote.download(remoteDestination, to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), data)

            // Clean up remote
            try await remote.remove(remoteDestination, directory: false)
        }
    }
}
