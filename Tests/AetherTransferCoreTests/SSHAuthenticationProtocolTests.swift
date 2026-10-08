import CryptoKit
import Foundation
import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    func testSSHAgentCancellationDuringAuthenticationIsBounded() async throws {
        let base = try client(.sftp)
        var profile = base.profile; profile.sshAuthentication = .agent
        profile.username = "agent-slow-\(UUID().uuidString)"
        let hash = SHA256.hash(data: Data(profile.username.utf8)).map { String(format: "%02x", $0) }.joined()
        let markers = try XCTUnwrap(ProcessInfo.processInfo.environment["AT_SFTP_AUTH_MARKERS"])
        let marker = URL(fileURLWithPath: markers).appendingPathComponent(hash)
        let remote = RemoteClient(profile: profile, credentials: Credentials())
        let operation = Task { try await remote.list("/") }
        defer { operation.cancel() }
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Server must observe agent authentication before cancellation")
        let cancelled = clock.now
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled authentication must not publish a listing") }
        catch is CancellationError { }
        XCTAssertLessThan(clock.now - cancelled, .seconds(2))
    }

    func testSSHAgentRoundTripUsesLoadedKeyAndPreservesFiles() async throws {
        let base = try client(.sftp)
        var profile = base.profile
        profile.sshAuthentication = .agent
        profile.privateKeyPath = "/nonexistent/unused-private-key"
        let remote = RemoteClient(profile: profile, credentials: Credentials(password: "incorrect", passphrase: "incorrect"))
        XCTAssertTrue(remote.credentials.password.isEmpty && remote.credentials.passphrase.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        let source = directory.appendingPathComponent("source"), downloaded = directory.appendingPathComponent("download")
        try data.write(to: source)
        let path = "/agent-\(UUID().uuidString) 中文 空格"
        try await remote.mkdir(path)
        let target = try RemotePath.join(path, "文件 #.txt")
        try await remote.upload(source, to: target)
        let entries = try await remote.list(path)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.name, "文件 #.txt"); XCTAssertEqual(entry.size, Int64(data.count))
        try await remote.download(target, to: downloaded)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: downloaded)), SHA256.hash(data: data))
        XCTAssertEqual(try Data(contentsOf: source), data)
        try await remote.rename(target, to: try RemotePath.join(path, "renamed.txt"))
        try await remote.remove(try RemotePath.join(path, "renamed.txt"), directory: false)
        try await remote.remove(path, directory: true)
    }

    func testSSHAgentSelectionNeverFallsBackToPasswordOrKeyFile() async throws {
        let base = try client(.sftp)
        var profile = base.profile
        profile.username = "password-only"; profile.sshAuthentication = .agent
        profile.privateKeyPath = try XCTUnwrap(ProcessInfo.processInfo.environment["AT_SFTP_PRIVATE_KEY"])
        let validSecrets = Credentials(password: "fixture-only", passphrase: "fixture-passphrase")
        do {
            _ = try await RemoteClient(profile: profile, credentials: validSecrets).list("/")
            XCTFail("Agent mode must not use other supplied authentication methods")
        } catch TransferError.remote { }
        profile.sshAuthentication = .password
        let listing = try await RemoteClient(profile: profile, credentials: validSecrets).list("/")
        XCTAssertTrue(listing.contains { $0.name == "中文 seed.txt" })
    }

    func testSSHPasswordAndKeyFileModesDoNotUseTheAvailableAgent() async throws {
        let base = try client(.sftp)
        var profile = base.profile
        profile.privateKeyPath = try XCTUnwrap(ProcessInfo.processInfo.environment["AT_SFTP_PRIVATE_KEY"])
        profile.sshAuthentication = .password
        do {
            _ = try await RemoteClient(profile: profile, credentials: Credentials(passphrase: "fixture-passphrase")).list("/")
            XCTFail("Password mode must not use a valid loaded agent key or key file")
        } catch TransferError.remote { }
        profile.sshAuthentication = .privateKey
        do {
            _ = try await RemoteClient(profile: profile, credentials: Credentials(password: "fixture-only", passphrase: "incorrect")).list("/")
            XCTFail("An invalid key-file passphrase must not fall back to agent or password")
        } catch TransferError.remote { }
        profile.username = "password-only"
        do {
            _ = try await RemoteClient(profile: profile, credentials: Credentials(password: "fixture-only", passphrase: "fixture-passphrase")).list("/")
            XCTFail("Key-file mode must not fall back to a valid password")
        } catch TransferError.remote { }
    }

    func testSSHAgentStillRequiresPinnedHostKeys() async throws {
        let base = try client(.sftp, trusted: false)
        var profile = base.profile; profile.sshAuthentication = .agent
        do {
            _ = try await RemoteClient(profile: profile, credentials: Credentials()).list("/")
            XCTFail("Agent authentication must not trust a new host")
        } catch TransferError.hostKeyRequired(let key, let changed) {
            XCTAssertFalse(changed); XCTAssertEqual(key, ProcessInfo.processInfo.environment["AT_SFTP_KEY"])
        }
        profile.trustedHostKey = Data("changed host".utf8).base64EncodedString()
        do {
            _ = try await RemoteClient(profile: profile, credentials: Credentials()).list("/")
            XCTFail("Agent authentication must reject a changed host key")
        } catch TransferError.hostKeyRequired(_, let changed) { XCTAssertTrue(changed) }
    }

    func testUnavailableSSHAgentNeverFallsBack() async throws {
        let base = try client(.sftp)
        guard ProcessInfo.processInfo.environment["AT_SSH_AGENT_STOPPED"] == "1" else {
            throw XCTSkip("Fixture reruns this case after stopping its owned SSH agent")
        }
        let socket = try XCTUnwrap(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        var profile = base.profile; profile.sshAuthentication = .agent
        profile.privateKeyPath = try XCTUnwrap(ProcessInfo.processInfo.environment["AT_SFTP_PRIVATE_KEY"])
        do {
            _ = try await RemoteClient(profile: profile, credentials: Credentials(password: "fixture-only", passphrase: "fixture-passphrase")).list("/")
            XCTFail("A stopped agent must not use a valid password or private key")
        } catch TransferError.remote { }
    }
}
