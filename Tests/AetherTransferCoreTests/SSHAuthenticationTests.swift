import XCTest
@testable import AetherTransferCore

final class SSHAuthenticationTests: XCTestCase {
    func testLegacyProfilesPreserveAuthenticationAndExplicitChoicesRoundTrip() throws {
        var profile = ServerProfile(host: "localhost", username: "fixture")
        XCTAssertEqual(profile.effectiveSSHAuthentication, .password)
        profile.privateKeyPath = "/fixture/key"
        XCTAssertEqual(profile.effectiveSSHAuthentication, .privateKey)
        let oldJSON = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("sshAuthentication"))
        XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: oldJSON).effectiveSSHAuthentication, .privateKey)
        for mode in SSHAuthentication.allCases {
            profile.sshAuthentication = mode
            XCTAssertEqual(try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile)), profile)
        }
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: oldJSON) as? [String: Any])
        value["sshAuthentication"] = "unknown-mechanism"
        XCTAssertThrowsError(try JSONDecoder().decode(ServerProfile.self, from: JSONSerialization.data(withJSONObject: value)))
    }

    func testCredentialsUseOnlyTheChosenMechanismAndAgentDoesNotReadKeychain() throws {
        let material = Credentials(password: "test-password", passphrase: "test-passphrase", accessKey: "test-access", secretKey: "test-secret", sessionToken: "test-token")
        var profile = ServerProfile(host: "localhost", username: "fixture", privateKeyPath: "/fixture/key")
        for mode in SSHAuthentication.allCases {
            profile.sshAuthentication = mode
            let selected = material.forProfile(profile)
            XCTAssertEqual(selected.password, mode == .password ? material.password : "")
            XCTAssertEqual(selected.passphrase, mode == .privateKey ? material.passphrase : "")
            XCTAssertTrue(selected.accessKey.isEmpty && selected.secretKey.isEmpty && selected.sessionToken.isEmpty)
            XCTAssertEqual(Credentials().needsPrompt(for: profile), mode == .password)
            XCTAssertFalse(material.needsPrompt(for: profile))
        }
        profile.sshAuthentication = .agent
        let agent = try CredentialStore.load(profile: profile)
        XCTAssertTrue(agent.password.isEmpty && agent.passphrase.isEmpty)
        profile.protocolKind = .ftp
        XCTAssertTrue(Credentials().needsPrompt(for: profile))
        XCTAssertEqual(material.forProfile(profile).password, material.password)
        XCTAssertTrue(material.forProfile(profile).passphrase.isEmpty)
        profile.protocolKind = .s3
        let cloud = material.forProfile(profile)
        XCTAssertTrue(cloud.password.isEmpty && cloud.passphrase.isEmpty)
        XCTAssertEqual(cloud.accessKey, material.accessKey)
        XCTAssertEqual(cloud.secretKey, material.secretKey)
        XCTAssertEqual(cloud.sessionToken, material.sessionToken)
    }

    func testImportDoesNotAuthorizeAgentOrPrivateKeys() throws {
        var profile = ServerProfile(host: "localhost", username: "fixture", privateKeyPath: "/fixture/key", trustedHostKey: "untrusted-import")
        for mode in [SSHAuthentication.agent, .privateKey] {
            profile.sshAuthentication = mode
            let imported = try XCTUnwrap(ProfileStore.importing(JSONEncoder().encode([profile]), into: []).first)
            XCTAssertNil(imported.sshAuthentication)
            XCTAssertEqual(imported.effectiveSSHAuthentication, .password)
            XCTAssertEqual(imported.privateKeyPath, "")
            XCTAssertNil(imported.trustedHostKey)
            XCTAssertNotEqual(imported.credentialID, profile.credentialID)
        }
    }

    func testAuthChangesInvalidateCredentialReadsWithoutChangingHostIdentity() throws {
        var profile = ServerProfile(host: "localhost", username: "fixture", sshAuthentication: .password)
        let endpoint = profile.connectionIdentity, password = profile.credentialIdentity
        profile.sshAuthentication = .agent
        XCTAssertEqual(profile.connectionIdentity, endpoint)
        XCTAssertNotEqual(profile.credentialIdentity, password)
        let agent = profile.credentialIdentity
        profile.privateKeyPath = "/fixture/unused-key"
        XCTAssertEqual(profile.credentialIdentity, agent)
        profile.sshAuthentication = .privateKey
        let key = profile.credentialIdentity
        profile.privateKeyPath = "/fixture/other-key"
        XCTAssertNotEqual(profile.credentialIdentity, key)
        for invalid in ["", "path\0tail"] {
            profile.privateKeyPath = invalid
            XCTAssertThrowsError(try profile.validate())
        }
        profile.sshAuthentication = .agent
        XCTAssertNoThrow(try profile.validate())
    }
}
