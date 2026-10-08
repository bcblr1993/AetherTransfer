import Foundation
import CryptoKit
import XCTest
import Darwin
@testable import AetherTransferCore

private final class S3ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: Int64 = 0
    private var announced = false
    let started: XCTestExpectation
    init(_ started: XCTestExpectation) { self.started = started }
    func record(_ value: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        completed = value.completed
        if completed > 0 && !announced { announced = true; started.fulfill() }
    }
    func value() -> Int64 { lock.lock(); defer { lock.unlock() }; return completed }
}

private final class S3TreeProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: TransferProgress?
    func record(_ value: TransferProgress) { lock.lock(); defer { lock.unlock() }; latest = value }
    func value() -> TransferProgress? { lock.lock(); defer { lock.unlock() }; return latest }
}

@MainActor final class S3ProtocolTests: XCTestCase {
    private func client(control: TransferControl? = nil, rate: Int64 = 0) throws -> S3Client {
        let env = ProcessInfo.processInfo.environment
        guard let number = Int(env["AT_S3_PORT"] ?? ""), let access = env["AT_S3_ACCESS_KEY"], let secret = env["AT_S3_SECRET_KEY"],
              let bucket = env["AT_S3_BUCKET"], let ca = env["AT_S3_CA"] else {
            throw XCTSkip("Run scripts/test_s3.sh for a real isolated HTTPS S3 server")
        }
        return S3Client(endpoint: S3Endpoint(host: "127.0.0.1", port: number, bucket: bucket),
                        credentials: S3Credentials(accessKey: access, secretKey: secret), control: control, rateLimit: rate,
                        certificateAuthority: URL(fileURLWithPath: ca))
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-s3-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testListUsesRealPaginationAndEncodedPrefixes() async throws {
        let remote = try client()
        let objects = try await remote.list(prefix: "pages/")
        XCTAssertEqual(objects.count, 1005); XCTAssertEqual(Set(objects.map(\.key)).count, 1005)
        XCTAssertEqual(objects.first?.name, "item-0000.txt"); XCTAssertEqual(objects.last?.name, "item-1004.txt")
        let root = try await remote.list()
        XCTAssertTrue(root.contains { $0.key == "same" && !$0.isPrefix })
        XCTAssertTrue(root.contains { $0.key == "keys/" && $0.isPrefix })
        let keys = try await remote.list(prefix: "keys/")
        XCTAssertEqual(keys.map(\.key), ["keys/中文 空格+#%?.txt"])
        let missing = try await remote.list(prefix: "missing-prefix/"); XCTAssertTrue(missing.isEmpty)
    }
    func testEncodedObjectRoundTripAndGuardedOverwrite() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), download = local.appendingPathComponent("download")
        let prefix = "roundtrip-\(UUID())/", target = prefix + "中文 空格+#%?.txt"
        let original = Data("原始数据 +#%".utf8); try original.write(to: source)
        try await remote.upload(source, to: target)
        let listed = try await remote.list(prefix: prefix), selected = try XCTUnwrap(listed.first)
        XCTAssertEqual(listed.count, 1); XCTAssertEqual(Data(selected.key.utf8), Data(target.utf8))
        try await remote.download(selected.key, to: download)
        XCTAssertEqual(try Data(contentsOf: download), original)
        do { try await remote.upload(source, to: target); XCTFail("Existing object must reject") }
        catch TransferError.conflict { }
        let replacement = Data("updated".utf8); try replacement.write(to: source)
        try await remote.upload(source, to: target, overwrite: true)
        try await remote.download(target, to: download, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: download), replacement)
        try await remote.remove(target)
        do { _ = try await remote.fileVersion(target); XCTFail("Deleted object cannot exist") }
        catch S3Error.notFound { }
    }
    func testMultipartSlicesPreserveDifferentPartBytesAndLeaveNoUploads() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), download = local.appendingPathComponent("download")
        let data = Data(repeating: 0x17, count: 8 * 1024 * 1024) + Data(repeating: 0x95, count: 700 * 1024 + 17)
        try data.write(to: source); let target = "multipart-\(UUID())"
        try await remote.upload(source, to: target)
        let version = try await remote.fileVersion(target)
        XCTAssertEqual(version.size, Int64(data.count)); XCTAssertTrue(version.etag?.hasSuffix("-2\"") == true)
        try await remote.download(target, to: download)
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: download))), Data(SHA256.hash(data: data)))
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        try await remote.remove(target)
    }
    func testEmptyObjectHasVerifiableDigestAndDownloadsAtomically() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), download = local.appendingPathComponent("download")
        try Data().write(to: source); let target = "empty-\(UUID())"
        try await remote.upload(source, to: target)
        let version = try await remote.fileVersion(target), digest = try await remote.contentDigest(target, version: version)
        XCTAssertEqual(version.size, 0); XCTAssertEqual(digest, Data(SHA256.hash(data: Data())))
        try await remote.download(target, to: download); XCTAssertEqual(try Data(contentsOf: download).count, 0)
        try await remote.remove(target)
    }
    func testBrowserFilePoliciesAndEmptyPrefixMarkers() async throws {
        let remote = try client(), local = try folder(), prefix = "browser-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        try await remote.createPrefix(prefix)
        let root = try await remote.list(); XCTAssertTrue(root.contains { $0.key == prefix && $0.isPrefix })
        let empty = try await remote.list(prefix: prefix); XCTAssertTrue(empty.isEmpty)
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("file.txt")
        let bytes = Data("browser verified content".utf8); try bytes.write(to: source)
        let key = prefix + "file.txt"
        try await remote.uploadFile(source, to: key, policy: .reject)
        try await remote.uploadFile(source, to: key, policy: .keepBoth)
        try Data("must skip".utf8).write(to: source)
        try await remote.uploadFile(source, to: key, policy: .skip)
        let listed = try await remote.list(prefix: prefix)
        XCTAssertEqual(Set(listed.map(\.name)), ["file.txt", "file 2.txt"])
        let selected = try XCTUnwrap(listed.first { $0.key == key }).fileEntry
        try await remote.downloadFile(selected, to: destination, policy: .reject)
        try await remote.downloadFile(selected, to: destination, policy: .keepBoth)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("file 2.txt")), bytes)
        try await remote.downloadFile(selected, to: destination, policy: .skip)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        do { try await remote.createPrefix(prefix); XCTFail("Existing marker must reject") } catch TransferError.conflict { }
        let wrong = S3MultipartCleanup(endpoint: S3Endpoint(host: "different.example", bucket: remote.endpoint.bucket), key: key, uploadID: "test-owned-id")
        do { try await remote.abort(wrong); XCTFail("Cleanup requires matching endpoint") } catch S3Error.invalidMultipart { }
        for object in listed { try await remote.remove(object.key) }
        try await remote.remove(prefix)
    }
    func testAuthenticationCertificateTrustAndHostnameMustVerify() async throws {
        let remote = try client()
        let wrong = S3Client(endpoint: remote.endpoint, credentials: S3Credentials(accessKey: remote.credentials.accessKey, secretKey: "incorrect"),
                             certificateAuthority: remote.certificateAuthority)
        do { _ = try await wrong.list(); XCTFail("Incorrect SigV4 secret must fail") }
        catch S3Error.authentication { }
        let untrusted = S3Client(endpoint: remote.endpoint, credentials: remote.credentials)
        do { _ = try await untrusted.list(); XCTFail("Untrusted certificate must fail") }
        catch TransferError.remote { }
        var wrongHost = remote.endpoint; wrongHost.host = "localhost"
        do { _ = try await S3Client(endpoint: wrongHost, credentials: remote.credentials, certificateAuthority: remote.certificateAuthority).list(); XCTFail("Hostname must match") }
        catch TransferError.remote { }
    }
    func testRangeDigestAndStaleVersionReject() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), target = "range-\(UUID())", data = Data(repeating: 0x71, count: 256 * 1024)
        try data.write(to: source); try await remote.upload(source, to: target)
        let version = try await remote.fileVersion(target), prefix = try await remote.contentDigest(target, version: version, prefixBytes: 12345)
        XCTAssertEqual(prefix, Data(SHA256.hash(data: data.prefix(12345))))
        try Data(repeating: 0x72, count: data.count).write(to: source); try await remote.upload(source, to: target, overwrite: true)
        do { _ = try await remote.contentDigest(target, version: version); XCTFail("Changed ETag must reject") }
        catch TransferError.conflict { }
        try await remote.remove(target)
    }
    func testDownloadConflictAndCancellationKeepExistingLocalFile() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let destination = local.appendingPathComponent("existing"), original = Data("preserve local".utf8)
        try original.write(to: destination)
        do { try await remote.download("keys/中文 空格+#%?.txt", to: destination); XCTFail("Do not overwrite by default") }
        catch TransferError.conflict { }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let source = local.appendingPathComponent("source"), target = "cancel-download-\(UUID())"
        try Data(repeating: 0x16, count: 128 * 1024).write(to: source); try await remote.upload(source, to: target)
        let started = expectation(description: "Download receives bytes"), recorder = S3ProgressRecorder(started)
        let slow = try client(rate: 64 * 1024)
        let operation = Task { try await slow.download(target, to: destination, overwrite: true) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 10); operation.cancel()
        do { try await operation.value; XCTFail("Cancelled download cannot succeed") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: local.path).contains { $0.hasPrefix(".aethertransfer-s3-") })
        try await remote.remove(target)
    }
    func testCancelledMultipartUploadAbortsAndPreservesRemoteTarget() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), target = "cancel-upload-\(UUID())", proof = local.appendingPathComponent("proof")
        try Data("preserve remote".utf8).write(to: source); try await remote.upload(source, to: target)
        try Data(repeating: 0x48, count: 512 * 1024).write(to: source)
        let started = expectation(description: "Upload sends bytes"), recorder = S3ProgressRecorder(started), slow = try client(rate: 64 * 1024)
        let operation = Task { try await slow.upload(source, to: target, overwrite: true) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 5); operation.cancel()
        do { try await operation.value; XCTFail("Cancelled upload cannot succeed") }
        catch is CancellationError { }
        try await remote.download(target, to: proof); XCTAssertEqual(try Data(contentsOf: proof), Data("preserve remote".utf8))
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        try await remote.remove(target)
    }
    func testSourceTruncationDuringSignedPartCannotCommit() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), target = "changed-source-\(UUID())"
        try Data(repeating: 0x31, count: 512 * 1024).write(to: source)
        let started = expectation(description: "Upload starts before source truncation"), recorder = S3ProgressRecorder(started), slow = try client(rate: 128 * 1024)
        let operation = Task { try await slow.upload(source, to: target) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 5); try Data("shortened".utf8).write(to: source)
        do { try await operation.value; XCTFail("Source mutation cannot succeed") }
        catch { XCTAssertFalse(error is CancellationError) }
        do { _ = try await remote.fileVersion(target); XCTFail("No complete object may be committed") }
        catch S3Error.notFound { }
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
    }
    func testSymlinkAndFIFOInputsRejectWithoutCreatingMultipartUploads() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), symlink = local.appendingPathComponent("symlink"), fifo = local.appendingPathComponent("fifo")
        try Data("real source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        for input in [symlink, fifo] {
            do { try await remote.upload(input, to: "invalid-source-\(UUID())"); XCTFail("Only regular files can be streamed") }
            catch TransferError.invalidPath { }
        }
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
    }
    private func race(existing: Bool) async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), other = local.appendingPathComponent("other"), proof = local.appendingPathComponent("proof")
        let target = "race-\(UUID())"
        if existing { try Data("initial".utf8).write(to: source); try await remote.upload(source, to: target) }
        try Data(repeating: 0x38, count: 512 * 1024).write(to: source)
        let started = expectation(description: "First conditional upload started"), recorder = S3ProgressRecorder(started), slow = try client(rate: 256 * 1024)
        let operation = Task { try await slow.upload(source, to: target, overwrite: existing) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 5)
        try Data("concurrent writer".utf8).write(to: other); try await remote.upload(other, to: target, overwrite: existing)
        do { try await operation.value; XCTFail("Concurrent writer must cause conditional commit to reject") }
        catch TransferError.conflict { }
        try await remote.download(target, to: proof); XCTAssertEqual(try Data(contentsOf: proof), Data("concurrent writer".utf8))
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        try await remote.remove(target)
    }
    func testConditionalOverwriteRejectsConcurrentRemoteChange() async throws { try await race(existing: true) }
    func testConditionalCreateRejectsConcurrentObjectCreation() async throws { try await race(existing: false) }
    func testUploadPauseResumeRetainsOneMultipartSession() async throws {
        let control = TransferControl(), remote = try client(), slow = try client(control: control, rate: 128 * 1024), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), proof = local.appendingPathComponent("proof"), target = "pause-\(UUID())"
        let data = Data(repeating: 0x67, count: 512 * 1024); try data.write(to: source)
        let started = expectation(description: "Upload starts before pause"), recorder = S3ProgressRecorder(started)
        let operation = Task { try await slow.upload(source, to: target) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 5); control.pause()
        try await Task.sleep(for: .milliseconds(300)); let paused = recorder.value()
        try await Task.sleep(for: .milliseconds(300)); XCTAssertEqual(recorder.value(), paused)
        let active = try await remote.activeMultipartUploads(); XCTAssertEqual(active, 1)
        control.resume(); try await operation.value
        try await remote.download(target, to: proof); XCTAssertEqual(try Data(contentsOf: proof), data)
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        try await remote.remove(target)
    }

    func testRecursiveDirectoryRoundTripPreservesEmptyHiddenAndSpecialFiles() async throws {
        let remote = try client(), local = try folder(), prefix = "tree-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent(".hidden"), withIntermediateDirectories: false)
        let bytes = Data(repeating: 0x83, count: 1024 * 1024 + 31)
        try bytes.write(to: source.appendingPathComponent("子目录/中文 空格+#%?.txt"))
        try Data().write(to: source.appendingPathComponent("empty.txt"))
        let upload = S3TreeProgressRecorder(), download = S3TreeProgressRecorder()
        try await remote.uploadTree(source, to: prefix) { upload.record($0) }
        let root = FileEntry(name: "source", path: prefix, isDirectory: true, s3Key: prefix)
        try await remote.downloadTree(root, to: destination) { download.record($0) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("子目录/中文 空格+#%?.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("empty.txt")), Data())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent(".hidden").path), [])
        for final in [try XCTUnwrap(upload.value()), try XCTUnwrap(download.value())] {
            XCTAssertEqual(final.scope, .directory); XCTAssertEqual(final.total, Int64(bytes.count))
            XCTAssertEqual(final.completed, final.total); XCTAssertEqual(final.completedItems, 5)
            XCTAssertEqual(final.totalItems, 5); XCTAssertEqual(final.skippedItems, 0)
        }
        let active = try await remote.activeMultipartUploads(); XCTAssertEqual(active, 0)
    }

    func testRecursiveDirectoryPoliciesRecheckAndPreserveUnrelatedFiles() async throws {
        let remote = try client(), local = try folder(), prefix = "tree-policy-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("file"), original = Data("original".utf8)
        try original.write(to: file); try await remote.uploadTree(source, to: prefix)
        do { try await remote.uploadTree(source, to: prefix); XCTFail("Existing prefix must reject") } catch TransferError.conflict { }
        try Data("replacement".utf8).write(to: file)
        let skip = S3TreeProgressRecorder()
        try await remote.uploadTree(source, to: prefix, policy: .skip) { skip.record($0) }
        XCTAssertEqual(skip.value()?.skippedItems, 1)
        try await remote.uploadTree(source, to: prefix, policy: .keepBoth)
        let alternative = String(prefix.dropLast()) + " (2)/"
        let root = FileEntry(name: "source", path: prefix, isDirectory: true, s3Key: prefix)
        try await remote.downloadTree(root, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), original)
        try await remote.downloadTree(root, to: destination, policy: .keepBoth)
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("download (2)/file")), original)
        let sentinel = destination.appendingPathComponent("unrelated"); try original.write(to: sentinel)
        try await remote.uploadTree(source, to: prefix, policy: .overwrite)
        try await remote.downloadTree(root, to: destination, policy: .skip)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), original)
        try await remote.downloadTree(root, to: destination, policy: .overwrite)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        let other = try await remote.list(prefix: alternative); XCTAssertEqual(other.map(\.name), ["file"])
    }

    func testRecursiveDownloadPreflightsCaseAliasesBeforeWritingAnyLocalFile() async throws {
        let remote = try client(), local = try folder()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"); try Data("payload".utf8).write(to: source)
        // MinIO rejects dot components, repeated slashes and nonempty trailing-slash keys.
        // Their client guards are covered in S3TreeTests; real AWS acceptance stays open.
        let cases = [["a.txt", "A.txt"], ["nested/a.txt", "nested/A.txt"]]
        for keys in cases {
            let prefix = "unsafe-tree-\(UUID())/", destination = local.appendingPathComponent(UUID().uuidString)
            for key in keys { try await remote.upload(source, to: prefix + key) }
            let siblings = try await remote.list(prefix: keys[0].contains("/") ? prefix + "nested/" : prefix)
            XCTAssertEqual(Set(siblings.map(\.name)), ["a.txt", "A.txt"], "The real service must actually preserve both case-sensitive keys")
            let root = FileEntry(name: "unsafe", path: prefix, isDirectory: true, s3Key: prefix)
            do { try await remote.downloadTree(root, to: destination); XCTFail("Cannot flatten unsafe object keys") }
            catch TransferError.remote { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("escape.txt").path))
        }
    }

    func testRecursiveDownloadRejectsSameSizeSourceChangeAfterScan() async throws {
        let remote = try client(), local = try folder(), prefix = "tree-changed-\(UUID())/", control = TransferControl()
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("download")
        try Data("before".utf8).write(to: source); try await remote.upload(source, to: prefix + "file")
        let root = FileEntry(name: "tree", path: prefix, isDirectory: true, s3Key: prefix), scanned = expectation(description: "Tree scan completed")
        let controlled = try client(control: control)
        let operation = Task { try await controlled.downloadTree(root, to: destination) { value in
            if value.scope == .directory && value.totalItems != nil && value.completedItems == 0 {
                control.pause(); scanned.fulfill()
            }
        } }
        await fulfillment(of: [scanned], timeout: 5)
        try Data("after!".utf8).write(to: source); try await remote.upload(source, to: prefix + "file", overwrite: true)
        control.resume()
        do { try await operation.value; XCTFail("Same-size ETag change cannot be downloaded as the scanned source") }
        catch ResumeTransferError.sourceChanged { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file").path))
    }

    func testRecursiveUploadRejectsSymlinkBeforeWritingAnyPrefix() async throws {
        let remote = try client(), local = try folder(), prefix = "tree-link-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: local)
        do { try await remote.uploadTree(source, to: prefix); XCTFail("Cannot follow a symlink tree") }
        catch ResumeTransferError.unsupportedVersion { }
        let listed = try await remote.list(prefix: prefix); XCTAssertTrue(listed.isEmpty)
        do { _ = try await remote.fileVersion(prefix); XCTFail("No marker may be written before preflight") } catch S3Error.notFound { }
    }

    func testRecursiveUploadPreflightsAllKeyLengthsBeforeCreatingMarkers() async throws {
        let remote = try client(), local = try folder(), anchor = "tree-long-\(UUID())/"
        let prefix = anchor + String(repeating: "a", count: 950) + "/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("long mapping".utf8).write(to: source.appendingPathComponent(String(repeating: "b", count: 80)))
        do { try await remote.uploadTree(source, to: prefix); XCTFail("S3 keys are limited to 1,024 UTF-8 bytes") }
        catch TransferError.invalidPath { }
        let listed = try await remote.list(); XCTAssertFalse(listed.contains { $0.key.utf8.elementsEqual(anchor.utf8) })
    }

    func testRecursiveUploadCancellationAbortsOwnedMultipart() async throws {
        let remote = try client(), slow = try client(rate: 128 * 1024), local = try folder(), prefix = "tree-cancel-upload-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 0x79, count: 512 * 1024).write(to: source.appendingPathComponent("file"))
        let started = expectation(description: "Tree upload started"), recorder = S3ProgressRecorder(started)
        let operation = Task { try await slow.uploadTree(source, to: prefix) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 5); operation.cancel()
        do { try await operation.value; XCTFail("Canceled tree cannot report success") } catch is CancellationError { }
        let active = try await remote.activeMultipartUploads(); XCTAssertEqual(active, 0)
        do { _ = try await remote.fileVersion(prefix + "file"); XCTFail("Canceled object cannot be committed") } catch S3Error.notFound { }
    }

    func testRecursiveDownloadCancellationPreservesExistingLeaf() async throws {
        let remote = try client(), slow = try client(rate: 128 * 1024), local = try folder(), prefix = "tree-cancel-download-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("download")
        try Data(repeating: 0x49, count: 512 * 1024).write(to: source)
        try await remote.upload(source, to: prefix + "file")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let original = Data("keep-existing".utf8); try original.write(to: destination.appendingPathComponent("file"))
        let root = FileEntry(name: "tree", path: prefix, isDirectory: true, s3Key: prefix)
        let started = expectation(description: "Tree download started"), recorder = S3ProgressRecorder(started)
        let operation = Task { try await slow.downloadTree(root, to: destination, policy: .overwrite) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 10); operation.cancel()
        do { try await operation.value; XCTFail("Canceled tree cannot report success") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("file")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["file"])
    }
}
