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

private final class S3SyncProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var announced = false
    let started: XCTestExpectation
    let threshold: Int64
    init(_ started: XCTestExpectation, threshold: Int64) { self.started = started; self.threshold = threshold }
    func record(_ value: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        if value.completed > threshold && !announced { announced = true; started.fulfill() }
    }
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
    func testColumnHistoryUsesRealS3PrefixesAndCachedHiddenFiltering() async throws {
        let remote = try client(), local = try folder(), prefix = "columns-\(UUID())/", child = prefix + "中文 +#%/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source")
        try Data("column bytes".utf8).write(to: source)
        try await remote.createPrefix(prefix); try await remote.createPrefix(child)
        try await remote.upload(source, to: child + "file.txt")
        try await remote.upload(source, to: child + ".hidden")
        let parent = FileColumnSnapshot(path: prefix, files: try await remote.list(prefix: prefix).map(\.fileEntry))
        let directory = try XCTUnwrap(parent.files.first { $0.isDirectory })
        XCTAssertEqual(Data(directory.path.utf8), Data(child.utf8))
        var history = FileColumnHistory(); history.accept(parent)
        let contents = FileColumnSnapshot(path: directory.path, files: try await remote.list(prefix: directory.path).map(\.fileEntry))
        history.accept(contents)
        XCTAssertEqual(history.columns.count, 2); XCTAssertEqual(history.branchSelection(at: 0), [directory.id])
        XCTAssertEqual(Set(contents.files.map(\.s3Key)), [child + "file.txt", child + ".hidden"])
        XCTAssertEqual(FilePresentation.entries(contents.files, query: "", showHidden: false).map(\.name), ["file.txt"])
        XCTAssertEqual(FilePresentation.entries(contents.files, query: "", showHidden: true).count, 2)
        for key in [child + "file.txt", child + ".hidden", child, prefix] { try await remote.remove(key) }
    }
    func testSyncNestedRoundTripContentComparisonAndS3MirrorDeletionIsBlocked() async throws {
        let remote = try client(), local = try folder(), prefix = "sync-roundtrip-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let bytes = Data("中英文 UTF-8\r\n".utf8)
        try bytes.write(to: source.appendingPathComponent("nested/中文 +#%?.txt"))
        try Data().write(to: source.appendingPathComponent("empty.txt"))
        try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
        try Data("excluded".utf8).write(to: source.appendingPathComponent("ignored"))
        try await remote.createPrefix(prefix)
        var options = SyncOptions(); options.comparison = .contents; options.excludedPaths = ["ignored"]
        let root = SyncRoot.s3(remote, prefix)
        let plan = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        XCTAssertNil(plan.left.records[".hidden"]); XCTAssertNil(plan.left.records["ignored"])
        _ = try await SyncEngine.execute(plan, left: .local(source), right: root, selected: Set(plan.items.filter(\.selectedByDefault).map(\.id)))
        let unchanged = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        XCTAssertTrue(unchanged.items.isEmpty); XCTAssertEqual(unchanged.unchanged, 4)
        options.includeHidden = true
        let hidden = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        XCTAssertEqual(hidden.items.map(\.path), [".hidden"])
        _ = try await SyncEngine.execute(hidden, left: .local(source), right: root, selected: [".hidden"])
        options.mode = .rightToLeft
        let download = try await SyncEngine.preview(left: .local(destination), right: root, options: options)
        _ = try await SyncEngine.execute(download, left: .local(destination), right: root, selected: Set(download.items.filter(\.selectedByDefault).map(\.id)))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("nested/中文 +#%?.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".hidden")), Data("hidden".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("empty.txt")), Data())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("nested/empty").path, isDirectory: &isDirectory)); XCTAssertTrue(isDirectory.boolValue)
        let seed = local.appendingPathComponent("seed")
        try Data("preserve".utf8).write(to: seed); try await remote.upload(seed, to: prefix + "orphan")
        try Data("new".utf8).write(to: source.appendingPathComponent("new-file"))
        options.mode = .leftToRight; options.mirror = true
        let mirror = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        XCTAssertEqual(mirror.items.first { $0.path == "orphan" }?.operation, .blocked)
        XCTAssertFalse(mirror.items.first { $0.path == "orphan" }!.selectedByDefault)
        do {
            _ = try await SyncEngine.execute(mirror, left: .local(source), right: root, selected: Set(mirror.items.map(\.id)))
            XCTFail("A blocked mirror deletion must reject before any other write")
        } catch SyncError.invalidPlan { }
        do { _ = try await remote.fileVersion(prefix + "new-file"); XCTFail("Rejected plan must not partially write") }
        catch S3Error.notFound { }
        _ = try await SyncEngine.execute(mirror, left: .local(source), right: root, selected: Set(mirror.items.filter(\.selectedByDefault).map(\.id)))
        let proof = local.appendingPathComponent("proof")
        try await remote.download(prefix + "orphan", to: proof)
        XCTAssertEqual(try Data(contentsOf: proof), Data("preserve".utf8))
    }
    func testSyncS3ToS3BidirectionalConflictsRequireExplicitDirection() async throws {
        let remote = try client(), local = try folder(), a = "sync-left-\(UUID())/", b = "sync-right-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        try await remote.createPrefix(a); try await remote.createPrefix(b)
        let seed = local.appendingPathComponent("seed"), proof = local.appendingPathComponent("proof")
        for (key, text) in [(a + "left-only", "left"), (b + "right-only", "right"), (a + "conflict", "old"), (b + "conflict", "new")] {
            try Data(text.utf8).write(to: seed); try await remote.upload(seed, to: key)
        }
        let left = SyncRoot.s3(remote, a), right = SyncRoot.s3(remote, b)
        var options = SyncOptions(); options.mode = .bidirectional; options.comparison = .contents
        let plan = try await SyncEngine.preview(left: left, right: right, options: options)
        XCTAssertEqual(plan.items.first { $0.path == "conflict" }?.operation, .conflict)
        let all = Set(plan.items.map(\.id))
        do { _ = try await SyncEngine.execute(plan, left: left, right: right, selected: all); XCTFail("Conflict needs a direction") }
        catch SyncError.unresolved { }
        _ = try await SyncEngine.execute(plan, left: left, right: right, selected: all, resolutions: ["conflict": .rightToLeft])
        for (key, text) in [(b + "left-only", "left"), (a + "right-only", "right"), (a + "conflict", "new")] {
            try await remote.download(key, to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), Data(text.utf8))
        }
        let finished = try await SyncEngine.preview(left: left, right: right, options: options)
        XCTAssertTrue(finished.items.isEmpty)
    }
    func testSyncRejectsStaleSourceAndDestinationETagsBeforeWritesEvenForSizeComparison() async throws {
        let remote = try client(), local = try folder(), prefix = "sync-stale-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), destination = local.appendingPathComponent("destination"), seed = local.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try await remote.createPrefix(prefix)
        try Data("old".utf8).write(to: seed); try await remote.upload(seed, to: prefix + "file")
        var options = SyncOptions(); options.comparison = .fileSize; options.mode = .rightToLeft
        let root = SyncRoot.s3(remote, prefix)
        let download = try await SyncEngine.preview(left: .local(destination), right: root, options: options)
        try Data("new".utf8).write(to: seed); try await remote.upload(seed, to: prefix + "file", overwrite: true)
        do { _ = try await SyncEngine.execute(download, left: .local(destination), right: root, selected: ["file"]); XCTFail("Source ETag changed") }
        catch SyncError.changed { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("file").path))
        try Data("replacement".utf8).write(to: source.appendingPathComponent("file"))
        options.mode = .leftToRight
        let upload = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        try Data("now".utf8).write(to: seed); try await remote.upload(seed, to: prefix + "file", overwrite: true)
        do { _ = try await SyncEngine.execute(upload, left: .local(source), right: root, selected: ["file"]); XCTFail("Destination ETag changed") }
        catch SyncError.changed { }
        try await remote.download(prefix + "file", to: seed, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: seed), Data("now".utf8))
    }
    func testSyncPreflightsAllDestinationKeyLengthsBeforeCreatingDirectories() async throws {
        let remote = try client(), local = try folder(), prefix = "sync-long-\(UUID())/" + String(repeating: "a", count: 200) + "/"
        defer { try? FileManager.default.removeItem(at: local) }
        try await remote.createPrefix(prefix)
        let nested = "new/" + String(repeating: String(repeating: "b", count: 100) + "/", count: 7)
        try FileManager.default.createDirectory(at: local.appendingPathComponent(nested), withIntermediateDirectories: true)
        try Data("keep local".utf8).write(to: local.appendingPathComponent(nested + String(repeating: "c", count: 80)))
        let root = SyncRoot.s3(remote, prefix), plan = try await SyncEngine.preview(left: .local(local), right: root, options: SyncOptions())
        do {
            _ = try await SyncEngine.execute(plan, left: .local(local), right: root, selected: Set(plan.items.map(\.id)))
            XCTFail("All object keys must be validated before the first directory marker is created")
        } catch TransferError.invalidPath { }
        let untouched = try await remote.list(prefix: prefix)
        XCTAssertTrue(untouched.isEmpty)
    }
    func testSyncRejectsAmbiguousCaseMappingsBeforeLocalWrites() async throws {
        let remote = try client(), local = try folder(), seed = local.appendingPathComponent("seed")
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("unsafe alias".utf8).write(to: seed)
        for names in [["A.txt", "a.txt"], ["nested/A.txt", "nested/a.txt"]] {
            let prefix = "sync-alias-\(UUID())/"
            try await remote.createPrefix(prefix)
            for name in names { try await remote.upload(seed, to: prefix + name) }
            let listingPrefix = names[0].contains("/") ? prefix + "nested/" : prefix
            let siblings = try await remote.list(prefix: listingPrefix)
            XCTAssertEqual(Set(siblings.map(\.name)), ["A.txt", "a.txt"], "The service must really preserve both distinct keys")
            var options = SyncOptions(); options.mode = .rightToLeft; options.excludedPaths = [names[0]]
            do {
                _ = try await SyncEngine.preview(left: .local(local), right: .s3(remote, prefix), options: options)
                XCTFail("Excluded aliases must not conceal an ambiguous mapping")
            } catch TransferError.remote { }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), ["seed"])
        let source = local.appendingPathComponent("source"), prefix = "sync-destination-alias-\(UUID())/"
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source.appendingPathComponent("a.txt"))
        try await remote.createPrefix(prefix); try await remote.upload(seed, to: prefix + "A.txt")
        var options = SyncOptions(); options.excludedPaths = ["A.txt"]
        let root = SyncRoot.s3(remote, prefix), plan = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        XCTAssertNil(plan.right.records["A.txt"])
        do {
            _ = try await SyncEngine.execute(plan, left: .local(source), right: root, selected: ["a.txt"])
            XCTFail("An excluded destination alias must still block a lossy sibling mapping")
        } catch TransferError.remote { }
        let after = try await remote.list(prefix: prefix)
        XCTAssertEqual(after.map(\.name), ["A.txt"])
    }
    func testSyncConditionalUploadRejectsDestinationChangedDuringMultipartCommit() async throws {
        let remote = try client(), local = try folder(), prefix = "sync-race-\(UUID())/", size = 12 * 1024 * 1024
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), seed = local.appendingPathComponent("seed"), proof = local.appendingPathComponent("proof")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 65, count: size).write(to: source.appendingPathComponent("file"))
        try Data("old".utf8).write(to: seed); try await remote.createPrefix(prefix); try await remote.upload(seed, to: prefix + "file")
        var options = SyncOptions(); options.comparison = .fileSize
        let root = SyncRoot.s3(remote, prefix), plan = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        let started = expectation(description: "Multipart sync has uploaded actual bytes"), probe = S3SyncProgressRecorder(started, threshold: Int64(size / 2))
        let task = Task { try await SyncEngine.execute(plan, left: .local(source), right: root, selected: ["file"], rateLimit: 2 * 1024 * 1024, progress: probe.record) }
        await fulfillment(of: [started], timeout: 20)
        try Data("concurrent".utf8).write(to: seed); try await remote.upload(seed, to: prefix + "file", overwrite: true)
        do { _ = try await task.value; XCTFail("Completion must preserve the preview destination ETag") }
        catch TransferError.conflict { }
        try await remote.download(prefix + "file", to: proof)
        XCTAssertEqual(try Data(contentsOf: proof), Data("concurrent".utf8))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("file")), Data(repeating: 65, count: size))
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
    }
    func testSyncCancellationDuringMultipartUploadAbortsOwnedUploadAndPreservesDestination() async throws {
        let remote = try client(), local = try folder(), prefix = "sync-cancel-\(UUID())/", size = 12 * 1024 * 1024
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), seed = local.appendingPathComponent("seed"), proof = local.appendingPathComponent("proof")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 66, count: size).write(to: source.appendingPathComponent("file"))
        try Data("old".utf8).write(to: seed); try await remote.createPrefix(prefix); try await remote.upload(seed, to: prefix + "file")
        var options = SyncOptions(); options.comparison = .fileSize
        let root = SyncRoot.s3(remote, prefix), plan = try await SyncEngine.preview(left: .local(source), right: root, options: options)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix(".aethertransfer-sync-") })
        let started = expectation(description: "Sync upload is incomplete"), probe = S3SyncProgressRecorder(started, threshold: Int64(size / 2))
        let task = Task { try await SyncEngine.execute(plan, left: .local(source), right: root, selected: ["file"], rateLimit: 1024 * 1024, progress: probe.record) }
        await fulfillment(of: [started], timeout: 20); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled sync must not report success") }
        catch is CancellationError { }
        try await remote.download(prefix + "file", to: proof)
        XCTAssertEqual(try Data(contentsOf: proof), Data("old".utf8))
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix(".aethertransfer-sync-") })
        XCTAssertEqual(before, after)
    }
    func testTextEditorPreservesBOMCRLFAndExternalDraftSavesWithVersionChecks() async throws {
        let remote = try client(), local = try folder(), prefix = "edit-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), proof = local.appendingPathComponent("proof")
        for name in ["中文 +#%?.txt", ".lease", "work", String(repeating: "a", count: 250) + ".txt"] {
            let key = prefix + name, original = Data([0xef, 0xbb, 0xbf]) + Data("第一行\r\n第二行\r\n".utf8)
            try original.write(to: source); try await remote.upload(source, to: key)
            let session = try await FileEditSession.open(.s3(remote, key))
            defer { try? FileManager.default.removeItem(at: session.directory) }
            XCTAssertEqual(session.draftURL.lastPathComponent, name.utf8.count > 240 ? "preview.txt" : name)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: session.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: session.draftURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let initial = try await session.snapshot()
            XCTAssertTrue(initial.hasUTF8BOM); XCTAssertEqual(initial.text, "第一行\r\n第二行\r\n")
            let draft = "第一行\r\nEdited 中文\r\n"
            try await session.persistDraft(draft)
            try await remote.download(key, to: proof, overwrite: true); XCTAssertEqual(try Data(contentsOf: proof), original)
            _ = try await session.save(text: draft)
            try await remote.download(key, to: proof, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: proof), Data([0xef, 0xbb, 0xbf]) + Data(draft.utf8))
            let external = Data([0xef, 0xbb, 0xbf]) + Data("External 原子保存\r\n".utf8)
            try external.write(to: session.draftURL, options: .atomic)
            _ = try await session.save()
            try await remote.download(key, to: proof, overwrite: true); XCTAssertEqual(try Data(contentsOf: proof), external)
            try await session.close(); XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
            try await remote.remove(key)
        }
    }
    func testTextEditorRejectsChangedAndDeletedObjectsAndPreservesDraftForMerge() async throws {
        let remote = try client(), local = try folder(), key = "edit-conflict-\(UUID())"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), proof = local.appendingPathComponent("proof"), export = local.appendingPathComponent("export.txt")
        try Data("old".utf8).write(to: source); try await remote.upload(source, to: key)
        let session = try await FileEditSession.open(.s3(remote, key)), version = try await remote.fileVersion(key)
        defer { try? FileManager.default.removeItem(at: session.directory) }
        try Data("new".utf8).write(to: source); try await remote.upload(source, to: key, overwrite: true)
        do { _ = try await session.save(text: "my draft"); XCTFail("Same-size source changes must reject") }
        catch FileEditError.changed { }
        try await session.exportDraft(to: export); XCTAssertEqual(try Data(contentsOf: export), Data("my draft".utf8))
        do { try await remote.upload(export, to: key, overwrite: true, expectedVersion: version); XCTFail("Stale upload baseline must reject") }
        catch ResumeTransferError.sourceChanged { }
        try await remote.download(key, to: proof); XCTAssertEqual(try Data(contentsOf: proof), Data("new".utf8))
        let latest = try await session.reload(); XCTAssertEqual(latest.text, "new")
        _ = try await session.save(text: "merged")
        try await remote.download(key, to: proof, overwrite: true); XCTAssertEqual(try Data(contentsOf: proof), Data("merged".utf8))
        let savedVersion = try await remote.fileVersion(key)
        try await remote.remove(key)
        do { _ = try await session.save(text: "kept after delete"); XCTFail("Deleted source cannot be recreated by an editor save") }
        catch FileEditError.changed { }
        do { try await remote.upload(export, to: key, overwrite: true, expectedVersion: savedVersion); XCTFail("Deleted upload baseline must reject") }
        catch ResumeTransferError.sourceChanged { }
        try await session.exportDraft(to: export); XCTAssertEqual(try Data(contentsOf: export), Data("kept after delete".utf8))
        do { _ = try await remote.fileVersion(key); XCTFail("The deleted object must remain deleted") }
        catch S3Error.notFound { }
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        try await session.close()
    }
    func testTextEditorRejectsBinaryAndOversizedObjectsButCanSaveEmptyText() async throws {
        let remote = try client(), local = try folder(), prefix = "edit-format-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), proof = local.appendingPathComponent("proof")
        for (index, bytes) in [Data([0, 1, 2]), Data([0xff]), Data(repeating: 65, count: FileEditSession.maximumBytes + 1)].enumerated() {
            try bytes.write(to: source); let key = prefix + "invalid-\(index)"
            try await remote.upload(source, to: key)
            do { _ = try await FileEditSession.open(.s3(remote, key)); XCTFail("Unsupported text cannot open an editor session") }
            catch FileEditError.tooLarge where index == 2 { }
            catch FileEditError.unsupportedText where index != 2 { }
            try await remote.remove(key)
        }
        let key = prefix + "empty.txt"; try Data().write(to: source); try await remote.upload(source, to: key)
        let session = try await FileEditSession.open(.s3(remote, key))
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let initial = try await session.snapshot(); XCTAssertEqual(initial.text, "")
        _ = try await session.save(text: "created text")
        _ = try await session.save(text: "")
        try await remote.download(key, to: proof); XCTAssertEqual(try Data(contentsOf: proof), Data())
        try await session.close(); try await remote.remove(key)
    }
    func testCancelledTextEditorOpenCleansItsPartialSnapshotAndKeepsObject() async throws {
        let remote = try client(), slow = try client(rate: 64 * 1024), local = try folder(), key = "edit-open-cancel-\(UUID())"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), proof = local.appendingPathComponent("proof"), bytes = Data(repeating: 65, count: 256 * 1024)
        try bytes.write(to: source); try await remote.upload(source, to: key)
        let fm = FileManager.default, temporary = fm.temporaryDirectory
        let before = Set(try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil))
        let operation = Task { try await FileEditSession.open(.s3(slow, key)) }
        defer { operation.cancel() }
        var pending: URL?
        for _ in 0..<120 {
            let current = Set(try fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil))
            for candidate in current.subtracting(before) where candidate.lastPathComponent.hasPrefix("aethertransfer-edit-") {
                // S3 downloads own a nested staging directory; legacy protocols use a sibling .part file.
                let files = fm.enumerator(at: candidate.appendingPathComponent("work"),
                                          includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])?.allObjects as? [URL] ?? []
                if files.contains(where: {
                    guard let info = try? $0.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                          info.isRegularFile == true, let size = info.fileSize else { return false }
                    return size > 0 && size < bytes.count
                }) {
                    pending = candidate; break
                }
            }
            if pending != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        operation.cancel()
        do { let unexpected = try await operation.value; try await unexpected.close(); XCTFail("Cancelled open cannot publish an editor session") }
        catch is CancellationError { }
        XCTAssertNotNil(pending, "Exercise cancellation after the actual snapshot has received bytes")
        if let pending { XCTAssertFalse(fm.fileExists(atPath: pending.path)) }
        try await remote.download(key, to: proof); XCTAssertEqual(try Data(contentsOf: proof), bytes)
        try await remote.remove(key)
    }
    private func waitForEditorMultipart(_ remote: S3Client) async throws -> Bool {
        for _ in 0..<50 {
            if try await remote.activeMultipartUploads() > 0 { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
    func testTextEditorConditionalCommitRejectsChangeDuringSaveAndKeepsDraft() async throws {
        let remote = try client(), slow = try client(rate: 64 * 1024), local = try folder(), key = "edit-race-\(UUID())"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), proof = local.appendingPathComponent("proof")
        try Data("initial".utf8).write(to: source); try await remote.upload(source, to: key)
        let session = try await FileEditSession.open(.s3(slow, key)), draft = String(repeating: "a", count: 512 * 1024)
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let operation = Task { try await session.save(text: draft) }
        defer { operation.cancel() }
        let started = try await waitForEditorMultipart(remote)
        if !started { operation.cancel(); _ = try? await operation.value }
        XCTAssertTrue(started, "A multipart save must have started before changing the source")
        guard started else { return }
        try Data("concurrent writer".utf8).write(to: source); try await remote.upload(source, to: key, overwrite: true)
        do { _ = try await operation.value; XCTFail("The editor cannot adopt a new ETag during conditional completion") }
        catch FileEditError.changed { }
        try await remote.download(key, to: proof); XCTAssertEqual(try Data(contentsOf: proof), Data("concurrent writer".utf8))
        let savedDraft = try await session.snapshot(); XCTAssertEqual(savedDraft.text, draft)
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        try await session.close(); try await remote.remove(key)
    }
    func testCancelledTextEditorSaveAbortsOnlyItsMultipartAndKeepsSourceAndDraft() async throws {
        let remote = try client(), slow = try client(rate: 64 * 1024), local = try folder(), key = "edit-save-cancel-\(UUID())"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), proof = local.appendingPathComponent("proof"), original = Data("initial".utf8)
        try original.write(to: source); try await remote.upload(source, to: key)
        let session = try await FileEditSession.open(.s3(slow, key)), draft = String(repeating: "a", count: 512 * 1024)
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let operation = Task { try await session.save(text: draft) }
        defer { operation.cancel() }
        let started = try await waitForEditorMultipart(remote)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled save cannot commit or report success") }
        catch is CancellationError { }
        XCTAssertTrue(started, "Cancel after multipart creation, not just the preflight read")
        try await remote.download(key, to: proof); XCTAssertEqual(try Data(contentsOf: proof), original)
        let savedDraft = try await session.snapshot(); XCTAssertEqual(savedDraft.text, draft)
        let pending = try await remote.activeMultipartUploads(); XCTAssertEqual(pending, 0)
        try await session.close(); try await remote.remove(key)
    }
    func testPreviewVerifiesBilingualReservedAndEmptyObjectSnapshotsAndClosesLease() async throws {
        let remote = try client(), local = try folder(), prefix = "preview-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), cache = local.appendingPathComponent("previews", isDirectory: true)
        for name in ["中文 +#%?.txt", ".lease", "empty.txt"] {
            let bytes = name == "empty.txt" ? Data() : Data("Verified preview 中文 \(name)".utf8)
            try bytes.write(to: source); let key = prefix + name
            try await remote.upload(source, to: key)
            let before = try await remote.fileVersion(key)
            let preview = try await FilePreview.open(.s3(remote, key), temporaryParent: cache)
            XCTAssertEqual(preview.url.lastPathComponent, name)
            XCTAssertEqual(preview.url.deletingLastPathComponent().lastPathComponent, "payload")
            XCTAssertEqual(preview.byteCount, Int64(bytes.count)); XCTAssertEqual(try Data(contentsOf: preview.url), bytes)
            let directory = try XCTUnwrap(preview.directory)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            let active = try await FilePreview.reclaimAbandoned(in: cache)
            XCTAssertEqual(active.inUse, 1); XCTAssertEqual(active.removed, 0)
            try await preview.close(); try await preview.close()
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
            let after = try await remote.fileVersion(key); XCTAssertEqual(after, before)
            try await remote.remove(key)
        }
    }
    func testPreviewLimitAndMissingObjectRejectBeforeCreatingCache() async throws {
        let remote = try client(), local = try folder(), key = "preview-limit-\(UUID())"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), cache = local.appendingPathComponent("previews", isDirectory: true)
        try Data(repeating: 0x41, count: 1024).write(to: source); try await remote.upload(source, to: key)
        do { _ = try await FilePreview.open(.s3(remote, key), maximumRemoteBytes: 32, temporaryParent: cache); XCTFail("Oversized preview must reject") }
        catch FilePreviewError.tooLarge { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        try await remote.remove(key)
        do { _ = try await FilePreview.open(.s3(remote, key), temporaryParent: cache); XCTFail("Missing object must reject") }
        catch S3Error.notFound { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
    func testCancelledPreviewRemovesSnapshotAndKeepsRemoteObject() async throws {
        let remote = try client(), local = try folder(), key = "preview-cancel-\(UUID())"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), cache = local.appendingPathComponent("previews", isDirectory: true)
        try Data(repeating: 0x37, count: 256 * 1024).write(to: source); try await remote.upload(source, to: key)
        let before = try await remote.fileVersion(key), slow = try client(rate: 64 * 1024)
        let started = expectation(description: "Preview download has bytes"), recorder = S3ProgressRecorder(started)
        let operation = Task { try await FilePreview.open(.s3(slow, key), temporaryParent: cache) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 12)
        let active = try await FilePreview.reclaimAbandoned(in: cache); XCTAssertEqual(active.inUse, 1)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled preview cannot publish a snapshot") }
        catch is CancellationError { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        let after = try await remote.fileVersion(key); XCTAssertEqual(after, before)
        try await remote.remove(key)
    }
    func testPreviewSourceChangedDuringDownloadDoesNotPublishSnapshot() async throws {
        let remote = try client(), local = try folder(), key = "preview-change-\(UUID())"
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source"), cache = local.appendingPathComponent("previews", isDirectory: true)
        let size = 256 * 1024
        try Data(repeating: 0x38, count: size).write(to: source); try await remote.upload(source, to: key)
        let slow = try client(rate: 64 * 1024)
        let started = expectation(description: "Preview download has bytes"), recorder = S3ProgressRecorder(started)
        let operation = Task { try await FilePreview.open(.s3(slow, key), temporaryParent: cache) { recorder.record($0) } }
        await fulfillment(of: [started], timeout: 12)
        try Data(repeating: 0x39, count: size).write(to: source); try await remote.upload(source, to: key, overwrite: true)
        do {
            let unexpected = try await operation.value
            try await unexpected.close(); XCTFail("Changed source cannot publish a preview")
        } catch FilePreviewError.changed { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        try await remote.remove(key)
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

extension S3ProtocolTests {
    func testPastePlanS3EncodedPrefixesHiddenEmptyMarkersAndETagChanges() async throws {
        let remote = try client(), local = try folder(), anchor = "paste-raw-\(UUID())/"
        let a = anchor + "中文 +#%/source/", b = anchor + "中文 +#%/target/"
        defer { try? FileManager.default.removeItem(at: local) }
        let seed = local.appendingPathComponent("seed"), proof = local.appendingPathComponent("proof")
        for prefix in [a, b, a + "folder/", a + "folder/empty/", b + "folder/"] { try await remote.createPrefix(prefix) }
        try Data("old".utf8).write(to: seed)
        for key in [a + "folder/.hidden", a + "folder/file"] { try await remote.upload(seed, to: key) }
        try Data().write(to: seed); try await remote.upload(seed, to: a + "folder/zero")
        try Data("keep".utf8).write(to: seed)
        for key in [b + "folder/file", b + "folder/extra"] { try await remote.upload(seed, to: key) }
        let selection = [FilePasteInput(root: .s3(remote, a), name: "folder")]
        let plan = try await FilePaste.preview(selection, destination: .s3(remote, b), move: true, policy: .overwrite)
        XCTAssertTrue(plan.canApply); XCTAssertEqual(plan.destination.path, b)
        XCTAssertEqual(plan.count, 5); XCTAssertEqual(plan.bytes, 6); XCTAssertEqual(plan.overwriteCount, 1)
        try await FilePaste.validate(plan)
        let targets = try await remote.list(prefix: b + "folder/")
        XCTAssertEqual(Set(targets.map(\.key)), [b + "folder/file", b + "folder/extra"])
        try await remote.download(b + "folder/file", to: proof)
        XCTAssertEqual(try Data(contentsOf: proof), Data("keep".utf8))
        let localPlan = try await FilePaste.preview(selection, destination: .local(local))
        XCTAssertTrue(localPlan.canApply); try await FilePaste.validate(localPlan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("folder").path))
        try Data("new".utf8).write(to: seed); try await remote.upload(seed, to: a + "folder/.hidden", overwrite: true)
        do { try await FilePaste.validate(plan); XCTFail("Same-size ETag change must invalidate") }
        catch FilePasteError.changed { }
        let second = try await FilePaste.preview(selection, destination: .s3(remote, b), policy: .overwrite)
        try await remote.remove(a + "folder/empty/")
        do { try await FilePaste.validate(second); XCTFail("Removed empty-folder marker must invalidate") }
        catch FilePasteError.changed { }
        for key in [a + "folder/.hidden", a + "folder/file", a + "folder/zero", b + "folder/file", b + "folder/extra", a + "folder/", b + "folder/", a, b] { try await remote.remove(key) }
    }
    func testPastePlanS3OverlapDuplicateVirtualPrefixLossAndHiddenArrival() async throws {
        let remote = try client(), local = try folder(), a = "paste-source-\(UUID())/", b = "paste-target-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let seed = local.appendingPathComponent("seed"); try Data("seed".utf8).write(to: seed)
        try await remote.createPrefix(a); try await remote.createPrefix(b)
        try await remote.upload(seed, to: a + "folder/sub/file")
        let item = FilePasteInput(root: .s3(remote, a), name: "folder")
        let overlap = try await FilePaste.preview([item], destination: .s3(remote, a + "folder/sub/"))
        XCTAssertFalse(overlap.canApply); XCTAssertEqual(overlap.items[0].issue, .overlap)
        let duplicate = try await FilePaste.preview([item], destination: .s3(remote, a), policy: .keepBoth)
        XCTAssertTrue(duplicate.canApply); XCTAssertEqual(duplicate.items[0].destinationName, "folder (2)")
        try await FilePaste.validate(duplicate)
        let plan = try await FilePaste.preview([item], destination: .s3(remote, b))
        try await remote.upload(seed, to: b + ".arrival")
        do { try await FilePaste.validate(plan); XCTFail("Hidden target arrival must invalidate") }
        catch FilePasteError.changed { }
        try await remote.remove(b + ".arrival")
        let virtual = try await FilePaste.preview([item], destination: .s3(remote, b))
        try await remote.remove(a + "folder/sub/file")
        do { try await FilePaste.validate(virtual); XCTFail("Lost virtual prefix must invalidate") }
        catch FilePasteError.changed { }
        try await remote.remove(a); try await remote.remove(b)
    }
    func testPastePlanS3MaximumDestinationKeyAndReservedSuffixFailureAreReadOnly() async throws {
        let remote = try client(), local = try folder(), anchor = "paste-long-\(UUID())/"
        defer { try? FileManager.default.removeItem(at: local) }
        let name = String(repeating: "x", count: 240), seed = local.appendingPathComponent("seed")
        let a = anchor + "source-a/", b = anchor + "source-b/"
        let prefixSize = 1024 - name.utf8.count, remaining = prefixSize - anchor.utf8.count
        let pieceSize = (remaining - 8) / 8
        let prefix = anchor + (0..<8).map { index in
            String(repeating: "d", count: index == 7 ? remaining - 7 * (pieceSize + 1) - 1 : pieceSize)
        }.joined(separator: "/") + "/"
        XCTAssertEqual(prefix.utf8.count + name.utf8.count, 1024)
        try Data("seed".utf8).write(to: seed)
        for value in [a, b, prefix] { try await remote.createPrefix(value) }
        for value in [a, b] { try await remote.upload(seed, to: value + name) }
        let selections = [FilePasteInput(root: .s3(remote, a), name: name), FilePasteInput(root: .s3(remote, b), name: name)]
        let allowed = try await FilePaste.preview([selections[0]], destination: .s3(remote, prefix))
        XCTAssertTrue(allowed.canApply); XCTAssertEqual(allowed.bytes, 4)
        try await FilePaste.validate(allowed)
        do { _ = try await FilePaste.preview(selections, destination: .s3(remote, prefix), policy: .keepBoth); XCTFail("Reserved suffix cannot exceed the destination key limit") }
        catch TransferError.invalidPath { }
        let objects = try await remote.list(prefix: prefix); XCTAssertTrue(objects.isEmpty)
        for value in [a, b] {
            let version = try await remote.fileVersion(value + name); XCTAssertEqual(version.size, 4)
            try await remote.remove(value + name); try await remote.remove(value)
        }
        try await remote.remove(prefix)
    }
}
