import CTransfer
import Foundation
import Testing
@testable import AetherTransferCore

@Test func transferModeAndDoubleClickActionMetadata() throws {
    #expect(TransferMode.allCases == [.automatic, .ascii, .binary])
    for mode in TransferMode.allCases {
        #expect(mode.id == mode.rawValue)
        #expect(!mode.localizedTitle.isEmpty)
    }

    #expect(DoubleClickAction.allCases == [.transfer, .editBuiltIn, .editExternal, .doNothing])
    for action in DoubleClickAction.allCases {
        #expect(action.id == action.rawValue)
        #expect(!action.localizedTitle.isEmpty)
    }

    let encodedModes = try JSONEncoder().encode(TransferMode.allCases)
    let decodedModes = try JSONDecoder().decode([TransferMode].self, from: encodedModes)
    #expect(decodedModes == TransferMode.allCases)

    let encodedActions = try JSONEncoder().encode(DoubleClickAction.allCases)
    let decodedActions = try JSONDecoder().decode([DoubleClickAction].self, from: encodedActions)
    #expect(decodedActions == DoubleClickAction.allCases)
}

@Test func serverProfileV3BackwardCompatibleDecodingAndRoundTrip() throws {
    let v020JSON = """
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "name": "v0.2.0 FTP",
      "host": "ftp.example.com",
      "port": 21,
      "username": "alice",
      "protocolKind": "ftp",
      "initialPath": "/pub",
      "preserveModificationDate": false
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(ServerProfile.self, from: v020JSON)
    #expect(decoded.name == "v0.2.0 FTP")
    #expect(decoded.preserveModificationDate == false)
    #expect(decoded.ftpPassiveMode == true)
    #expect(decoded.connectTimeoutSeconds == 15)
    #expect(decoded.s3IAMRoleARN == "")
    #expect(decoded.s3STSExternalID == "")
    #expect(decoded.s3MFASerial == "")
    #expect(decoded.s3STSEndpoint == "")
    #expect(decoded.defaultTransferMode == .automatic)

    let custom = ServerProfile(
        name: "S3 IAM Role",
        host: "",
        username: "AKIAIOSFODNN7EXAMPLE",
        protocolKind: .s3,
        s3Bucket: "prod-assets",
        ftpPassiveMode: false,
        connectTimeoutSeconds: 45,
        s3IAMRoleARN: "arn:aws:iam::123456789012:role/DeployRole",
        s3STSExternalID: "ext-42",
        s3MFASerial: "arn:aws:iam::123456789012:mfa/alice",
        s3STSEndpoint: "https://sts.us-west-2.amazonaws.com",
        defaultTransferMode: .ascii
    )
    let roundTripData = try JSONEncoder().encode(custom)
    let roundTripped = try JSONDecoder().decode(ServerProfile.self, from: roundTripData)
    #expect(roundTripped == custom)
}

@Test func validateForBucketDiscoveryAllowsEmptyBucketWithoutChangingValidate() throws {
    // Empty bucket with default AWS S3 host succeeds for bucket discovery, fails standard validate()
    let emptyBucketAWS = ServerProfile(
        host: "",
        port: 443,
        username: "AKIAIOSFODNN7EXAMPLE",
        protocolKind: .s3,
        s3Bucket: ""
    )
    try emptyBucketAWS.validateForBucketDiscovery()
    #expect(throws: TransferError.self) { try emptyBucketAWS.validate() }

    // Custom S3 host with empty bucket succeeds for bucket discovery
    let customHostEmptyBucket = ServerProfile(
        host: "minio.example.com",
        port: 9000,
        username: "minioadmin",
        protocolKind: .s3,
        s3Bucket: ""
    )
    try customHostEmptyBucket.validateForBucketDiscovery()
    #expect(throws: TransferError.self) { try customHostEmptyBucket.validate() }

    // Missing username fails bucket discovery
    let missingUser = ServerProfile(host: "s3.amazonaws.com", port: 443, username: "  ", protocolKind: .s3, s3Bucket: "")
    #expect(throws: TransferError.self) { try missingUser.validateForBucketDiscovery() }

    // Invalid port fails bucket discovery
    let invalidPort = ServerProfile(host: "s3.amazonaws.com", port: 70000, username: "AKIA", protocolKind: .s3, s3Bucket: "")
    #expect(throws: TransferError.self) { try invalidPort.validateForBucketDiscovery() }

    // Invalid host characters fail bucket discovery
    let invalidHost = ServerProfile(host: "bad host/path", port: 443, username: "AKIA", protocolKind: .s3, s3Bucket: "")
    #expect(throws: TransferError.self) { try invalidHost.validateForBucketDiscovery() }

    // Non-S3 protocol fails bucket discovery
    let nonS3 = ServerProfile(host: "sftp.example.com", port: 22, username: "deploy", protocolKind: .sftp)
    #expect(throws: TransferError.self) { try nonS3.validateForBucketDiscovery() }
}

@Test func s3ProviderPresetsAndContracts() throws {
    #expect(S3ProviderPreset.allCases.count == 7)
    for preset in S3ProviderPreset.allCases {
        #expect(preset.id == preset.rawValue)
        #expect(!preset.localizedTitle.isEmpty)
    }

    #expect(S3ProviderPreset.awsS3.defaultHost(region: "") == "s3.amazonaws.com")
    #expect(S3ProviderPreset.awsS3.defaultHost(region: "us-west-2") == "s3.us-west-2.amazonaws.com")
    #expect(S3ProviderPreset.awsS3IAMRole.defaultHost(region: "eu-central-1") == "s3.eu-central-1.amazonaws.com")
    #expect(S3ProviderPreset.cloudflareR2.defaultHost(region: "auto") == "<account-id>.r2.cloudflarestorage.com")
    #expect(S3ProviderPreset.minio.defaultHost(region: "us-east-1") == "")
    #expect(S3ProviderPreset.dreamObjects.defaultHost(region: "") == "objects-us-east-1.dream.io")
    #expect(S3ProviderPreset.wasabi.defaultHost(region: "ap-northeast-1") == "s3.ap-northeast-1.wasabisys.com")
    #expect(S3ProviderPreset.digitalOceanSpaces.defaultHost(region: "sgp1") == "sgp1.digitaloceanspaces.com")

    #expect(S3ProviderPreset.awsS3.defaultPathStyle == false)
    #expect(S3ProviderPreset.awsS3IAMRole.defaultPathStyle == false)
    #expect(S3ProviderPreset.cloudflareR2.defaultPathStyle == true)
    #expect(S3ProviderPreset.minio.defaultPathStyle == true)
    #expect(S3ProviderPreset.dreamObjects.defaultPathStyle == false)
    #expect(S3ProviderPreset.wasabi.defaultPathStyle == false)
    #expect(S3ProviderPreset.digitalOceanSpaces.defaultPathStyle == false)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let bucket = S3BucketInfo(name: "media-archive", creationDate: now)
    #expect(bucket.id == "media-archive")
    #expect(bucket.creationDate == now)

    let imported = ImportedServerItem(
        sourceFormat: "FileZilla XML",
        profile: ServerProfile(name: "Imported", host: "files.example.com", username: "bob", protocolKind: .ftp),
        hasPassword: true,
        optionalPassword: nil,
        selected: true
    )
    #expect(imported.sourceFormat == "FileZilla XML")
    #expect(imported.hasPassword == true)
    #expect(imported.optionalPassword == nil)
    #expect(imported.selected == true)

    let editorMapping = CustomEditorMapping(fileExtension: "swift", appPath: "/Applications/Xcode.app", appName: "Xcode")
    let mappingData = try JSONEncoder().encode(editorMapping)
    let decodedMapping = try JSONDecoder().decode(CustomEditorMapping.self, from: mappingData)
    #expect(decodedMapping == editorMapping)

    let defaultSync = SyncOptions()
    #expect(defaultSync.timeOffsetSeconds == 0)
    #expect(defaultSync.modifiedWithinSeconds == nil)
    #expect(defaultSync.followSymlinks == false)
    #expect(defaultSync.simulateOnly == false)

    let rawResult = RawCommandResult(command: "SYST", output: "215 UNIX Type: L8", succeeded: true, timestamp: now)
    #expect(rawResult.command == "SYST")
    #expect(rawResult.output == "215 UNIX Type: L8")
    #expect(rawResult.succeeded == true)
    #expect(rawResult.timestamp == now)
}

@Test func textFileEncodingConversions() throws {
    #expect(TextFileEncoding.allCases == [.utf8, .utf16, .isoLatin1, .gb18030])
    for enc in TextFileEncoding.allCases {
        #expect(enc.id == enc.rawValue)
        #expect(!enc.localizedTitle.isEmpty)
    }

    #expect(TextFileEncoding.utf8.stringEncoding == .utf8)
    #expect(TextFileEncoding.utf16.stringEncoding == .utf16)
    #expect(TextFileEncoding.isoLatin1.stringEncoding == .isoLatin1)

    let chineseSample = "你好，AetherTransfer 传输测试 2026"
    let gbData = chineseSample.data(using: TextFileEncoding.gb18030.stringEncoding)
    #expect(gbData != nil)
    #expect(gbData != chineseSample.data(using: .utf8))
    let decodedGB = gbData.flatMap { String(data: $0, encoding: TextFileEncoding.gb18030.stringEncoding) }
    #expect(decodedGB == chineseSample)

    let utf8Data = chineseSample.data(using: TextFileEncoding.utf8.stringEncoding)
    #expect(utf8Data.flatMap { String(data: $0, encoding: .utf8) } == chineseSample)

    let utf16Data = chineseSample.data(using: TextFileEncoding.utf16.stringEncoding)
    #expect(utf16Data.flatMap { String(data: $0, encoding: .utf16) } == chineseSample)

    let latinSample = "café résumé"
    let latinData = latinSample.data(using: TextFileEncoding.isoLatin1.stringEncoding)
    #expect(latinData.flatMap { String(data: $0, encoding: .isoLatin1) } == latinSample)
}

@Test func cTransferV3SettersAndValidation() throws {
    #expect(at_set_ascii_mode(nil, 1) != 0)
    #expect(at_set_ftp_active(nil, 1) != 0)
    #expect(at_set_connect_timeout(nil, 15) != 0)
    #expect(at_perform_raw(nil, "SYST") != 0)

    let req = try #require(at_create("ftp://ftp.example.com:21/", "alice", "secret", "", "", ""))
    defer { at_destroy(req) }

    #expect(at_set_ascii_mode(req, 1) == 0)
    #expect(at_set_ascii_mode(req, 0) == 0)

    #expect(at_set_ftp_active(req, 1) == 0)
    #expect(at_set_ftp_active(req, 0) == 0)

    #expect(at_set_connect_timeout(req, 1) == 0)
    #expect(at_set_connect_timeout(req, 5) == 0)
    #expect(at_set_connect_timeout(req, 30) == 0)
    #expect(at_set_connect_timeout(req, 120) == 0)
    #expect(at_set_connect_timeout(req, 999) == 0)

    #expect(at_perform_raw(req, nil) != 0)
    #expect(at_perform_raw(req, "") != 0)
    #expect(at_perform_raw(req, "   \r\n  ") != 0)
}
