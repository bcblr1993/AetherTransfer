import Foundation
import CryptoKit

public struct S3Client: Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let session: URLSession

    public init(profile: ServerProfile, credentials: Credentials, session: URLSession = .shared) {
        self.profile = profile
        self.credentials = credentials
        self.session = session
    }

    public var accessKeyId: String { profile.username.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var secretAccessKey: String { credentials.password }
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
    public func presignedDownloadURL(for remotePath: String, expiresIn seconds: Int = 3600, now: Date = Date()) throws -> URL {
        let key = Self.s3ObjectKey(for: remotePath, isDirectory: false)
        let clampedExpires = min(604_800, max(60, seconds))
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"

        let baseURL = try endpointURL(objectKey: key)
        guard let host = baseURL.host else { throw TransferError.invalidConnection }
        let hostHeader = (baseURL.port != nil && baseURL.port != 443) ? "\(host):\(baseURL.port!)" : host

        let queryPairs: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKeyId)/\(credentialScope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", "\(clampedExpires)"),
            ("X-Amz-SignedHeaders", "host")
        ]
        let canonicalQuery = queryPairs
            .sorted { $0.0 < $1.0 }
            .map { "\(Self.awsURIEnode($0.0, encodeSlash: true))=\(Self.awsURIEnode($0.1, encodeSlash: true))" }
            .joined(separator: "&")

        let canonicalURI = Self.canonicalURIPath(from: baseURL.path)
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
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: " delimiter".trimmingCharacters(in: .whitespaces), value: "/"),
            URLQueryItem(name: "list-type", value: "2")
        ]
        if !prefix.isEmpty {
            queryItems.append(URLQueryItem(name: "prefix", value: prefix))
        }
        let url = try endpointURL(objectKey: "", queryItems: queryItems)
        let req = try signedRequest(url: url, method: "GET", payload: Data())
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TransferError.remote("S3 ListObjectsV2 HTTP \(status): \(bodyText.prefix(160))")
        }
        return try Self.parseListObjectsXML(data, requestedPath: normalized)
    }

    public func download(_ remote: String, to destination: URL, overwrite: Bool = false,
                         offset: Int64? = nil, stagingURL: URL? = nil,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) && !overwrite {
            throw TransferError.conflict(destination.lastPathComponent)
        }
        let key = Self.s3ObjectKey(for: remote, isDirectory: false)
        let url = try endpointURL(objectKey: key)
        var extraHeaders: [String: String] = [:]
        if let offset, offset > 0 {
            extraHeaders["Range"] = "bytes=\(offset)-"
        }
        let req = try signedRequest(url: url, method: "GET", payload: Data(), extraHeaders: extraHeaders)

        let temporary = stagingURL ?? destination.deletingLastPathComponent().appendingPathComponent(".aethertransfer-\(UUID().uuidString).part")
        defer {
            if stagingURL == nil { try? fm.removeItem(at: temporary) }
        }

        let (tempDownloadedURL, response) = try await session.download(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("S3 GET HTTP \(status)")
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: temporary.path) {
            try? fm.removeItem(at: temporary)
        }
        try fm.moveItem(at: tempDownloadedURL, to: temporary)
        let attrs = try? fm.attributesOfItem(atPath: temporary.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        progress(TransferProgress(completed: size, total: size))
        try await LocalFileCommit.commit(temporary, to: destination, overwrite: overwrite)
    }

    public func upload(_ local: URL, to remote: String, overwrite: Bool = false,
                       progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        if !overwrite {
            let parent = RemotePath.parent(remote)
            let name = URL(fileURLWithPath: remote).lastPathComponent
            let existing = (try? await list(parent)) ?? []
            if existing.contains(where: { $0.name == name }) {
                throw TransferError.conflict(name)
            }
        }
        let key = Self.s3ObjectKey(for: remote, isDirectory: false)
        let url = try endpointURL(objectKey: key)
        let fileData = try Data(contentsOf: local)
        let total = Int64(fileData.count)
        let req = try signedRequest(url: url, method: "PUT", payload: fileData, extraHeaders: [
            "Content-Length": "\(total)"
        ])
        progress(TransferProgress(completed: 0, total: total))
        let (data, response) = try await session.upload(for: req, from: fileData)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TransferError.remote("S3 PUT HTTP \(status): \(bodyText.prefix(160))")
        }
        progress(TransferProgress(completed: total, total: total))
    }

    public func mkdir(_ path: String) async throws {
        try Task.checkCancellation()
        let key = Self.s3ObjectKey(for: path, isDirectory: true)
        guard !key.isEmpty else { return }
        let url = try endpointURL(objectKey: key)
        let req = try signedRequest(url: url, method: "PUT", payload: Data(), extraHeaders: ["Content-Length": "0"])
        let (_, response) = try await session.upload(for: req, from: Data())
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("S3 PUT Folder HTTP \(status)")
        }
    }

    public func rename(_ source: String, to destination: String) async throws {
        try Task.checkCancellation()
        let srcKey = Self.s3ObjectKey(for: source, isDirectory: false)
        let dstKey = Self.s3ObjectKey(for: destination, isDirectory: false)
        let dstURL = try endpointURL(objectKey: dstKey)
        let copySourceHeader = "/\(bucket)/\(Self.awsURIEnode(srcKey, encodeSlash: false))"
        let copyReq = try signedRequest(url: dstURL, method: "PUT", payload: Data(), extraHeaders: [
            "x-amz-copy-source": copySourceHeader
        ])
        let (_, copyResp) = try await session.data(for: copyReq)
        guard let http = copyResp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (copyResp as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("S3 CopyObject HTTP \(status)")
        }
        try await remove(source, directory: false)
    }

    public func remove(_ path: String, directory: Bool) async throws {
        try Task.checkCancellation()
        let key = Self.s3ObjectKey(for: path, isDirectory: directory)
        let url = try endpointURL(objectKey: key)
        let req = try signedRequest(url: url, method: "DELETE", payload: Data())
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("S3 DELETE HTTP \(status)")
        }
    }

    // MARK: - AWS Signature V4 Request Signer
    public func signedRequest(url: URL, method: String, payload: Data, extraHeaders: [String: String] = [:], now: Date = Date()) throws -> URLRequest {
        guard let host = url.host else { throw TransferError.invalidConnection }
        let hostHeader = (url.port != nil && url.port != 443 && url.port != 80) ? "\(host):\(url.port!)" : host
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = Self.sha256Hex(payload)

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method

        var headersToSign: [String: String] = [
            "host": hostHeader,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
            let lower = k.lowercased()
            if lower.hasPrefix("x-amz-") || lower == "content-type" {
                headersToSign[lower] = v.trimmingCharacters(in: .whitespaces)
            }
        }
        req.setValue(hostHeader, forHTTPHeaderField: "Host")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")

        let sortedHeaderKeys = headersToSign.keys.sorted()
        let canonicalHeaders = sortedHeaderKeys.map { "\($0):\(headersToSign[$0]!)\n" }.joined()
        let signedHeaders = sortedHeaderKeys.joined(separator: ";")

        let canonicalURI = Self.canonicalURIPath(from: url.path)
        let canonicalQuery = Self.canonicalQueryString(from: url)

        let canonicalRequest = [
            method.uppercased(),
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
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
        let normalized = RemotePath.normalize(requestedPath)
        let prefix = s3ObjectKey(for: normalized, isDirectory: true)
        let delegate = S3ListObjectsXMLDelegate(requestedPath: normalized, requestedPrefix: prefix)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw TransferError.invalidListing("S3 ListObjectsV2 XML parse error")
        }
        return FileEntry.sorted(delegate.entries)
    }

    public static func s3ObjectKey(for remotePath: String, isDirectory: Bool) -> String {
        let normalized = RemotePath.normalize(remotePath)
        if normalized == "/" { return "" }
        let trimmed = String(normalized.dropFirst())
        return isDirectory ? (trimmed.hasSuffix("/") ? trimmed : trimmed + "/") : trimmed
    }

    // MARK: - Crypto & Encoding Helpers
    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

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

private final class S3ListObjectsXMLDelegate: NSObject, XMLParserDelegate {
    let requestedPath: String
    let requestedPrefix: String
    var entries: [FileEntry] = []

    private var section = ""
    private var currentElement = ""
    private var currentKey = ""
    private var currentSize = ""
    private var currentLastModified = ""
    private var currentPrefix = ""

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let isoFallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Contents" {
            section = ""
            appendFileEntry()
        } else if elementName == "CommonPrefixes" {
            section = ""
            appendFolderPrefix()
        }
        currentElement = ""
    }

    private func appendFileEntry() {
        let key = currentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != requestedPrefix else { return }
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
        let size = isFolderPlaceholder ? 0 : (Int64(currentSize.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        let modStr = currentLastModified.trimmingCharacters(in: .whitespacesAndNewlines)
        let modified = isoFormatter.date(from: modStr) ?? isoFallbackFormatter.date(from: modStr)

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
