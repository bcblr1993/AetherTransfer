import Foundation
import Testing
@testable import AetherTransferCore

@Test func webdavPropfindXMLParsingAndFiltering() throws {
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/webdav/docs/</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>docs</D:displayname>
            <D:resourcetype><D:collection/></D:resourcetype>
          </D:prop>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/webdav/docs/architecture.pdf</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>architecture.pdf</D:displayname>
            <D:getcontentlength>204800</D:getcontentlength>
            <D:getlastmodified>Wed, 21 Oct 2026 07:28:00 GMT</D:getlastmodified>
            <D:resourcetype/>
          </D:prop>
        </D:propstat>
      </D:response>
      <D:response>
        <D:href>/webdav/docs/assets/</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>assets</D:displayname>
            <D:resourcetype><D:collection/></D:resourcetype>
          </D:prop>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """.data(using: .utf8)!

    let entries = try WebDAVClient.parsePropfindXML(xml, requestedPath: "/webdav/docs")
    #expect(entries.count == 2)
    #expect(entries[0].name == "assets")
    #expect(entries[0].isDirectory == true)
    #expect(entries[1].name == "architecture.pdf")
    #expect(entries[1].isDirectory == false)
    #expect(entries[1].size == 204_800)
    #expect(entries[1].modified != nil)
}

@Test func s3ListObjectsXMLAndSigV4PresignedURL() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>aether-bucket</Name>
      <Prefix>releases/</Prefix>
      <Delimiter>/</Delimiter>
      <Contents>
        <Key>releases/</Key>
        <LastModified>2026-10-21T06:00:00.000Z</LastModified>
        <Size>0</Size>
      </Contents>
      <Contents>
        <Key>releases/AetherTransfer-0.2.0.dmg</Key>
        <LastModified>2026-10-21T08:30:00.000Z</LastModified>
        <Size>4194304</Size>
      </Contents>
      <CommonPrefixes>
        <Prefix>releases/archive/</Prefix>
      </CommonPrefixes>
    </ListBucketResult>
    """.data(using: .utf8)!

    let entries = try S3Client.parseListObjectsXML(xml, requestedPath: "/releases")
    #expect(entries.count == 2)
    #expect(entries[0].name == "archive")
    #expect(entries[0].isDirectory == true)
    #expect(entries[1].name == "AetherTransfer-0.2.0.dmg")
    #expect(entries[1].isDirectory == false)
    #expect(entries[1].size == 4_194_304)

    let profile = ServerProfile(
        name: "Prod S3",
        host: "s3.amazonaws.com",
        port: 443,
        username: "AKIAIOSFODNN7EXAMPLE",
        protocolKind: .s3,
        s3Bucket: "aether-bucket",
        s3Region: "us-west-2",
        s3PathStyle: false
    )
    let client = S3Client(profile: profile, credentials: Credentials(password: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))
    let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
    let presigned = try client.presignedDownloadURL(for: "/releases/AetherTransfer-0.2.0.dmg", expiresIn: 3600, now: fixedDate)
    let urlStr = presigned.absoluteString
    #expect(urlStr.hasPrefix("https://aether-bucket.s3.us-west-2.amazonaws.com/releases/AetherTransfer-0.2.0.dmg?"))
    #expect(urlStr.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
    #expect(urlStr.contains("X-Amz-Expires=3600"))
    #expect(urlStr.contains("X-Amz-Signature="))
}

@Test func sshConfigParserAndKeyGeneration() throws {
    let sampleConfig = """
    # Production Servers
    Host prod-web
        HostName 10.20.30.40
        User deploy
        Port 2222
        IdentityFile ~/.ssh/id_ed25519_prod

    Host *.internal
        User admin

    Host staging-api
        HostName staging.example.com
        User ubuntu
    """
    let parsed = SSHConfigParser.parse(sampleConfig)
    #expect(parsed.count == 2)
    #expect(parsed[0].alias == "prod-web")
    #expect(parsed[0].hostName == "10.20.30.40")
    #expect(parsed[0].user == "deploy")
    #expect(parsed[0].port == 2222)
    #expect(parsed[0].identityFile?.hasSuffix("/.ssh/id_ed25519_prod") == true)

    let profile = parsed[0].toServerProfile()
    #expect(profile.host == "10.20.30.40")
    #expect(profile.port == 2222)
    #expect(profile.username == "deploy")
    #expect(profile.protocolKind == .sftp)

    // Test Ed25519 key generation in isolated temporary folder
    let tempSSHDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-ssh-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempSSHDir) }

    let keyItem = try SSHKeyManager.generateKeyPair(
        name: "test_ed25519",
        algorithm: .ed25519,
        comment: "unit-test@aether",
        passphrase: "",
        in: tempSSHDir
    )
    #expect(keyItem.name == "test_ed25519")
    #expect(keyItem.keyType == "ssh-ed25519")
    #expect(keyItem.publicKeyContent.contains("unit-test@aether"))

    let listed = SSHKeyManager.listKeys(in: tempSSHDir)
    #expect(listed.count == 1)
    #expect(listed[0].name == "test_ed25519")
}

@Test func externalEditorAutoUploadSessionTrackingAndClipboard() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-ext-edit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("nginx.conf")
    try "worker_processes 1;\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let manager = ExternalEditorManager(stagingRootDirectory: tempDir)
    let profile = ServerProfile(name: "Gateway", host: "10.0.0.1", username: "root")
    _ = try manager.registerSession(entryName: "nginx.conf", remotePath: "/etc/nginx/nginx.conf", localFileURL: fileURL, profile: profile)

    // Unchanged file should not trigger upload
    #expect(manager.drainModifiedSessions().isEmpty)

    // Modify file on disk (simulating external editor save)
    try "worker_processes auto;\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let modified = manager.drainModifiedSessions()
    #expect(modified.count == 1)
    #expect(modified[0].remotePath == "/etc/nginx/nginx.conf")
    #expect(modified[0].uploadCount == 1)

    // Subsequent poll without new edits should be empty
    #expect(manager.drainModifiedSessions().isEmpty)

    // Duplicate name formatting
    let dup1 = FileClipboard.duplicateName(for: "index.html", existingNames: ["index.html"])
    #expect(dup1.hasSuffix(".html"))
    #expect(dup1 != "index.html")
}

@Test func syncIgnoreFilterAndEncryptedProfileSyncRoundTrip() throws {
    let patterns = SyncIgnoreFilter.parsePatterns(".DS_Store, .git, node_modules, *.log")
    #expect(SyncIgnoreFilter.shouldIgnore(relativePath: ".DS_Store", patterns: patterns) == true)
    #expect(SyncIgnoreFilter.shouldIgnore(relativePath: "sub/.DS_Store", patterns: patterns) == true)
    #expect(SyncIgnoreFilter.shouldIgnore(relativePath: ".git/config", patterns: patterns) == true)
    #expect(SyncIgnoreFilter.shouldIgnore(relativePath: "web/node_modules/pkg/index.js", patterns: patterns) == true)
    #expect(SyncIgnoreFilter.shouldIgnore(relativePath: "logs/debug.log", patterns: patterns) == true)
    #expect(SyncIgnoreFilter.shouldIgnore(relativePath: "src/main.swift", patterns: patterns) == false)

    // Zero-knowledge encrypted vault round-trip
    let originalProfiles = [
        ServerProfile(name: "Prod SFTP", group: "Cloud", host: "prod.example.com", port: 22, username: "ubuntu", protocolKind: .sftp, useSSHAgent: true),
        ServerProfile(name: "Assets R2", group: "CDN", host: "acc.r2.cloudflarestorage.com", port: 443, username: "AKIA123", protocolKind: .s3, s3Bucket: "static-assets", s3Region: "auto")
    ]
    let vaultData = try EncryptedProfileSync.encrypt(profiles: originalProfiles, masterPassword: "Correct-Horse-Battery-Staple-99!")
    let decrypted = try EncryptedProfileSync.decrypt(vaultData: vaultData, masterPassword: "Correct-Horse-Battery-Staple-99!")
    #expect(decrypted.count == 2)
    #expect(decrypted[0].name == "Prod SFTP")
    #expect(decrypted[0].useSSHAgent == true)
    #expect(decrypted[1].protocolKind == .s3)
    #expect(decrypted[1].s3Bucket == "static-assets")

    // Wrong password must fail authentication tag verification
    #expect(throws: EncryptedProfileSyncError.self) {
        _ = try EncryptedProfileSync.decrypt(vaultData: vaultData, masterPassword: "Wrong-Password")
    }
}
