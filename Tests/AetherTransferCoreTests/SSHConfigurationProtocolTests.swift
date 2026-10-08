import Foundation
import XCTest
@testable import AetherTransferCore

extension ProtocolIntegrationTests {
    private func configFixture(_ text: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-config-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: home.appendingPathComponent(".ssh/config"))
        return home
    }
    private func configuredProfile() -> ServerProfile {
        var source = ServerProfile(host: "isolated-fixture", sshAuthentication: .password)
        source.sshConfiguration = true
        return source
    }
    private func configured(_ source: ServerProfile, home: URL) throws -> SSHPreparedConnection {
        try SSHConnectionPreparation.resolve(source, environment: .init(home: home, systemFile: nil, localUsername: "local-fixture", variables: [:]))
    }

    func testSSHConfiguredAliasRequiresTrustAndFrozenEndpointRoundTrips() async throws {
        let base = try client(.sftp)
        let home = try configFixture("Host isolated-fixture\nHostName 127.0.0.1\nUser fixture\nPort \(base.profile.port)\n")
        defer { try? FileManager.default.removeItem(at: home) }
        let prepared = try configured(configuredProfile(), home: home)
        let secrets = Credentials(password: "fixture-only")
        do {
            _ = try await RemoteClient(profile: prepared.profile, credentials: secrets).list("/")
            XCTFail("A config alias does not authorize the resolved host")
        } catch TransferError.hostKeyRequired(let key, let changed) {
            XCTAssertFalse(changed); XCTAssertEqual(key, ProcessInfo.processInfo.environment["AT_SFTP_KEY"])
        }
        let trusted = prepared.trusting(try XCTUnwrap(ProcessInfo.processInfo.environment["AT_SFTP_KEY"]))
        // Configuration changes after the fingerprint is shown must not change
        // the request that the user approved.
        try Data("Host *\nHostName changed.invalid\nUser other\nPort 1\n".utf8).write(to: home.appendingPathComponent(".ssh/config"))
        let remote = RemoteClient(profile: trusted.profile, credentials: secrets)
        let data = Data("configured 中文 空格\n".utf8), source = home.appendingPathComponent("source"), destination = home.appendingPathComponent("download")
        try data.write(to: source)
        let path = "/configured-\(UUID().uuidString) 中文 空格.txt"
        try await remote.upload(source, to: path)
        try await remote.download(path, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data); XCTAssertEqual(try Data(contentsOf: source), data)
        try await remote.remove(path, directory: false)
        let changed = try configured(trusted.source, home: home)
        XCTAssertNil(changed.profile.trustedHostKey)
        XCTAssertNotEqual(ResumeEndpoint(remote.profile), ResumeEndpoint(changed.profile))
    }

    func testSSHConfiguredIdentityFileUsesOnlySelectedEncryptedKey() async throws {
        let base = try client(.sftp)
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["AT_SFTP_PRIVATE_KEY"])
        let home = try configFixture("Host *\nHostName 127.0.0.1\nUser fixture\nPort \(base.profile.port)\nIdentityFile /fixture/missing\nIdentityFile \"\(key)\"\n")
        defer { try? FileManager.default.removeItem(at: home) }
        var source = configuredProfile(); source.sshAuthentication = .privateKey
        let prepared = try configured(source, home: home).trusting(try XCTUnwrap(ProcessInfo.processInfo.environment["AT_SFTP_KEY"]))
        let remote = RemoteClient(profile: prepared.profile, credentials: Credentials(password: "incorrect", passphrase: "fixture-passphrase"))
        let listing = try await remote.list("/")
        XCTAssertTrue(listing.contains { $0.name == "中文 seed.txt" }); XCTAssertTrue(remote.credentials.password.isEmpty)
        do {
            _ = try await RemoteClient(profile: prepared.profile, credentials: Credentials(password: "fixture-only", passphrase: "incorrect")).list("/")
            XCTFail("Configuration must not broaden explicit key authentication")
        } catch TransferError.remote { }
    }

    func testSSHConfiguredEndpointStillRejectsChangedHostKey() async throws {
        let base = try client(.sftp)
        let home = try configFixture("Host *\nHostName 127.0.0.1\nUser fixture\nPort \(base.profile.port)\n")
        defer { try? FileManager.default.removeItem(at: home) }
        let prepared = try configured(configuredProfile(), home: home).trusting(Data("incorrect host key".utf8).base64EncodedString())
        do {
            _ = try await RemoteClient(profile: prepared.profile, credentials: Credentials(password: "fixture-only")).list("/")
            XCTFail("Configuration must preserve changed-key rejection")
        } catch TransferError.hostKeyRequired(_, let changed) { XCTAssertTrue(changed) }
    }
}
