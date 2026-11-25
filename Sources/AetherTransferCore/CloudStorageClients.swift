import Foundation
import CryptoKit

// MARK: - Shared HTTP Streaming, Hashing, and Date Helpers

enum HTTPStreamingHelper {
    private static let formatterLock = NSLock()

    private static let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private static let rfc1123GMTFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static let swiftIsoMicroFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        return f
    }()

    private static let swiftIsoSecFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func formatRFC1123GMT(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return rfc1123GMTFormatter.string(from: date)
    }

    static func parseHTTPDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) {
            return parsed
        }
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(trimmed) {
            return parsed
        }

        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let d = rfc1123Formatter.date(from: trimmed) { return d }
        if let d = rfc1123GMTFormatter.date(from: trimmed) { return d }
        if let d = swiftIsoMicroFormatter.date(from: trimmed) { return d }
        if let d = swiftIsoSecFormatter.date(from: trimmed) { return d }
        return nil
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func percentEncodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    static func performData(session: URLSession, request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        do {
            let result = try await session.data(for: request)
            try Task.checkCancellation()
            return result
        } catch let urlError as URLError where urlError.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    static func fileSize(at url: URL) async throws -> Int64 {
        try await ResumeIO.run {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    static func streamDigest<H: HashFunction>(
        fileAt url: URL,
        offset: Int64 = 0,
        length: Int64? = nil,
        using _: H.Type
    ) async throws -> (hex: String, byteCount: Int64) {
        try await ResumeIO.run {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let totalSize = try Int64(handle.seekToEnd())
            let start = max(0, offset)
            guard start <= totalSize else { throw TransferError.invalidPath }
            let targetLength = length.map { max(0, min($0, totalSize - start)) } ?? (totalSize - start)
            try handle.seek(toOffset: UInt64(start))

            var hasher = H()
            var remaining = targetLength
            var processed: Int64 = 0
            let chunkSize = StreamingThrottler.defaultChunkSize

            while remaining > 0 {
                try Task.checkCancellation()
                let toRead = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
                remaining -= Int64(chunk.count)
                processed += Int64(chunk.count)
            }
            let digest = hasher.finalize()
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return (hex, processed)
        }
    }

    static func sendStreamedUpload(
        session: URLSession,
        request: URLRequest,
        fileURL: URL,
        offset: Int64 = 0,
        length: Int64,
        speedLimitBytesPerSec: Int64?,
        progress: @escaping @Sendable (TransferProgress) -> Void,
        totalReportedSize: Int64? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var req = request
        let reportedTotal = totalReportedSize ?? (offset + length)

        if length <= 0 {
            req.httpBody = Data()
            req.setValue("0", forHTTPHeaderField: "Content-Length")
            progress(TransferProgress(completed: offset, total: reportedTotal))
            let (data, response) = try await performData(session: session, request: req)
            guard let http = response as? HTTPURLResponse else {
                throw TransferError.remote(L10n.tr("无效的 HTTP 响应。", "Invalid HTTP response."))
            }
            return (data, http)
        }

        let throttler = StreamingThrottler(speedLimitBytesPerSec: speedLimitBytesPerSec)
        let (inputStream, feedTask) = try throttler.pipeFileToBoundStream(
            at: fileURL,
            offset: offset,
            length: length
        ) { chunkProgress in
            progress(TransferProgress(completed: chunkProgress.completed, total: reportedTotal))
        }
        req.httpBodyStream = inputStream
        req.setValue("\(length)", forHTTPHeaderField: "Content-Length")

        do {
            let (data, response) = try await withTaskCancellationHandler {
                try await session.data(for: req)
            } onCancel: {
                feedTask.cancel()
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                feedTask.cancel()
                throw TransferError.remote(L10n.tr("无效的 HTTP 响应。", "Invalid HTTP response."))
            }
            if (200...299).contains(http.statusCode) {
                try await feedTask.value
            } else {
                feedTask.cancel()
            }
            return (data, http)
        } catch let urlError as URLError where urlError.code == .cancelled || Task.isCancelled {
            feedTask.cancel()
            throw CancellationError()
        } catch {
            feedTask.cancel()
            throw error
        }
    }

    static func streamDownload(
        session: URLSession,
        request: URLRequest,
        destination: URL,
        overwrite: Bool,
        offset: Int64?,
        stagingURL: URL?,
        speedLimitBytesPerSec: Int64?,
        preserveModificationDate: Bool,
        protocolLabel: String,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) && !overwrite {
            throw TransferError.conflict(destination.lastPathComponent)
        }

        let temporary = stagingURL ?? destination.deletingLastPathComponent()
            .appendingPathComponent(".aethertransfer-\(UUID().uuidString).part")
        defer {
            if stagingURL == nil {
                try? fm.removeItem(at: temporary)
            }
        }

        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError where urlError.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        }

        guard let http = response as? HTTPURLResponse else {
            throw TransferError.remote(L10n.tr("\(protocolLabel) 响应无效。", "Invalid \(protocolLabel) response."))
        }
        guard (200...299).contains(http.statusCode) else {
            throw TransferError.remote("\(protocolLabel) GET HTTP \(http.statusCode)")
        }

        let effectiveOffset: Int64 = (http.statusCode == 206) ? max(0, offset ?? 0) : 0
        let expectedTotal: Int64
        if http.statusCode == 206, let rangeTotal = contentRangeTotal(http) {
            expectedTotal = rangeTotal
        } else if http.expectedContentLength > 0 {
            expectedTotal = effectiveOffset + http.expectedContentLength
        } else {
            expectedTotal = -1
        }

        let throttler = StreamingThrottler(speedLimitBytesPerSec: speedLimitBytesPerSec)
        do {
            _ = try await throttler.writeAsyncBytes(
                asyncBytes,
                to: temporary,
                expectedTotal: expectedTotal,
                appendOffset: effectiveOffset,
                progress: progress
            )
        } catch let urlError as URLError where urlError.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        }

        try Task.checkCancellation()
        try await LocalFileCommit.commit(temporary, to: destination, overwrite: overwrite)

        if preserveModificationDate {
            var mtime = parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified"))
            if mtime == nil,
               let tsStr = http.value(forHTTPHeaderField: "X-Bz-Upload-Timestamp"),
               let ms = Double(tsStr.trimmingCharacters(in: .whitespacesAndNewlines)),
               ms > 0 {
                mtime = Date(timeIntervalSince1970: ms / 1000.0)
            }
            if let mtime {
                try? await ResumeIO.run {
                    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: destination.path)
                }
            }
        }
    }

    static func checkConflict(
        transport: any RemoteTransport,
        remote: String,
        overwrite: Bool,
        offset: Int64?
    ) async throws {
        guard !overwrite && offset == nil else { return }
        let parent = RemotePath.parent(remote)
        let name = URL(fileURLWithPath: remote).lastPathComponent
        let existing = (try? await transport.list(parent)) ?? []
        if existing.contains(where: { $0.name == name }) {
            throw TransferError.conflict(name)
        }
    }

    private static func contentRangeTotal(_ http: HTTPURLResponse) -> Int64? {
        guard let header = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        guard let slashIdx = header.lastIndex(of: "/") else { return nil }
        let suffix = header[header.index(after: slashIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(suffix)
    }
}

// MARK: - Backblaze B2 Native API v2 Client

public final class B2Client: RemoteTransport, @unchecked Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let session: URLSession
    public let speedLimitBytesPerSec: Int64?
    public let largeFileThreshold: Int64
    public let partSize: Int64

    private struct AuthContext: Sendable {
        let accountId: String
        let authorizationToken: String
        let apiUrl: String
        let downloadUrl: String
        let bucketId: String
        let bucketName: String
    }

    private let authLock = NSLock()
    private var cachedAuth: AuthContext?

    public init(
        profile: ServerProfile,
        credentials: Credentials,
        session: URLSession = .shared,
        speedLimitBytesPerSec: Int64? = nil,
        largeFileThreshold: Int64 = 16 * 1024 * 1024,
        partSize: Int64 = 8 * 1024 * 1024
    ) {
        self.profile = profile
        self.credentials = credentials
        self.session = session
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.largeFileThreshold = max(1024, largeFileThreshold)
        self.partSize = max(1024, partSize)
    }

    private var keyId: String { profile.username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var applicationKey: String { credentials.password }
    private var configuredBucketName: String { profile.b2BucketName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var configuredBucketId: String { profile.b2BucketId.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func authEndpointURL() throws -> URL {
        let rawHost = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = rawHost.isEmpty ? "api.backblazeb2.com" : rawHost
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if profile.port > 0 && profile.port != 443 {
            components.port = profile.port
        }
        components.path = "/b2api/v2/b2_authorize_account"
        guard let url = components.url else { throw TransferError.invalidConnection }
        return url
    }

    public static func b2Key(for remotePath: String, isDirectory: Bool) -> String {
        S3Client.s3ObjectKey(for: remotePath, isDirectory: isDirectory)
    }

    private func authorize(forceRefresh: Bool = false) async throws -> AuthContext {
        if !forceRefresh, let existing = authLock.withLock({ cachedAuth }) {
            return existing
        }

        guard !keyId.isEmpty else { throw TransferError.invalidConnection }
        let url = try authEndpointURL()
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "GET"
        let authPair = "\(keyId):\(applicationKey)"
        guard let pairData = authPair.data(using: .utf8) else { throw TransferError.invalidConnection }
        req.setValue("Basic \(pairData.base64EncodedString())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("B2 b2_authorize_account HTTP \(status)")
        }

        let decoded = try JSONDecoder().decode(B2AuthorizeResponse.self, from: data)
        var resolvedBucketId = configuredBucketId.isEmpty ? (decoded.allowed?.bucketId ?? "") : configuredBucketId
        var resolvedBucketName = configuredBucketName.isEmpty ? (decoded.allowed?.bucketName ?? "") : configuredBucketName

        if resolvedBucketId.isEmpty || resolvedBucketName.isEmpty {
            let buckets = try await listBuckets(
                apiUrl: decoded.apiUrl,
                authToken: decoded.authorizationToken,
                accountId: decoded.accountId
            )
            if resolvedBucketId.isEmpty, !resolvedBucketName.isEmpty,
               let match = buckets.first(where: { $0.bucketName == resolvedBucketName }) {
                resolvedBucketId = match.bucketId
            } else if resolvedBucketName.isEmpty, !resolvedBucketId.isEmpty,
                      let match = buckets.first(where: { $0.bucketId == resolvedBucketId }) {
                resolvedBucketName = match.bucketName
            }
        }

        guard !resolvedBucketId.isEmpty else {
            throw TransferError.invalidConnection
        }

        let context = AuthContext(
            accountId: decoded.accountId,
            authorizationToken: decoded.authorizationToken,
            apiUrl: decoded.apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            downloadUrl: decoded.downloadUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            bucketId: resolvedBucketId,
            bucketName: resolvedBucketName
        )
        authLock.withLock {
            cachedAuth = context
        }
        return context
    }

    private func listBuckets(apiUrl: String, authToken: String, accountId: String) async throws -> [B2BucketInfo] {
        guard let url = URL(string: "\(apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/b2api/v2/b2_list_buckets") else {
            throw TransferError.invalidConnection
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(authToken, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["accountId": accountId])
        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("B2 b2_list_buckets HTTP \(status)")
        }
        return try JSONDecoder().decode(B2ListBucketsResponse.self, from: data).buckets
    }

    private func apiPostJSON<T: Decodable>(path: String, body: [String: Any], auth: AuthContext) async throws -> T {
        guard let url = URL(string: "\(auth.apiUrl)\(path)") else {
            throw TransferError.invalidConnection
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("B2 \(path) HTTP \(status)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try Task.checkCancellation()
        let auth = try await authorize()
        let normalized = RemotePath.normalize(path)
        let prefix = Self.b2Key(for: normalized, isDirectory: true)

        var entries: [FileEntry] = []
        var seen = Set<String>()
        var nextFileName: String?

        while true {
            try Task.checkCancellation()
            var payload: [String: Any] = [
                "bucketId": auth.bucketId,
                "prefix": prefix,
                "delimiter": "/",
                "maxFileCount": 1000
            ]
            if let nextFileName, !nextFileName.isEmpty {
                payload["startFileName"] = nextFileName
            }
            let page: B2ListFilesResponse = try await apiPostJSON(path: "/b2api/v2/b2_list_file_names", body: payload, auth: auth)
            for item in page.files {
                if item.action == "hide" || item.action == "start" { continue }
                let fileName = item.fileName
                guard !fileName.isEmpty, fileName != prefix else { continue }
                let rel = (!prefix.isEmpty && fileName.hasPrefix(prefix))
                    ? String(fileName.dropFirst(prefix.count))
                    : fileName
                let isDir = item.action == "folder" || rel.hasSuffix("/")
                let cleanName = isDir ? String(rel.dropLast()) : rel
                guard !cleanName.isEmpty, cleanName != ".bzEmpty", !cleanName.contains("/") else { continue }

                let fullPath = (try? RemotePath.join(normalized, cleanName)) ?? (normalized + "/" + cleanName)
                if seen.insert(fullPath).inserted {
                    let modified = item.uploadTimestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000.0) : nil }
                    entries.append(FileEntry(
                        name: cleanName,
                        path: fullPath,
                        isDirectory: isDir,
                        size: isDir ? 0 : (item.contentLength ?? 0),
                        modified: modified,
                        permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--"
                    ))
                }
            }
            if let next = page.nextFileName, !next.isEmpty, next != nextFileName {
                nextFileName = next
            } else {
                break
            }
        }
        return FileEntry.sorted(entries)
    }

    private func listAllFiles(withPrefix prefix: String, auth: AuthContext) async throws -> [B2FileItem] {
        var collected: [B2FileItem] = []
        var nextFileName: String?
        while true {
            try Task.checkCancellation()
            var payload: [String: Any] = [
                "bucketId": auth.bucketId,
                "prefix": prefix,
                "maxFileCount": 1000
            ]
            if let nextFileName, !nextFileName.isEmpty {
                payload["startFileName"] = nextFileName
            }
            let page: B2ListFilesResponse = try await apiPostJSON(path: "/b2api/v2/b2_list_file_names", body: payload, auth: auth)
            collected.append(contentsOf: page.files.filter { $0.action != "folder" && $0.action != "hide" })
            if let next = page.nextFileName, !next.isEmpty, next != nextFileName {
                nextFileName = next
            } else {
                break
            }
        }
        return collected
    }

    private func downloadFileURL(for remotePath: String, auth: AuthContext) throws -> URL {
        guard !auth.bucketName.isEmpty else { throw TransferError.invalidConnection }
        let key = Self.b2Key(for: remotePath, isDirectory: false)
        let encodedBucket = HTTPStreamingHelper.percentEncodePath(auth.bucketName)
        let encodedKey = HTTPStreamingHelper.percentEncodePath(key)
        guard let url = URL(string: "\(auth.downloadUrl)/file/\(encodedBucket)/\(encodedKey)") else {
            throw TransferError.invalidConnection
        }
        return url
    }

    public func download(
        _ remote: String,
        to destination: URL,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingURL: URL? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        let auth = try await authorize()
        let url = try downloadFileURL(for: remote, auth: auth)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "GET"
        req.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")
        if let offset, offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        try await HTTPStreamingHelper.streamDownload(
            session: session,
            request: req,
            destination: destination,
            overwrite: overwrite,
            offset: offset,
            stagingURL: stagingURL,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            preserveModificationDate: profile.preserveModificationDate,
            protocolLabel: "B2",
            progress: progress
        )
    }

    public func upload(
        _ local: URL,
        to remote: String,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingRemotePath: String? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        try await HTTPStreamingHelper.checkConflict(transport: self, remote: remote, overwrite: overwrite, offset: offset)
        let auth = try await authorize()
        let key = Self.b2Key(for: remote, isDirectory: false)
        let fileSize = try await HTTPStreamingHelper.fileSize(at: local)

        if fileSize > largeFileThreshold {
            try await uploadLargeFile(local: local, key: key, fileSize: fileSize, auth: auth, progress: progress)
            return
        }

        let (sha1Hex, byteCount) = try await HTTPStreamingHelper.streamDigest(fileAt: local, using: Insecure.SHA1.self)
        let uploadTicket: B2UploadURLResponse = try await apiPostJSON(
            path: "/b2api/v2/b2_get_upload_url",
            body: ["bucketId": auth.bucketId],
            auth: auth
        )
        guard let uploadURL = URL(string: uploadTicket.uploadUrl) else {
            throw TransferError.invalidConnection
        }
        var req = URLRequest(url: uploadURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(uploadTicket.authorizationToken, forHTTPHeaderField: "Authorization")
        req.setValue(Self.b2PercentEncode(key), forHTTPHeaderField: "X-Bz-File-Name")
        req.setValue("b2/x-auto", forHTTPHeaderField: "Content-Type")
        req.setValue("\(byteCount)", forHTTPHeaderField: "Content-Length")
        req.setValue(sha1Hex, forHTTPHeaderField: "X-Bz-Content-Sha1")

        let (_, http) = try await HTTPStreamingHelper.sendStreamedUpload(
            session: session,
            request: req,
            fileURL: local,
            offset: 0,
            length: byteCount,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            progress: progress
        )
        guard (200...299).contains(http.statusCode) else {
            throw TransferError.remote("B2 b2_upload_file HTTP \(http.statusCode)")
        }
    }

    private func uploadLargeFile(
        local: URL,
        key: String,
        fileSize: Int64,
        auth: AuthContext,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let startResp: B2StartLargeFileResponse = try await apiPostJSON(
            path: "/b2api/v2/b2_start_large_file",
            body: [
                "bucketId": auth.bucketId,
                "fileName": key,
                "contentType": "b2/x-auto"
            ],
            auth: auth
        )
        let fileId = startResp.fileId
        var partSha1s: [String] = []

        do {
            var offset: Int64 = 0
            var partNumber = 1
            while offset < fileSize {
                try Task.checkCancellation()
                let length = min(partSize, fileSize - offset)
                let (sha1Hex, _) = try await HTTPStreamingHelper.streamDigest(
                    fileAt: local,
                    offset: offset,
                    length: length,
                    using: Insecure.SHA1.self
                )
                let partTicket: B2UploadPartURLResponse = try await apiPostJSON(
                    path: "/b2api/v2/b2_get_upload_part_url",
                    body: ["fileId": fileId],
                    auth: auth
                )
                guard let partURL = URL(string: partTicket.uploadUrl) else {
                    throw TransferError.invalidConnection
                }
                var req = URLRequest(url: partURL, timeoutInterval: 60)
                req.httpMethod = "POST"
                req.setValue(partTicket.authorizationToken, forHTTPHeaderField: "Authorization")
                req.setValue("\(partNumber)", forHTTPHeaderField: "X-Bz-Part-Number")
                req.setValue("\(length)", forHTTPHeaderField: "Content-Length")
                req.setValue(sha1Hex, forHTTPHeaderField: "X-Bz-Content-Sha1")

                let (_, http) = try await HTTPStreamingHelper.sendStreamedUpload(
                    session: session,
                    request: req,
                    fileURL: local,
                    offset: offset,
                    length: length,
                    speedLimitBytesPerSec: speedLimitBytesPerSec,
                    progress: progress,
                    totalReportedSize: fileSize
                )
                guard (200...299).contains(http.statusCode) else {
                    throw TransferError.remote("B2 b2_upload_part \(partNumber) HTTP \(http.statusCode)")
                }
                partSha1s.append(sha1Hex)
                offset += length
                partNumber += 1
            }

            let _: B2FileItem = try await apiPostJSON(
                path: "/b2api/v2/b2_finish_large_file",
                body: [
                    "fileId": fileId,
                    "partSha1Array": partSha1s
                ],
                auth: auth
            )
        } catch {
            let clientCopy = self
            _ = try? await Task.detached {
                let _: B2CancelResponse = try await clientCopy.apiPostJSON(
                    path: "/b2api/v2/b2_cancel_large_file",
                    body: ["fileId": fileId],
                    auth: auth
                )
            }.value
            throw error
        }
    }

    public func mkdir(_ path: String) async throws {
        try Task.checkCancellation()
        let prefix = Self.b2Key(for: path, isDirectory: true)
        guard !prefix.isEmpty else { return }
        let auth = try await authorize()
        let uploadTicket: B2UploadURLResponse = try await apiPostJSON(
            path: "/b2api/v2/b2_get_upload_url",
            body: ["bucketId": auth.bucketId],
            auth: auth
        )
        guard let uploadURL = URL(string: uploadTicket.uploadUrl) else {
            throw TransferError.invalidConnection
        }
        var req = URLRequest(url: uploadURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(uploadTicket.authorizationToken, forHTTPHeaderField: "Authorization")
        req.setValue(Self.b2PercentEncode(prefix + ".bzEmpty"), forHTTPHeaderField: "X-Bz-File-Name")
        req.setValue("application/x-directory", forHTTPHeaderField: "Content-Type")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.setValue("da39a3ee5e6b4b0d3255bfef95601890afd80709", forHTTPHeaderField: "X-Bz-Content-Sha1")
        req.httpBody = Data()

        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("B2 mkdir HTTP \(status)")
        }
    }

    public func rename(_ source: String, to destination: String) async throws {
        try Task.checkCancellation()
        let auth = try await authorize()
        let srcKey = Self.b2Key(for: source, isDirectory: false)
        let dstKey = Self.b2Key(for: destination, isDirectory: false)

        let exactFiles = try await listAllFiles(withPrefix: srcKey, auth: auth)
        if !source.hasSuffix("/"), let fileItem = exactFiles.first(where: { $0.fileName == srcKey }), let fileId = fileItem.fileId {
            let _: B2FileItem = try await apiPostJSON(
                path: "/b2api/v2/b2_copy_file",
                body: [
                    "sourceFileId": fileId,
                    "fileName": dstKey,
                    "destinationBucketId": auth.bucketId
                ],
                auth: auth
            )
            let _: B2DeleteResponse = try await apiPostJSON(
                path: "/b2api/v2/b2_delete_file_version",
                body: ["fileName": fileItem.fileName, "fileId": fileId],
                auth: auth
            )
            return
        }

        let srcPrefix = Self.b2Key(for: source, isDirectory: true)
        let dstPrefix = Self.b2Key(for: destination, isDirectory: true)
        let folderFiles = try await listAllFiles(withPrefix: srcPrefix, auth: auth)
        guard !folderFiles.isEmpty else {
            throw TransferError.remote("B2 file not found: \(source)")
        }
        for item in folderFiles {
            guard let fileId = item.fileId else { continue }
            let suffix = item.fileName.hasPrefix(srcPrefix) ? String(item.fileName.dropFirst(srcPrefix.count)) : item.fileName
            let targetKey = dstPrefix + suffix
            let _: B2FileItem = try await apiPostJSON(
                path: "/b2api/v2/b2_copy_file",
                body: [
                    "sourceFileId": fileId,
                    "fileName": targetKey,
                    "destinationBucketId": auth.bucketId
                ],
                auth: auth
            )
            let _: B2DeleteResponse = try await apiPostJSON(
                path: "/b2api/v2/b2_delete_file_version",
                body: ["fileName": item.fileName, "fileId": fileId],
                auth: auth
            )
        }
    }

    public func remove(_ path: String, directory: Bool) async throws {
        try Task.checkCancellation()
        let auth = try await authorize()
        if !directory {
            let key = Self.b2Key(for: path, isDirectory: false)
            let matches = try await listAllFiles(withPrefix: key, auth: auth)
            guard let item = matches.first(where: { $0.fileName == key }), let fileId = item.fileId else {
                throw TransferError.remote("B2 file not found: \(path)")
            }
            let _: B2DeleteResponse = try await apiPostJSON(
                path: "/b2api/v2/b2_delete_file_version",
                body: ["fileName": item.fileName, "fileId": fileId],
                auth: auth
            )
            return
        }

        let prefix = Self.b2Key(for: path, isDirectory: true)
        guard !prefix.isEmpty else { throw TransferError.invalidPath }
        let items = try await listAllFiles(withPrefix: prefix, auth: auth)
        for item in items {
            try Task.checkCancellation()
            guard let fileId = item.fileId else { continue }
            let _: B2DeleteResponse = try await apiPostJSON(
                path: "/b2api/v2/b2_delete_file_version",
                body: ["fileName": item.fileName, "fileId": fileId],
                auth: auth
            )
        }
    }

    public func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata {
        try Task.checkCancellation()
        let auth = try await authorize()
        let url = try downloadFileURL(for: remotePath, auth: auth)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "HEAD"
        req.setValue(auth.authorizationToken, forHTTPHeaderField: "Authorization")

        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.remote(L10n.tr("B2 响应无效。", "Invalid B2 response."))
        }
        if (200...299).contains(http.statusCode) {
            var custom: [String: String] = [:]
            for (rawKey, rawVal) in http.allHeaderFields {
                let lower = String(describing: rawKey).lowercased()
                if lower.hasPrefix("x-bz-info-") {
                    custom[String(lower.dropFirst("x-bz-info-".count))] = String(describing: rawVal)
                }
            }
            var modified = HTTPStreamingHelper.parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified"))
            if modified == nil,
               let ts = http.value(forHTTPHeaderField: "X-Bz-Upload-Timestamp"),
               let ms = Double(ts.trimmingCharacters(in: .whitespacesAndNewlines)), ms > 0 {
                modified = Date(timeIntervalSince1970: ms / 1000.0)
            }
            let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
                ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
            return RemoteObjectMetadata(
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                customMetadata: custom,
                etag: http.value(forHTTPHeaderField: "X-Bz-Content-Sha1") ?? http.value(forHTTPHeaderField: "X-Bz-File-Id"),
                size: size,
                modified: modified
            )
        }
        if http.statusCode == 405 {
            let key = Self.b2Key(for: remotePath, isDirectory: false)
            let files = try await listAllFiles(withPrefix: key, auth: auth)
            if let item = files.first(where: { $0.fileName == key }) {
                let modified = item.uploadTimestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000.0) : nil }
                return RemoteObjectMetadata(
                    contentType: item.contentType,
                    etag: item.fileId,
                    size: item.contentLength,
                    modified: modified
                )
            }
        }
        throw TransferError.remote("B2 HEAD HTTP \(http.statusCode)")
    }

    public func presignedURL(for remotePath: String, expiresIn seconds: Int = 3600) async throws -> URL {
        try Task.checkCancellation()
        let auth = try await authorize()
        let key = Self.b2Key(for: remotePath, isDirectory: false)
        let validDuration = min(604_800, max(1, seconds))
        let resp: B2DownloadAuthResponse = try await apiPostJSON(
            path: "/b2api/v2/b2_get_download_authorization",
            body: [
                "bucketId": auth.bucketId,
                "fileNamePrefix": key,
                "validDurationInSeconds": validDuration
            ],
            auth: auth
        )
        let base = try downloadFileURL(for: remotePath, auth: auth)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "Authorization", value: resp.authorizationToken)]
        guard let signedURL = components?.url else {
            throw TransferError.invalidConnection
        }
        return signedURL
    }

    private static func b2PercentEncode(_ input: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        allowed.remove(charactersIn: "")
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }
}

private struct B2AuthorizeResponse: Decodable {
    struct Allowed: Decodable {
        let bucketId: String?
        let bucketName: String?
    }
    let accountId: String
    let authorizationToken: String
    let apiUrl: String
    let downloadUrl: String
    let allowed: Allowed?
}

private struct B2BucketInfo: Decodable {
    let bucketId: String
    let bucketName: String
}

private struct B2ListBucketsResponse: Decodable {
    let buckets: [B2BucketInfo]
}

private struct B2FileItem: Decodable {
    let fileId: String?
    let fileName: String
    let contentLength: Int64?
    let uploadTimestamp: Int64?
    let action: String?
    let contentType: String?
}

private struct B2ListFilesResponse: Decodable {
    let files: [B2FileItem]
    let nextFileName: String?
}

private struct B2UploadURLResponse: Decodable {
    let uploadUrl: String
    let authorizationToken: String
}

private struct B2StartLargeFileResponse: Decodable {
    let fileId: String
}

private struct B2UploadPartURLResponse: Decodable {
    let uploadUrl: String
    let authorizationToken: String
}

private struct B2DeleteResponse: Decodable {
    let fileId: String?
}

private struct B2CancelResponse: Decodable {
    let fileId: String?
}

private struct B2DownloadAuthResponse: Decodable {
    let authorizationToken: String
}

// MARK: - Azure Blob Storage REST API Client

public struct AzureBlobClient: RemoteTransport, Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let session: URLSession
    public let speedLimitBytesPerSec: Int64?

    private static let apiVersion = "2021-12-02"
    private static let folderMarkerName = ".aetherfolder"

    public init(
        profile: ServerProfile,
        credentials: Credentials,
        session: URLSession = .shared,
        speedLimitBytesPerSec: Int64? = nil
    ) {
        self.profile = profile
        self.credentials = credentials
        self.session = session
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
    }

    public var accountName: String {
        let acct = profile.azureAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return acct.isEmpty ? profile.username.trimmingCharacters(in: .whitespacesAndNewlines) : acct
    }
    public var container: String { profile.azureContainer.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sharedKey: String { credentials.password.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sasToken: String {
        let raw = credentials.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasPrefix("?") ? String(raw.dropFirst()) : raw
    }

    private var usesSAS: Bool {
        (profile.azureUseSAS && !sasToken.isEmpty) || (sharedKey.isEmpty && !sasToken.isEmpty)
    }

    public func endpointURL(blobKey: String = "", queryItems: [URLQueryItem] = []) throws -> URL {
        guard !container.isEmpty else { throw TransferError.invalidConnection }
        let rawHost = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if rawHost.isEmpty {
            guard !accountName.isEmpty else { throw TransferError.invalidConnection }
            host = "\(accountName).blob.core.windows.net"
        } else {
            host = rawHost
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if profile.port > 0 && profile.port != 443 {
            components.port = profile.port
        }
        let cleanBlob = blobKey.hasPrefix("/") ? String(blobKey.dropFirst()) : blobKey
        components.path = cleanBlob.isEmpty ? "/\(container)" : "/\(container)/\(cleanBlob)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw TransferError.invalidConnection }
        return url
    }

    public static func azureBlobKey(for remotePath: String, isDirectory: Bool) -> String {
        S3Client.s3ObjectKey(for: remotePath, isDirectory: isDirectory)
    }

    public func signedRequest(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        contentLength: Int64? = nil,
        now: Date = Date()
    ) throws -> URLRequest {
        if usesSAS {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let existing = components?.percentEncodedQuery
            if let existing, !existing.isEmpty {
                components?.percentEncodedQuery = "\(existing)&\(sasToken)"
            } else {
                components?.percentEncodedQuery = sasToken
            }
            guard let sasURL = components?.url else { throw TransferError.invalidConnection }
            var req = URLRequest(url: sasURL, timeoutInterval: 60)
            req.httpMethod = method
            req.setValue(Self.apiVersion, forHTTPHeaderField: "x-ms-version")
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
            return req
        }

        guard !accountName.isEmpty, let keyData = Data(base64Encoded: sharedKey), !keyData.isEmpty else {
            throw TransferError.invalidConnection
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method

        var mergedHeaders: [String: String] = [
            "x-ms-date": HTTPStreamingHelper.formatRFC1123GMT(now),
            "x-ms-version": Self.apiVersion
        ]
        for (k, v) in headers {
            mergedHeaders[k] = v
        }
        for (k, v) in mergedHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }

        func header(_ name: String) -> String {
            mergedHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }

        let contentLengthHeader: String
        if let contentLength, contentLength > 0 {
            contentLengthHeader = "\(contentLength)"
        } else {
            let explicit = header("Content-Length")
            contentLengthHeader = (explicit.isEmpty || explicit == "0") ? "" : explicit
        }

        let xmsHeaders = mergedHeaders
            .compactMap { key, val -> (String, String)? in
                let lower = key.lowercased()
                guard lower.hasPrefix("x-ms-") else { return nil }
                return (lower, val.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()

        let canonicalResource = Self.canonicalizedResource(accountName: accountName, url: url)
        let stringToSign = [
            method.uppercased(),
            header("Content-Encoding"),
            header("Content-Language"),
            contentLengthHeader,
            header("Content-MD5"),
            header("Content-Type"),
            "", // Date is omitted because x-ms-date is sent
            header("If-Modified-Since"),
            header("If-Match"),
            header("If-None-Match"),
            header("If-Unmodified-Since"),
            header("Range"),
            xmsHeaders + canonicalResource
        ].joined(separator: "\n")

        let mac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: keyData))
        let signature = Data(mac).base64EncodedString()
        req.setValue("SharedKey \(accountName):\(signature)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func canonicalizedResource(accountName: String, url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? url.path
        var result = "/\(accountName)\(path)"
        if let items = components?.queryItems, !items.isEmpty {
            var grouped: [String: [String]] = [:]
            for item in items {
                grouped[item.name.lowercased(), default: []].append(item.value ?? "")
            }
            for key in grouped.keys.sorted() {
                let values = grouped[key]!.sorted().joined(separator: ",")
                result += "\n\(key):\(values)"
            }
        }
        return result
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try Task.checkCancellation()
        let normalized = RemotePath.normalize(path)
        let prefix = Self.azureBlobKey(for: normalized, isDirectory: true)
        var allEntries: [FileEntry] = []
        var seen = Set<String>()
        var marker: String?

        while true {
            try Task.checkCancellation()
            var queryItems = [
                URLQueryItem(name: "restype", value: "container"),
                URLQueryItem(name: "comp", value: "list"),
                URLQueryItem(name: "delimiter", value: "/")
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let marker, !marker.isEmpty {
                queryItems.append(URLQueryItem(name: "marker", value: marker))
            }
            let url = try endpointURL(blobKey: "", queryItems: queryItems)
            let req = try signedRequest(url: url, method: "GET")
            let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TransferError.remote("Azure Blob List HTTP \(status)")
            }
            let page = try Self.parseListBlobsXML(data, requestedPath: normalized)
            for entry in page.entries where seen.insert(entry.path).inserted {
                allEntries.append(entry)
            }
            if let next = page.nextMarker, !next.isEmpty, next != marker {
                marker = next
            } else {
                break
            }
        }
        return FileEntry.sorted(allEntries)
    }

    private func listAllBlobNames(withPrefix prefix: String) async throws -> [String] {
        var names: [String] = []
        var marker: String?
        while true {
            try Task.checkCancellation()
            var queryItems = [
                URLQueryItem(name: "restype", value: "container"),
                URLQueryItem(name: "comp", value: "list")
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let marker, !marker.isEmpty {
                queryItems.append(URLQueryItem(name: "marker", value: marker))
            }
            let url = try endpointURL(blobKey: "", queryItems: queryItems)
            let req = try signedRequest(url: url, method: "GET")
            let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TransferError.remote("Azure Blob List HTTP \(status)")
            }
            let page = try Self.parseRawBlobNamesXML(data)
            names.append(contentsOf: page.names)
            if let next = page.nextMarker, !next.isEmpty, next != marker {
                marker = next
            } else {
                break
            }
        }
        return names
    }

    public func download(
        _ remote: String,
        to destination: URL,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingURL: URL? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        let key = Self.azureBlobKey(for: remote, isDirectory: false)
        let url = try endpointURL(blobKey: key)
        var headers: [String: String] = [:]
        if let offset, offset > 0 {
            headers["Range"] = "bytes=\(offset)-"
        }
        let req = try signedRequest(url: url, method: "GET", headers: headers)
        try await HTTPStreamingHelper.streamDownload(
            session: session,
            request: req,
            destination: destination,
            overwrite: overwrite,
            offset: offset,
            stagingURL: stagingURL,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            preserveModificationDate: profile.preserveModificationDate,
            protocolLabel: "Azure Blob",
            progress: progress
        )
    }

    public func upload(
        _ local: URL,
        to remote: String,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingRemotePath: String? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        try await HTTPStreamingHelper.checkConflict(transport: self, remote: remote, overwrite: overwrite, offset: offset)

        let key = Self.azureBlobKey(for: remote, isDirectory: false)
        let url = try endpointURL(blobKey: key)
        let fileSize = try await HTTPStreamingHelper.fileSize(at: local)
        let headers: [String: String] = [
            "x-ms-blob-type": "BlockBlob",
            "Content-Length": "\(fileSize)"
        ]
        let req = try signedRequest(url: url, method: "PUT", headers: headers, contentLength: fileSize)
        let (_, http) = try await HTTPStreamingHelper.sendStreamedUpload(
            session: session,
            request: req,
            fileURL: local,
            offset: 0,
            length: fileSize,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            progress: progress
        )
        guard (200...299).contains(http.statusCode) else {
            throw TransferError.remote("Azure Blob PUT HTTP \(http.statusCode)")
        }
    }

    public func mkdir(_ path: String) async throws {
        try Task.checkCancellation()
        let prefix = Self.azureBlobKey(for: path, isDirectory: true)
        guard !prefix.isEmpty else { return }
        let markerKey = prefix + Self.folderMarkerName
        let url = try endpointURL(blobKey: markerKey)
        var req = try signedRequest(
            url: url,
            method: "PUT",
            headers: [
                "x-ms-blob-type": "BlockBlob",
                "Content-Length": "0"
            ],
            contentLength: 0
        )
        req.httpBody = Data()
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Azure Blob mkdir HTTP \(status)")
        }
    }

    public func rename(_ source: String, to destination: String) async throws {
        try Task.checkCancellation()
        let srcKey = Self.azureBlobKey(for: source, isDirectory: false)
        let dstKey = Self.azureBlobKey(for: destination, isDirectory: false)

        if !source.hasSuffix("/") && !srcKey.isEmpty {
            let status = try await copyBlob(fromKey: srcKey, toKey: dstKey)
            if (200...299).contains(status) {
                try await deleteBlob(key: srcKey)
                return
            }
            if status != 404 {
                throw TransferError.remote("Azure Blob Copy HTTP \(status)")
            }
        }

        let srcPrefix = Self.azureBlobKey(for: source, isDirectory: true)
        let dstPrefix = Self.azureBlobKey(for: destination, isDirectory: true)
        let blobs = try await listAllBlobNames(withPrefix: srcPrefix)
        guard !blobs.isEmpty else {
            throw TransferError.remote("Azure Blob not found: \(source)")
        }
        for name in blobs {
            try Task.checkCancellation()
            let suffix = name.hasPrefix(srcPrefix) ? String(name.dropFirst(srcPrefix.count)) : name
            let status = try await copyBlob(fromKey: name, toKey: dstPrefix + suffix)
            guard (200...299).contains(status) else {
                throw TransferError.remote("Azure Blob Copy HTTP \(status)")
            }
            try await deleteBlob(key: name)
        }
    }

    private func copyBlob(fromKey srcKey: String, toKey dstKey: String) async throws -> Int {
        let srcURL = try endpointURL(blobKey: srcKey)
        let copySourceString: String
        if usesSAS {
            copySourceString = "\(srcURL.absoluteString)?\(sasToken)"
        } else {
            copySourceString = srcURL.absoluteString
        }
        let dstURL = try endpointURL(blobKey: dstKey)
        let req = try signedRequest(
            url: dstURL,
            method: "PUT",
            headers: ["x-ms-copy-source": copySourceString]
        )
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func deleteBlob(key: String) async throws {
        let url = try endpointURL(blobKey: key)
        let req = try signedRequest(url: url, method: "DELETE")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Azure Blob DELETE HTTP \(status)")
        }
    }

    public func remove(_ path: String, directory: Bool) async throws {
        try Task.checkCancellation()
        if !directory {
            try await deleteBlob(key: Self.azureBlobKey(for: path, isDirectory: false))
            return
        }
        let prefix = Self.azureBlobKey(for: path, isDirectory: true)
        guard !prefix.isEmpty else { throw TransferError.invalidPath }
        let names = try await listAllBlobNames(withPrefix: prefix)
        for name in names {
            try Task.checkCancellation()
            try await deleteBlob(key: name)
        }
    }

    public func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata {
        try Task.checkCancellation()
        let key = Self.azureBlobKey(for: remotePath, isDirectory: false)
        let url = try endpointURL(blobKey: key)
        let req = try signedRequest(url: url, method: "HEAD")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Azure Blob HEAD HTTP \(status)")
        }
        var custom: [String: String] = [:]
        for (rawKey, rawVal) in http.allHeaderFields {
            let lower = String(describing: rawKey).lowercased()
            if lower.hasPrefix("x-ms-meta-") {
                custom[String(lower.dropFirst("x-ms-meta-".count))] = String(describing: rawVal)
            }
        }
        let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
        return RemoteObjectMetadata(
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
            storageClass: http.value(forHTTPHeaderField: "x-ms-access-tier"),
            customMetadata: custom,
            etag: http.value(forHTTPHeaderField: "ETag"),
            size: size,
            modified: HTTPStreamingHelper.parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified"))
        )
    }

    public func updateMetadata(_ remotePath: String, metadata: RemoteObjectMetadata) async throws {
        try Task.checkCancellation()
        let key = Self.azureBlobKey(for: remotePath, isDirectory: false)

        var metaHeaders: [String: String] = [:]
        for (k, v) in metadata.customMetadata {
            let cleanKey = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleanKey.isEmpty else { continue }
            let headerKey = cleanKey.hasPrefix("x-ms-meta-") ? cleanKey : "x-ms-meta-\(cleanKey)"
            metaHeaders[headerKey] = v
        }
        let metaURL = try endpointURL(blobKey: key, queryItems: [URLQueryItem(name: "comp", value: "metadata")])
        let metaReq = try signedRequest(url: metaURL, method: "PUT", headers: metaHeaders)
        let (_, metaResp) = try await HTTPStreamingHelper.performData(session: session, request: metaReq)
        guard let metaHTTP = metaResp as? HTTPURLResponse, (200...299).contains(metaHTTP.statusCode) else {
            let status = (metaResp as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Azure Blob SetMetadata HTTP \(status)")
        }

        var propHeaders: [String: String] = [:]
        if let ct = metadata.contentType?.trimmingCharacters(in: .whitespacesAndNewlines), !ct.isEmpty {
            propHeaders["x-ms-blob-content-type"] = ct
        }
        if let cc = metadata.cacheControl?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
            propHeaders["x-ms-blob-cache-control"] = cc
        }
        if !propHeaders.isEmpty {
            let propURL = try endpointURL(blobKey: key, queryItems: [URLQueryItem(name: "comp", value: "properties")])
            let propReq = try signedRequest(url: propURL, method: "PUT", headers: propHeaders)
            let (_, propResp) = try await HTTPStreamingHelper.performData(session: session, request: propReq)
            guard let propHTTP = propResp as? HTTPURLResponse, (200...299).contains(propHTTP.statusCode) else {
                let status = (propResp as? HTTPURLResponse)?.statusCode ?? -1
                throw TransferError.remote("Azure Blob SetProperties HTTP \(status)")
            }
        }
    }

    public func presignedURL(for remotePath: String, expiresIn seconds: Int = 3600) async throws -> URL {
        try presignedDownloadURL(for: remotePath, expiresIn: seconds)
    }

    public func presignedDownloadURL(for remotePath: String, expiresIn seconds: Int = 3600, now: Date = Date()) throws -> URL {
        let key = Self.azureBlobKey(for: remotePath, isDirectory: false)
        let baseURL = try endpointURL(blobKey: key)

        if usesSAS {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.percentEncodedQuery = sasToken
            guard let url = components?.url else { throw TransferError.invalidConnection }
            return url
        }

        guard !accountName.isEmpty, let keyData = Data(base64Encoded: sharedKey), !keyData.isEmpty else {
            throw TransferError.invalidConnection
        }
        let clamped = min(604_800, max(60, seconds))
        let start = now.addingTimeInterval(-60)
        let expiry = now.addingTimeInterval(TimeInterval(clamped))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)

        let st = iso.string(from: start)
        let se = iso.string(from: expiry)
        let canonicalResource = "/blob/\(accountName)/\(container)/\(key)"
        let stringToSign = [
            "r",               // sp
            st,                // st
            se,                // se
            canonicalResource, // canonicalizedResource
            "",                // signedIdentifier
            "",                // signedIP
            "https",           // spr
            Self.apiVersion,   // sv
            "b",               // sr
            "",                // snapshotTime
            "",                // encryptionScope
            "", "", "", "", "" // rscc, rscd, rsce, rscl, rsct
        ].joined(separator: "\n")

        let mac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: keyData))
        let sig = Data(mac).base64EncodedString()

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let queryPairs: [(String, String)] = [
            ("sv", Self.apiVersion),
            ("sr", "b"),
            ("sp", "r"),
            ("st", st),
            ("se", se),
            ("spr", "https"),
            ("sig", sig)
        ]
        components?.percentEncodedQuery = queryPairs
            .map { "\(S3Client.awsURIEnode($0.0, encodeSlash: true))=\(S3Client.awsURIEnode($0.1, encodeSlash: true))" }
            .joined(separator: "&")
        guard let signedURL = components?.url else { throw TransferError.invalidConnection }
        return signedURL
    }

    // MARK: - Azure EnumerationResults XML Parser
    public static func parseListBlobsXML(_ data: Data, requestedPath: String) throws -> (entries: [FileEntry], nextMarker: String?) {
        let normalized = RemotePath.normalize(requestedPath)
        let prefix = azureBlobKey(for: normalized, isDirectory: true)
        let delegate = AzureListBlobsXMLDelegate(requestedPath: normalized, requestedPrefix: prefix)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw TransferError.invalidListing("Azure Blob XML parse error")
        }
        return (FileEntry.sorted(delegate.entries), delegate.nextMarker)
    }

    private static func parseRawBlobNamesXML(_ data: Data) throws -> (names: [String], nextMarker: String?) {
        let delegate = AzureListBlobsXMLDelegate(requestedPath: "/", requestedPrefix: "")
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw TransferError.invalidListing("Azure Blob XML parse error")
        }
        return (delegate.rawBlobNames, delegate.nextMarker)
    }
}

private final class AzureListBlobsXMLDelegate: NSObject, XMLParserDelegate {
    let requestedPath: String
    let requestedPrefix: String
    var entries: [FileEntry] = []
    var rawBlobNames: [String] = []
    var nextMarker: String?

    private var section = ""
    private var inProperties = false
    private var currentElement = ""
    private var currentName = ""
    private var currentSize = ""
    private var currentLastModified = ""
    private var markerBuffer = ""

    init(requestedPath: String, requestedPrefix: String) {
        self.requestedPath = requestedPath
        self.requestedPrefix = requestedPrefix
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "Blob" {
            section = "Blob"
            inProperties = false
            currentName = ""
            currentSize = ""
            currentLastModified = ""
        } else if elementName == "BlobPrefix" {
            section = "BlobPrefix"
            currentName = ""
        } else if section == "Blob" && elementName == "Properties" {
            inProperties = true
        } else if elementName == "NextMarker" {
            markerBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if section == "Blob" {
            if !inProperties && currentElement == "Name" {
                currentName += string
            } else if inProperties {
                switch currentElement {
                case "Content-Length": currentSize += string
                case "Last-Modified": currentLastModified += string
                default: break
                }
            }
        } else if section == "BlobPrefix" && currentElement == "Name" {
            currentName += string
        } else if currentElement == "NextMarker" {
            markerBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Properties" {
            inProperties = false
        } else if elementName == "Blob" {
            section = ""
            appendBlob()
        } else if elementName == "BlobPrefix" {
            section = ""
            appendPrefix()
        } else if elementName == "NextMarker" {
            let trimmed = markerBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { nextMarker = trimmed }
        }
        currentElement = ""
    }

    private func appendBlob() {
        let key = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        rawBlobNames.append(key)
        guard key != requestedPrefix else { return }

        let rel = (!requestedPrefix.isEmpty && key.hasPrefix(requestedPrefix))
            ? String(key.dropFirst(requestedPrefix.count))
            : key
        let isDir = rel.hasSuffix("/")
        let cleanName = isDir ? String(rel.dropLast()) : rel
        guard !cleanName.isEmpty, cleanName != ".aetherfolder", cleanName != ".bzEmpty", !cleanName.contains("/") else { return }

        let fullPath = (try? RemotePath.join(requestedPath, cleanName)) ?? (requestedPath + "/" + cleanName)
        let size = isDir ? 0 : (Int64(currentSize.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        let modified = HTTPStreamingHelper.parseHTTPDate(currentLastModified)
        if !entries.contains(where: { $0.path == fullPath }) {
            entries.append(FileEntry(
                name: cleanName,
                path: fullPath,
                isDirectory: isDir,
                size: size,
                modified: modified,
                permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--"
            ))
        }
    }

    private func appendPrefix() {
        let prefix = currentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, prefix != requestedPrefix else { return }
        let rel = (!requestedPrefix.isEmpty && prefix.hasPrefix(requestedPrefix))
            ? String(prefix.dropFirst(requestedPrefix.count))
            : prefix
        let cleanName = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
        guard !cleanName.isEmpty, !cleanName.contains("/") else { return }
        let fullPath = (try? RemotePath.join(requestedPath, cleanName)) ?? (requestedPath + "/" + cleanName)
        if !entries.contains(where: { $0.path == fullPath }) {
            entries.append(FileEntry(
                name: cleanName,
                path: fullPath,
                isDirectory: true,
                size: 0,
                modified: nil,
                permissions: "drwxr-xr-x"
            ))
        }
    }
}

// MARK: - OpenStack Swift REST API Client

public final class SwiftStorageClient: RemoteTransport, @unchecked Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let session: URLSession
    public let speedLimitBytesPerSec: Int64?

    private struct SwiftAuthState: Sendable {
        let token: String
        let storageURL: String
    }

    private let authLock = NSLock()
    private var cachedAuth: SwiftAuthState?

    public init(
        profile: ServerProfile,
        credentials: Credentials,
        session: URLSession = .shared,
        speedLimitBytesPerSec: Int64? = nil
    ) {
        self.profile = profile
        self.credentials = credentials
        self.session = session
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
    }

    private var container: String { profile.swiftContainer.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tenantOrProject: String { profile.swiftTenantOrProject.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func authenticate() async throws -> SwiftAuthState {
        if let existing = authLock.withLock({ cachedAuth }) {
            return existing
        }

        let suppliedToken = credentials.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAuthURL = profile.swiftAuthURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct token mode (no password needed when sessionToken is supplied and authURL is storage base or host is set)
        if !suppliedToken.isEmpty && credentials.password.isEmpty {
            let base = resolveDirectStorageURL(from: rawAuthURL)
            let state = SwiftAuthState(token: suppliedToken, storageURL: base)
            cache(state)
            return state
        }

        let authURL = try resolvedAuthURL(from: rawAuthURL)
        if authURL.path.contains("/v3") {
            let state = try await authenticateKeystoneV3(authURL: authURL)
            cache(state)
            return state
        } else {
            let state = try await authenticateV1(authURL: authURL)
            cache(state)
            return state
        }
    }

    private func cache(_ state: SwiftAuthState) {
        authLock.lock()
        cachedAuth = state
        authLock.unlock()
    }

    private func resolveDirectStorageURL(from rawAuthURL: String) -> String {
        if !rawAuthURL.isEmpty && !rawAuthURL.contains("/auth/") && !rawAuthURL.contains("/v3") {
            return rawAuthURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portPart = (profile.port > 0 && profile.port != 443) ? ":\(profile.port)" : ""
        let account = tenantOrProject.isEmpty ? "AUTH_\(profile.username)" : "AUTH_\(tenantOrProject)"
        return "https://\(host)\(portPart)/v1/\(account)"
    }

    private func resolvedAuthURL(from rawAuthURL: String) throws -> URL {
        if !rawAuthURL.isEmpty {
            if rawAuthURL.hasSuffix("/v3") {
                guard let url = URL(string: rawAuthURL + "/auth/tokens") else { throw TransferError.invalidConnection }
                return url
            }
            guard let url = URL(string: rawAuthURL) else { throw TransferError.invalidConnection }
            return url
        }
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw TransferError.invalidConnection }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if profile.port > 0 && profile.port != 443 {
            components.port = profile.port
        }
        components.path = "/auth/v1.0"
        guard let url = components.url else { throw TransferError.invalidConnection }
        return url
    }

    private func authenticateV1(authURL: URL) async throws -> SwiftAuthState {
        var req = URLRequest(url: authURL, timeoutInterval: 60)
        req.httpMethod = "GET"
        let authUser: String
        if !tenantOrProject.isEmpty && !profile.username.contains(":") {
            authUser = "\(tenantOrProject):\(profile.username)"
        } else {
            authUser = profile.username
        }
        req.setValue(authUser, forHTTPHeaderField: "X-Auth-User")
        req.setValue(credentials.password, forHTTPHeaderField: "X-Auth-Key")

        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Swift Auth v1 HTTP \(status)")
        }
        guard let token = http.value(forHTTPHeaderField: "X-Auth-Token"), !token.isEmpty,
              let storage = http.value(forHTTPHeaderField: "X-Storage-Url"), !storage.isEmpty else {
            throw TransferError.remote(L10n.tr("Swift 认证响应缺少 X-Auth-Token 或 X-Storage-Url。", "Swift auth response missing X-Auth-Token or X-Storage-Url."))
        }
        return SwiftAuthState(
            token: token,
            storageURL: storage.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }

    private func authenticateKeystoneV3(authURL: URL) async throws -> SwiftAuthState {
        let identity: [String: Any] = [
            "methods": ["password"],
            "password": [
                "user": [
                    "name": profile.username,
                    "domain": ["name": "Default"],
                    "password": credentials.password
                ]
            ]
        ]
        var body: [String: Any] = ["identity": identity]
        if !tenantOrProject.isEmpty {
            body["scope"] = [
                "project": [
                    "name": tenantOrProject,
                    "domain": ["name": "Default"]
                ]
            ]
        }
        var req = URLRequest(url: authURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["auth": body])

        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Swift Keystone v3 HTTP \(status)")
        }
        guard let token = http.value(forHTTPHeaderField: "X-Subject-Token") ?? http.value(forHTTPHeaderField: "X-Auth-Token"),
              !token.isEmpty else {
            throw TransferError.remote(L10n.tr("Swift Keystone 响应缺少认证令牌。", "Swift Keystone response missing auth token."))
        }

        var storageURL = http.value(forHTTPHeaderField: "X-Storage-Url")
        if storageURL == nil,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokenObj = json["token"] as? [String: Any],
           let catalog = tokenObj["catalog"] as? [[String: Any]] {
            for service in catalog where (service["type"] as? String) == "object-store" {
                if let endpoints = service["endpoints"] as? [[String: Any]] {
                    if let pub = endpoints.first(where: { ($0["interface"] as? String) == "public" })?["url"] as? String {
                        storageURL = pub
                        break
                    }
                    if let first = endpoints.first?["url"] as? String {
                        storageURL = first
                        break
                    }
                }
            }
        }
        let resolvedStorage = (storageURL ?? resolveDirectStorageURL(from: profile.swiftAuthURL))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return SwiftAuthState(token: token, storageURL: resolvedStorage)
    }

    private func containerURL(auth: SwiftAuthState, queryItems: [URLQueryItem] = []) throws -> URL {
        guard !container.isEmpty else { throw TransferError.invalidConnection }
        let encodedContainer = HTTPStreamingHelper.percentEncodePath(container)
        guard var components = URLComponents(string: "\(auth.storageURL)/\(encodedContainer)") else {
            throw TransferError.invalidConnection
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw TransferError.invalidConnection }
        return url
    }

    private func objectURL(for remotePath: String, isDirectory: Bool = false, auth: SwiftAuthState) throws -> URL {
        guard !container.isEmpty else { throw TransferError.invalidConnection }
        let key = S3Client.s3ObjectKey(for: remotePath, isDirectory: isDirectory)
        let encodedContainer = HTTPStreamingHelper.percentEncodePath(container)
        let encodedKey = HTTPStreamingHelper.percentEncodePath(key)
        guard let url = URL(string: "\(auth.storageURL)/\(encodedContainer)/\(encodedKey)") else {
            throw TransferError.invalidConnection
        }
        return url
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try Task.checkCancellation()
        let auth = try await authenticate()
        let normalized = RemotePath.normalize(path)
        let prefix = S3Client.s3ObjectKey(for: normalized, isDirectory: true)

        var entries: [FileEntry] = []
        var seen = Set<String>()
        var marker: String?
        let pageLimit = 10_000

        while true {
            try Task.checkCancellation()
            var queryItems = [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "delimiter", value: "/"),
                URLQueryItem(name: "limit", value: "\(pageLimit)")
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let marker, !marker.isEmpty {
                queryItems.append(URLQueryItem(name: "marker", value: marker))
            }
            let url = try containerURL(auth: auth, queryItems: queryItems)
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.httpMethod = "GET"
            req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")

            let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TransferError.remote("Swift List HTTP \(status)")
            }
            let items = try JSONDecoder().decode([SwiftObjectListItem].self, from: data)
            var lastKey: String?
            for item in items {
                if let subdir = item.subdir {
                    lastKey = subdir
                    let rel = (!prefix.isEmpty && subdir.hasPrefix(prefix))
                        ? String(subdir.dropFirst(prefix.count))
                        : subdir
                    let cleanName = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
                    guard !cleanName.isEmpty, !cleanName.contains("/") else { continue }
                    let fullPath = (try? RemotePath.join(normalized, cleanName)) ?? (normalized + "/" + cleanName)
                    if seen.insert(fullPath).inserted {
                        entries.append(FileEntry(
                            name: cleanName,
                            path: fullPath,
                            isDirectory: true,
                            size: 0,
                            modified: nil,
                            permissions: "drwxr-xr-x"
                        ))
                    }
                } else if let name = item.name {
                    lastKey = name
                    guard name != prefix else { continue }
                    let rel = (!prefix.isEmpty && name.hasPrefix(prefix))
                        ? String(name.dropFirst(prefix.count))
                        : name
                    let isDir = rel.hasSuffix("/") || item.content_type == "application/directory"
                    let cleanName = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
                    guard !cleanName.isEmpty, !cleanName.contains("/") else { continue }
                    let fullPath = (try? RemotePath.join(normalized, cleanName)) ?? (normalized + "/" + cleanName)
                    if seen.insert(fullPath).inserted {
                        entries.append(FileEntry(
                            name: cleanName,
                            path: fullPath,
                            isDirectory: isDir,
                            size: isDir ? 0 : (item.bytes ?? 0),
                            modified: HTTPStreamingHelper.parseHTTPDate(item.last_modified),
                            permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--"
                        ))
                    }
                }
            }
            if items.count < pageLimit || lastKey == nil || lastKey == marker {
                break
            }
            marker = lastKey
        }
        return FileEntry.sorted(entries)
    }

    private func listAllObjectNames(withPrefix prefix: String, auth: SwiftAuthState) async throws -> [String] {
        var names: [String] = []
        var marker: String?
        let pageLimit = 10_000
        while true {
            try Task.checkCancellation()
            var queryItems = [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "limit", value: "\(pageLimit)")
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let marker, !marker.isEmpty {
                queryItems.append(URLQueryItem(name: "marker", value: marker))
            }
            let url = try containerURL(auth: auth, queryItems: queryItems)
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.httpMethod = "GET"
            req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")

            let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TransferError.remote("Swift List HTTP \(status)")
            }
            let items = try JSONDecoder().decode([SwiftObjectListItem].self, from: data)
            let batchNames = items.compactMap(\.name)
            names.append(contentsOf: batchNames)
            if items.count < pageLimit || batchNames.last == nil || batchNames.last == marker {
                break
            }
            marker = batchNames.last
        }
        return names
    }

    public func download(
        _ remote: String,
        to destination: URL,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingURL: URL? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        let auth = try await authenticate()
        let url = try objectURL(for: remote, isDirectory: false, auth: auth)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "GET"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")
        if let offset, offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        try await HTTPStreamingHelper.streamDownload(
            session: session,
            request: req,
            destination: destination,
            overwrite: overwrite,
            offset: offset,
            stagingURL: stagingURL,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            preserveModificationDate: profile.preserveModificationDate,
            protocolLabel: "Swift",
            progress: progress
        )
    }

    public func upload(
        _ local: URL,
        to remote: String,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingRemotePath: String? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        try await HTTPStreamingHelper.checkConflict(transport: self, remote: remote, overwrite: overwrite, offset: offset)
        let auth = try await authenticate()
        let url = try objectURL(for: remote, isDirectory: false, auth: auth)
        let fileSize = try await HTTPStreamingHelper.fileSize(at: local)

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "PUT"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")
        req.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")

        let (_, http) = try await HTTPStreamingHelper.sendStreamedUpload(
            session: session,
            request: req,
            fileURL: local,
            offset: 0,
            length: fileSize,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            progress: progress
        )
        guard (200...299).contains(http.statusCode) else {
            throw TransferError.remote("Swift PUT HTTP \(http.statusCode)")
        }
    }

    public func mkdir(_ path: String) async throws {
        try Task.checkCancellation()
        let auth = try await authenticate()
        let key = S3Client.s3ObjectKey(for: path, isDirectory: true)
        guard !key.isEmpty else { return }
        let url = try objectURL(for: path, isDirectory: true, auth: auth)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "PUT"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")
        req.setValue("application/directory", forHTTPHeaderField: "Content-Type")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.httpBody = Data()
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Swift mkdir HTTP \(status)")
        }
    }

    public func rename(_ source: String, to destination: String) async throws {
        try Task.checkCancellation()
        let auth = try await authenticate()
        let srcKey = S3Client.s3ObjectKey(for: source, isDirectory: false)
        let dstKey = S3Client.s3ObjectKey(for: destination, isDirectory: false)

        if !source.hasSuffix("/") && !srcKey.isEmpty {
            let status = try await copyObject(fromKey: srcKey, toKey: dstKey, auth: auth)
            if (200...299).contains(status) {
                try await deleteObject(key: srcKey, auth: auth)
                return
            }
            if status != 404 {
                throw TransferError.remote("Swift Copy HTTP \(status)")
            }
        }

        let srcPrefix = S3Client.s3ObjectKey(for: source, isDirectory: true)
        let dstPrefix = S3Client.s3ObjectKey(for: destination, isDirectory: true)
        let names = try await listAllObjectNames(withPrefix: srcPrefix, auth: auth)
        guard !names.isEmpty else {
            throw TransferError.remote("Swift object not found: \(source)")
        }
        for name in names {
            try Task.checkCancellation()
            let suffix = name.hasPrefix(srcPrefix) ? String(name.dropFirst(srcPrefix.count)) : name
            let status = try await copyObject(fromKey: name, toKey: dstPrefix + suffix, auth: auth)
            guard (200...299).contains(status) else {
                throw TransferError.remote("Swift Copy HTTP \(status)")
            }
            try await deleteObject(key: name, auth: auth)
        }
    }

    private func copyObject(fromKey srcKey: String, toKey dstKey: String, auth: SwiftAuthState) async throws -> Int {
        let encodedContainer = HTTPStreamingHelper.percentEncodePath(container)
        let encodedDst = HTTPStreamingHelper.percentEncodePath(dstKey)
        guard let dstURL = URL(string: "\(auth.storageURL)/\(encodedContainer)/\(encodedDst)") else {
            throw TransferError.invalidConnection
        }
        var req = URLRequest(url: dstURL, timeoutInterval: 60)
        req.httpMethod = "PUT"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")
        req.setValue("/\(container)/\(HTTPStreamingHelper.percentEncodePath(srcKey))", forHTTPHeaderField: "X-Copy-From")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        req.httpBody = Data()
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func deleteObject(key: String, auth: SwiftAuthState) async throws {
        let encodedContainer = HTTPStreamingHelper.percentEncodePath(container)
        let encodedKey = HTTPStreamingHelper.percentEncodePath(key)
        guard let url = URL(string: "\(auth.storageURL)/\(encodedContainer)/\(encodedKey)") else {
            throw TransferError.invalidConnection
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "DELETE"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Swift DELETE HTTP \(status)")
        }
    }

    public func remove(_ path: String, directory: Bool) async throws {
        try Task.checkCancellation()
        let auth = try await authenticate()
        if !directory {
            try await deleteObject(key: S3Client.s3ObjectKey(for: path, isDirectory: false), auth: auth)
            return
        }
        let prefix = S3Client.s3ObjectKey(for: path, isDirectory: true)
        guard !prefix.isEmpty else { throw TransferError.invalidPath }
        let names = try await listAllObjectNames(withPrefix: prefix, auth: auth)
        if names.isEmpty {
            try await deleteObject(key: prefix, auth: auth)
            return
        }
        for name in names {
            try Task.checkCancellation()
            try await deleteObject(key: name, auth: auth)
        }
    }

    public func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata {
        try Task.checkCancellation()
        let auth = try await authenticate()
        let url = try objectURL(for: remotePath, isDirectory: false, auth: auth)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "HEAD"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Swift HEAD HTTP \(status)")
        }
        var custom: [String: String] = [:]
        for (rawKey, rawVal) in http.allHeaderFields {
            let lower = String(describing: rawKey).lowercased()
            if lower.hasPrefix("x-object-meta-") {
                custom[String(lower.dropFirst("x-object-meta-".count))] = String(describing: rawVal)
            }
        }
        let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
        return RemoteObjectMetadata(
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            customMetadata: custom,
            etag: http.value(forHTTPHeaderField: "ETag"),
            size: size,
            modified: HTTPStreamingHelper.parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified"))
        )
    }

    public func updateMetadata(_ remotePath: String, metadata: RemoteObjectMetadata) async throws {
        try Task.checkCancellation()
        let auth = try await authenticate()
        let url = try objectURL(for: remotePath, isDirectory: false, auth: auth)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(auth.token, forHTTPHeaderField: "X-Auth-Token")
        if let ct = metadata.contentType?.trimmingCharacters(in: .whitespacesAndNewlines), !ct.isEmpty {
            req.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in metadata.customMetadata {
            let cleanKey = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleanKey.isEmpty else { continue }
            let headerKey = cleanKey.hasPrefix("x-object-meta-") ? cleanKey : "x-object-meta-\(cleanKey)"
            req.setValue(v, forHTTPHeaderField: headerKey)
        }
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("Swift POST metadata HTTP \(status)")
        }
    }
}

private struct SwiftObjectListItem: Decodable {
    let name: String?
    let subdir: String?
    let bytes: Int64?
    let last_modified: String?
    let hash: String?
    let content_type: String?
}
