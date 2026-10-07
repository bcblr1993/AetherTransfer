import Foundation
import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    private func resumePayload(multiplier: Int, period: Int) -> Data {
        var data = Data(count: 256 * 1024)
        for index in 0..<data.count { data[index] = UInt8((index * multiplier + index / period) % 256) }
        return data
    }
    private func resumeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-resume-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    private func suspend(_ transfer: ResumableTransfer, remote: RemoteClient) async throws -> ResumeTransferRecord {
        let control = TransferControl()
        let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, control: control, rateLimit: 64 * 1024,
                                certificateAuthority: remote.certificateAuthority)
        do {
            try await transfer.run(client: slow) { progress in
                if progress.phase == nil && progress.completed >= 16 * 1024 && progress.completed < progress.total { control.retainProgress() }
            }
            XCTFail("Must retain a partially transferred file")
        } catch ResumeTransferError.suspended { }
        let record = await transfer.checkpoint()
        XCTAssertGreaterThan(record.retainedBytes, 0); XCTAssertLessThan(record.retainedBytes, record.expectedSize)
        return record
    }
    func testPersistentDownloadResumeForEveryProtocol() async throws {
        for kind in TransferProtocol.allCases {
            let remote = try client(kind), root = try resumeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let data = resumePayload(multiplier: 17, period: 251)
            let local = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            let path = "/续传 \(UUID().uuidString) #.bin", store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
            try data.write(to: local); try Data("old target".utf8).write(to: target); try await remote.upload(local, to: path)
            let task = try ResumableTransfer(direction: .download, local: target, remote: path, profile: remote.profile, overwrite: true, store: store)
            let retained = try await suspend(task, remote: remote)
            XCTAssertEqual(try Data(contentsOf: target), Data("old target".utf8))
            let persisted = try await store.records(); XCTAssertEqual(persisted.map(\.id), [retained.id])
            let restored = try ResumableTransfer(restoring: persisted[0], store: store)
            try await restored.run(client: remote)
            XCTAssertEqual(try Data(contentsOf: target), data)
            let remaining = try await store.records(); XCTAssertTrue(remaining.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent(".aethertransfer-resume-\(retained.id.uuidString)").path))
            try await remote.remove(path, directory: false)
        }
    }
    func testPersistentUploadResumeForFTPAndSFTPAndTLS() async throws {
        for kind in [TransferProtocol.ftp, .sftp, .ftpes, .ftps] {
            let remote = try client(kind), root = try resumeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let data = resumePayload(multiplier: 31, period: 127)
            let local = root.appendingPathComponent("source"), proof = root.appendingPathComponent("proof")
            let path = "/resume-upload-\(UUID().uuidString)", store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
            try Data("old remote".utf8).write(to: local); try await remote.upload(local, to: path)
            try data.write(to: local)
            let task = try ResumableTransfer(direction: .upload, local: local, remote: path, profile: remote.profile, overwrite: true, store: store)
            let retained = try await suspend(task, remote: remote)
            try await remote.download(path, to: proof)
            XCTAssertEqual(try Data(contentsOf: proof), Data("old remote".utf8))
            let records = try await store.records(), restored = try ResumableTransfer(restoring: records[0], store: store)
            try await restored.run(client: remote)
            try await remote.download(path, to: proof, overwrite: true); XCTAssertEqual(try Data(contentsOf: proof), data)
            let listing = try await remote.list("/")
            XCTAssertFalse(listing.contains { $0.name.contains(retained.id.uuidString) })
            let remaining = try await store.records(); XCTAssertTrue(remaining.isEmpty)
            try await remote.remove(path, directory: false)
        }
    }
    func testDownloadRefusesChangedSourceAndUploadRefusesSameSizeLocalChange() async throws {
        let remote = try client(.sftp), root = try resumeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 65, count: 256 * 1024), local = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let path = "/changed-resume-\(UUID().uuidString)", store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
        try data.write(to: local); try await remote.upload(local, to: path)
        let download = try ResumableTransfer(direction: .download, local: target, remote: path, profile: remote.profile, store: store)
        _ = try await suspend(download, remote: remote)
        try Data(repeating: 66, count: data.count).write(to: local); try await remote.upload(local, to: path, overwrite: true)
        do { try await download.run(client: remote); XCTFail("Changed remote prefix must reject") }
        catch ResumeTransferError.sourceChanged { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)); try await download.discard(client: remote)
        let upload = try ResumableTransfer(direction: .upload, local: local, remote: path, profile: remote.profile, overwrite: true, store: store)
        _ = try await suspend(upload, remote: remote)
        let date = try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try Data(repeating: 67, count: data.count).write(to: local)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: local.path)
        do { try await upload.run(client: remote); XCTFail("Same-size local change must reject") }
        catch ResumeTransferError.sourceChanged { }
        try await upload.discard(client: remote); try await remote.remove(path, directory: false)
    }
    func testCancelRemovesPartialAndRecoveryManifest() async throws {
        let remote = try client(.ftp), root = try resumeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target"), data = Data(repeating: 71, count: 256 * 1024)
        let path = "/cancel-resume-\(UUID().uuidString)", store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
        try data.write(to: source); try await remote.upload(source, to: path)
        let control = TransferControl(), slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, control: control, rateLimit: 64 * 1024)
        let task = try ResumableTransfer(direction: .download, local: target, remote: path, profile: remote.profile, store: store)
        let operation = Task { try await task.run(client: slow) }
        for _ in 0..<50 {
            if !(try await store.records()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(150)); operation.cancel()
        do { try await operation.value; XCTFail("Cancellation must fail") }
        catch is CancellationError { }
        let records = try await store.records(); XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)); try await remote.remove(path, directory: false)
    }
    func testWebDAVUploadRequiresExplicitRestart() async throws {
        for kind in [TransferProtocol.webdav, .webdavs] {
            let remote = try client(kind), root = try resumeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let local = root.appendingPathComponent("source"), proof = root.appendingPathComponent("proof")
            let payload = resumePayload(multiplier: 13, period: 97), path = "/restart-\(UUID().uuidString)"
            let store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
            try Data("original".utf8).write(to: local); try await remote.upload(local, to: path)
            try payload.write(to: local)
            let task = try ResumableTransfer(direction: .upload, local: local, remote: path, profile: remote.profile, overwrite: true, store: store)
            let control = TransferControl()
            let slow = RemoteClient(profile: remote.profile, credentials: remote.credentials, control: control, rateLimit: 64 * 1024,
                                    certificateAuthority: remote.certificateAuthority)
            do {
                try await task.run(client: slow) { p in
                    if p.completed >= 16 * 1024 && p.completed < p.total { control.retainProgress() }
                }
                XCTFail("Expected retained checkpoint")
            } catch ResumeTransferError.suspended { }
            let record = await task.checkpoint()
            // Some DAV servers discard an aborted PUT. Simulate a server retaining a partial resource.
            let partial = root.appendingPathComponent("partial"); try payload.prefix(32 * 1024).write(to: partial)
            let staging = "/.aethertransfer-resume-\(record.id.uuidString).part"
            try await remote.upload(partial, to: staging, overwrite: true)
            do { try await task.run(client: remote); XCTFail("PUT must not silently append or restart") }
            catch ResumeTransferError.uploadRestartRequired { }
            try await remote.download(path, to: proof); XCTAssertEqual(try Data(contentsOf: proof), Data("original".utf8))
            let records = try await store.records()
            let restored = try ResumableTransfer(restoring: records[0], store: store)
            try await restored.run(client: remote, restartWebDAVUpload: true)
            try await remote.download(path, to: proof, overwrite: true); XCTAssertEqual(try Data(contentsOf: proof), payload)
            let remaining = try await store.records(); XCTAssertTrue(remaining.isEmpty)
            try await remote.remove(path, directory: false)
        }
    }
    func testHTTPIgnoredAndMalformedRangesPreservePartial() async throws {
        for prefix in ["/__aether_fixture_range_ignore__", "/__aether_fixture_range_bad__"] {
            let remote = try client(.webdavs), root = try resumeFolder()
            defer { try? FileManager.default.removeItem(at: root) }
            let local = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
            let payload = resumePayload(multiplier: 43, period: 193), path = prefix + UUID().uuidString
            let store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
            try payload.write(to: local); try await remote.upload(local, to: path)
            let task = try ResumableTransfer(direction: .download, local: target, remote: path, profile: remote.profile, store: store)
            let record = try await suspend(task, remote: remote)
            let partial = root.appendingPathComponent(".aethertransfer-resume-\(record.id.uuidString)/partial")
            let before = try Data(contentsOf: partial)
            do { try await task.run(client: remote); XCTFail("Invalid Range response must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("range"), error.localizedDescription) }
            XCTAssertEqual(try Data(contentsOf: partial), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            try await task.discard(); try await remote.remove(path, directory: false)
        }
    }
    func testChangedDestinationAndStaleRestorationRefuseOverwrite() async throws {
        let remote = try client(.sftp), root = try resumeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let payload = resumePayload(multiplier: 29, period: 101), path = "/destination-\(UUID().uuidString)"
        let store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
        try payload.write(to: local); try Data("original".utf8).write(to: target); try await remote.upload(local, to: path)
        let task = try ResumableTransfer(direction: .download, local: target, remote: path, profile: remote.profile, overwrite: true, store: store)
        let record = try await suspend(task, remote: remote)
        let stale = try ResumableTransfer(restoring: record, store: store)
        try Data("user changed destination".utf8).write(to: target)
        do { try await task.run(client: remote); XCTFail("Changed destination must survive") }
        catch ResumeTransferError.targetChanged { }
        XCTAssertEqual(try Data(contentsOf: target), Data("user changed destination".utf8))
        try await task.discard()
        do { try await stale.run(client: remote); XCTFail("Discarded checkpoint must never run again") }
        catch ResumeTransferError.invalidCheckpoint { }
        try await remote.remove(path, directory: false)
    }
    func testRecoveryAcceptsVerifiedBytesBeyondLastCheckpoint() async throws {
        let remote = try client(.sftp), root = try resumeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let data = resumePayload(multiplier: 19, period: 109), path = "/checkpoint-lag-\(UUID().uuidString)"
        let store = ResumeTransferStore(directory: root.appendingPathComponent("journal"))
        try data.write(to: source); try await remote.upload(source, to: path)
        let task = try ResumableTransfer(direction: .download, local: target, remote: path, profile: remote.profile, store: store)
        let record = try await suspend(task, remote: remote)
        let partial = root.appendingPathComponent(".aethertransfer-resume-\(record.id.uuidString)/partial")
        // A process can stop after appending bytes but before updating the journal.
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd(); try handle.write(contentsOf: data[Int(record.retainedBytes)..<Int(record.retainedBytes + 4096)]); try handle.close()
        let restored = try ResumableTransfer(restoring: record, store: store)
        try await restored.run(client: remote)
        XCTAssertEqual(try Data(contentsOf: target), data)
        let remaining = try await store.records(); XCTAssertTrue(remaining.isEmpty)
        try await remote.remove(path, directory: false)
    }
}
