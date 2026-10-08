import Darwin
import XCTest
@testable import AetherTransferCore

final class SSHConfigurationTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, _ home: URL, _ file: String = ".ssh/config") throws {
        let url = home.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func profile(_ host: String = "fixture-alias", mode: SSHAuthentication = .password) -> ServerProfile {
        var value = ServerProfile(host: host, sshAuthentication: mode)
        value.sshConfiguration = true
        return value
    }
    private func resolve(_ value: ServerProfile, _ home: URL, system: URL? = nil) throws -> SSHPreparedConnection {
        try SSHConnectionPreparation.resolve(value, environment: .init(home: home, systemFile: system, localUsername: "local-fixture", variables: ["FIXTURE_HOME": home.path]))
    }

    func testFirstValueWinsWithHostPatternsNegationQuotesAndEquals() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("""
        Host fixture-* !fixture-excluded
          HOSTNAME = 127.0.0.1 # comment
          User="configured-user"
          Port 2201
        Host *
          HostName fallback.invalid
          User fallback-user
          Port 2202
        """, home)
        let included = try resolve(profile(), home).profile
        XCTAssertEqual(included.host, "127.0.0.1"); XCTAssertEqual(included.username, "configured-user"); XCTAssertEqual(included.port, 2201)
        let excluded = try resolve(profile("fixture-excluded"), home).profile
        XCTAssertEqual(excluded.host, "fallback.invalid"); XCTAssertEqual(excluded.username, "fallback-user"); XCTAssertEqual(excluded.port, 2202)
        XCTAssertNil(included.sshConfiguration)
        XCTAssertNoThrow(try included.url(path: "/"))
    }

    func testIncludesAreConditionalLexicalAndUseSshRootWithSystemFallback() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("Host other\n Include never-read\nHost fixture-*\n Include config.d/*.conf\nPort 2209\n", home)
        try write("Port 2208\nUser second\nHostName 127.0.0.2\n", home, ".ssh/config.d/20.conf")
        try write("User first\nInclude nested\nHost other\n", home, ".ssh/config.d/10.conf")
        try write("HostName 127.0.0.1\n", home, ".ssh/nested")
        try write("Host *\nUser system\nPort 2210\n", home, "system/ssh_config")
        let prepared = try resolve(profile(), home, system: home.appendingPathComponent("system/ssh_config"))
        XCTAssertEqual(prepared.profile.username, "first"); XCTAssertEqual(prepared.profile.host, "127.0.0.1")
        XCTAssertEqual(prepared.profile.port, 2208)
    }

    func testExplicitUsernameAndPortOverrideWithoutReadingWhenDisabled() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("Host *\nHostName 127.0.0.1\nUser configured\nPort 2201\n", home)
        var value = profile(); value.username = "explicit"; value.port = 2203; value.sshUseConfiguredPort = false
        XCTAssertEqual(try resolve(value, home).profile.username, "explicit")
        XCTAssertEqual(try resolve(value, home).profile.port, 2203)
        value.sshConfiguration = nil
        try write("Match exec \"must never execute\"\n", home)
        XCTAssertEqual(try resolve(value, home).profile.host, value.host)
        XCTAssertThrowsError(try profile().url(path: "/"))
    }

    func testAbsentConfigUsesLocalUsernameAndDefaultPortAndNotHiddenDraftPort() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        var value = profile(); value.port = 0
        let resolved = try resolve(value, home).profile
        XCTAssertEqual(resolved.username, "local-fixture"); XCTAssertEqual(resolved.port, 22)
        value.sshUseConfiguredPort = false
        XCTAssertThrowsError(try resolve(value, home))
    }

    func testIdentityFilesAccumulateAndExpandAfterFinalEndpointIsKnown() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("""
        Host fixture-*
        IdentityFile ~/.ssh/missing
        IdentityFile "${FIXTURE_HOME}/.ssh/%h-%r-%p private"
        HostName 127.0.0.1
        User configured
        Port 2201
        """, home)
        let path = ".ssh/127.0.0.1-configured-2201 private"
        try write("fixture only", home, path)
        let key = try resolve(profile(mode: .privateKey), home).profile
        XCTAssertEqual(key.privateKeyPath, home.appendingPathComponent(path).path)
        var explicit = profile(mode: .privateKey); explicit.privateKeyPath = "~/.ssh/explicit"
        try write("other fixture", home, ".ssh/explicit")
        XCTAssertEqual(try resolve(explicit, home).profile.privateKeyPath, home.appendingPathComponent(".ssh/explicit").path)
        explicit.privateKeyPath = "~/.ssh/missing"
        XCTAssertThrowsError(try resolve(explicit, home))
    }

    func testUnsupportedTransportAndMatchFailWithoutExecutingCommands() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let marker = home.appendingPathComponent("command-was-run")
        for line in ["Match exec \"touch \(marker.path)\"", "ProxyCommand \"touch \(marker.path)\"", "ProxyJump fixture-hop", "IdentityAgent /fixture/socket", "StrictHostKeyChecking no", "CertificateFile /fixture/cert"] {
            try write("Host *\n\(line)\n", home)
            XCTAssertThrowsError(try resolve(profile(), home)) { XCTAssertTrue($0 is SSHConfigurationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
        try write("Host unrelated\nProxyJump unused\nHost fixture-*\nUser configured\n", home)
        XCTAssertEqual(try resolve(profile(), home).profile.username, "configured")
        let secret = String(repeating: "private-fixture-material", count: 4)
        try write("\(secret) credential-fixture\n", home)
        XCTAssertThrowsError(try resolve(profile(), home)) {
            XCTAssertFalse($0.localizedDescription.contains(secret)); XCTAssertFalse($0.localizedDescription.contains("credential-fixture"))
        }
    }

    func testSelectedAuthRespectsDisabledMethodsAndCannotBroadenAgentIdentityPolicy() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        for text in ["PasswordAuthentication no", "PreferredAuthentications publickey"] {
            try write(text + "\n", home)
            XCTAssertThrowsError(try resolve(profile(), home))
        }
        for text in ["PubkeyAuthentication no", "IdentityAgent none", "IdentitiesOnly yes", "PreferredAuthentications password"] {
            try write(text + "\n", home)
            XCTAssertThrowsError(try resolve(profile(mode: .agent), home))
        }
    }

    func testPinsFollowResolvedEndpointAndApprovalUsesFrozenSnapshot() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("Host *\nHostName 127.0.0.1\nUser configured\n", home)
        var value = profile(); value.trustedHostKey = "legacy-pin"
        let prepared = try resolve(value, home)
        XCTAssertNil(prepared.profile.trustedHostKey)
        let trusted = prepared.trusting("approved-pin")
        XCTAssertEqual(trusted.source.host, "fixture-alias")
        XCTAssertEqual(trusted.source.sshTrustedEndpoint, SSHHostIdentity(profile: prepared.profile))
        XCTAssertEqual(try resolve(trusted.source, home).profile.trustedHostKey, "approved-pin")
        try write("Host *\nHostName 127.0.0.2\nUser configured\n", home)
        XCTAssertNil(try resolve(trusted.source, home).profile.trustedHostKey)
        XCTAssertEqual(trusted.profile.host, "127.0.0.1"); XCTAssertEqual(trusted.profile.trustedHostKey, "approved-pin")
        value = ServerProfile(host: "127.0.0.1", username: "configured", trustedHostKey: "literal-pin"); value.sshConfiguration = true
        try write("Host *\nHostName 127.0.0.1\nUser configured\n", home)
        XCTAssertEqual(try resolve(value, home).profile.trustedHostKey, "literal-pin")
        var manual = trusted.source; manual.sshConfiguration = nil; manual.username = "configured"
        XCTAssertNil(try resolve(manual, home).profile.trustedHostKey)
    }

    func testMalformedOversizedRecursiveAndNonRegularConfigsFailWithinBounds() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        for text in ["User \"unterminated\n", "User==unexpected\n", "Port not-a-port\n", "User %unsupported\nHostName %z\n", "HostName ${MISSING}\n", "Include config\n", String(repeating: "#", count: 256 * 1024 + 1)] {
            try write(text, home)
            XCTAssertThrowsError(try resolve(profile(), home))
        }
        let file = home.appendingPathComponent(".ssh/config")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let start = ContinuousClock.now
        XCTAssertThrowsError(try resolve(profile(), home))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testWritableConfigIsRejectedAndSavedCredentialsRebindWithoutRereading() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("Host *\nHostName 127.0.0.1\nUser configured\n", home)
        let source = profile(), prepared = try resolve(source, home)
        let file = home.appendingPathComponent(".ssh/config")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        XCTAssertThrowsError(try resolve(source, home))
        var saved = source; saved.credentialID = UUID(); saved.name = "Saved alias"
        let bound = try prepared.withSavedSource(saved)
        XCTAssertEqual(bound.profile.host, "127.0.0.1"); XCTAssertEqual(bound.profile.credentialID, saved.credentialID)
        XCTAssertEqual(bound.source.host, source.host); XCTAssertEqual(bound.profile.name, saved.name)
        saved.host = "different-alias"
        XCTAssertThrowsError(try prepared.withSavedSource(saved))
    }

    func testIncludeAndIdentityLimitsRejectRatherThanTruncate() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("Include parts/*.conf\n", home)
        for index in 0..<33 { try write("User fixture\n", home, ".ssh/parts/\(index).conf") }
        XCTAssertThrowsError(try resolve(profile(), home))
        try write((0..<33).map { "IdentityFile /fixture/key-\($0)" }.joined(separator: "\n"), home)
        XCTAssertThrowsError(try resolve(profile(mode: .privateKey), home))
    }

    func testImportRemovesConfigAuthorityEndpointPinAndKeyBinding() throws {
        var value = profile(); value.username = "fixture"; value.trustedHostKey = "imported-pin"
        value.sshTrustedEndpoint = SSHHostIdentity(profile: value); value.sshUseConfiguredPort = true
        let data = try JSONEncoder().encode([value])
        let imported = try XCTUnwrap(ProfileStore.importing(data, into: []).first)
        XCTAssertNil(imported.sshConfiguration); XCTAssertNil(imported.sshUseConfiguredPort); XCTAssertNil(imported.sshTrustedEndpoint)
        XCTAssertNil(imported.trustedHostKey); XCTAssertNotEqual(imported.credentialID, value.credentialID)
        XCTAssertEqual(try JSONDecoder().decode([ServerProfile].self, from: data).first, value)
    }

    func testPreparedEndpointTrustPersistsAgainstOriginalAliasIdentity() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        try write("Host *\nHostName 127.0.0.1\nUser fixture\n", home)
        let source = profile(), trusted = try resolve(source, home).trusting("approved-pin")
        let store = ProfileStore(file: home.appendingPathComponent("profiles.json"))
        try store.save([source])
        let repository = ProfileRepository(store: store)
        let saved = try await repository.trust(trusted.source)
        XCTAssertEqual(saved.first?.host, source.host)
        XCTAssertEqual(saved.first?.trustedHostKey, "approved-pin")
        XCTAssertEqual(saved.first?.sshTrustedEndpoint, trusted.source.sshTrustedEndpoint)
        var changed = trusted.source; changed.username = "another"
        changed.trustedHostKey = "must-not-save"
        _ = try await repository.trust(changed)
        XCTAssertEqual(try store.load().first?.trustedHostKey, "approved-pin")
    }

    func testCancelledPreparationDoesNotPublishAnEndpoint() async throws {
        let operation = Task { try await SSHConnectionPreparation.prepare(ServerProfile(host: "127.0.0.1", username: "fixture")) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled preparation must not publish a profile") }
        catch is CancellationError { }
    }
}
