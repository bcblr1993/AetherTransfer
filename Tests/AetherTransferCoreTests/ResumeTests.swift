import Foundation
import XCTest
@testable import AetherTransferCore

@MainActor final class ResumeTests: XCTestCase {
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
