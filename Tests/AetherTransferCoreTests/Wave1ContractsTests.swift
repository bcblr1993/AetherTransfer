import Foundation
import Testing
@testable import AetherTransferCore

@Test func transferProtocolMetadataAndBackwardCompatibleDecoding() throws {
    #expect(TransferProtocol.sftp.defaultPort == 22)
    #expect(TransferProtocol.ftp.defaultPort == 21)
    #expect(TransferProtocol.ftps.defaultPort == 990)
    #expect(TransferProtocol.ftpsExplicit.defaultPort == 21)
    #expect(TransferProtocol.webdav.defaultPort == 80)
    #expect(TransferProtocol.webdavs.defaultPort == 443)
    #expect(TransferProtocol.s3.defaultPort == 443)
    #expect(TransferProtocol.b2.defaultPort == 443)
    #expect(TransferProtocol.azureBlob.defaultPort == 443)
    #expect(TransferProtocol.openstackSwift.defaultPort == 443)

    #expect(TransferProtocol.ftpsExplicit.httpScheme == "ftp")
    #expect(TransferProtocol.b2.httpScheme == "https")
    #expect(TransferProtocol.azureBlob.httpScheme == "https")
    #expect(TransferProtocol.openstackSwift.httpScheme == "https")

    let json = #"["sftp","ftp","ftps","ftpsExplicit","ftps_explicit","webdav","webdavs","s3","b2","azureBlob","azure_blob","openstackSwift","swift"]"#
    let decoded = try JSONDecoder().decode([TransferProtocol].self, from: Data(json.utf8))
    #expect(decoded == [
        .sftp, .ftp, .ftps, .ftpsExplicit, .ftpsExplicit, .webdav, .webdavs,
        .s3, .b2, .azureBlob, .azureBlob, .openstackSwift, .openstackSwift
    ])
}

@Test func serverProfileBackwardCompatibleDecodeAndCloudValidation() throws {
    // Legacy v0.1.x profile JSON without Wave 1 fields
    let legacyJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Legacy SFTP",
      "host": "legacy.example.com",
      "port": 22,
      "username": "deploy",
      "protocolKind": "sftp",
      "initialPath": "/var/www"
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ServerProfile.self, from: legacyJSON)
    #expect(decoded.name == "Legacy SFTP")
    #expect(decoded.defaultLocalPath == "")
    #expect(decoded.siteURL == "")
    #expect(decoded.colorTag == "")
    #expect(decoded.s3StorageClass == "STANDARD")
    #expect(decoded.s3UseSessionToken == false)
    #expect(decoded.b2BucketName == "")
    #expect(decoded.b2BucketId == "")
    #expect(decoded.azureAccountName == "")
    #expect(decoded.azureContainer == "")
    #expect(decoded.azureUseSAS == false)
    #expect(decoded.swiftAuthURL == "")
    #expect(decoded.swiftContainer == "")
    #expect(decoded.swiftTenantOrProject == "")
    #expect(decoded.preserveModificationDate == true)

    // Validation of new protocol kinds
    let ftpsExp = ServerProfile(host: "ftp.example.com", port: 21, username: "alice", protocolKind: .ftpsExplicit)
    try ftpsExp.validate()
    #expect(try ftpsExp.url(path: "/uploads", directory: true) == "ftp://ftp.example.com:21//uploads/")

    let b2Valid = ServerProfile(username: "keyId123", protocolKind: .b2, b2BucketName: "backups")
    try b2Valid.validate()
    #expect(try b2Valid.url(path: "/archive.tar") == "https://api.backblazeb2.com:443/archive.tar")

    let b2MissingBucket = ServerProfile(username: "keyId123", protocolKind: .b2)
    #expect(throws: TransferError.self) { try b2MissingBucket.validate() }

    let azureSAS = ServerProfile(protocolKind: .azureBlob, azureAccountName: "myacct", azureContainer: "media", azureUseSAS: true)
    try azureSAS.validate()
    #expect(azureSAS.needsPasswordPrompt(for: Credentials(sessionToken: "sv=2022-11-02&sig=abc")) == false)
    #expect(try azureSAS.url(path: "/logo.png") == "https://myacct.blob.core.windows.net:443/logo.png")

    let swiftValid = ServerProfile(
        username: "swiftuser",
        protocolKind: .openstackSwift,
        swiftAuthURL: "https://identity.example.com/v3/auth/tokens",
        swiftContainer: "objects",
        swiftTenantOrProject: "prod-proj"
    )
    try swiftValid.validate()
    #expect(try swiftValid.url(path: "/data.json") == "https://identity.example.com:443/data.json")
}

@Test func customPlacesStoreRoundTripAndPermissions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-places-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = CustomPlacesStore(file: dir.appendingPathComponent("places.json"))
    #expect(try store.load().isEmpty)

    let profileID = UUID()
    let places = [
        CustomPlaceItem(name: "Projects", path: "/Users/test/Projects", isRemote: false, profileId: nil, systemImage: "folder.fill"),
        CustomPlaceItem(name: "Web Root", path: "/var/www/html", isRemote: true, profileId: profileID, systemImage: "network")
    ]
    try store.save(places)
    let loaded = try store.load()
    #expect(loaded == places)

    let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
    let perms = attrs[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

@Test func credentialsSessionTokenRoundTripInKeychain() throws {
    let id = UUID()
    defer { try? CredentialStore.store(Credentials(), id: id, remember: false) }

    do {
        let creds = Credentials(password: "secret-key", passphrase: "key-phrase", sessionToken: "AQoDYXdzEJr///token")
        try CredentialStore.store(creds, id: id, remember: true)
    } catch TransferError.keychain {
        return
    }

    let loaded = try CredentialStore.loadCredentials(id: id)
    #expect(loaded.password == "secret-key")
    #expect(loaded.passphrase == "key-phrase")
    #expect(loaded.sessionToken == "AQoDYXdzEJr///token")

    try CredentialStore.store(Credentials(), id: id, remember: false)
    let cleared = try CredentialStore.loadCredentials(id: id)
    #expect(cleared == Credentials())
}

@Test func streamingThrottlerBoundedChunkingPacingAndCancellation() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-throttle-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let source = dir.appendingPathComponent("payload.bin")
    let totalSize = 192 * 1024 // 3 x 64 KiB chunks
    let payload = Data((0..<totalSize).map { UInt8($0 % 251) })
    try payload.write(to: source)

    // 256 KiB/s limit: first 64 KiB uses initial bucket, remaining 128 KiB takes ~0.5s
    let throttler = StreamingThrottler(speedLimitBytesPerSec: 256 * 1024)
    let clock = ContinuousClock()
    let start = clock.now
    var reassembled = Data()
    var chunkSizes: [Int] = []

    for try await chunk in throttler.streamFileChunks(at: source) {
        chunkSizes.append(chunk.count)
        reassembled.append(chunk)
    }
    let elapsed = start.duration(to: clock.now)
    let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    #expect(chunkSizes == [65_536, 65_536, 65_536])
    #expect(reassembled == payload)
    #expect(elapsedSeconds >= 0.25)

    // Verify writeAsyncBytes writes exact data in bounded 64 KiB chunks
    let byteStream = AsyncStream<UInt8> { continuation in
        for byte in payload {
            continuation.yield(byte)
        }
        continuation.finish()
    }
    let sink = dir.appendingPathComponent("sink.bin")
    let unthrottled = StreamingThrottler(speedLimitBytesPerSec: nil)
    let written = try await unthrottled.writeAsyncBytes(byteStream, to: sink, expectedTotal: Int64(totalSize))
    #expect(written == Int64(totalSize))
    #expect(try Data(contentsOf: sink) == payload)

    // Verify cancellation stops streaming immediately
    let slowThrottler = StreamingThrottler(speedLimitBytesPerSec: 1024)
    let task = Task {
        var count = 0
        for try await chunk in slowThrottler.streamFileChunks(at: source) {
            count += chunk.count
        }
        return count
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
}
