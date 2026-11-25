import Foundation
import CryptoKit
import Testing
import CTransfer
@testable import AetherTransferCore

// MARK: - Thread-Safe Isolated MockURLProtocol

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: Handler] = [:]

    static func makeSession(handler: @escaping Handler) -> URLSession {
        let suiteID = UUID().uuidString
        lock.withLock {
            handlers[suiteID] = handler
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Mock-Suite-Id": suiteID]
        return URLSession(configuration: config)
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let suiteID = request.value(forHTTPHeaderField: "X-Mock-Suite-Id") else {
            return nil
        }
        return lock.withLock { handlers[suiteID] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let req = request
        let client = self.client
        guard let handler = Self.handler(for: req) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // Read httpBody or httpBodyStream off the calling thread in bounded chunks
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bodyData = try Self.readBody(from: req)
                let (response, data) = try handler(req, bodyData)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    // Deliver in bounded chunks to exercise async byte streaming
                    let chunkSize = 16 * 1024
                    var offset = 0
                    while offset < data.count {
                        let end = min(data.count, offset + chunkSize)
                        client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                        offset = end
                    }
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }

        var collected = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let readCount = stream.read(&buffer, maxLength: bufferSize)
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

private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.withLock { items.append(item) }
    }

    func snapshot() -> [T] {
        lock.withLock { items }
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aether-cloud-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeHTTPResponse(url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private func makePatternData(count: Int, multiplier: Int = 1, offset: Int = 0, modulus: Int = 256) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        bytes[index] = UInt8((index * multiplier + offset) % modulus)
    }
    return Data(bytes)
}

// MARK: - CTransfer Explicit FTPS & Mtime Tests

@Test func ctransferExplicitFTPSOptionsAndFileTimeAPI() throws {
    let profile = ServerProfile(
        name: "Explicit FTPS",
        host: "ftps.example.com",
        port: 21,
        username: "alice",
        protocolKind: .ftpsExplicit
    )
    try profile.validate()
    let generated = try profile.url(path: "/releases/app.dmg", directory: false)
    #expect(generated == "ftp://ftps.example.com:21//releases/app.dmg")

    let req = at_create(generated, "alice", "secret", "", "", "")
    #expect(req != nil)
    if let req {
        defer { at_destroy(req) }
        #expect(at_set_ftps_explicit(req, 1) == 0)
        #expect(at_set_ftps_explicit(req, 0) == 0)
        // Before perform, file_time defaults to -1
        #expect(at_file_time(req) == -1)
    }
    #expect(at_set_ftps_explicit(nil, 1) != 0)
}

// MARK: - WebDAV Streaming Upload, Range Download & Metadata Tests

@Test func webdavStreamingUploadDownloadResumeAndStatMetadata() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // >200 KiB payload to verify multi-chunk 64 KiB streaming
    let payloadSize = 256 * 1024 + 137
    let payload = makePatternData(count: payloadSize, multiplier: 13, offset: 7)
    let localSource = dir.appendingPathComponent("upload.bin")
    try payload.write(to: localSource)

    let uploadedCapture = Recorder<Data>()
    let methodsSeen = Recorder<String>()
    let expectedModHeader = "Wed, 21 Oct 2026 07:28:00 GMT"

    let session = MockURLProtocol.makeSession { req, body in
        let method = req.httpMethod ?? "GET"
        methodsSeen.append(method)
        let url = req.url!

        if method == "PUT" {
            #expect(req.value(forHTTPHeaderField: "Content-Length") == "\(payloadSize)")
            #expect(req.httpBody == nil) // Must stream via httpBodyStream, not Data(contentsOf:)
            uploadedCapture.append(body)
            return (makeHTTPResponse(url: url, status: 201), Data())
        }
        if method == "GET" {
            if let range = req.value(forHTTPHeaderField: "Range"), range == "bytes=65536-" {
                let slice = payload.subdata(in: 65_536..<payload.count)
                return (makeHTTPResponse(url: url, status: 206, headers: [
                    "Content-Length": "\(slice.count)",
                    "Content-Range": "bytes 65536-\(payload.count - 1)/\(payload.count)",
                    "Last-Modified": expectedModHeader
                ]), slice)
            }
            return (makeHTTPResponse(url: url, status: 200, headers: [
                "Content-Length": "\(payload.count)",
                "Last-Modified": expectedModHeader
            ]), payload)
        }
        if method == "HEAD" {
            return (makeHTTPResponse(url: url, status: 200, headers: [
                "Content-Type": "application/octet-stream",
                "Cache-Control": "max-age=300",
                "ETag": "\"dav-etag-1\"",
                "Content-Length": "\(payloadSize)",
                "Last-Modified": expectedModHeader
            ]), Data())
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let profile = ServerProfile(
        name: "DAV",
        host: "dav.example.com",
        port: 443,
        username: "user",
        protocolKind: .webdavs,
        preserveModificationDate: true
    )
    let client = WebDAVClient(
        profile: profile,
        credentials: Credentials(password: "dav-pass"),
        session: session,
        speedLimitBytesPerSec: nil
    )

    let uploadProgress = Recorder<TransferProgress>()
    try await client.upload(localSource, to: "/uploads/large.bin", overwrite: true) { p in
        uploadProgress.append(p)
    }

    #expect(uploadedCapture.snapshot().first == payload)
    let progressEvents = uploadProgress.snapshot()
    #expect(progressEvents.count >= 4)
    #expect(progressEvents.last?.completed == Int64(payloadSize))
    #expect(progressEvents.last?.total == Int64(payloadSize))

    // Range-resumed download via stagingURL + mtime preservation
    let stagingURL = dir.appendingPathComponent("resume.part")
    try payload.prefix(65_536).write(to: stagingURL)
    let destination = dir.appendingPathComponent("downloaded.bin")
    let dlProgress = Recorder<TransferProgress>()
    try await client.download("/uploads/large.bin", to: destination, overwrite: true, offset: 65_536, stagingURL: stagingURL) { p in
        dlProgress.append(p)
    }
    #expect(try Data(contentsOf: destination) == payload)
    #expect(dlProgress.snapshot().last?.completed == Int64(payloadSize))

    let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
    let modDate = attrs[.modificationDate] as? Date
    #expect(modDate != nil)
    if let modDate {
        #expect(abs(modDate.timeIntervalSince1970 - 1792567680) < 2)
    }

    // statMetadata via HEAD
    let meta = try await client.statMetadata("/uploads/large.bin")
    #expect(meta.contentType == "application/octet-stream")
    #expect(meta.cacheControl == "max-age=300")
    #expect(meta.etag == "\"dav-etag-1\"")
    #expect(meta.size == Int64(payloadSize))
    #expect(meta.modified != nil)
}

@Test func webdavStreamingThrottleAndCancellation() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let totalSize = 256 * 1024 // 4 x 64 KiB chunks
    let payload = makePatternData(count: totalSize, modulus: 239)
    let localSource = dir.appendingPathComponent("throttled.bin")
    try payload.write(to: localSource)

    let session = MockURLProtocol.makeSession { req, _ in
        (makeHTTPResponse(url: req.url!, status: 200), Data())
    }
    let profile = ServerProfile(host: "dav.example.com", port: 443, username: "u", protocolKind: .webdavs)
    // Slow limit so cancellation fires mid-stream cleanly
    let client = WebDAVClient(
        profile: profile,
        credentials: Credentials(password: "p"),
        session: session,
        speedLimitBytesPerSec: 16 * 1024
    )

    let uploadTask = Task {
        try await client.upload(localSource, to: "/slow.bin", overwrite: true)
    }
    try await Task.sleep(nanoseconds: 60_000_000)
    uploadTask.cancel()

    await #expect(throws: CancellationError.self) {
        try await uploadTask.value
    }
}

// MARK: - S3 Pagination, Multipart Upload, Metadata, Security Token & Presigned URL Tests

@Test func s3PaginationSessionTokenMetadataAndCustomExpiry() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let capturedRequests = Recorder<(method: String, query: String, headers: [String: String])>()
    let session = MockURLProtocol.makeSession { req, body in
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        var lowerHeaders: [String: String] = [:]
        for (k, v) in req.allHTTPHeaderFields ?? [:] {
            lowerHeaders[k.lowercased()] = v
        }
        capturedRequests.append((method, url.query ?? "", lowerHeaders))

        if method == "GET" && (url.query ?? "").contains("list-type=2") {
            if (url.query ?? "").contains("continuation-token=tok2") {
                let page2 = """
                <?xml version="1.0" encoding="UTF-8"?>
                <ListBucketResult>
                  <IsTruncated>false</IsTruncated>
                  <Contents><Key>docs/b.txt</Key><LastModified>2026-10-21T09:00:00Z</LastModified><Size>200</Size></Contents>
                </ListBucketResult>
                """.data(using: .utf8)!
                return (makeHTTPResponse(url: url, status: 200), page2)
            } else {
                let page1 = """
                <?xml version="1.0" encoding="UTF-8"?>
                <ListBucketResult>
                  <IsTruncated>true</IsTruncated>
                  <NextContinuationToken>tok2</NextContinuationToken>
                  <Contents><Key>docs/a.txt</Key><LastModified>2026-10-21T08:00:00Z</LastModified><Size>100</Size></Contents>
                  <CommonPrefixes><Prefix>docs/sub/</Prefix></CommonPrefixes>
                </ListBucketResult>
                """.data(using: .utf8)!
                return (makeHTTPResponse(url: url, status: 200), page1)
            }
        }

        if method == "HEAD" {
            return (makeHTTPResponse(url: url, status: 200, headers: [
                "Content-Type": "text/plain",
                "Cache-Control": "public, max-age=60",
                "x-amz-storage-class": "STANDARD_IA",
                "x-amz-acl": "private",
                "x-amz-meta-author": "aether",
                "ETag": "\"s3-etag\"",
                "Content-Length": "100",
                "Last-Modified": "Wed, 21 Oct 2026 08:00:00 GMT"
            ]), Data())
        }

        if method == "PUT" && lowerHeaders["x-amz-metadata-directive"] == "REPLACE" {
            #expect(lowerHeaders["x-amz-security-token"] == "STS-TOKEN-XYZ")
            #expect(lowerHeaders["x-amz-meta-env"] == "prod")
            #expect(lowerHeaders["content-type"] == "application/json")
            #expect(lowerHeaders["cache-control"] == "no-cache")
            _ = body
            return (makeHTTPResponse(url: url, status: 200), Data("<CopyObjectResult></CopyObjectResult>".utf8))
        }

        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let profile = ServerProfile(
        name: "STS S3",
        host: "s3.amazonaws.com",
        port: 443,
        username: "AKIAEXAMPLE",
        protocolKind: .s3,
        s3Bucket: "my-bucket",
        s3Region: "us-east-1",
        s3UseSessionToken: true
    )
    let creds = Credentials(password: "SECRETKEY", sessionToken: "STS-TOKEN-XYZ")
    let client = S3Client(profile: profile, credentials: creds, session: session)

    // 1. Paginated ListObjectsV2
    let entries = try await client.list("/docs")
    #expect(entries.map { $0.name } == ["sub", "a.txt", "b.txt"])
    #expect(capturedRequests.snapshot().allSatisfy { $0.headers["x-amz-security-token"] == "STS-TOKEN-XYZ" })

    // 2. statMetadata & updateMetadata
    let stat = try await client.statMetadata("/docs/a.txt")
    #expect(stat.contentType == "text/plain")
    #expect(stat.storageClass == "STANDARD_IA")
    #expect(stat.customMetadata["author"] == "aether")
    #expect(stat.etag == "\"s3-etag\"")

    let updated = RemoteObjectMetadata(
        contentType: "application/json",
        cacheControl: "no-cache",
        storageClass: "GLACIER",
        acl: "private",
        customMetadata: ["env": "prod"]
    )
    try await client.updateMetadata("/docs/a.txt", metadata: updated)

    // 3. Presigned URL with custom expiry & X-Amz-Security-Token
    let presigned = try client.presignedDownloadURL(for: "/docs/a.txt", expiresIn: 999_999)
    let urlStr = presigned.absoluteString
    #expect(urlStr.contains("X-Amz-Expires=604800"))
    #expect(urlStr.contains("X-Amz-Security-Token=STS-TOKEN-XYZ"))
    #expect(urlStr.contains("X-Amz-Signature="))

    let minPresigned = try client.presignedDownloadURL(for: "/docs/a.txt", expiresIn: 10)
    #expect(minPresigned.absoluteString.contains("X-Amz-Expires=60"))
}

@Test func s3StreamingUploadSHA256MultipartAndFolderOperations() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 250 KiB payload: with multipartThreshold=128 KiB and partSize=90 KiB -> 3 parts (90K, 90K, 70K)
    let totalSize = 250 * 1024
    let payload = makePatternData(count: totalSize, multiplier: 7, offset: 3)
    let localFile = dir.appendingPathComponent("multipart.bin")
    try payload.write(to: localFile)

    let uploadedParts = Recorder<(partNumber: Int, data: Data, shaHeader: String)>()
    let ops = Recorder<String>()

    let session = MockURLProtocol.makeSession { req, body in
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        let query = url.query ?? ""

        if method == "POST" && query.contains("uploads") {
            ops.append("CreateMultipartUpload")
            return (makeHTTPResponse(url: url, status: 200), Data("<InitiateMultipartUploadResult><UploadId>up-123</UploadId></InitiateMultipartUploadResult>".utf8))
        }
        if method == "PUT" && query.contains("partNumber=") && query.contains("uploadId=up-123") {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let partNum = Int(items.first(where: { $0.name == "partNumber" })?.value ?? "0") ?? 0
            let shaHeader = req.value(forHTTPHeaderField: "x-amz-content-sha256") ?? ""
            let actualSHA = S3Client.sha256Hex(body)
            #expect(shaHeader == actualSHA)
            uploadedParts.append((partNum, body, shaHeader))
            ops.append("UploadPart-\(partNum)")
            return (makeHTTPResponse(url: url, status: 200, headers: ["ETag": "\"etag-\(partNum)\""]), Data())
        }
        if method == "POST" && query.contains("uploadId=up-123") {
            ops.append("CompleteMultipartUpload")
            let xmlText = String(data: body, encoding: .utf8) ?? ""
            #expect(xmlText.contains("<PartNumber>1</PartNumber>"))
            #expect(xmlText.contains("<PartNumber>2</PartNumber>"))
            #expect(xmlText.contains("<PartNumber>3</PartNumber>"))
            return (makeHTTPResponse(url: url, status: 200), Data("<CompleteMultipartUploadResult></CompleteMultipartUploadResult>".utf8))
        }
        if method == "PUT" && url.path.contains("/small.bin") {
            let shaHeader = req.value(forHTTPHeaderField: "x-amz-content-sha256") ?? ""
            #expect(shaHeader == S3Client.sha256Hex(body))
            ops.append("SinglePUT")
            return (makeHTTPResponse(url: url, status: 200), Data())
        }
        if method == "GET" && query.contains("list-type=2") {
            let listXML = """
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
              <Contents><Key>folder/one.txt</Key><Size>10</Size></Contents>
              <Contents><Key>folder/sub/two.txt</Key><Size>20</Size></Contents>
            </ListBucketResult>
            """.data(using: .utf8)!
            return (makeHTTPResponse(url: url, status: 200), listXML)
        }
        if method == "PUT" && req.value(forHTTPHeaderField: "x-amz-copy-source") != nil {
            let copySrc = req.value(forHTTPHeaderField: "x-amz-copy-source") ?? ""
            if copySrc.hasSuffix("/folder") {
                return (makeHTTPResponse(url: url, status: 404), Data())
            }
            ops.append("Copy:\(copySrc)->\(url.path)")
            return (makeHTTPResponse(url: url, status: 200), Data("<CopyObjectResult/>".utf8))
        }
        if method == "POST" && query.contains("delete") {
            let deleteXML = String(data: body, encoding: .utf8) ?? ""
            #expect(deleteXML.contains("folder/one.txt"))
            #expect(deleteXML.contains("folder/sub/two.txt"))
            ops.append("BatchDelete")
            return (makeHTTPResponse(url: url, status: 200), Data("<DeleteResult/>".utf8))
        }
        if method == "DELETE" {
            ops.append("DELETE:\(url.path)")
            return (makeHTTPResponse(url: url, status: 204), Data())
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let profile = ServerProfile(
        host: "minio.local",
        port: 9000,
        username: "AKIA",
        protocolKind: .s3,
        s3Bucket: "bucket",
        s3Region: "us-east-1",
        s3PathStyle: true
    )
    let client = S3Client(
        profile: profile,
        credentials: Credentials(password: "SECRET"),
        session: session,
        multipartThreshold: 128 * 1024,
        multipartPartSize: 90 * 1024
    )

    // Multipart upload verification
    let mpProgress = Recorder<TransferProgress>()
    try await client.upload(localFile, to: "/big.bin", overwrite: true) { p in
        mpProgress.append(p)
    }
    let parts = uploadedParts.snapshot().sorted { $0.partNumber < $1.partNumber }
    #expect(parts.count == 3)
    let reassembled = parts.reduce(into: Data()) { $0.append($1.data) }
    #expect(reassembled == payload)
    #expect(mpProgress.snapshot().last?.completed == Int64(totalSize))
    #expect(ops.snapshot().contains("CompleteMultipartUpload"))

    // Single streamed PUT (< multipartThreshold)
    let smallFile = dir.appendingPathComponent("small.bin")
    try Data("hello streamed s3".utf8).write(to: smallFile)
    try await client.upload(smallFile, to: "/small.bin", overwrite: true)
    #expect(ops.snapshot().contains("SinglePUT"))

    // Recursive folder rename & recursive folder delete
    try await client.rename("/folder", to: "/moved")
    #expect(ops.snapshot().contains("Copy:/bucket/folder/one.txt->/bucket/moved/one.txt"))
    #expect(ops.snapshot().contains("Copy:/bucket/folder/sub/two.txt->/bucket/moved/sub/two.txt"))

    try await client.remove("/folder", directory: true)
    #expect(ops.snapshot().contains("BatchDelete"))
}

@Test func s3MultipartUploadAbortsOnPartFailure() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("fail-mp.bin")
    try Data(repeating: 0xAB, count: 200 * 1024).write(to: file)

    let aborted = Recorder<String>()
    let session = MockURLProtocol.makeSession { req, _ in
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        let query = url.query ?? ""
        if method == "POST" && query.contains("uploads") {
            return (makeHTTPResponse(url: url, status: 200), Data("<InitiateMultipartUploadResult><UploadId>abort-me</UploadId></InitiateMultipartUploadResult>".utf8))
        }
        if method == "PUT" && query.contains("partNumber=1") {
            return (makeHTTPResponse(url: url, status: 200, headers: ["ETag": "\"p1\""]), Data())
        }
        if method == "PUT" && query.contains("partNumber=2") {
            return (makeHTTPResponse(url: url, status: 500), Data("boom".utf8))
        }
        if method == "DELETE" && query.contains("uploadId=abort-me") {
            aborted.append("abort-me")
            return (makeHTTPResponse(url: url, status: 204), Data())
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let profile = ServerProfile(host: "minio.local", port: 9000, username: "AKIA", protocolKind: .s3, s3Bucket: "b", s3PathStyle: true)
    let client = S3Client(profile: profile, credentials: Credentials(password: "SEC"), session: session, multipartThreshold: 100 * 1024, multipartPartSize: 100 * 1024)

    await #expect(throws: TransferError.self) {
        try await client.upload(file, to: "/fail.bin", overwrite: true)
    }
    #expect(aborted.snapshot() == ["abort-me"])
}

// MARK: - Backblaze B2 Tests

@Test func b2ClientAuthorizeListStreamedUploadDownloadAndMetadata() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePatternData(count: 210 * 1024, multiplier: 5, offset: 1)
    let localFile = dir.appendingPathComponent("b2-upload.bin")
    try payload.write(to: localFile)

    let expectedSHA1 = Insecure.SHA1.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let b2Actions = Recorder<String>()
    let uploadedBytes = Recorder<Data>()

    let session = MockURLProtocol.makeSession { req, body in
        let url = req.url!
        let path = url.path

        if path == "/b2api/v2/b2_authorize_account" {
            b2Actions.append("authorize")
            let json = """
            {
              "accountId": "acct-1",
              "authorizationToken": "auth-tok-1",
              "apiUrl": "https://b2-api.local:8443",
              "downloadUrl": "https://b2-dl.local:8443",
              "allowed": { "bucketId": "bucket-id-1", "bucketName": "backups" }
            }
            """.data(using: .utf8)!
            return (makeHTTPResponse(url: url, status: 200), json)
        }
        if path == "/b2api/v2/b2_list_file_names" {
            b2Actions.append("list")
            let bodyJSON = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            if (bodyJSON["startFileName"] as? String) == "page2" {
                let json = """
                {
                  "files": [
                    { "fileId": "fid-2", "fileName": "docs/notes.txt", "contentLength": 42, "uploadTimestamp": 1760000000000, "action": "upload" }
                  ],
                  "nextFileName": null
                }
                """.data(using: .utf8)!
                return (makeHTTPResponse(url: url, status: 200), json)
            } else {
                let json = """
                {
                  "files": [
                    { "fileId": null, "fileName": "docs/archive/", "action": "folder" },
                    { "fileId": "fid-1", "fileName": "docs/report.pdf", "contentLength": 1024, "uploadTimestamp": 1760000000000, "action": "upload" },
                    { "fileId": "fid-empty", "fileName": "docs/.bzEmpty", "contentLength": 0, "action": "upload" }
                  ],
                  "nextFileName": "page2"
                }
                """.data(using: .utf8)!
                return (makeHTTPResponse(url: url, status: 200), json)
            }
        }
        if path == "/b2api/v2/b2_get_upload_url" {
            b2Actions.append("get_upload_url")
            let json = """
            { "bucketId": "bucket-id-1", "uploadUrl": "https://b2-up.local:8443/upload/1", "authorizationToken": "up-tok-1" }
            """.data(using: .utf8)!
            return (makeHTTPResponse(url: url, status: 200), json)
        }
        if path == "/upload/1" {
            let fileNameHeader = req.value(forHTTPHeaderField: "X-Bz-File-Name") ?? ""
            b2Actions.append("upload:\(fileNameHeader)")
            if fileNameHeader.hasSuffix(".bzEmpty") {
                #expect(req.value(forHTTPHeaderField: "X-Bz-Content-Sha1") == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
            } else {
                #expect(req.value(forHTTPHeaderField: "X-Bz-Content-Sha1") == expectedSHA1)
                uploadedBytes.append(body)
            }
            return (makeHTTPResponse(url: url, status: 200), Data("{\"fileId\":\"fid-new\"}".utf8))
        }
        if path == "/file/backups/docs/report.pdf" {
            if req.httpMethod == "HEAD" {
                return (makeHTTPResponse(url: url, status: 200, headers: [
                    "Content-Type": "application/pdf",
                    "Content-Length": "\(payload.count)",
                    "X-Bz-File-Id": "fid-1",
                    "X-Bz-Info-owner": "team"
                ]), Data())
            }
            return (makeHTTPResponse(url: url, status: 200, headers: ["Content-Length": "\(payload.count)"]), payload)
        }
        if path == "/b2api/v2/b2_copy_file" {
            b2Actions.append("copy")
            return (makeHTTPResponse(url: url, status: 200), Data("{\"fileId\":\"fid-copied\",\"fileName\":\"docs/report2.pdf\"}".utf8))
        }
        if path == "/b2api/v2/b2_delete_file_version" {
            b2Actions.append("delete")
            return (makeHTTPResponse(url: url, status: 200), Data("{\"fileId\":\"fid-1\"}".utf8))
        }
        if path == "/b2api/v2/b2_get_download_authorization" {
            return (makeHTTPResponse(url: url, status: 200), Data("{\"authorizationToken\":\"dl-auth-token\"}".utf8))
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let profile = ServerProfile(
        host: "b2-api.local",
        port: 8443,
        username: "keyId123",
        protocolKind: .b2,
        b2BucketName: "backups",
        b2BucketId: "bucket-id-1"
    )
    let client = B2Client(profile: profile, credentials: Credentials(password: "appKeySecret"), session: session)

    let listed = try await client.list("/docs")
    #expect(listed.map { $0.name } == ["archive", "notes.txt", "report.pdf"])

    try await client.upload(localFile, to: "/docs/upload.bin", overwrite: true)
    #expect(uploadedBytes.snapshot().first == payload)

    try await client.mkdir("/docs/newdir")
    #expect(b2Actions.snapshot().contains("upload:docs/newdir/.bzEmpty"))

    let dlTarget = dir.appendingPathComponent("b2-dl.pdf")
    try await client.download("/docs/report.pdf", to: dlTarget, overwrite: true)
    #expect(try Data(contentsOf: dlTarget) == payload)

    let meta = try await client.statMetadata("/docs/report.pdf")
    #expect(meta.contentType == "application/pdf")
    #expect(meta.customMetadata["owner"] == "team")

    try await client.rename("/docs/report.pdf", to: "/docs/report2.pdf")
    #expect(b2Actions.snapshot().contains("copy"))
    #expect(b2Actions.snapshot().contains("delete"))

    let signedURL = try await client.presignedURL(for: "/docs/report.pdf", expiresIn: 1800)
    #expect(signedURL.absoluteString.contains("Authorization=dl-auth-token"))
}

// MARK: - Azure Blob Storage Tests

@Test func azureBlobSharedKeySigningSASXMLListingAndTransfers() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePatternData(count: 190 * 1024, multiplier: 11, offset: 2)
    let localFile = dir.appendingPathComponent("az-upload.bin")
    try payload.write(to: localFile)

    let sharedKeyBytes = makePatternData(count: 32, offset: 1).base64EncodedString()
    let seenHeaders = Recorder<[String: String]>()
    let uploadedCapture = Recorder<Data>()

    let session = MockURLProtocol.makeSession { req, body in
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        let query = url.query ?? ""

        var lowerHeaders: [String: String] = [:]
        for (k, v) in req.allHTTPHeaderFields ?? [:] {
            lowerHeaders[k.lowercased()] = v
        }
        seenHeaders.append(lowerHeaders)

        if method == "GET" && query.contains("comp=list") {
            let auth = lowerHeaders["authorization"] ?? ""
            #expect(auth.hasPrefix("SharedKey myacct:"))
            #expect(lowerHeaders["x-ms-version"] == "2021-12-02")

            if query.contains("marker=m2") {
                let xml = """
                <?xml version="1.0" encoding="utf-8"?>
                <EnumerationResults>
                  <Blobs>
                    <Blob><Name>assets/b.png</Name><Properties><Content-Length>512</Content-Length><Last-Modified>Wed, 21 Oct 2026 07:28:00 GMT</Last-Modified></Properties></Blob>
                  </Blobs>
                  <NextMarker />
                </EnumerationResults>
                """.data(using: .utf8)!
                return (makeHTTPResponse(url: url, status: 200), xml)
            } else {
                let xml = """
                <?xml version="1.0" encoding="utf-8"?>
                <EnumerationResults>
                  <Blobs>
                    <BlobPrefix><Name>assets/icons/</Name></BlobPrefix>
                    <Blob><Name>assets/a.png</Name><Properties><Content-Length>256</Content-Length><Last-Modified>Wed, 21 Oct 2026 07:28:00 GMT</Last-Modified></Properties></Blob>
                    <Blob><Name>assets/.aetherfolder</Name><Properties><Content-Length>0</Content-Length></Properties></Blob>
                  </Blobs>
                  <NextMarker>m2</NextMarker>
                </EnumerationResults>
                """.data(using: .utf8)!
                return (makeHTTPResponse(url: url, status: 200), xml)
            }
        }
        if method == "PUT" && query.contains("comp=metadata") {
            #expect(lowerHeaders["x-ms-meta-tier"] == "hot")
            return (makeHTTPResponse(url: url, status: 200), Data())
        }
        if method == "PUT" && query.contains("comp=properties") {
            #expect(lowerHeaders["x-ms-blob-content-type"] == "image/png")
            return (makeHTTPResponse(url: url, status: 200), Data())
        }
        if method == "PUT" && lowerHeaders["x-ms-blob-type"] == "BlockBlob" {
            uploadedCapture.append(body)
            return (makeHTTPResponse(url: url, status: 201), Data())
        }
        if method == "GET" && url.path.hasSuffix("/assets/a.png") {
            return (makeHTTPResponse(url: url, status: 200, headers: ["Content-Length": "\(payload.count)"]), payload)
        }
        if method == "HEAD" {
            return (makeHTTPResponse(url: url, status: 200, headers: [
                "Content-Type": "image/png",
                "x-ms-access-tier": "Cool",
                "x-ms-meta-tier": "hot",
                "Content-Length": "\(payload.count)",
                "ETag": "0x8DA"
            ]), Data())
        }
        if method == "DELETE" {
            return (makeHTTPResponse(url: url, status: 202), Data())
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let profile = ServerProfile(
        host: "127.0.0.1",
        port: 10000,
        protocolKind: .azureBlob,
        azureAccountName: "myacct",
        azureContainer: "media",
        azureUseSAS: false
    )
    let client = AzureBlobClient(profile: profile, credentials: Credentials(password: sharedKeyBytes), session: session)

    let entries = try await client.list("/assets")
    #expect(entries.map { $0.name } == ["icons", "a.png", "b.png"])

    try await client.upload(localFile, to: "/assets/up.bin", overwrite: true)
    #expect(uploadedCapture.snapshot().first == payload)

    let downloaded = dir.appendingPathComponent("az-dl.png")
    try await client.download("/assets/a.png", to: downloaded, overwrite: true)
    #expect(try Data(contentsOf: downloaded) == payload)

    let meta = try await client.statMetadata("/assets/a.png")
    #expect(meta.storageClass == "Cool")
    #expect(meta.customMetadata["tier"] == "hot")

    try await client.updateMetadata("/assets/a.png", metadata: RemoteObjectMetadata(contentType: "image/png", customMetadata: ["tier": "hot"]))

    let sasURL = try client.presignedDownloadURL(for: "/assets/a.png", expiresIn: 1200)
    #expect(sasURL.absoluteString.contains("sv=2021-12-02"))
    #expect(sasURL.absoluteString.contains("sig="))

    // SAS token client mode
    var sasProfile = profile
    sasProfile.azureUseSAS = true
    let sasClient = AzureBlobClient(profile: sasProfile, credentials: Credentials(sessionToken: "sv=2022-11-02&sig=mockSig%3D"), session: session)
    let signedSASReq = try sasClient.signedRequest(url: sasClient.endpointURL(blobKey: "assets/a.png"), method: "GET")
    #expect(signedSASReq.url?.absoluteString.contains("sig=mockSig%3D") == true)
    #expect(signedSASReq.value(forHTTPHeaderField: "Authorization") == nil)
}

// MARK: - OpenStack Swift Tests

@Test func swiftStorageAuthV1JSONListingAndTransfers() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePatternData(count: 205 * 1024, multiplier: 3, offset: 9)
    let localFile = dir.appendingPathComponent("swift-up.bin")
    try payload.write(to: localFile)

    let uploadedCapture = Recorder<Data>()
    let ops = Recorder<String>()

    let session = MockURLProtocol.makeSession { req, body in
        let url = req.url!
        let method = req.httpMethod ?? "GET"

        if url.path == "/auth/v1.0" {
            #expect(req.value(forHTTPHeaderField: "X-Auth-User") == "proj:swiftuser")
            #expect(req.value(forHTTPHeaderField: "X-Auth-Key") == "swift-secret")
            return (makeHTTPResponse(url: url, status: 200, headers: [
                "X-Auth-Token": "AUTH_tk_123",
                "X-Storage-Url": "https://swift.local:8443/v1/AUTH_proj"
            ]), Data())
        }

        #expect(req.value(forHTTPHeaderField: "X-Auth-Token") == "AUTH_tk_123")

        if method == "GET" && (url.query ?? "").contains("format=json") {
            let json = """
            [
              { "subdir": "releases/v1/" },
              { "name": "releases/app.tar.gz", "bytes": 4096, "last_modified": "2026-10-21T08:30:00.123450", "content_type": "application/gzip" }
            ]
            """.data(using: .utf8)!
            return (makeHTTPResponse(url: url, status: 200), json)
        }
        if method == "PUT" && req.value(forHTTPHeaderField: "X-Copy-From") != nil {
            ops.append("copy:\(req.value(forHTTPHeaderField: "X-Copy-From") ?? "")")
            return (makeHTTPResponse(url: url, status: 201), Data())
        }
        if method == "PUT" && req.value(forHTTPHeaderField: "Content-Type") == "application/directory" {
            ops.append("mkdir:\(url.absoluteString)")
            return (makeHTTPResponse(url: url, status: 201), Data())
        }
        if method == "PUT" {
            uploadedCapture.append(body)
            return (makeHTTPResponse(url: url, status: 201), Data())
        }
        if method == "GET" {
            return (makeHTTPResponse(url: url, status: 200, headers: ["Content-Length": "\(payload.count)"]), payload)
        }
        if method == "HEAD" {
            return (makeHTTPResponse(url: url, status: 200, headers: [
                "Content-Type": "application/gzip",
                "ETag": "swift-etag",
                "X-Object-Meta-build": "42",
                "Content-Length": "\(payload.count)"
            ]), Data())
        }
        if method == "POST" {
            #expect(req.value(forHTTPHeaderField: "X-Object-Meta-release") == "stable")
            ops.append("updateMeta")
            return (makeHTTPResponse(url: url, status: 202), Data())
        }
        if method == "DELETE" {
            ops.append("delete:\(url.path)")
            return (makeHTTPResponse(url: url, status: 204), Data())
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let profile = ServerProfile(
        host: "swift.local",
        port: 8443,
        username: "swiftuser",
        protocolKind: .openstackSwift,
        swiftAuthURL: "https://swift.local:8443/auth/v1.0",
        swiftContainer: "artifacts",
        swiftTenantOrProject: "proj"
    )
    let client = SwiftStorageClient(profile: profile, credentials: Credentials(password: "swift-secret"), session: session)

    let entries = try await client.list("/releases")
    #expect(entries.map { $0.name } == ["v1", "app.tar.gz"])
    #expect(entries[1].size == 4096)
    #expect(entries[1].modified != nil)

    try await client.upload(localFile, to: "/releases/app.bin", overwrite: true)
    #expect(uploadedCapture.snapshot().first == payload)

    let dlURL = dir.appendingPathComponent("swift-dl.bin")
    try await client.download("/releases/app.bin", to: dlURL, overwrite: true)
    #expect(try Data(contentsOf: dlURL) == payload)

    try await client.mkdir("/releases/newdir")
    #expect(ops.snapshot().contains("mkdir:https://swift.local:8443/v1/AUTH_proj/artifacts/releases/newdir/"))

    try await client.rename("/releases/app.bin", to: "/releases/app2.bin")
    #expect(ops.snapshot().contains("copy:/artifacts/releases/app.bin"))
    #expect(ops.snapshot().contains("delete:/v1/AUTH_proj/artifacts/releases/app.bin"))

    let meta = try await client.statMetadata("/releases/app.tar.gz")
    #expect(meta.customMetadata["build"] == "42")
    try await client.updateMetadata("/releases/app.tar.gz", metadata: RemoteObjectMetadata(customMetadata: ["release": "stable"]))
    #expect(ops.snapshot().contains("updateMeta"))
}

// MARK: - RemoteClient Dispatch & No Secret Leakage Tests

@Test func remoteClientPresignedURLAndNoSecretLeakageAcrossProtocols() throws {
    let s3Profile = ServerProfile(
        host: "s3.amazonaws.com",
        port: 443,
        username: "AKIA123",
        protocolKind: .s3,
        s3Bucket: "bkt",
        s3Region: "us-east-1"
    )
    let s3Remote = RemoteClient(
        profile: s3Profile,
        credentials: Credentials(password: "SUPER_SECRET_S3_KEY", sessionToken: "TOK_SECRET_999"),
        speedLimitBytesPerSec: 128_000
    )
    let s3URL = try s3Remote.presignedDownloadURL(for: "/file.zip", expiresIn: 900)
    #expect(s3URL.absoluteString.contains("X-Amz-Expires=900"))
    #expect(!s3URL.absoluteString.contains("SUPER_SECRET_S3_KEY"))

    let azProfile = ServerProfile(
        protocolKind: .azureBlob,
        azureAccountName: "acct",
        azureContainer: "cnt",
        azureUseSAS: false
    )
    let azKey = Data(repeating: 0x11, count: 32).base64EncodedString()
    let azRemote = RemoteClient(profile: azProfile, credentials: Credentials(password: azKey))
    let azURL = try azRemote.presignedDownloadURL(for: "/logo.png", expiresIn: 600)
    #expect(azURL.absoluteString.contains("https://acct.blob.core.windows.net/cnt/logo.png?"))
    #expect(!azURL.absoluteString.contains(azKey))

    let ftpsExpProfile = ServerProfile(host: "ftp.example.com", port: 21, username: "alice", protocolKind: .ftpsExplicit)
    let ftpsExpRemote = RemoteClient(profile: ftpsExpProfile, credentials: Credentials(password: "FTP_SECRET_PW"))
    let ftpsURL = try ftpsExpRemote.presignedDownloadURL(for: "/pub/readme.txt")
    #expect(ftpsURL.absoluteString == "ftp://ftp.example.com:21//pub/readme.txt")
    #expect(!ftpsURL.absoluteString.contains("FTP_SECRET_PW"))
}

@Test func b2LargeFilePartsAndCancelFallback() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let totalSize = 230 * 1024
    let payload = makePatternData(count: totalSize, multiplier: 17, offset: 5)
    let localFile = dir.appendingPathComponent("b2-large.bin")
    try payload.write(to: localFile)

    let uploadedParts = Recorder<(part: Int, data: Data, sha1: String)>()
    let finishedPayload = Recorder<[String]>()
    let canceled = Recorder<String>()
    let failOnSecondPart = Recorder<Bool>()

    let session = MockURLProtocol.makeSession { req, body in
        let url = req.url!
        switch url.path {
        case "/b2api/v2/b2_authorize_account":
            return (makeHTTPResponse(url: url, status: 200), Data("""
            {
              "accountId": "acct-2",
              "authorizationToken": "tok-2",
              "apiUrl": "https://b2-api.local",
              "downloadUrl": "https://b2-dl.local",
              "allowed": {}
            }
            """.utf8))
        case "/b2api/v2/b2_list_buckets":
            return (makeHTTPResponse(url: url, status: 200), Data("""
            { "buckets": [ { "bucketId": "resolved-bkt-id", "bucketName": "archive-bkt" } ] }
            """.utf8))
        case "/b2api/v2/b2_start_large_file":
            return (makeHTTPResponse(url: url, status: 200), Data("{\"fileId\":\"large-fid-1\"}".utf8))
        case "/b2api/v2/b2_get_upload_part_url":
            return (makeHTTPResponse(url: url, status: 200), Data("{\"uploadUrl\":\"https://b2-part.local/part\",\"authorizationToken\":\"part-tok\"}".utf8))
        case "/part":
            let partNum = Int(req.value(forHTTPHeaderField: "X-Bz-Part-Number") ?? "0") ?? 0
            if !failOnSecondPart.snapshot().isEmpty && partNum == 2 {
                return (makeHTTPResponse(url: url, status: 503), Data())
            }
            let sha1 = req.value(forHTTPHeaderField: "X-Bz-Content-Sha1") ?? ""
            let expected = Insecure.SHA1.hash(data: body).map { String(format: "%02x", $0) }.joined()
            #expect(sha1 == expected)
            uploadedParts.append((partNum, body, sha1))
            return (makeHTTPResponse(url: url, status: 200), Data("{\"partNumber\":\(partNum)}".utf8))
        case "/b2api/v2/b2_finish_large_file":
            let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            finishedPayload.append(obj["partSha1Array"] as? [String] ?? [])
            return (makeHTTPResponse(url: url, status: 200), Data("{\"fileId\":\"large-fid-1\",\"fileName\":\"big.bin\"}".utf8))
        case "/b2api/v2/b2_cancel_large_file":
            canceled.append("large-fid-1")
            return (makeHTTPResponse(url: url, status: 200), Data("{\"fileId\":\"large-fid-1\"}".utf8))
        default:
            return (makeHTTPResponse(url: url, status: 404), Data())
        }
    }

    let profile = ServerProfile(host: "b2-api.local", port: 443, username: "kid", protocolKind: .b2, b2BucketName: "archive-bkt")
    let client = B2Client(profile: profile, credentials: Credentials(password: "secret"), session: session, largeFileThreshold: 128 * 1024, partSize: 100 * 1024)

    try await client.upload(localFile, to: "/big.bin", overwrite: true)
    let parts = uploadedParts.snapshot().sorted { $0.part < $1.part }
    #expect(parts.count == 3)
    #expect(parts.reduce(into: Data()) { $0.append($1.data) } == payload)
    #expect(finishedPayload.snapshot().first == parts.map { $0.sha1 })

    // Verify failure triggers b2_cancel_large_file
    failOnSecondPart.append(true)
    await #expect(throws: TransferError.self) {
        try await client.upload(localFile, to: "/big2.bin", overwrite: true)
    }
    #expect(canceled.snapshot() == ["large-fid-1"])
}

@Test func swiftKeystoneV3AuthAndWebDAV405MetadataFallback() async throws {
    let seen = Recorder<String>()
    let session = MockURLProtocol.makeSession { req, body in
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        if url.path == "/v3/auth/tokens" {
            let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            #expect(json["auth"] != nil)
            let catalog = """
            {
              "token": {
                "catalog": [
                  {
                    "type": "object-store",
                    "endpoints": [
                      { "interface": "public", "url": "https://obj.swift.local/v1/AUTH_p1" }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
            return (makeHTTPResponse(url: url, status: 201, headers: ["X-Subject-Token": "v3-tok-abc"]), catalog)
        }
        if url.host == "obj.swift.local" {
            #expect(req.value(forHTTPHeaderField: "X-Auth-Token") == "v3-tok-abc")
            seen.append("\(method):\(url.path)")
            if method == "GET" {
                return (makeHTTPResponse(url: url, status: 200), Data("[]".utf8))
            }
            return (makeHTTPResponse(url: url, status: 204), Data())
        }
        if url.host == "dav405.local" {
            if method == "HEAD" {
                return (makeHTTPResponse(url: url, status: 405), Data())
            }
            if method == "PROPFIND" {
                let xml = """
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:">
                  <D:response>
                    <D:href>/docs/spec.md</D:href>
                    <D:propstat><D:prop>
                      <D:getcontentlength>512</D:getcontentlength>
                      <D:getlastmodified>Wed, 21 Oct 2026 07:28:00 GMT</D:getlastmodified>
                    </D:prop></D:propstat>
                  </D:response>
                </D:multistatus>
                """.data(using: .utf8)!
                return (makeHTTPResponse(url: url, status: 207), xml)
            }
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let swiftProfile = ServerProfile(
        username: "kuser",
        protocolKind: .openstackSwift,
        swiftAuthURL: "https://keystone.swift.local/v3/auth/tokens",
        swiftContainer: "logs",
        swiftTenantOrProject: "p1"
    )
    let swiftClient = SwiftStorageClient(profile: swiftProfile, credentials: Credentials(password: "kpw"), session: session)
    let items = try await swiftClient.list("/")
    #expect(items.isEmpty)
    #expect(seen.snapshot().contains("GET:/v1/AUTH_p1/logs"))

    let davProfile = ServerProfile(host: "dav405.local", port: 443, username: "u", protocolKind: .webdavs)
    let davClient = WebDAVClient(profile: davProfile, credentials: Credentials(password: "p"), session: session)
    let davMeta = try await davClient.statMetadata("/docs/spec.md")
    #expect(davMeta.size == 512)
    #expect(davMeta.modified != nil)
}

@Test func remoteClientDispatchesAllHTTPProtocolsAndForwardsSpeedLimit() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 192 KiB payload with 256 KiB/s limit via RemoteClient -> exercises speedLimitBytesPerSec forwarding
    let payload = makePatternData(count: 192 * 1024, modulus: 251)
    let localFile = dir.appendingPathComponent("rc-up.bin")
    try payload.write(to: localFile)

    let session = MockURLProtocol.makeSession { req, _ in
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        switch url.host {
        case "dav.dispatch.local":
            if method == "PROPFIND" {
                return (makeHTTPResponse(url: url, status: 207), Data("<D:multistatus xmlns:D=\"DAV:\"></D:multistatus>".utf8))
            }
            return (makeHTTPResponse(url: url, status: 201), Data())
        case "bkt.s3.us-east-1.amazonaws.com", "s3.us-east-1.amazonaws.com":
            if method == "GET" {
                return (makeHTTPResponse(url: url, status: 200), Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
            }
            return (makeHTTPResponse(url: url, status: 200), Data())
        case "b2.dispatch.local":
            if url.path == "/b2api/v2/b2_authorize_account" {
                return (makeHTTPResponse(url: url, status: 200), Data("""
                {"accountId":"a","authorizationToken":"t","apiUrl":"https://b2.dispatch.local","downloadUrl":"https://b2.dispatch.local","allowed":{"bucketId":"bid","bucketName":"b"}}
                """.utf8))
            }
            return (makeHTTPResponse(url: url, status: 200), Data("{\"files\":[],\"nextFileName\":null}".utf8))
        case "az.dispatch.local":
            return (makeHTTPResponse(url: url, status: 200), Data("<EnumerationResults><Blobs/><NextMarker/></EnumerationResults>".utf8))
        case "sw.dispatch.local":
            if url.path == "/auth/v1.0" {
                return (makeHTTPResponse(url: url, status: 200, headers: ["X-Auth-Token": "tk", "X-Storage-Url": "https://sw.dispatch.local/v1/AUTH_a"]), Data())
            }
            return (makeHTTPResponse(url: url, status: 200), Data("[]".utf8))
        default:
            return (makeHTTPResponse(url: url, status: 404), Data())
        }
    }

    let davRemote = RemoteClient(
        profile: ServerProfile(host: "dav.dispatch.local", port: 443, username: "u", protocolKind: .webdavs),
        credentials: Credentials(password: "p"),
        speedLimitBytesPerSec: 256 * 1024,
        httpSession: session
    )
    let clock = ContinuousClock()
    let start = clock.now
    try await davRemote.upload(localFile, to: "/paced.bin", overwrite: true)
    let elapsed = start.duration(to: clock.now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    #expect(seconds >= 0.25)

    let httpTransports: [RemoteClient] = [
        davRemote,
        RemoteClient(profile: ServerProfile(host: "s3.amazonaws.com", username: "AK", protocolKind: .s3, s3Bucket: "bkt"), credentials: Credentials(password: "SK"), httpSession: session),
        RemoteClient(profile: ServerProfile(host: "b2.dispatch.local", username: "kid", protocolKind: .b2, b2BucketName: "b", b2BucketId: "bid"), credentials: Credentials(password: "k"), httpSession: session),
        RemoteClient(profile: ServerProfile(host: "az.dispatch.local", protocolKind: .azureBlob, azureAccountName: "acct", azureContainer: "c"), credentials: Credentials(password: Data(repeating: 1, count: 32).base64EncodedString()), httpSession: session),
        RemoteClient(profile: ServerProfile(host: "sw.dispatch.local", username: "su", protocolKind: .openstackSwift, swiftAuthURL: "https://sw.dispatch.local/auth/v1.0", swiftContainer: "c"), credentials: Credentials(password: "sp"), httpSession: session)
    ]
    for client in httpTransports {
        let listed = try await (client as any RemoteTransport).list("/")
        #expect(listed.isEmpty)
    }
}

@Test func s3NestedListRecursiveExcludesAncestorsAndSwiftCopyEncodesContainer() async throws {
    let copyFromValues = Recorder<String>()
    let session = MockURLProtocol.makeSession { req, _ in
        let url = req.url!
        let method = req.httpMethod ?? "GET"
        if url.host == "s3.us-east-1.amazonaws.com" || url.host == "bkt.s3.us-east-1.amazonaws.com" {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
              <Contents><Key>docs/sub/</Key><Size>0</Size></Contents>
              <Contents><Key>docs/sub/a/file.txt</Key><Size>12</Size></Contents>
              <Contents><Key>docs/sub/b.txt</Key><Size>34</Size></Contents>
            </ListBucketResult>
            """.data(using: .utf8)!
            return (makeHTTPResponse(url: url, status: 200), xml)
        }
        if url.host == "swift.enc.local" {
            if url.path == "/auth/v1.0" {
                return (makeHTTPResponse(url: url, status: 200, headers: [
                    "X-Auth-Token": "tk-enc",
                    "X-Storage-Url": "https://swift.enc.local/v1/AUTH_p"
                ]), Data())
            }
            if method == "PUT", let copyFrom = req.value(forHTTPHeaderField: "X-Copy-From") {
                copyFromValues.append(copyFrom)
                return (makeHTTPResponse(url: url, status: 201), Data())
            }
            if method == "DELETE" {
                return (makeHTTPResponse(url: url, status: 204), Data())
            }
        }
        return (makeHTTPResponse(url: url, status: 404), Data())
    }

    let s3Profile = ServerProfile(host: "s3.amazonaws.com", username: "AK", protocolKind: .s3, s3Bucket: "bkt", s3PathStyle: true)
    let s3Client = S3Client(profile: s3Profile, credentials: Credentials(password: "SK"), session: session)
    let recursive = try await s3Client.listRecursive("/docs/sub")
    let paths = recursive.map(\.path)
    #expect(!paths.contains("/docs"))
    #expect(!paths.contains("/docs/sub"))
    #expect(paths == ["/docs/sub/a", "/docs/sub/a/file.txt", "/docs/sub/b.txt"])

    let swiftProfile = ServerProfile(
        host: "swift.enc.local",
        username: "u",
        protocolKind: .openstackSwift,
        swiftAuthURL: "https://swift.enc.local/auth/v1.0",
        swiftContainer: "my container"
    )
    let swiftClient = SwiftStorageClient(profile: swiftProfile, credentials: Credentials(password: "p"), session: session)
    try await swiftClient.rename("/old name.txt", to: "/new name.txt")
    #expect(copyFromValues.snapshot() == ["/my%20container/old%20name.txt"])
}


