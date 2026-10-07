import Foundation
import XCTest
@testable import AetherTransferCore

@MainActor final class ResumeTests: XCTestCase {
    func testAtomicLocalCommitRejectsConflictsAndRetainsPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), staging = root.appendingPathComponent("staging")
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try Data("replacement".utf8).write(to: staging)
        do { try await LocalFileCommit.commit(staging, to: target, overwrite: false); XCTFail("Existing target must survive") }
        catch TransferError.conflict { }
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        for index in 0..<100 {
            let data = Data(repeating: UInt8(index), count: 64 * 1024)
            try data.write(to: staging)
            try await LocalFileCommit.commit(staging, to: target, overwrite: true)
            XCTAssertEqual(try Data(contentsOf: target), data)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let link = root.appendingPathComponent("dangling-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent"))
        try Data("replacement".utf8).write(to: staging)
        do { try await LocalFileCommit.commit(staging, to: link, overwrite: true); XCTFail("Symlink must not be replaced") }
        catch TransferError.conflict { }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.appendingPathComponent("absent").path)
    }
    func testManifestHasNoCredentialsTrustOrPrivateKeyAndRejectsInvalidJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-resume-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ServerProfile(host: "fixture.invalid", username: "test", privateKeyPath: "/private-key-must-not-persist", trustedHostKey: "trust-must-not-persist")
        let task = try ResumableTransfer(direction: .download, local: root.appendingPathComponent("file"), remote: "/file", profile: profile)
        let record = await task.checkpoint(), data = try JSONEncoder().encode(record)
        let text = String(decoding: data, as: UTF8.self)
        for word in ["password", "passphrase", "trustedHostKey", "privateKeyPath", "must-not-persist"] { XCTAssertFalse(text.contains(word)) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["version"] = 99
        let file = root.appendingPathComponent(record.id.uuidString + ".json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let store = ResumeTransferStore(directory: root)
        do { _ = try await store.records(); XCTFail("Unknown manifest version must reject") }
        catch ResumeTransferError.invalidCheckpoint { }
        try FileManager.default.removeItem(at: file)
        let source = root.appendingPathComponent("source"); try data.write(to: source)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        do { _ = try await store.records(); XCTFail("Symlink journal must reject") }
        catch ResumeTransferError.invalidCheckpoint { }
    }
}
