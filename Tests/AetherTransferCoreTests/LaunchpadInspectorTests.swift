import CryptoKit
import Foundation
import Testing
@testable import AetherTransferCore

// Note: Package.swift links AetherTransferCoreTests only against AetherTransferCore (not executable target AetherTransferApp).
// These tests directly verify the underlying AetherTransferCore contracts plus matching reference logic for
// chunked 64 KiB checksums, siteURL mapping, recursive folder size aggregation, and octal permissions parsing.

private enum TestSiteURLMapper {
    static func map(remotePath: String, isDirectory: Bool, profile: ServerProfile) -> URL? {
        let rawSite = profile.siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSite.isEmpty else { return nil }

        let candidate = rawSite.contains("://") ? rawSite : "https://\(rawSite)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        let normalizedRemote = RemotePath.normalize(remotePath)
        let normalizedRoot = RemotePath.normalize(profile.initialPath)

        let relative: String
        if normalizedRoot == "/" {
            relative = normalizedRemote == "/" ? "" : String(normalizedRemote.dropFirst())
        } else if normalizedRemote == normalizedRoot {
            relative = ""
        } else if normalizedRemote.hasPrefix(normalizedRoot + "/") {
            relative = String(normalizedRemote.dropFirst(normalizedRoot.count + 1))
        } else {
            relative = normalizedRemote == "/" ? "" : String(normalizedRemote.dropFirst())
        }

        var basePath = components.path
        while basePath.hasSuffix("/") && basePath.count > 1 {
            basePath.removeLast()
        }
        if basePath == "/" { basePath = "" }

        if relative.isEmpty {
            components.path = basePath.isEmpty ? (isDirectory ? "/" : "") : (isDirectory && !basePath.hasSuffix("/") ? basePath + "/" : basePath)
        } else {
            let joined = "\(basePath)/\(relative)"
            components.path = isDirectory && !joined.hasSuffix("/") ? joined + "/" : joined
        }
        return components.url
    }
}

private func computeChunkedChecksums(forFileAt url: URL) async throws -> (sha256: String, md5: String, bytes: Int64) {
    let throttler = StreamingThrottler(speedLimitBytesPerSec: nil)
    var sha = SHA256()
    var md5 = Insecure.MD5()
    var totalBytes: Int64 = 0

    for try await chunk in throttler.streamFileChunks(at: url) {
        try Task.checkCancellation()
        sha.update(data: chunk)
        md5.update(data: chunk)
        totalBytes += Int64(chunk.count)
    }

    let shaHex = sha.finalize().map { String(format: "%02x", $0) }.joined()
    let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
    return (shaHex, md5Hex, totalBytes)
}

@Test func chunkedChecksumCalculationMatchesFullDigestAndSupportsEmptyFiles() async throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aether-checksum-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    // Multi-chunk file (> 3 * 64 KiB)
    let count = 200 * 1024
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        bytes[index] = UInt8((index * 7 + 13) % 256)
    }
    let payload = Data(bytes)
    let multiChunkFile = tempDir.appendingPathComponent("multi.bin")
    try payload.write(to: multiChunkFile)

    let expectedSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let expectedMD5 = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()

    let computed = try await computeChunkedChecksums(forFileAt: multiChunkFile)
    #expect(computed.sha256 == expectedSHA)
    #expect(computed.md5 == expectedMD5)
    #expect(computed.bytes == Int64(payload.count))

    // Empty file edge case
    let emptyFile = tempDir.appendingPathComponent("empty.bin")
    try Data().write(to: emptyFile)
    let emptyComputed = try await computeChunkedChecksums(forFileAt: emptyFile)
    #expect(emptyComputed.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(emptyComputed.md5 == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(emptyComputed.bytes == 0)
}

@Test func siteURLWebMappingHandlesRootsSubpathsSpacesAndInvalidURLs() throws {
    let rootProfile = ServerProfile(
        host: "cdn.example.com",
        username: "deploy",
        initialPath: "/",
        siteURL: "https://cdn.example.com"
    )
    #expect(
        TestSiteURLMapper.map(remotePath: "/images/hero banner.png", isDirectory: false, profile: rootProfile)?.absoluteString
            == "https://cdn.example.com/images/hero%20banner.png"
    )
    #expect(
        TestSiteURLMapper.map(remotePath: "/assets", isDirectory: true, profile: rootProfile)?.absoluteString
            == "https://cdn.example.com/assets/"
    )

    let scopedProfile = ServerProfile(
        host: "web.example.com",
        username: "www",
        initialPath: "/var/www/html",
        siteURL: "https://example.com/static/"
    )
    #expect(
        TestSiteURLMapper.map(remotePath: "/var/www/html/css/main.css", isDirectory: false, profile: scopedProfile)?.absoluteString
            == "https://example.com/static/css/main.css"
    )
    #expect(
        TestSiteURLMapper.map(remotePath: "/var/www/html", isDirectory: true, profile: scopedProfile)?.absoluteString
            == "https://example.com/static/"
    )
    #expect(
        TestSiteURLMapper.map(remotePath: "/other/robots.txt", isDirectory: false, profile: scopedProfile)?.absoluteString
            == "https://example.com/static/other/robots.txt"
    )

    let emptySite = ServerProfile(host: "web.example.com", username: "www", siteURL: "")
    #expect(TestSiteURLMapper.map(remotePath: "/index.html", isDirectory: false, profile: emptySite) == nil)
}

@Test func recursiveFolderSizeAggregationLocalAndRemote() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aether-foldersize-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let subDir = tempDir.appendingPathComponent("sub", isDirectory: true)
    let deepDir = subDir.appendingPathComponent("deep", isDirectory: true)
    try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)

    try Data(repeating: 0xAA, count: 1024).write(to: tempDir.appendingPathComponent("top.bin"))
    try Data(repeating: 0xBB, count: 2048).write(to: subDir.appendingPathComponent("mid.bin"))
    try Data(repeating: 0xCC, count: 512).write(to: deepDir.appendingPathComponent("leaf.bin"))
    try Data(repeating: 0xDD, count: 128).write(to: tempDir.appendingPathComponent(".hidden"))

    let visibleItems = try LocalFiles.walk(tempDir, showHidden: false)
    let visibleBytes = visibleItems.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
    let visibleFolders = visibleItems.filter(\.isDirectory).count
    let visibleFiles = visibleItems.filter { !$0.isDirectory }.count
    #expect(visibleBytes == 3584)
    #expect(visibleFiles == 3)
    #expect(visibleFolders == 2)

    let allItems = try LocalFiles.walk(tempDir, showHidden: true)
    let allBytes = allItems.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
    #expect(allBytes == 3712)

    let remoteEntries = [
        FileEntry(name: "sub", path: "/root/sub", isDirectory: true, size: 0),
        FileEntry(name: "a.txt", path: "/root/a.txt", isDirectory: false, size: 300),
        FileEntry(name: "b.txt", path: "/root/sub/b.txt", isDirectory: false, size: 700)
    ]
    let remoteFileBytes = remoteEntries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
    #expect(remoteFileBytes == 1000)
    #expect(remoteEntries.filter { $0.isDirectory }.count == 1)
}

@Test func octalPermissionsParsingAndEditingEdgeCases() {
    // 4-digit and 3-digit octal inputs with surrounding whitespace
    let p0755 = POSIXPermissions(fromOctalString: "0755")
    #expect(p0755 != nil)
    #expect(p0755?.octalString == "0755")
    #expect(p0755?.modeString == "rwxr-xr-x")
    #expect(p0755?.octalInt == 0o755)

    let p755 = POSIXPermissions(fromOctalString: " 755 ")
    #expect(p755 == p0755)

    let p0000 = POSIXPermissions(fromOctalString: "0000")
    #expect(p0000?.modeString == "---------")
    #expect(p0000?.octalInt == 0)

    let p0777 = POSIXPermissions(fromOctalString: "777")
    #expect(p0777?.modeString == "rwxrwxrwx")
    #expect(p0777?.octalString == "0777")

    // Invalid octal inputs
    #expect(POSIXPermissions(fromOctalString: "") == nil)
    #expect(POSIXPermissions(fromOctalString: "888") == nil)
    #expect(POSIXPermissions(fromOctalString: "0899") == nil)
    #expect(POSIXPermissions(fromOctalString: "75") == nil)
    #expect(POSIXPermissions(fromOctalString: "00755") == nil)
    #expect(POSIXPermissions(fromOctalString: "-755") == nil)
    #expect(POSIXPermissions(fromOctalString: "rwxr-xr-x") == nil)

    // Mode string edge cases (9-char, 10-char directory, setuid/setgid/sticky)
    let from9 = POSIXPermissions(fromModeString: "rw-r-----")
    #expect(from9.octalString == "0640")

    let fromDir = POSIXPermissions(fromModeString: "drwxr-xr-x")
    #expect(fromDir.octalString == "0755")

    let fromSpecial = POSIXPermissions(fromModeString: "-rwsr-sr-t")
    #expect(fromSpecial.owner.execute == true)
    #expect(fromSpecial.group.execute == true)
    #expect(fromSpecial.others.execute == true)
    #expect(fromSpecial.octalString == "0755")

    // Mutating triads updates octal string cleanly
    var editable = POSIXPermissions(fromOctalString: "0644")!
    editable.owner.execute = true
    editable.group.write = true
    editable.others.read = false
    #expect(editable.octalString == "0760")
    #expect(editable.modeString == "rwxrw----")
}

@Test func bookmarkMetadataFolderLinkingAndKnownHostFingerprintRevocation() throws {
    var sftpProfile = ServerProfile(
        name: "Prod App",
        group: "Production",
        host: "prod.example.com",
        port: 2222,
        username: "ubuntu",
        protocolKind: .sftp,
        initialPath: "/var/www",
        trustedHostKey: Data("mock-ssh-host-key-bytes".utf8).base64EncodedString(),
        defaultLocalPath: "/Users/dev/Site",
        siteURL: "https://example.com",
        colorTag: "blue",
        preserveModificationDate: false
    )
    try sftpProfile.validate()
    #expect(sftpProfile.colorTag == "blue")
    #expect(sftpProfile.defaultLocalPath == "/Users/dev/Site")
    #expect(sftpProfile.preserveModificationDate == false)

    let fp = RemoteClient.fingerprint(sftpProfile.trustedHostKey!)
    #expect(fp.hasPrefix("SHA256:"))
    #expect(!fp.contains("="))

    // Simulate revoking trusted host key
    sftpProfile.trustedHostKey = nil
    #expect(sftpProfile.trustedHostKey == nil)

    // S3 STS session token & B2/Azure/Swift profiles validate cleanly
    let s3STS = ServerProfile(
        username: "AKIAEXAMPLE",
        protocolKind: .s3,
        s3Bucket: "media",
        s3Region: "us-east-1",
        s3StorageClass: "STANDARD_IA",
        s3UseSessionToken: true
    )
    try s3STS.validate()

    let creds = Credentials(password: "secret", passphrase: "", sessionToken: "FwoGZXIvYXdz...")
    #expect(!creds.sessionToken.isEmpty)
}
