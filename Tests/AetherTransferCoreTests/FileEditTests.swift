import XCTest
@testable import AetherTransferCore

@MainActor final class FileEditTests: XCTestCase {
    func testS3EditorRejectsBucketAndPrefixSourcesBeforeNetworkAccess() async throws {
        let client = S3Client(endpoint: S3Endpoint(host: "127.0.0.1", port: 1, bucket: "fixture-bucket"),
                              credentials: S3Credentials(accessKey: "fixture", secretKey: "test-only"))
        for key in ["", "folder/"] {
            do { _ = try await FileEditSession.open(.s3(client, key)); XCTFail("Bucket and prefix cannot be edited as text") }
            catch FileEditError.unsupportedText { }
        }
    }
    func testS3ExpectedUploadVersionRequiresETagBeforeReadingSourceOrSendingRequest() async throws {
        let client = S3Client(endpoint: S3Endpoint(host: "127.0.0.1", port: 1, bucket: "fixture-bucket"),
                              credentials: S3Credentials(accessKey: "fixture", secretKey: "test-only"))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-missing-\(UUID())")
        do {
            try await client.upload(missing, to: "text.txt", overwrite: true,
                                    expectedVersion: RemoteFileVersion(size: 0, modified: nil, etag: nil))
            XCTFail("An expected version cannot silently become an unconditional write")
        } catch ResumeTransferError.unsupportedVersion { }
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-edit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testLocalSavePreservesBOMLineEndingsPermissionsAndCleansSession() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 文本.txt")
        let data = Data([0xef, 0xbb, 0xbf]) + Data("第一行\r\n第二行\r\n".utf8)
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let session = try await FileEditSession.open(.local(file))
        defer { try? FileManager.default.removeItem(at: session.directory) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: session.directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: session.draftURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let original = try await session.snapshot()
        XCTAssertEqual(original.text, "第一行\r\n第二行\r\n"); XCTAssertTrue(original.hasUTF8BOM)
        let draft = "第一行\r\n修改后\r\n"
        try await session.persistDraft(draft)
        XCTAssertEqual(try Data(contentsOf: file), data, "Persisting a draft cannot overwrite the source")
        _ = try await session.save(text: draft)
        XCTAssertEqual(try Data(contentsOf: file), Data([0xef, 0xbb, 0xbf]) + Data(draft.utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        try await session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
    }
    func testContentConflictWithUnchangedSizeAndDatePreservesSourceAndDraft() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conflict.txt"), export = root.appendingPathComponent("draft.txt")
        try Data("old".utf8).write(to: file)
        let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let session = try await FileEditSession.open(.local(file))
        defer { try? FileManager.default.removeItem(at: session.directory) }
        try Data("new".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        do { _ = try await session.save(text: "my draft"); XCTFail("Content change must reject") }
        catch FileEditError.changed { }
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        try await session.exportDraft(to: export)
        XCTAssertEqual(try Data(contentsOf: export), Data("my draft".utf8))
        let latest = try await session.reload(); XCTAssertEqual(latest.text, "new")
        _ = try await session.save(text: "merged")
        XCTAssertEqual(try Data(contentsOf: file), Data("merged".utf8))
        try await session.close()
    }
    func testRejectsBinaryOversizedAndSymbolicSourcesButAcceptsEmpty() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for (index, bytes) in [Data([0, 1, 2]), Data([0xff, 0xff]), Data(repeating: 65, count: FileEditSession.maximumBytes + 1)].enumerated() {
            let file = root.appendingPathComponent("invalid-\(index)"); try bytes.write(to: file)
            do { _ = try await FileEditSession.open(.local(file)); XCTFail("Unsupported text must reject") }
            catch is FileEditError { }
        }
        // Legitimate source names cannot collide with the session's internal work directory.
        let empty = root.appendingPathComponent("work"); try Data().write(to: empty)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
        do { _ = try await FileEditSession.open(.local(link)); XCTFail("Symbolic source must reject") }
        catch FileEditError.unsupportedText { }
        let session = try await FileEditSession.open(.local(empty))
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let snapshot = try await session.snapshot(); XCTAssertEqual(snapshot.text, "")
        try await session.close()
    }
    func testWatcherSeesAtomicReplacementAndSubsequentInPlaceSave() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("external.txt"); try Data("one".utf8).write(to: file)
        let replacement = expectation(description: "Atomic save observed"); replacement.assertForOverFulfill = false
        let inPlace = expectation(description: "In-place save observed after rebinding"); inPlace.assertForOverFulfill = false
        let watcher = try FileEditWatcher(file: file) {
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                if contents == "two" { replacement.fulfill() }
                if contents == "two three" { inPlace.fulfill() }
            }
        }
        defer { watcher.stop() }
        try Data("two".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [replacement], timeout: 2)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data(" three".utf8)); try handle.close()
        await fulfillment(of: [inPlace], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: file), Data("two three".utf8))
    }
}
