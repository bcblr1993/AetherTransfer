import Foundation
import XCTest
@testable import AetherTransferCore

@MainActor final class ResumeTests: XCTestCase {

    func testAtomicLocalCommitRejectsConflictsAndRetainsPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target")
        let staging = root.appendingPathComponent("staging")

        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try Data("replacement".utf8).write(to: staging)

        // Conflict check: overwrite is false
        do {
            try await LocalFileCommit.commit(staging, to: target, overwrite: false)
            XCTFail("Existing target must survive when overwrite is false")
        } catch TransferError.conflict {
            // Success
        }

        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        // Overwrite is true: commits replacement atomically
        let data = Data(repeating: 42, count: 64 * 1024)
        try data.write(to: staging)
        try await LocalFileCommit.commit(staging, to: target, overwrite: true)

        XCTAssertEqual(try Data(contentsOf: target), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        // Permissions preserved
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o640)

        // Refuse to overwrite dangling symlink
        let link = root.appendingPathComponent("dangling-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent"))
        try Data("replacement".utf8).write(to: staging)
        do {
            try await LocalFileCommit.commit(staging, to: link, overwrite: true)
            XCTFail("Symlink must not be replaced")
        } catch TransferError.conflict {
            // Expected
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.appendingPathComponent("absent").path)
    }

    func testManifestHasNoCredentialsTrustOrPrivateKeyAndRejectsInvalidJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = ServerProfile(
            host: "fixture.invalid",
            username: "test",
            privateKeyPath: "/private-key-must-not-persist",
            trustedHostKey: "trust-must-not-persist"
        )
        let store = ResumeTransferStore(directory: root)
        let record = ResumeTransferRecord(
            id: UUID(),
            direction: .download,
            endpoint: ResumeEndpoint(profile),
            localPath: root.appendingPathComponent("file.bin").path,
            remotePath: "/file.bin",
            overwrite: false,
            created: Date(),
            expectedSize: 1024,
            retainedBytes: 512
        )

        try await store.save(record)
        let loaded = try await store.records()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, record.id)
        XCTAssertEqual(loaded[0].expectedSize, 1024)
        XCTAssertEqual(loaded[0].retainedBytes, 512)

        // Verify JSON contains NO secrets or credentials
        let jsonURL = root.appendingPathComponent(record.id.uuidString + ".json")
        let data = try Data(contentsOf: jsonURL)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["password", "passphrase", "trustedHostKey", "privateKeyPath", "must-not-persist"] {
            XCTAssertFalse(text.contains(forbidden), "JSON must not contain secret or sensitive field: \(forbidden)")
        }

        // Corrupt journal version rejection
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["version"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: jsonURL)
        do {
            _ = try await store.records()
            XCTFail("Unknown manifest version must reject")
        } catch ResumeTransferError.invalidCheckpoint {
            // Expected
        }

        // Symlink rejection
        try FileManager.default.removeItem(at: jsonURL)
        let source = root.appendingPathComponent("source")
        try data.write(to: source)
        try FileManager.default.createSymbolicLink(at: jsonURL, withDestinationURL: source)
        do {
            _ = try await store.records()
            XCTFail("Symlink journal must reject")
        } catch ResumeTransferError.invalidCheckpoint {
            // Expected
        }
    }

    func testFingerprintValidationAndSourceChangedDetection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("source.bin")
        let content = Data("test data for fingerprinting 1234567890".utf8)
        try content.write(to: file)

        let fp1 = try await ResumeIO.fingerprint(file)
        XCTAssertEqual(fp1.size, Int64(content.count))
        XCTAssertEqual(fp1.digest.count, 32)

        let fp2 = try await ResumeIO.fingerprint(file)
        XCTAssertEqual(fp1, fp2)

        // Modify file
        try Data("modified content".utf8).write(to: file)
        let fp3 = try await ResumeIO.fingerprint(file)
        XCTAssertNotEqual(fp1.digest, fp3.digest)
    }

    func testRecordValidationRejectsTamperedCheckpoints() {
        let endpoint = ResumeEndpoint(host: "example.com", port: 22, username: "user", protocolKind: .sftp)

        // retainedBytes > expectedSize must fail
        var record = ResumeTransferRecord(
            id: UUID(),
            direction: .download,
            endpoint: endpoint,
            localPath: "/tmp/local.bin",
            remotePath: "/remote.bin",
            overwrite: false,
            created: Date(),
            expectedSize: 100,
            retainedBytes: 200
        )
        XCTAssertThrowsError(try record.validate())

        // Non-absolute path must fail
        record = ResumeTransferRecord(
            id: UUID(),
            direction: .download,
            endpoint: endpoint,
            localPath: "relative/path.bin",
            remotePath: "/remote.bin",
            overwrite: false,
            created: Date(),
            expectedSize: 100,
            retainedBytes: 50
        )
        XCTAssertThrowsError(try record.validate())

        // Invalid partial digest length must fail
        record = ResumeTransferRecord(
            id: UUID(),
            direction: .download,
            endpoint: endpoint,
            localPath: "/tmp/local.bin",
            remotePath: "/remote.bin",
            overwrite: false,
            created: Date(),
            expectedSize: 100,
            retainedBytes: 50,
            partialDigest: Data([1, 2, 3]) // not 32 bytes
        )
        XCTAssertThrowsError(try record.validate())
    }

    func testResumeStoreRemovalAndMultiRecordSorting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-store-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResumeTransferStore(directory: root)
        let endpoint = ResumeEndpoint(host: "example.com", port: 22, username: "user", protocolKind: .sftp)

        let id1 = UUID(), id2 = UUID()
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        let r1 = ResumeTransferRecord(id: id1, direction: .download, endpoint: endpoint, localPath: "/tmp/a.bin", remotePath: "/a.bin", overwrite: false, created: date1, expectedSize: 10, retainedBytes: 5)
        let r2 = ResumeTransferRecord(id: id2, direction: .upload, endpoint: endpoint, localPath: "/tmp/b.bin", remotePath: "/b.bin", overwrite: false, created: date2, expectedSize: 20, retainedBytes: 10)

        try await store.save(r2)
        try await store.save(r1)

        let list = try await store.records()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].id, id1) // Sorted by created ascending
        XCTAssertEqual(list[1].id, id2)

        try await store.remove(id1)
        let listAfter = try await store.records()
        XCTAssertEqual(listAfter.count, 1)
        XCTAssertEqual(listAfter[0].id, id2)
    }
}
