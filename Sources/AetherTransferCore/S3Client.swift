import Foundation
import CryptoKit
import Darwin
import CTransfer

private struct S3Response: Sendable {
    let body: String
    let version: RemoteFileVersion
    let bytes: Int64
    let digest: Data?
}

/// Bucket-scoped S3 transport; uses the same bounded native worker, TLS and cancellation control.
public struct S3Client: Sendable {
    public let endpoint: S3Endpoint
    public let credentials: S3Credentials
    public let control: TransferControl?
    public let rateLimit: Int64
    public let certificateAuthority: URL?
    public init(endpoint: S3Endpoint, credentials: S3Credentials, control: TransferControl? = nil,
                rateLimit: Int64 = 0, certificateAuthority: URL? = nil) {
        self.endpoint = endpoint; self.credentials = credentials; self.control = control; self.rateLimit = max(0, rateLimit)
        self.certificateAuthority = certificateAuthority ?? Bundle.main.url(forResource: "cacert", withExtension: "pem")
    }
    private func perform(key: String = "", query: [(String, String)] = [], method: String = "GET", mode: Int32 = 0,
                         headers: [String] = [], body: String? = nil, local: URL? = nil,
                         uploadSlice: (Int64, Int64)? = nil, version: RemoteFileVersion? = nil, end: Int64 = -1,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> S3Response {
        try Task.checkCancellation(); try credentials.validate()
        let url = try endpoint.url(key: key, query: query)
        let pointer = url.withCString { at_create($0, "", "", "", "", "") }
        guard let pointer else { throw TransferError.remote("无法创建 S3 请求。") }
        let digest = mode == 5 ? NativeDigest() : nil
        let box = RequestBox(pointer: pointer, callback: progress, digest: digest)
        let allHeaders = try await S3IO.run {
            try S3Signature.headers(method: method, url: url, region: endpoint.region, credentials: credentials, headers: headers, body: body)
        } + ["Expect:"]
        let configured = method.withCString { method in allHeaders.joined(separator: "\n").withCString { headers in
            if let body { return body.withCString { at_http(pointer, method, headers, $0) } }
            return at_http(pointer, method, headers, nil)
        }}
        guard configured == 0, method.withCString({ at_s3(pointer, $0) }) == 0,
              (certificateAuthority?.path ?? "").withCString({ at_tls(pointer, 0, $0) }) == 0 else {
            throw TransferError.remote("无法配置 S3 签名或 TLS。")
        }
        if let uploadSlice, at_upload_window(pointer, uploadSlice.0, uploadSlice.1) != 0 { throw TransferError.invalidPath }
        if let version {
            try version.validate()
            guard at_transfer_window(pointer, 0, end, version.size) == 0 else { throw TransferError.invalidPath }
            at_download_limit(pointer, version.size)
        }
        if let digest {
            at_body_sink(pointer, { context, bytes, count in
                guard let context else { return }
                Unmanaged<NativeDigest>.fromOpaque(context).takeUnretainedValue().consume(bytes, count)
            }, Unmanaged.passUnretained(digest).toOpaque())
        }
        at_rate_limit(pointer, rateLimit); control?.attach(box); defer { control?.detach() }
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let code = (local?.path ?? "").withCString { path in
                    at_perform(box.pointer, mode, path, "", { context, done, total in
                        guard let context else { return }
                        Unmanaged<RequestBox>.fromOpaque(context).takeUnretainedValue().callback(TransferProgress(completed: done, total: total))
                    }, Unmanaged.passUnretained(box).toOpaque())
                }
                if code == 42 { throw CancellationError() }
                let status = at_response_code(box.pointer)
                if status == 412 || status == 409 { throw TransferError.conflict(key) }
                if status == 404 { throw S3Error.notFound }
                if status == 401 || status == 403 { throw S3Error.authentication }
                guard code == 0 else { throw TransferError.remote(String(cString: at_error(box.pointer))) }
                let accepted = method == "DELETE" ? [200, 204] : ((method == "GET" && end >= 0) ? [206] : [200])
                guard accepted.contains(Int(status)) else { throw S3Error.unsupportedResponse(Int(status)) }
                let rawETag = String(cString: at_etag(box.pointer)), time = at_file_time(box.pointer)
                return S3Response(body: String(cString: at_result(box.pointer)),
                    version: RemoteFileVersion(size: at_file_size(box.pointer), modified: time >= 0 ? time : nil,
                                               etag: rawETag.isEmpty ? nil : rawETag),
                    bytes: at_body_bytes(box.pointer), digest: digest.map { Data($0.hash.finalize()) })
            }.value
        } onCancel: { box.cancel() }
    }

    public func list(prefix: String = "") async throws -> [S3Object] {
        try S3Endpoint.validateKey(prefix)
        guard prefix.isEmpty || prefix.hasSuffix("/") else { throw TransferError.invalidPath }
        var next: String?, tokens = Set<Data>(), ids = Set<Data>(), result: [S3Object] = [], estimatedBytes = 0
        repeat {
            try Task.checkCancellation()
            var query = [("list-type", "2"), ("prefix", prefix), ("delimiter", "/"), ("encoding-type", "url"), ("max-keys", "1000")]
            if let next { query.append(("continuation-token", next)) }
            let response = try await perform(query: query)
            let page = try await S3IO.run { try S3ListingPage.parse(response.body, prefix: prefix, bucket: endpoint.bucket) }
            for object in page.objects {
                guard ids.insert(Data(object.key.utf8)).inserted else { throw TransferError.invalidListing("S3 分页包含重复对象。") }
                estimatedBytes += object.key.utf8.count * 2 + 256
                guard estimatedBytes <= 32 * 1024 * 1024, result.count < 100_000 else {
                    throw TransferError.invalidListing("S3 目录元数据超出限制，请浏览更具体的前缀。")
                }
                result.append(object)
            }
            next = page.next
            if let next, !tokens.insert(Data(next.utf8)).inserted || tokens.count > 1000 { throw TransferError.invalidListing("S3 分页没有结束。") }
        } while next != nil
        let objects = result
        return try await S3IO.run {
            try Task.checkCancellation()
            return objects.sorted { a, b in a.isPrefix != b.isPrefix ? a.isPrefix : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        }
    }
    public func fileVersion(_ key: String) async throws -> RemoteFileVersion {
        guard !key.isEmpty else { throw TransferError.invalidPath }
        let response = try await perform(key: key, method: "HEAD", mode: 6)
        try response.version.validate()
        guard response.version.etag != nil else { throw ResumeTransferError.unsupportedVersion }
        return response.version
    }
    public func contentDigest(_ key: String, version: RemoteFileVersion, prefixBytes: Int64? = nil) async throws -> Data {
        try Task.checkCancellation(); try version.validate()
        let count = prefixBytes ?? version.size
        guard count >= 0, count <= version.size, let etag = version.etag else { throw ResumeTransferError.invalidCheckpoint }
        if count == 0 { return Data(SHA256.hash(data: Data())) }
        let response = try await perform(key: key, mode: 5, headers: ["If-Match: \(etag)"], version: version,
                                         end: prefixBytes == nil ? -1 : count - 1)
        guard response.bytes == count, let hash = response.digest else { throw ResumeTransferError.sourceChanged }
        return hash
    }
    public func download(_ key: String, to destination: URL, overwrite: Bool = false,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        let version = try await fileVersion(key), expected = try await contentDigest(key, version: version)
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".aethertransfer-s3-\(UUID())")
        let partial = directory.appendingPathComponent("partial")
        try await S3IO.run { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        do {
            try await S3IO.run {
                let descriptor = partial.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
                guard descriptor >= 0 else { throw TransferError.invalidPath }
                Darwin.close(descriptor)
            }
            let response = try await perform(key: key, mode: 1, headers: ["If-Match: \(version.etag!)"], local: partial, version: version, progress: progress)
            guard response.bytes == version.size, try await S3IO.run({ try S3IO.digest(partial, size: version.size) }) == expected else {
                throw ResumeTransferError.sourceChanged
            }
            try Task.checkCancellation(); try await LocalFileCommit.commit(partial, to: destination, overwrite: overwrite)
            _ = try? await S3IO.run { try FileManager.default.removeItem(at: directory) }
        } catch {
            let cleanup = Task.detached { try? FileManager.default.removeItem(at: directory) }; await cleanup.value
            throw error
        }
    }
    /// Every part is streamed with signed SHA-256 and Content-MD5; completion commits one conditional object.
    public func upload(_ source: URL, to key: String, overwrite: Bool = false,
                       progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        guard !key.isEmpty else { throw TransferError.invalidPath }; try S3Endpoint.validateKey(key)
        let before: RemoteFileVersion?
        do { before = try await fileVersion(key) } catch S3Error.notFound { before = nil }
        if before != nil && !overwrite { throw TransferError.conflict(key) }
        let conditions = before?.etag.map { ["If-Match: \($0)"] } ?? ["If-None-Match: *"]
        progress(TransferProgress(completed: 0, total: 0, phase: "核对上传源"))
        let snapshot = try await S3IO.run { try S3UploadSnapshot.read(source) }
        if snapshot.size == 0 {
            try await S3IO.run { try snapshot.verify(source) }; try Task.checkCancellation()
            _ = try await perform(key: key, method: "PUT", mode: 2,
                headers: conditions + ["x-amz-content-sha256: \(snapshot.parts[0].sha256)", "Content-MD5: \(snapshot.parts[0].md5)"],
                local: source, uploadSlice: (0, 0), progress: progress)
            try await S3IO.run { try snapshot.verify(source) }
            return
        }
        let created = try await perform(key: key, query: [("uploads", "")], method: "POST", mode: 4)
        let initiation = try await S3IO.run { try S3XML.parse(created.body, root: "InitiateMultipartUploadResult") }
        guard let id = try initiation.value("UploadId"), !id.isEmpty, id.utf8.count <= 4096 else {
            throw TransferError.invalidListing("S3 没有返回可核对的分片上传标识。")
        }
        do {
            guard try initiation.value("Key")?.utf8.elementsEqual(key.utf8) == true, try initiation.value("Bucket") == endpoint.bucket else {
                throw S3Error.invalidMultipart
            }
            var etags: [String] = []
            for (number, part) in snapshot.parts.enumerated() {
                try Task.checkCancellation()
                let response = try await perform(key: key, query: [("uploadId", id), ("partNumber", "\(number + 1)")], method: "PUT", mode: 2,
                    headers: ["x-amz-content-sha256: \(part.sha256)", "Content-MD5: \(part.md5)"], local: source, uploadSlice: (part.start, part.length)) { value in
                        progress(TransferProgress(completed: part.start + min(part.length, value.completed), total: snapshot.size))
                    }
                guard let etag = response.version.etag else { throw S3Error.invalidMultipart }
                try RemoteFileVersion(size: 0, modified: nil, etag: etag).validate(); etags.append(etag)
            }
            try await S3IO.run { try snapshot.verify(source) }; try Task.checkCancellation()
            progress(TransferProgress(completed: snapshot.size, total: snapshot.size, phase: "提交对象"))
            let xml = "<CompleteMultipartUpload>" + etags.enumerated().map {
                "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\(S3XML.escape($0.element))</ETag></Part>"
            }.joined() + "</CompleteMultipartUpload>"
            let completed = try await perform(key: key, query: [("uploadId", id)], method: "POST", mode: 4,
                                               headers: conditions + ["Content-Type: application/xml"], body: xml)
            let result = try await S3IO.run { try S3XML.parse(completed.body, root: "CompleteMultipartUploadResult") }
            guard try result.value("Key")?.utf8.elementsEqual(key.utf8) == true, try result.value("Bucket") == endpoint.bucket,
                  let etag = try result.value("ETag") else { throw S3Error.invalidMultipart }
            try RemoteFileVersion(size: snapshot.size, modified: nil, etag: etag).validate()
        } catch {
            // Abort belongs to this upload only and is independent of the cancelled worker.
            let cleanup = S3Client(endpoint: endpoint, credentials: credentials, certificateAuthority: certificateAuthority)
            do { _ = try await Task.detached { try await cleanup.perform(key: key, query: [("uploadId", id)], method: "DELETE", mode: 4) }.value }
            catch S3Error.notFound { } // Completion may already have consumed the upload ID.
            catch { throw S3Error.cleanupRequired(S3MultipartCleanup(endpoint: endpoint, key: key, uploadID: id)) }
            throw error
        }
    }
    public func abort(_ upload: S3MultipartCleanup) async throws {
        guard upload.endpoint == endpoint, !upload.key.isEmpty, !upload.uploadID.isEmpty,
              upload.uploadID.utf8.count <= 4096 else { throw S3Error.invalidMultipart }
        do { _ = try await perform(key: upload.key, query: [("uploadId", upload.uploadID)], method: "DELETE", mode: 4) }
        catch S3Error.notFound { }
    }
    public func remove(_ key: String) async throws {
        guard !key.isEmpty else { throw TransferError.invalidPath }
        _ = try await perform(key: key, method: "DELETE", mode: 4)
    }
    public func createPrefix(_ prefix: String) async throws {
        try S3BrowserPath.validatePrefix(prefix)
        guard !prefix.isEmpty else { throw TransferError.invalidPath }
        _ = try await perform(key: prefix, method: "PUT", mode: 4, headers: ["If-None-Match: *"], body: "")
    }
    public func activeMultipartUploads() async throws -> Int {
        let response = try await perform(query: [("uploads", ""), ("max-uploads", "1000")])
        let root = try await S3IO.run { try S3XML.parse(response.body, root: "ListMultipartUploadsResult") }
        guard try root.value("IsTruncated") == "false" else { throw S3Error.invalidMultipart }
        return root.children.filter { $0.name == "Upload" }.count
    }
}

/// Identifies only the owned upload to retry aborting; never contains access credentials.
public struct S3MultipartCleanup: Codable, Hashable, Sendable {
    public let endpoint: S3Endpoint
    public let key: String
    public let uploadID: String
    public init(endpoint: S3Endpoint, key: String, uploadID: String) {
        self.endpoint = endpoint; self.key = key; self.uploadID = uploadID
    }
    public var id: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let encoded = (try? encoder.encode(endpoint)).map { $0.base64EncodedString() } ?? ""
        return Data(SHA256.hash(data: Data((encoded + "\0" + key + "\0" + uploadID).utf8))).map { String(format: "%02x", $0) }.joined()
    }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum S3Error: Error, LocalizedError, Sendable {
    case notFound, authentication, unsupportedResponse(Int), invalidMultipart, cleanupRequired(S3MultipartCleanup)
    public var errorDescription: String? {
        switch self {
        case .notFound: "S3 存储桶或对象不存在。"
        case .authentication: "S3 拒绝认证或操作，请核对访问密钥、权限和系统时间。"
        case .unsupportedResponse(let status): "S3 返回了不支持的结果（HTTP \(status)）。"
        case .invalidMultipart: "S3 分片结果不完整，未确认上传成功。"
        case .cleanupRequired: "未能清理此次 S3 分片上传，需重新连接后重试清理；未确认传输成功。"
        }
    }
}

private enum S3IO {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func digest(_ url: URL, size: Int64) throws -> Data {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw TransferError.invalidPath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size == size else {
            throw ResumeTransferError.sourceChanged
        }
        var hash = SHA256(), remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: Int(min(256 * 1024, remaining))) ?? Data()
            guard !bytes.isEmpty else { throw ResumeTransferError.sourceChanged }
            hash.update(data: bytes); remaining -= Int64(bytes.count)
        }
        guard fstat(descriptor, &after) == 0, S3UploadSnapshot.identity(before) == S3UploadSnapshot.identity(after) else {
            throw ResumeTransferError.sourceChanged
        }
        return Data(hash.finalize())
    }
}

private struct S3UploadSnapshot: Sendable {
    struct Part: Sendable { let start: Int64; let length: Int64; let sha256: String; let md5: String }
    let size: Int64
    let parts: [Part]
    private let identity: [Int64]
    static func identity(_ metadata: stat) -> [Int64] {
        [Int64(metadata.st_dev), Int64(bitPattern: metadata.st_ino), metadata.st_size,
         Int64(metadata.st_mtimespec.tv_sec), Int64(metadata.st_mtimespec.tv_nsec), Int64(metadata.st_ctimespec.tv_sec), Int64(metadata.st_ctimespec.tv_nsec)]
    }
    static func read(_ url: URL) throws -> S3UploadSnapshot {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw TransferError.invalidPath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              before.st_size <= 5 * 1024 * 1024 * 1024 * 1024 else { throw TransferError.invalidPath }
        let partSize = max(Int64(8 * 1024 * 1024), (before.st_size + 9999) / 10000)
        var parts: [Part] = [], offset: Int64 = 0
        repeat {
            var sha = SHA256(), md5 = Insecure.MD5(); let length = min(partSize, before.st_size - offset)
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                let bytes = try handle.read(upToCount: Int(min(256 * 1024, remaining))) ?? Data()
                guard !bytes.isEmpty else { throw ResumeTransferError.sourceChanged }
                sha.update(data: bytes); md5.update(data: bytes); remaining -= Int64(bytes.count)
            }
            parts.append(Part(start: offset, length: length, sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(), md5: Data(md5.finalize()).base64EncodedString()))
            offset += length
        } while offset < before.st_size
        var after = stat()
        guard fstat(descriptor, &after) == 0, identity(before) == identity(after) else { throw ResumeTransferError.sourceChanged }
        return S3UploadSnapshot(size: before.st_size, parts: parts, identity: identity(before))
    }
    func verify(_ url: URL) throws {
        var current = stat()
        guard url.path.withCString({ lstat($0, &current) }) == 0, current.st_mode & S_IFMT == S_IFREG,
              Self.identity(current) == identity else { throw ResumeTransferError.sourceChanged }
    }
}
