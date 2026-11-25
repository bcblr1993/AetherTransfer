import CTransfer
import Foundation
import Testing
@testable import AetherTransferCore

// MARK: - Isolated Thread-Safe MockURLProtocol

private final class V3MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: Handler] = [:]

    static func makeSession(handler: @escaping Handler) -> URLSession {
        let suiteID = UUID().uuidString
        lock.withLock {
            handlers[suiteID] = handler
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [V3MockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-V3-Mock-Suite-Id": suiteID]
        return URLSession(configuration: config)
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let suiteID = request.value(forHTTPHeaderField: "X-V3-Mock-Suite-Id") else {
            return nil
        }
        return lock.withLock { handlers[suiteID] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let client = self.client
        guard let handler = Self.handler(for: req) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bodyData = try Self.readBody(from: req)
                let (response, data) = try handler(req, bodyData)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            if readCount > 0 {
                collected.append(buffer, count: readCount)
            } else if readCount == 0 {
                break
            } else {
                throw stream.streamError ?? URLError(.cannotOpenFile)
            }
        }
        return collected
    }
}

// MARK: - RemoteClient V3 Options & Raw Command Tests

@Test func remoteClientTransferModePassiveAndTimeoutResolution() async throws {
    let ftpProfile = ServerProfile(
        name: "FTP Server",
        host: "ftp.example.com",
        port: 21,
        username: "alice",
        protocolKind: .ftp,
        ftpPassiveMode: false,
        connectTimeoutSeconds: 42,
        defaultTransferMode: .automatic
    )
    let autoClient = RemoteClient(profile: ftpProfile, credentials: Credentials(password: "pw"))
    #expect(autoClient.transferMode == .automatic)
    #expect(autoClient.shouldUseAsciiTransfer(forFilename: "index.html") == true)
    #expect(autoClient.shouldUseAsciiTransfer(forFilename: "README.MD") == true)
    #expect(autoClient.shouldUseAsciiTransfer(forFilename: "archive.zip") == false)
    #expect(autoClient.shouldUseAsciiTransfer(forFilename: "photo.png") == false)

    let asciiClient = RemoteClient(profile: ftpProfile, credentials: Credentials(), transferMode: .ascii)
    #expect(asciiClient.transferMode == .ascii)
    #expect(asciiClient.shouldUseAsciiTransfer(forFilename: "archive.zip") == true)

    let binaryClient = RemoteClient(profile: ftpProfile, credentials: Credentials(), transferMode: .binary)
    #expect(binaryClient.transferMode == .binary)
    #expect(binaryClient.shouldUseAsciiTransfer(forFilename: "index.html") == false)

    let ftpsExplicitProfile = ServerProfile(
        name: "FTPES",
        host: "ftpes.example.com",
        port: 21,
        username: "alice",
        protocolKind: .ftpsExplicit,
        defaultTransferMode: .automatic
    )
    let ftpsClient = RemoteClient(profile: ftpsExplicitProfile, credentials: Credentials())
    #expect(ftpsClient.shouldUseAsciiTransfer(forFilename: "script.sh") == true)

    let sftpProfile = ServerProfile(
        name: "SFTP",
        host: "sftp.example.com",
        port: 22,
        username: "alice",
        protocolKind: .sftp,
        defaultTransferMode: .ascii
    )
    let sftpClient = RemoteClient(profile: sftpProfile, credentials: Credentials())
    #expect(sftpClient.shouldUseAsciiTransfer(forFilename: "index.html") == false)

    // Verify configured CTransfer request succeeds for Active FTP + custom connectTimeout + ASCII mode
    let reqPtr = try autoClient.createConfiguredRequest(
        path: "/pub/index.html",
        directory: false,
        mode: 2,
        transferFilename: "index.html"
    )
    at_destroy(reqPtr)
}

@Test func remoteClientSendRawCommandValidationAndRedaction() async throws {
    #expect(throws: TransferError.self) {
        _ = try RemoteClient.validateRawCommand("")
    }
    #expect(throws: TransferError.self) {
        _ = try RemoteClient.validateRawCommand("   ")
    }
    #expect(throws: TransferError.self) {
        _ = try RemoteClient.validateRawCommand("SYST\nQUIT")
    }
    #expect(throws: TransferError.self) {
        _ = try RemoteClient.validateRawCommand("SYST\rQUIT")
    }
    #expect(throws: TransferError.self) {
        _ = try RemoteClient.validateRawCommand("SYST\r\nFEAT")
    }
    #expect(throws: TransferError.self) {
        _ = try RemoteClient.validateRawCommand("SYST\0")
    }
    #expect(try RemoteClient.validateRawCommand("  SYST  ") == "SYST")

    // Raw command rejects HTTP-based cloud protocols cleanly
    let s3Profile = ServerProfile(
        name: "S3",
        host: "s3.amazonaws.com",
        username: "AKIA",
        protocolKind: .s3,
        s3Bucket: "my-bucket"
    )
    let s3Client = RemoteClient(profile: s3Profile, credentials: Credentials(password: "secret"))
    await #expect(throws: TransferError.self) {
        _ = try await s3Client.sendRawCommand("SYST")
    }

    // Raw command rejects newline injection even via async sendRawCommand
    let ftpProfile = ServerProfile(
        name: "FTP",
        host: "127.0.0.1",
        port: 21,
        username: "alice",
        protocolKind: .ftp,
        ftpPassiveMode: false,
        connectTimeoutSeconds: 5
    )
    let ftpClient = RemoteClient(profile: ftpProfile, credentials: Credentials(password: "secret"))
    await #expect(throws: TransferError.self) {
        _ = try await ftpClient.sendRawCommand("USER alice\r\nPASS secret")
    }

    // TranscriptRedactor redacts echoed PASS secrets in raw command logs/output
    let echoedOutput = """
    > PASS super-secret-pass
    230 User logged in.
    215 UNIX Type: L8
    """
    let sanitized = TranscriptRedactor.sanitize(echoedOutput)
    #expect(!sanitized.contains("super-secret-pass"))
    #expect(sanitized.contains("PASS [REDACTED]"))
    #expect(sanitized.contains("215 UNIX Type: L8"))
}

// MARK: - S3 ListBuckets & Empty-Bucket Discovery Tests

@Test func s3ClientListBucketsWithEmptyBucketAndSigV4Signing() async throws {
    final class CaptureBox: @unchecked Sendable {
        var requests: [URLRequest] = []
    }
    let capture = CaptureBox()

    let session = V3MockURLProtocol.makeSession { req, _ in
        capture.requests.append(req)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Owner>
            <ID>owner-id</ID>
            <DisplayName>alice</DisplayName>
          </Owner>
          <Buckets>
            <Bucket>
              <Name>zeta-backups</Name>
              <CreationDate>2025-11-01T10:20:30.000Z</CreationDate>
            </Bucket>
            <Bucket>
              <Name>alpha-assets</Name>
              <CreationDate>2024-05-12T08:00:00Z</CreationDate>
            </Bucket>
          </Buckets>
        </ListAllMyBucketsResult>
        """.data(using: .utf8)!
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/xml"])!
        return (resp, xml)
    }

    let profile = ServerProfile(
        name: "AWS S3",
        host: "",
        port: 443,
        username: "AKIAIOSFODNN7EXAMPLE",
        protocolKind: .s3,
        s3Bucket: "",
        s3Region: "us-west-2",
        s3PathStyle: false,
        s3UseSessionToken: true
    )
    try profile.validateForBucketDiscovery()

    let client = S3Client(
        profile: profile,
        credentials: Credentials(password: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", sessionToken: "FwoGZXIvYXdzEXAMPLE"),
        session: session
    )
    let buckets = try await client.listBuckets()

    #expect(buckets.count == 2)
    #expect(buckets[0].name == "alpha-assets")
    #expect(buckets[0].creationDate != nil)
    #expect(buckets[1].name == "zeta-backups")
    #expect(buckets[1].creationDate != nil)

    let req = try #require(capture.requests.first)
    #expect(req.httpMethod == "GET")
    #expect(req.url?.host == "s3.us-west-2.amazonaws.com")
    #expect(req.url?.path == "/")
    let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
    #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/"))
    #expect(auth.contains("/us-west-2/s3/aws4_request"))
    #expect(req.value(forHTTPHeaderField: "X-Amz-Security-Token") == "FwoGZXIvYXdzEXAMPLE")

    // Object endpointURL still rejects empty bucket
    #expect(throws: TransferError.self) {
        _ = try client.endpointURL(objectKey: "test.txt")
    }
}

// MARK: - AWS STS AssumeRole Tests

@Test func awsSTSAssumeRoleSignsSigV4AndParsesTemporaryCredentials() async throws {
    final class CaptureBox: @unchecked Sendable {
        var request: URLRequest?
        var bodyText: String = ""
    }
    let capture = CaptureBox()

    let session = V3MockURLProtocol.makeSession { req, body in
        capture.request = req
        capture.bodyText = String(data: body, encoding: .utf8) ?? ""
        let xml = """
        <AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
          <AssumeRoleResult>
            <Credentials>
              <AccessKeyId>ASIAIOSFODNN7EXAMPLE</AccessKeyId>
              <SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYTEMPKEY</SecretAccessKey>
              <SessionToken>AQoDYXdzEJr1234567890SessionToken</SessionToken>
              <Expiration>2026-11-26T12:00:00Z</Expiration>
            </Credentials>
          </AssumeRoleResult>
        </AssumeRoleResponse>
        """.data(using: .utf8)!
        let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/xml"])!
        return (resp, xml)
    }

    let baseProfile = ServerProfile(
        name: "Prod IAM S3",
        host: "s3.ap-northeast-1.amazonaws.com",
        port: 443,
        username: "AKIAIOSFODNN7BASE",
        protocolKind: .s3,
        s3Bucket: "prod-bucket",
        s3Region: "ap-northeast-1",
        s3IAMRoleARN: "arn:aws:iam::123456789012:role/AetherReadWrite",
        s3STSExternalID: "external-id-99",
        s3MFASerial: "arn:aws:iam::123456789012:mfa/alice",
        s3STSEndpoint: "https://sts.ap-northeast-1.amazonaws.com/"
    )
    let baseCreds = Credentials(password: "base-secret-key")
    let stsClient = AWSSTSClient()

    // Missing MFA token code must fail fast when s3MFASerial is configured
    await #expect(throws: TransferError.self) {
        _ = try await stsClient.assumeRole(profile: baseProfile, credentials: baseCreds, mfaTokenCode: nil, session: session)
    }

    let (ephemeralProfile, tempCredentials, stsTemp) = try await stsClient.assumeRoleProfileAndCredentials(
        profile: baseProfile,
        credentials: baseCreds,
        mfaTokenCode: "123456",
        sessionName: "AetherTestSession",
        session: session
    )

    #expect(stsTemp.accessKeyId == "ASIAIOSFODNN7EXAMPLE")
    #expect(stsTemp.secretAccessKey == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYTEMPKEY")
    #expect(stsTemp.sessionToken == "AQoDYXdzEJr1234567890SessionToken")
    #expect(stsTemp.expiration != nil)

    #expect(tempCredentials.passphrase == "ASIAIOSFODNN7EXAMPLE")
    #expect(tempCredentials.password == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYTEMPKEY")
    #expect(tempCredentials.sessionToken == "AQoDYXdzEJr1234567890SessionToken")

    #expect(ephemeralProfile.username == "ASIAIOSFODNN7EXAMPLE")
    #expect(ephemeralProfile.s3UseSessionToken == true)
    // Original profile stays untouched
    #expect(baseProfile.username == "AKIAIOSFODNN7BASE")

    let req = try #require(capture.request)
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://sts.ap-northeast-1.amazonaws.com/")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
    let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
    #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7BASE/"))
    #expect(auth.contains("/ap-northeast-1/sts/aws4_request"))

    #expect(capture.bodyText.contains("Action=AssumeRole"))
    #expect(capture.bodyText.contains("Version=2011-06-15"))
    #expect(capture.bodyText.contains("RoleSessionName=AetherTestSession"))
    #expect(capture.bodyText.contains("ExternalId=external-id-99"))
    #expect(capture.bodyText.contains("TokenCode=123456"))
}

// MARK: - AWS Config & Credentials Parser Tests

@Test func awsConfigParserMergesConfigAndCredentialsWithoutLeakingSecrets() throws {
    let configINI = """
    [default]
    region = us-west-2
    endpoint_url = https://s3.us-west-2.amazonaws.com

    [profile staging-role]
    region = eu-central-1
    role_arn = arn:aws:iam::999988887777:role/StagingRole
    source_profile = default
    mfa_serial = arn:aws:iam::999988887777:mfa/bob
    external_id = ext-staging

    [profile minio-local]
    region = us-east-1
    endpoint_url = https://minio.internal:9000

    [sso-session my-sso]
    sso_start_url = https://example.awsapps.com/start
    """

    let credentialsINI = """
    [default]
    aws_access_key_id = AKIADEFAULTKEY
    aws_secret_access_key = default-secret-never-in-profile
    aws_session_token = default-session-token

    [minio-local]
    aws_access_key_id = minioadmin
    aws_secret_access_key = minio-secret-pass
    """

    let items = AWSConfigParser.parse(configContent: configINI, credentialsContent: credentialsINI)
    #expect(items.count == 3)

    let def = items[0]
    #expect(def.sourceFormat == "AWS Config")
    #expect(def.profile.protocolKind == .s3)
    #expect(def.profile.username == "AKIADEFAULTKEY")
    #expect(def.profile.s3Region == "us-west-2")
    #expect(def.profile.s3UseSessionToken == true)
    #expect(def.hasPassword == true)
    #expect(def.optionalPassword == "default-secret-never-in-profile")

    let staging = items[1]
    #expect(staging.profile.s3Region == "eu-central-1")
    #expect(staging.profile.s3IAMRoleARN == "arn:aws:iam::999988887777:role/StagingRole")
    #expect(staging.profile.s3MFASerial == "arn:aws:iam::999988887777:mfa/bob")
    #expect(staging.profile.s3STSExternalID == "ext-staging")
    #expect(staging.profile.username == "AKIADEFAULTKEY")
    #expect(staging.optionalPassword == "default-secret-never-in-profile")

    let minio = items[2]
    #expect(minio.profile.host == "minio.internal")
    #expect(minio.profile.port == 9000)
    #expect(minio.profile.s3PathStyle == true)
    #expect(minio.profile.username == "minioadmin")
    #expect(minio.optionalPassword == "minio-secret-pass")

    // Verify ServerProfile JSON serialization never contains secrets
    let encodedJSON = String(data: try ServerProfile.exportJSON(items.map(\.profile)), encoding: .utf8) ?? ""
    #expect(!encodedJSON.contains("default-secret-never-in-profile"))
    #expect(!encodedJSON.contains("minio-secret-pass"))
    #expect(!encodedJSON.contains("default-session-token"))
}

// MARK: - Bookmark Importers Tests

@Test func fileZillaXMLImporterParsesProtocolsFoldersBase64PassAndRemoteDir() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <FileZilla3 version="3.66.5">
      <Servers>
        <Folder expanded="1">Production
          <Folder expanded="1">Web
            <Server>
              <Host>web01.example.com</Host>
              <Port>22</Port>
              <Protocol>1</Protocol>
              <User>deploy</User>
              <Pass encoding="base64">czNjcjN0LXB3</Pass>
              <Name>Prod Web 01</Name>
              <RemoteDir>1 0 3 var 3 www 4 html</RemoteDir>
              <LocalDir>/Users/alice/Sites</LocalDir>
            </Server>
          </Folder>
          <Server>
            <Host>ftp.example.com</Host>
            <Port>21</Port>
            <Protocol>3</Protocol>
            <User>ftpadmin</User>
            <Pass encoding="base64">ZnRwLXBhc3M=</Pass>
            <Name>Explicit FTPS</Name>
            <RemoteDir>/uploads/daily</RemoteDir>
            <PasvMode>MODE_ACTIVE</PasvMode>
          </Server>
        </Folder>
        <Server>
          <Host>legacy.example.com</Host>
          <Port>990</Port>
          <Protocol>4</Protocol>
          <User>legacy</User>
          <Name>Implicit FTPS</Name>
        </Server>
        <Server>
          <Host>plain.example.com</Host>
          <Port>21</Port>
          <Protocol>0</Protocol>
          <User>anonymous</User>
          <Name>Plain FTP</Name>
        </Server>
      </Servers>
    </FileZilla3>
    """.data(using: .utf8)!

    let items = try BookmarkImporter.importFileZillaXML(data: xml)
    #expect(items.count == 4)

    #expect(items[0].sourceFormat == "FileZilla XML")
    #expect(items[0].profile.name == "Prod Web 01")
    #expect(items[0].profile.group == "Production / Web")
    #expect(items[0].profile.protocolKind == .sftp)
    #expect(items[0].profile.port == 22)
    #expect(items[0].profile.initialPath == "/var/www/html")
    #expect(items[0].profile.defaultLocalPath == "/Users/alice/Sites")
    #expect(items[0].hasPassword == true)
    #expect(items[0].optionalPassword == "s3cr3t-pw")

    #expect(items[1].profile.group == "Production")
    #expect(items[1].profile.protocolKind == .ftpsExplicit)
    #expect(items[1].profile.ftpPassiveMode == false)
    #expect(items[1].profile.initialPath == "/uploads/daily")
    #expect(items[1].optionalPassword == "ftp-pass")

    #expect(items[2].profile.protocolKind == .ftps)
    #expect(items[2].profile.port == 990)
    #expect(items[2].hasPassword == false)

    #expect(items[3].profile.protocolKind == .ftp)
    #expect(items[3].profile.port == 21)
}

@Test func cyberduckBookmarkImporterParsesXMLAndBinaryPlists() throws {
    let dict: [String: Any] = [
        "Protocol": "sftp",
        "Hostname": "duck.example.com",
        "Port": 2222,
        "Username": "duckuser",
        "Nickname": "Duck SFTP",
        "Path": "/srv/app",
        "Private Key File": "/tmp/id_ed25519"
    ]
    let xmlData = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    let binaryData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)

    for data in [xmlData, binaryData] {
        let items = try BookmarkImporter.importCyberduckBookmark(data: data)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.sourceFormat == "Cyberduck")
        #expect(item.profile.name == "Duck SFTP")
        #expect(item.profile.host == "duck.example.com")
        #expect(item.profile.port == 2222)
        #expect(item.profile.username == "duckuser")
        #expect(item.profile.protocolKind == .sftp)
        #expect(item.profile.initialPath == "/srv/app")
        #expect(item.profile.privateKeyPath == "/tmp/id_ed25519")
    }
}

@Test func transmitAndInetlocImporterParsesFavoritesAndInetlocSafely() throws {
    let exportedFavorites: [String: Any] = [
        "TRFavorite": [
            [
                "Protocol": "SFTP",
                "Server": "nova.example.com",
                "Port": 22,
                "Username": "nova",
                "Nickname": "Nova Prod",
                "InitialPath": "/var/www",
                "LocalPath": "/Users/nova/Code",
                "SiteURL": "https://nova.example.com"
            ],
            [
                "Protocol": "FTP with TLS/SSL",
                "Server": "ftpes.nova.dev",
                "Port": 21,
                "Username": "uploader",
                "Nickname": "Nova FTPES",
                "InitialPath": "/dist"
            ]
        ]
    ]
    let favData = try PropertyListSerialization.data(fromPropertyList: exportedFavorites, format: .xml, options: 0)
    let favItems = try BookmarkImporter.importTransmitOrNova(data: favData)
    #expect(favItems.count == 2)
    #expect(favItems[0].profile.name == "Nova Prod")
    #expect(favItems[0].profile.protocolKind == .sftp)
    #expect(favItems[0].profile.initialPath == "/var/www")
    #expect(favItems[0].profile.defaultLocalPath == "/Users/nova/Code")
    #expect(favItems[0].profile.siteURL == "https://nova.example.com")
    #expect(favItems[1].profile.protocolKind == .ftpsExplicit)

    // .inetloc URL with embedded password must strip password from ServerProfile and surface only in optionalPassword
    let inetloc: [String: Any] = [
        "URL": "ftp://bob:topsecret@files.example.com:2121/pub/releases"
    ]
    let inetlocData = try PropertyListSerialization.data(fromPropertyList: inetloc, format: .xml, options: 0)
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let inetlocFile = tempDir.appendingPathComponent("files.inetloc")
    try inetlocData.write(to: inetlocFile)

    let loaded = try BookmarkImporter.importFromFile(at: inetlocFile)
    #expect(loaded.count == 1)
    #expect(loaded[0].profile.protocolKind == .ftp)
    #expect(loaded[0].profile.host == "files.example.com")
    #expect(loaded[0].profile.port == 2121)
    #expect(loaded[0].profile.username == "bob")
    #expect(loaded[0].profile.initialPath == "/pub/releases")
    #expect(loaded[0].hasPassword == true)
    #expect(loaded[0].optionalPassword == "topsecret")

    let profileJSON = String(data: try ServerProfile.exportJSON([loaded[0].profile]), encoding: .utf8) ?? ""
    #expect(!profileJSON.contains("topsecret"))

    // Test combined local config scan (SSH + AWS)
    let sshFile = tempDir.appendingPathComponent("ssh_config")
    let awsCfgFile = tempDir.appendingPathComponent("aws_config")
    let awsCredsFile = tempDir.appendingPathComponent("aws_creds")
    try """
    Host prod-bastion
      HostName bastion.example.com
      User ops
      Port 2222
    """.write(to: sshFile, atomically: true, encoding: .utf8)
    try """
    [profile dev]
    region = us-east-1
    """.write(to: awsCfgFile, atomically: true, encoding: .utf8)
    try """
    [dev]
    aws_access_key_id = AKIADEV
    aws_secret_access_key = dev-secret
    """.write(to: awsCredsFile, atomically: true, encoding: .utf8)

    let combined = BookmarkImporter.importFromLocalConfigs(
        sshConfigURL: sshFile,
        awsConfigURL: awsCfgFile,
        awsCredentialsURL: awsCredsFile
    )
    #expect(combined.count == 2)
    #expect(combined[0].sourceFormat == "SSH Config")
    #expect(combined[0].profile.host == "bastion.example.com")
    #expect(combined[1].sourceFormat == "AWS Config")
    #expect(combined[1].profile.username == "AKIADEV")
    #expect(combined[1].optionalPassword == "dev-secret")
}

// MARK: - Safe Zip Extraction Tests

@Test func archiveHelperExtractZipWorksForSafeArchiveAndRejectsZipSlipAndSymlinks() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("aether-unzip-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // 1. Safe extraction round-trip
    let srcDir = tempDir.appendingPathComponent("src")
    let nestedDir = srcDir.appendingPathComponent("bundle/sub")
    try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
    let sampleFile = nestedDir.appendingPathComponent("hello.txt")
    try "Hello safe zip".write(to: sampleFile, atomically: true, encoding: .utf8)

    let safeZip = tempDir.appendingPathComponent("safe.zip")
    try ArchiveHelper.createZip(from: [srcDir.appendingPathComponent("bundle")], destinationZipURL: safeZip)

    let extractDest = tempDir.appendingPathComponent("out")
    let extractedURLs = try await ArchiveHelper.extractZip(at: safeZip, to: extractDest)
    #expect(extractedURLs.map(\.lastPathComponent) == ["bundle"])
    let extractedText = try String(contentsOf: extractDest.appendingPathComponent("bundle/sub/hello.txt"), encoding: .utf8)
    #expect(extractedText == "Hello safe zip")

    // 2. Zip-Slip (`../evil.txt`) must be rejected before extraction
    let zipSlipArchive = tempDir.appendingPathComponent("zipslip.zip")
    try createCraftedZip(at: zipSlipArchive, script: """
    import zipfile, sys
    with zipfile.ZipFile(sys.argv[1], 'w') as z:
        z.writestr('../evil.txt', 'pwned')
    """)
    let slipDest = tempDir.appendingPathComponent("slip-out")
    await #expect(throws: ArchiveError.self) {
        _ = try await ArchiveHelper.extractZip(at: zipSlipArchive, to: slipDest)
    }
    #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("evil.txt").path))

    // 3. Absolute path (`/etc/passwd`) must be rejected before extraction
    let absArchive = tempDir.appendingPathComponent("abs.zip")
    try createCraftedZip(at: absArchive, script: """
    import zipfile, sys
    with zipfile.ZipFile(sys.argv[1], 'w') as z:
        z.writestr('/etc/passwd', 'fake')
    """)
    let absDest = tempDir.appendingPathComponent("abs-out")
    await #expect(throws: ArchiveError.self) {
        _ = try await ArchiveHelper.extractZip(at: absArchive, to: absDest)
    }

    // 4. Symlink entry must be rejected before extraction
    let symlinkArchive = tempDir.appendingPathComponent("symlink.zip")
    try createCraftedZip(at: symlinkArchive, script: """
    import zipfile, sys
    with zipfile.ZipFile(sys.argv[1], 'w') as z:
        info = zipfile.ZipInfo('escape-link')
        info.create_system = 3
        info.external_attr = (0o120777 << 16)
        z.writestr(info, '/etc/hosts')
    """)
    let symDest = tempDir.appendingPathComponent("sym-out")
    await #expect(throws: ArchiveError.self) {
        _ = try await ArchiveHelper.extractZip(at: symlinkArchive, to: symDest)
    }
    #expect(!FileManager.default.fileExists(atPath: symDest.appendingPathComponent("escape-link").path))
}

private func createCraftedZip(at url: URL, script: String) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    proc.arguments = ["-c", script, url.path]
    let errPipe = Pipe()
    proc.standardError = errPipe
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "python3 failed"
        throw NSError(domain: "CraftedZip", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
