import Foundation
import CryptoKit

public struct S3Client: RemoteTransport, Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let session: URLSession
    public let speedLimitBytesPerSec: Int64?
    public let multipartThreshold: Int64
    public let multipartPartSize: Int64

    public init(
        profile: ServerProfile,
        credentials: Credentials,
        session: URLSession = .shared,
        speedLimitBytesPerSec: Int64? = nil,
        multipartThreshold: Int64 = 16 * 1024 * 1024,
        multipartPartSize: Int64 = 8 * 1024 * 1024
    ) {
        self.profile = profile
        self.credentials = credentials
        self.session = session
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.multipartThreshold = max(1024, multipartThreshold)
        self.multipartPartSize = max(1024, multipartPartSize)
    }

    public var accessKeyId: String { profile.username.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var secretAccessKey: String { credentials.password }
    private var securityToken: String { credentials.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var bucket: String { profile.s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var region: String {
        let r = profile.s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "us-east-1" : r
    }
    public var endpointHost: String {
        let h = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty || h == "s3.amazonaws.com" {
            return "s3.\(region).amazonaws.com"
        }
        return h
    }

    /// Resolves host and path for S3 request (supports both virtual-hosted-style and path-style for R2 / MinIO).
    public func endpointURL(objectKey: String = "", queryItems: [URLQueryItem] = []) throws -> URL {
        guard !bucket.isEmpty else { throw TransferError.invalidConnection }
        var components = URLComponents()
        components.scheme = "https"
        if profile.port != 443 && profile.port > 0 {
            components.port = profile.port
        }
        let cleanKey = objectKey.hasPrefix("/") ? String(objectKey.dropFirst()) : objectKey
        if profile.s3PathStyle {
            components.host = endpointHost
            components.path = cleanKey.isEmpty ? "/\(bucket)" : "/\(bucket)/\(cleanKey)"
        } else {
            if endpointHost.hasPrefix("\(bucket).") {
                components.host = endpointHost
            } else {
                components.host = "\(bucket).\(endpointHost)"
            }
            components.path = cleanKey.isEmpty ? "/" : "/\(cleanKey)"
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw TransferError.invalidConnection }
        return url
    }

    // MARK: - Presigned URL Generator (Transmit "Copy Signed URL" Parity)
    public func presignedURL(for remotePath: String, expiresIn seconds: Int = 3600) async throws -> URL {
        try presignedDownloadURL(for: remotePath, expiresIn: seconds)
    }

    public func presignedDownloadURL(for remotePath: String, expiresIn seconds: Int = 3600, now: Date = Date()) throws -> URL {
        let key = Self.s3ObjectKey(for: remotePath, isDirectory: false)
        let clampedExpires = min(604_800, max(60, seconds))
        let amzDate = Self.formatAMZDate(now)
        let dateStamp = String(amzDate.prefix(8))
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"

        let baseURL = try endpointURL(objectKey: key)
        guard let host = baseURL.host else { throw TransferError.invalidConnection }
        let hostHeader = (baseURL.port != nil && baseURL.port != 443) ? "\(host):\(baseURL.port!)" : host

        var queryPairs: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKeyId)/\(credentialScope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", "\(clampedExpires)"),
            ("X-Amz-SignedHeaders", "host")
        ]
        if (profile.s3UseSessionToken || !securityToken.isEmpty) && !securityToken.isEmpty {
            queryPairs.append(("X-Amz-Security-Token", securityToken))
        }
        let canonicalQuery = queryPairs
            .sorted { $0.0 < $1.0 }
            .map { "\(Self.awsURIEnode($0.0, encodeSlash: true))=\(Self.awsURIEnode($0.1, encodeSlash: true))" }
            .joined(separator: "&")

        let resolvedPath = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.path ?? baseURL.path
        let canonicalURI = Self.canonicalURIPath(from: resolvedPath)
        let canonicalHeaders = "host:\(hostHeader)\n"
        let canonicalRequest = [
            "GET",
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            "host",
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = Self.deriveSigningKey(secretKey: secretAccessKey, dateStamp: dateStamp, region: region, service: "s3")
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let finalURLString = "\(baseURL.scheme ?? "https")://\(hostHeader)\(canonicalURI)?\(canonicalQuery)&X-Amz-Signature=\(signature)"
        guard let signedURL = URL(string: finalURLString) else {
            throw TransferError.invalidConnection
        }
        return signedURL
    }

    // MARK: - S3 Operations
    public func list(_ path: String) async throws -> [FileEntry] {
        try Task.checkCancellation()
        let normalized = RemotePath.normalize(path)
        let prefix = Self.s3ObjectKey(for: normalized, isDirectory: true)
        var allEntries: [FileEntry] = []
        var seenPaths = Set<String>()
        var continuationToken: String?

        while true {
            try Task.checkCancellation()
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "delimiter", value: "/"),
                URLQueryItem(name: "list-type", value: "2")
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let token = continuationToken, !token.isEmpty {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }
            let url = try endpointURL(objectKey: "", queryItems: queryItems)
            let req = try signedRequest(url: url, method: "GET", payload: Data())
            let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw TransferError.remote("S3 ListObjectsV2 HTTP \(status): \(bodyText.prefix(160))")
            }
            let page = try Self.parseListObjectsPageXML(data, requestedPath: normalized)
            for entry in page.entries where seenPaths.insert(entry.path).inserted {
                allEntries.append(entry)
            }
            if page.isTruncated,
               let next = page.nextContinuationToken,
               !next.isEmpty,
               next != continuationToken {
                continuationToken = next
            } else {
                break
            }
        }
        return FileEntry.sorted(allEntries)
    }

    public func listRecursive(_ remotePath: String) async throws -> [FileEntry] {
        try Task.checkCancellation()
        let normalized = RemotePath.normalize(remotePath)
        let prefix = Self.s3ObjectKey(for: normalized, isDirectory: true)
        let childPrefix = normalized == "/" ? "/" : normalized + "/"
        let objects = try await listAllObjectEntries(withPrefix: prefix)

        var results: [FileEntry] = []
        var seenPaths = Set<String>()

        for obj in objects {
            let key = obj.key
            guard !key.isEmpty, key != prefix else { continue }
            let isDir = key.hasSuffix("/")
            let cleanRelative = isDir ? String(key.dropLast()) : key
            let relParts = cleanRelative.split(separator: "/").map(String.init)
            guard !relParts.isEmpty else { continue }

            // Synthesize intermediate folders if objects exist without explicit directory marker objects
            var built = ""
            let dirDepth = isDir ? relParts.count : max(0, relParts.count - 1)
            for idx in 0..<dirDepth {
                built += "/" + relParts[idx]
                let dirPath = RemotePath.normalize(built)
                if dirPath != normalized && dirPath.hasPrefix(childPrefix) && seenPaths.insert(dirPath).inserted {
                    results.append(FileEntry(
                        name: relParts[idx],
                        path: dirPath,
                        isDirectory: true,
                        size: 0,
                        modified: idx == relParts.count - 1 ? obj.modified : nil,
                        permissions: "drwxr-xr-x"
                    ))
                }
            }

            if !isDir {
                let fullPath = RemotePath.normalize("/" + cleanRelative)
                if fullPath.hasPrefix(childPrefix) && seenPaths.insert(fullPath).inserted {
                    results.append(FileEntry(
                        name: relParts.last ?? cleanRelative,
                        path: fullPath,
                        isDirectory: false,
                        size: obj.size,
                        modified: obj.modified,
                        permissions: "-rw-r--r--"
                    ))
                }
            }
        }
        return results
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
        let key = Self.s3ObjectKey(for: remote, isDirectory: false)
        let url = try endpointURL(objectKey: key)
        var extraHeaders: [String: String] = [:]
        if let offset, offset > 0 {
            extraHeaders["Range"] = "bytes=\(offset)-"
        }
        let req = try signedRequest(url: url, method: "GET", payload: Data(), extraHeaders: extraHeaders)
        try await HTTPStreamingHelper.streamDownload(
            session: session,
            request: req,
            destination: destination,
            overwrite: overwrite,
            offset: offset,
            stagingURL: stagingURL,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            preserveModificationDate: profile.preserveModificationDate,
            protocolLabel: "S3",
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

        let key = Self.s3ObjectKey(for: remote, isDirectory: false)
        let fileSize = try await HTTPStreamingHelper.fileSize(at: local)

        if fileSize > multipartThreshold {
            try await uploadMultipart(local: local, key: key, fileSize: fileSize, progress: progress)
            return
        }

        let (payloadHash, byteCount) = try await HTTPStreamingHelper.streamDigest(fileAt: local, using: SHA256.self)
        let url = try endpointURL(objectKey: key)
        var extraHeaders: [String: String] = [
            "Content-Length": "\(byteCount)"
        ]
        let storageClass = profile.s3StorageClass.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storageClass.isEmpty && storageClass != "STANDARD" {
            extraHeaders["x-amz-storage-class"] = storageClass
        }
        let req = try signedRequest(url: url, method: "PUT", payloadSHA256Hex: payloadHash, extraHeaders: extraHeaders)
        let (data, http) = try await HTTPStreamingHelper.sendStreamedUpload(
            session: session,
            request: req,
            fileURL: local,
            offset: 0,
            length: byteCount,
            speedLimitBytesPerSec: speedLimitBytesPerSec,
            progress: progress
        )
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TransferError.remote("S3 PUT HTTP \(http.statusCode): \(bodyText.prefix(160))")
        }
    }

    private func uploadMultipart(
        local: URL,
        key: String,
        fileSize: Int64,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        // 1. Initiate multipart upload
        let initURL = try endpointURL(objectKey: key, queryItems: [URLQueryItem(name: "uploads", value: nil)])
        var initHeaders: [String: String] = [:]
        let storageClass = profile.s3StorageClass.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storageClass.isEmpty && storageClass != "STANDARD" {
            initHeaders["x-amz-storage-class"] = storageClass
        }
        let initReq = try signedRequest(url: initURL, method: "POST", payload: Data(), extraHeaders: initHeaders)
        let (initData, initResp) = try await HTTPStreamingHelper.performData(session: session, request: initReq)
        guard let initHTTP = initResp as? HTTPURLResponse, (200...299).contains(initHTTP.statusCode) else {
            let status = (initResp as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: initData, encoding: .utf8) ?? ""
            throw TransferError.remote("S3 CreateMultipartUpload HTTP \(status): \(bodyText.prefix(160))")
        }
        let uploadId = try Self.parseSingleXMLValue(initData, elementName: "UploadId")

        var completedParts: [(partNumber: Int, etag: String)] = []
        do {
            var offset: Int64 = 0
            var partNumber = 1
            while offset < fileSize {
                try Task.checkCancellation()
                let partLength = min(multipartPartSize, fileSize - offset)
                let (partHash, _) = try await HTTPStreamingHelper.streamDigest(
                    fileAt: local,
                    offset: offset,
                    length: partLength,
                    using: SHA256.self
                )
                let partURL = try endpointURL(objectKey: key, queryItems: [
                    URLQueryItem(name: "partNumber", value: "\(partNumber)"),
                    URLQueryItem(name: "uploadId", value: uploadId)
                ])
                let partReq = try signedRequest(
                    url: partURL,
                    method: "PUT",
                    payloadSHA256Hex: partHash,
                    extraHeaders: ["Content-Length": "\(partLength)"]
                )
                let (partData, partHTTP) = try await HTTPStreamingHelper.sendStreamedUpload(
                    session: session,
                    request: partReq,
                    fileURL: local,
                    offset: offset,
                    length: partLength,
                    speedLimitBytesPerSec: speedLimitBytesPerSec,
                    progress: progress,
                    totalReportedSize: fileSize
                )
                guard (200...299).contains(partHTTP.statusCode) else {
                    let bodyText = String(data: partData, encoding: .utf8) ?? ""
                    throw TransferError.remote("S3 UploadPart \(partNumber) HTTP \(partHTTP.statusCode): \(bodyText.prefix(160))")
                }
                guard let etag = partHTTP.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !etag.isEmpty else {
                    throw TransferError.remote("S3 UploadPart \(partNumber) missing ETag header")
                }
                completedParts.append((partNumber, etag))
                offset += partLength
                partNumber += 1
            }

            // 3. Complete multipart upload
            let partsXML = completedParts.map { part in
                "<Part><PartNumber>\(part.partNumber)</PartNumber><ETag>\(HTTPStreamingHelper.xmlEscape(part.etag))</ETag></Part>"
            }.joined()
            let completeBody = Data("<CompleteMultipartUpload>\(partsXML)</CompleteMultipartUpload>".utf8)
            let completeURL = try endpointURL(objectKey: key, queryItems: [
                URLQueryItem(name: "uploadId", value: uploadId)
            ])
            let completeReq = try signedRequest(
                url: completeURL,
                method: "POST",
                payload: completeBody,
                extraHeaders: [
                    "Content-Type": "application/xml",
                    "Content-Length": "\(completeBody.count)"
                ]
            )
            let (completeData, completeResp) = try await HTTPStreamingHelper.performData(session: session, request: completeReq)
            guard let completeHTTP = completeResp as? HTTPURLResponse, (200...299).contains(completeHTTP.statusCode) else {
                let status = (completeResp as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: completeData, encoding: .utf8) ?? ""
                throw TransferError.remote("S3 CompleteMultipartUpload HTTP \(status): \(bodyText.prefix(160))")
            }
            if let bodyString = String(data: completeData, encoding: .utf8), bodyString.contains("<Error>") {
                throw TransferError.remote("S3 CompleteMultipartUpload error: \(bodyString.prefix(160))")
            }
        } catch {
            // Abort multipart upload outside the potentially cancelled Task so orphan parts are cleaned up.
            let clientCopy = self
            _ = try? await Task.detached {
                try await clientCopy.abortMultipartUpload(key: key, uploadId: uploadId)
            }.value
            throw error
        }
    }

    private func abortMultipartUpload(key: String, uploadId: String) async throws {
        let abortURL = try endpointURL(objectKey: key, queryItems: [
            URLQueryItem(name: "uploadId", value: uploadId)
        ])
        let req = try signedRequest(url: abortURL, method: "DELETE", payload: Data())
        _ = try await session.data(for: req)
    }

    public func mkdir(_ path: String) async throws {
        try Task.checkCancellation()
        let key = Self.s3ObjectKey(for: path, isDirectory: true)
        guard !key.isEmpty else { return }
        let url = try endpointURL(objectKey: key)
        var req = try signedRequest(url: url, method: "PUT", payload: Data(), extraHeaders: ["Content-Length": "0"])
        req.httpBody = Data()
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("S3 PUT Folder HTTP \(status)")
        }
    }

    public func rename(_ source: String, to destination: String) async throws {
        try Task.checkCancellation()
        let srcKey = Self.s3ObjectKey(for: source, isDirectory: false)
        let dstKey = Self.s3ObjectKey(for: destination, isDirectory: false)

        if !source.hasSuffix("/") && !srcKey.isEmpty {
            let status = try await copySingleObject(fromKey: srcKey, toKey: dstKey)
            if (200...299).contains(status) {
                try await deleteSingleObject(key: srcKey)
                return
            }
            if status != 404 {
                throw TransferError.remote("S3 CopyObject HTTP \(status)")
            }
        }

        // Folder / prefix rename
        let srcPrefix = Self.s3ObjectKey(for: source, isDirectory: true)
        let dstPrefix = Self.s3ObjectKey(for: destination, isDirectory: true)
        guard !srcPrefix.isEmpty, !dstPrefix.isEmpty else {
            throw TransferError.invalidPath
        }
        let objects = try await listAllObjectEntries(withPrefix: srcPrefix)
        guard !objects.isEmpty else {
            throw TransferError.remote("S3 CopyObject HTTP 404")
        }
        for obj in objects {
            try Task.checkCancellation()
            let suffix = obj.key.hasPrefix(srcPrefix) ? String(obj.key.dropFirst(srcPrefix.count)) : obj.key
            let targetKey = dstPrefix + suffix
            let copyStatus = try await copySingleObject(fromKey: obj.key, toKey: targetKey)
            guard (200...299).contains(copyStatus) else {
                throw TransferError.remote("S3 CopyObject HTTP \(copyStatus)")
            }
            try await deleteSingleObject(key: obj.key)
        }
    }

    public func remove(_ path: String, directory: Bool) async throws {
        try Task.checkCancellation()
        if !directory {
            let key = Self.s3ObjectKey(for: path, isDirectory: false)
            try await deleteSingleObject(key: key)
            return
        }

        let prefix = Self.s3ObjectKey(for: path, isDirectory: true)
        guard !prefix.isEmpty else { throw TransferError.invalidPath }

        let objects = try await listAllObjectEntries(withPrefix: prefix)
        var keys = objects.map(\.key)
        if keys.isEmpty {
            try await deleteSingleObject(key: prefix)
            return
        }
        if keys.count == 1 {
            try await deleteSingleObject(key: keys[0])
            return
        }

        while !keys.isEmpty {
            try Task.checkCancellation()
            let batch = Array(keys.prefix(1000))
            keys.removeFirst(batch.count)
            let batchDeleted = try await deleteObjectsBatch(keys: batch)
            if !batchDeleted {
                for key in batch {
                    try Task.checkCancellation()
                    try await deleteSingleObject(key: key)
                }
            }
        }
    }

    public func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata {
        try Task.checkCancellation()
        let key = Self.s3ObjectKey(for: remotePath, isDirectory: false)
        let url = try endpointURL(objectKey: key)
        let req = try signedRequest(url: url, method: "HEAD", payload: Data())
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("S3 HEAD HTTP \(status)")
        }

        var custom: [String: String] = [:]
        for (rawKey, rawVal) in http.allHeaderFields {
            let lower = String(describing: rawKey).lowercased()
            if lower.hasPrefix("x-amz-meta-") {
                let metaKey = String(lower.dropFirst("x-amz-meta-".count))
                custom[metaKey] = String(describing: rawVal)
            }
        }
        let sizeHeader = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        let size = sizeHeader ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : nil)

        return RemoteObjectMetadata(
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
            storageClass: http.value(forHTTPHeaderField: "x-amz-storage-class"),
            acl: http.value(forHTTPHeaderField: "x-amz-acl"),
            customMetadata: custom,
            etag: http.value(forHTTPHeaderField: "ETag"),
            size: size,
            modified: HTTPStreamingHelper.parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified"))
        )
    }

    public func updateMetadata(_ remotePath: String, metadata: RemoteObjectMetadata) async throws {
        try Task.checkCancellation()
        let key = Self.s3ObjectKey(for: remotePath, isDirectory: false)
        let url = try endpointURL(objectKey: key)
        let copySourceHeader = "/\(bucket)/\(Self.awsURIEnode(key, encodeSlash: false))"
        var headers: [String: String] = [
            "x-amz-copy-source": copySourceHeader,
            "x-amz-metadata-directive": "REPLACE"
        ]
        if let ct = metadata.contentType?.trimmingCharacters(in: .whitespacesAndNewlines), !ct.isEmpty {
            headers["Content-Type"] = ct
        }
        if let cc = metadata.cacheControl?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
            headers["Cache-Control"] = cc
        }
        if let sc = metadata.storageClass?.trimmingCharacters(in: .whitespacesAndNewlines), !sc.isEmpty {
            headers["x-amz-storage-class"] = sc
        }
        if let acl = metadata.acl?.trimmingCharacters(in: .whitespacesAndNewlines), !acl.isEmpty {
            headers["x-amz-acl"] = acl
        }
        for (k, v) in metadata.customMetadata {
            let trimmedKey = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmedKey.isEmpty else { continue }
            let headerName = trimmedKey.hasPrefix("x-amz-meta-") ? trimmedKey : "x-amz-meta-\(trimmedKey)"
            headers[headerName] = v
        }

        let req = try signedRequest(url: url, method: "PUT", payload: Data(), extraHeaders: headers)
        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TransferError.remote("S3 UpdateMetadata HTTP \(status): \(bodyText.prefix(160))")
        }
    }

    // MARK: - Internal S3 Helpers
    private func copySingleObject(fromKey srcKey: String, toKey dstKey: String) async throws -> Int {
        let dstURL = try endpointURL(objectKey: dstKey)
        let copySourceHeader = "/\(bucket)/\(Self.awsURIEnode(srcKey, encodeSlash: false))"
        let copyReq = try signedRequest(url: dstURL, method: "PUT", payload: Data(), extraHeaders: [
            "x-amz-copy-source": copySourceHeader
        ])
        let (_, copyResp) = try await HTTPStreamingHelper.performData(session: session, request: copyReq)
        return (copyResp as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func deleteSingleObject(key: String) async throws {
        let url = try endpointURL(objectKey: key)
        let req = try signedRequest(url: url, method: "DELETE", payload: Data())
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("S3 DELETE HTTP \(status)")
        }
    }

    private func deleteObjectsBatch(keys: [String]) async throws -> Bool {
        let objectsXML = keys.map { "<Object><Key>\(HTTPStreamingHelper.xmlEscape($0))</Key></Object>" }.joined()
        let body = Data("<Delete><Quiet>true</Quiet>\(objectsXML)</Delete>".utf8)
        let md5Base64 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        let url = try endpointURL(objectKey: "", queryItems: [URLQueryItem(name: "delete", value: nil)])
        let req = try signedRequest(
            url: url,
            method: "POST",
            payload: body,
            extraHeaders: [
                "Content-Type": "application/xml",
                "Content-MD5": md5Base64,
                "Content-Length": "\(body.count)"
            ]
        )
        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse else { return false }
        if (200...299).contains(http.statusCode) {
            if let text = String(data: data, encoding: .utf8), text.contains("<Error>") {
                throw TransferError.remote("S3 DeleteObjects partial failure")
            }
            return true
        }
        if [400, 404, 405, 501].contains(http.statusCode) {
            return false
        }
        throw TransferError.remote("S3 DeleteObjects HTTP \(http.statusCode)")
    }

    private func listAllObjectEntries(withPrefix prefix: String) async throws -> [(key: String, size: Int64, modified: Date?)] {
        var collected: [(key: String, size: Int64, modified: Date?)] = []
        var seen = Set<String>()
        var continuationToken: String?

        while true {
            try Task.checkCancellation()
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "list-type", value: "2")
            ]
            if !prefix.isEmpty {
                queryItems.append(URLQueryItem(name: "prefix", value: prefix))
            }
            if let token = continuationToken, !token.isEmpty {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }
            let url = try endpointURL(objectKey: "", queryItems: queryItems)
            let req = try signedRequest(url: url, method: "GET", payload: Data())
            let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TransferError.remote("S3 ListObjectsV2 HTTP \(status)")
            }
            let page = try Self.parseRawObjectsPageXML(data)
            for item in page.objects where seen.insert(item.key).inserted {
                collected.append(item)
            }
            if page.isTruncated,
               let next = page.nextContinuationToken,
               !next.isEmpty,
               next != continuationToken {
                continuationToken = next
            } else {
                break
            }
        }
        return collected
    }

    // MARK: - AWS Signature V4 Request Signer
    public func signedRequest(
        url: URL,
        method: String,
        payload: Data,
        extraHeaders: [String: String] = [:],
        now: Date = Date()
    ) throws -> URLRequest {
        var req = try signedRequest(
            url: url,
            method: method,
            payloadSHA256Hex: Self.sha256Hex(payload),
            extraHeaders: extraHeaders,
            now: now
        )
        if !payload.isEmpty {
            req.httpBody = payload
        }
        return req
    }

    public func signedRequest(
        url: URL,
        method: String,
        payloadSHA256Hex: String,
        extraHeaders: [String: String] = [:],
        now: Date = Date()
    ) throws -> URLRequest {
        guard let host = url.host else { throw TransferError.invalidConnection }
        let hostHeader = (url.port != nil && url.port != 443 && url.port != 80) ? "\(host):\(url.port!)" : host
        let amzDate = Self.formatAMZDate(now)
        let dateStamp = String(amzDate.prefix(8))

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method

        var headersToSign: [String: String] = [
            "host": hostHeader,
            "x-amz-content-sha256": payloadSHA256Hex,
            "x-amz-date": amzDate
        ]
        if (profile.s3UseSessionToken || !securityToken.isEmpty) && !securityToken.isEmpty {
            req.setValue(securityToken, forHTTPHeaderField: "X-Amz-Security-Token")
            headersToSign["x-amz-security-token"] = securityToken
        }
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
            let lower = k.lowercased()
            if lower.hasPrefix("x-amz-") || lower == "content-type" || lower == "content-md5" {
                headersToSign[lower] = v.trimmingCharacters(in: .whitespaces)
            }
        }
        req.setValue(hostHeader, forHTTPHeaderField: "Host")
        req.setValue(payloadSHA256Hex, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")

        let sortedHeaderKeys = headersToSign.keys.sorted()
        let canonicalHeaders = sortedHeaderKeys.map { "\($0):\(headersToSign[$0]!)\n" }.joined()
        let signedHeaders = sortedHeaderKeys.joined(separator: ";")

        let resolvedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
        let canonicalURI = Self.canonicalURIPath(from: resolvedPath)
        let canonicalQuery = Self.canonicalQueryString(from: url)

        let canonicalRequest = [
            method.uppercased(),
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadSHA256Hex
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let signingKey = Self.deriveSigningKey(secretKey: secretAccessKey, dateStamp: dateStamp, region: region, service: "s3")
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))
        let authHeader = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - S3 XML Parser (ListObjectsV2)
    public static func parseListObjectsXML(_ data: Data, requestedPath: String) throws -> [FileEntry] {
        let page = try parseListObjectsPageXML(data, requestedPath: requestedPath)
        return FileEntry.sorted(page.entries)
    }

    static func parseListObjectsPageXML(
        _ data: Data,
        requestedPath: String
    ) throws -> (entries: [FileEntry], isTruncated: Bool, nextContinuationToken: String?) {
        let normalized = RemotePath.normalize(requestedPath)
        let prefix = s3ObjectKey(for: normalized, isDirectory: true)
        let delegate = S3ListObjectsXMLDelegate(requestedPath: normalized, requestedPrefix: prefix)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw TransferError.invalidListing("S3 ListObjectsV2 XML parse error")
        }
        return (delegate.entries, delegate.isTruncated, delegate.nextContinuationToken)
    }

    private static func parseRawObjectsPageXML(
        _ data: Data
    ) throws -> (objects: [(key: String, size: Int64, modified: Date?)], isTruncated: Bool, nextContinuationToken: String?) {
        let delegate = S3ListObjectsXMLDelegate(requestedPath: "/", requestedPrefix: "")
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw TransferError.invalidListing("S3 ListObjectsV2 XML parse error")
        }
        return (delegate.rawObjects, delegate.isTruncated, delegate.nextContinuationToken)
    }

    private static func parseSingleXMLValue(_ data: Data, elementName: String) throws -> String {
        let delegate = S3SingleElementXMLDelegate(targetElement: elementName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let value = delegate.value, !value.isEmpty else {
            throw TransferError.invalidListing("S3 XML missing \(elementName)")
        }
        return value
    }

    public static func s3ObjectKey(for remotePath: String, isDirectory: Bool) -> String {
        let normalized = RemotePath.normalize(remotePath)
        if normalized == "/" { return "" }
        let trimmed = String(normalized.dropFirst())
        return isDirectory ? (trimmed.hasSuffix("/") ? trimmed : trimmed + "/") : trimmed
    }

    // MARK: - Crypto & Encoding Helpers
    private static let amzDateLock = NSLock()
    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func formatAMZDate(_ date: Date) -> String {
        amzDateLock.lock()
        defer { amzDateLock.unlock() }
        return amzDateFormatter.string(from: date)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func hmacHex(key: SymmetricKey, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func deriveSigningKey(secretKey: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        let kSecret = SymmetricKey(data: Data(("AWS4" + secretKey).utf8))
        let kDate = SymmetricKey(data: hmac(key: kSecret, data: Data(dateStamp.utf8)))
        let kRegion = SymmetricKey(data: hmac(key: kDate, data: Data(region.utf8)))
        let kService = SymmetricKey(data: hmac(key: kRegion, data: Data(service.utf8)))
        let kSigning = SymmetricKey(data: hmac(key: kService, data: Data("aws4_request".utf8)))
        return kSigning
    }

    static func awsURIEnode(_ input: String, encodeSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if !encodeSlash {
            allowed.insert("/")
        }
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }

    private static func canonicalURIPath(from path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return awsURIEnode(path, encodeSlash: false)
    }

    private static func canonicalQueryString(from url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else {
            return ""
        }
        var pairs: [(String, String)] = []
        for item in items {
            let k = awsURIEnode(item.name, encodeSlash: true)
            let v = awsURIEnode(item.value ?? "", encodeSlash: true)
            pairs.append((k, v))
        }
        pairs.sort { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }
}

private final class S3SingleElementXMLDelegate: NSObject, XMLParserDelegate {
    let targetElement: String
    var value: String?
    private var capturing = false
    private var buffer = ""

    init(targetElement: String) {
        self.targetElement = targetElement
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == targetElement {
            capturing = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == targetElement {
            capturing = false
            value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private final class S3ListObjectsXMLDelegate: NSObject, XMLParserDelegate {
    let requestedPath: String
    let requestedPrefix: String
    var entries: [FileEntry] = []
    var rawObjects: [(key: String, size: Int64, modified: Date?)] = []
    var isTruncated = false
    var nextContinuationToken: String?

    private var section = ""
    private var currentElement = ""
    private var currentKey = ""
    private var currentSize = ""
    private var currentLastModified = ""
    private var currentPrefix = ""
    private var topLevelBuffer = ""

    init(requestedPath: String, requestedPrefix: String) {
        self.requestedPath = requestedPath
        self.requestedPrefix = requestedPrefix
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "Contents" {
            section = "Contents"
            currentKey = ""
            currentSize = ""
            currentLastModified = ""
        } else if elementName == "CommonPrefixes" {
            section = "CommonPrefixes"
            currentPrefix = ""
        } else if section.isEmpty && (elementName == "IsTruncated" || elementName == "NextContinuationToken") {
            topLevelBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if section == "Contents" {
            switch currentElement {
            case "Key": currentKey += string
            case "Size": currentSize += string
            case "LastModified": currentLastModified += string
            default: break
            }
        } else if section == "CommonPrefixes" && currentElement == "Prefix" {
            currentPrefix += string
        } else if section.isEmpty && (currentElement == "IsTruncated" || currentElement == "NextContinuationToken") {
            topLevelBuffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Contents" {
            section = ""
            appendFileEntry()
        } else if elementName == "CommonPrefixes" {
            section = ""
            appendFolderPrefix()
        } else if section.isEmpty && elementName == "IsTruncated" {
            isTruncated = topLevelBuffer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        } else if section.isEmpty && elementName == "NextContinuationToken" {
            let trimmed = topLevelBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { nextContinuationToken = trimmed }
        }
        currentElement = ""
    }

    private func appendFileEntry() {
        let key = currentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let modStr = currentLastModified.trimmingCharacters(in: .whitespacesAndNewlines)
        let modified = HTTPStreamingHelper.parseHTTPDate(modStr)
        let rawSize = Int64(currentSize.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        rawObjects.append((key: key, size: rawSize, modified: modified))

        guard key != requestedPrefix else { return }
        let relative: String
        if !requestedPrefix.isEmpty && key.hasPrefix(requestedPrefix) {
            relative = String(key.dropFirst(requestedPrefix.count))
        } else {
            relative = key
        }
        let isFolderPlaceholder = relative.hasSuffix("/")
        let cleanName = isFolderPlaceholder ? String(relative.dropLast()) : relative
        guard !cleanName.isEmpty, !cleanName.contains("/") else { return }

        let fullPath = (try? RemotePath.join(requestedPath, cleanName)) ?? (requestedPath + "/" + cleanName)
        let size = isFolderPlaceholder ? 0 : rawSize

        if !entries.contains(where: { $0.path == fullPath }) {
            entries.append(FileEntry(
                name: cleanName,
                path: fullPath,
                isDirectory: isFolderPlaceholder,
                size: size,
                modified: modified,
                permissions: isFolderPlaceholder ? "drwxr-xr-x" : "-rw-r--r--"
            ))
        }
    }

    private func appendFolderPrefix() {
        let prefix = currentPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, prefix != requestedPrefix else { return }
        let relative: String
        if !requestedPrefix.isEmpty && prefix.hasPrefix(requestedPrefix) {
            relative = String(prefix.dropFirst(requestedPrefix.count))
        } else {
            relative = prefix
        }
        let cleanName = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
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
