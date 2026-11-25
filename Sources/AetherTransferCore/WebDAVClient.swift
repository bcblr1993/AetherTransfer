import Foundation

public struct WebDAVClient: RemoteTransport, Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let session: URLSession
    public let speedLimitBytesPerSec: Int64?

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

    private func buildURL(for remotePath: String, directory: Bool = false) throws -> URL {
        let urlString = try profile.url(path: remotePath, directory: directory)
        guard let url = URL(string: urlString) else {
            throw TransferError.invalidConnection
        }
        return url
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method
        if !profile.username.isEmpty || !credentials.password.isEmpty {
            let authPair = "\(profile.username):\(credentials.password)"
            if let data = authPair.data(using: .utf8) {
                req.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }
        return req
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try Task.checkCancellation()
        let normalized = RemotePath.normalize(path)
        let url = try buildURL(for: normalized, directory: true)
        var req = authorizedRequest(url: url, method: "PROPFIND")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getlastmodified/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """
        req.httpBody = propfindBody.data(using: .utf8)

        let (data, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.remote(L10n.tr("WebDAV 响应无效。", "Invalid WebDAV response."))
        }
        guard (200...299).contains(http.statusCode) else {
            throw TransferError.remote("WebDAV PROPFIND HTTP \(http.statusCode)")
        }
        return try Self.parsePropfindXML(data, requestedPath: normalized)
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
        let url = try buildURL(for: remote, directory: false)
        var req = authorizedRequest(url: url, method: "GET")
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
            protocolLabel: "WebDAV",
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
        if let offset, offset > 0 {
            throw ResumeTransferError.uploadRestartRequired
        }
        try await HTTPStreamingHelper.checkConflict(transport: self, remote: remote, overwrite: overwrite, offset: offset)

        let targetRemote = stagingRemotePath ?? remote
        let url = try buildURL(for: targetRemote, directory: false)
        let req = authorizedRequest(url: url, method: "PUT")
        let fileSize = try await HTTPStreamingHelper.fileSize(at: local)

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
            throw TransferError.remote("WebDAV PUT HTTP \(http.statusCode)")
        }
        if targetRemote != remote {
            try await rename(targetRemote, to: remote)
        }
    }

    public func mkdir(_ path: String) async throws {
        try Task.checkCancellation()
        let url = try buildURL(for: path, directory: true)
        let req = authorizedRequest(url: url, method: "MKCOL")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 405 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("WebDAV MKCOL HTTP \(status)")
        }
    }

    public func rename(_ source: String, to destination: String) async throws {
        try Task.checkCancellation()
        let srcURL = try buildURL(for: source, directory: false)
        let dstURL = try buildURL(for: destination, directory: false)
        var req = authorizedRequest(url: srcURL, method: "MOVE")
        req.setValue(dstURL.absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("WebDAV MOVE HTTP \(status)")
        }
    }

    public func remove(_ path: String, directory: Bool) async throws {
        try Task.checkCancellation()
        let url = try buildURL(for: path, directory: directory)
        let req = authorizedRequest(url: url, method: "DELETE")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("WebDAV DELETE HTTP \(status)")
        }
    }

    public func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata {
        try Task.checkCancellation()
        let url = try buildURL(for: remotePath, directory: false)
        let headReq = authorizedRequest(url: url, method: "HEAD")
        let (_, response) = try await HTTPStreamingHelper.performData(session: session, request: headReq)
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.remote(L10n.tr("WebDAV 响应无效。", "Invalid WebDAV response."))
        }
        if (200...299).contains(http.statusCode) {
            let sizeHeader = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            let size = sizeHeader ?? (http.expectedContentLength >= 0 ? http.expectedContentLength : nil)
            return RemoteObjectMetadata(
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
                etag: http.value(forHTTPHeaderField: "ETag"),
                size: size,
                modified: HTTPStreamingHelper.parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified"))
            )
        }
        if http.statusCode == 405 {
            var propReq = authorizedRequest(url: url, method: "PROPFIND")
            propReq.setValue("0", forHTTPHeaderField: "Depth")
            propReq.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            propReq.httpBody = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:">
              <D:prop>
                <D:getcontentlength/>
                <D:getlastmodified/>
                <D:getcontenttype/>
                <D:getetag/>
              </D:prop>
            </D:propfind>
            """.data(using: .utf8)
            let (data, propResp) = try await HTTPStreamingHelper.performData(session: session, request: propReq)
            guard let propHTTP = propResp as? HTTPURLResponse, (200...299).contains(propHTTP.statusCode) else {
                let code = (propResp as? HTTPURLResponse)?.statusCode ?? -1
                throw TransferError.remote("WebDAV PROPFIND HTTP \(code)")
            }
            let normalized = RemotePath.normalize(remotePath)
            let parent = RemotePath.parent(normalized)
            let entries = try Self.parsePropfindXML(data, requestedPath: parent)
            if let entry = entries.first(where: { $0.path == normalized }) {
                return RemoteObjectMetadata(size: entry.size, modified: entry.modified)
            }
            throw TransferError.remote(L10n.tr("未找到远程对象：\(normalized)", "Remote object not found: \(normalized)"))
        }
        throw TransferError.remote("WebDAV HEAD HTTP \(http.statusCode)")
    }

    // MARK: - RFC 4918 PROPFIND XML Parser
    public static func parsePropfindXML(_ data: Data, requestedPath: String) throws -> [FileEntry] {
        let delegate = PropfindXMLParserDelegate(requestedPath: RemotePath.normalize(requestedPath))
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw TransferError.invalidListing("WebDAV XML parse error")
        }
        return FileEntry.sorted(delegate.entries)
    }
}

private final class PropfindXMLParserDelegate: NSObject, XMLParserDelegate {
    let requestedPath: String
    var entries: [FileEntry] = []

    private var inResponse = false
    private var inResourceType = false
    private var currentElement = ""
    private var currentHref = ""
    private var currentDisplayName = ""
    private var currentLength = ""
    private var currentLastModified = ""
    private var currentIsDirectory = false

    init(requestedPath: String) {
        self.requestedPath = requestedPath
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        currentElement = local
        if local == "response" {
            inResponse = true
            currentHref = ""
            currentDisplayName = ""
            currentLength = ""
            currentLastModified = ""
            currentIsDirectory = false
        } else if inResponse && local == "resourcetype" {
            inResourceType = true
        } else if inResourceType && local == "collection" {
            currentIsDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inResponse else { return }
        switch currentElement {
        case "href": currentHref += string
        case "displayname": currentDisplayName += string
        case "getcontentlength": currentLength += string
        case "getlastmodified": currentLastModified += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        if local == "resourcetype" {
            inResourceType = false
        } else if local == "response" {
            inResponse = false
            appendCurrentResponse()
        }
        currentElement = ""
    }

    private func appendCurrentResponse() {
        let rawHref = currentHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHref.isEmpty else { return }

        let extractedPath: String
        if let url = URL(string: rawHref), !url.path.isEmpty {
            extractedPath = url.path.removingPercentEncoding ?? url.path
        } else {
            extractedPath = rawHref.removingPercentEncoding ?? rawHref
        }

        let normalizedPath = RemotePath.normalize(extractedPath)
        guard normalizedPath != requestedPath else { return }

        let parent = RemotePath.parent(normalizedPath)
        guard parent == requestedPath else { return }

        let name = URL(fileURLWithPath: normalizedPath).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return }

        let isDir = currentIsDirectory || rawHref.hasSuffix("/")
        let size = isDir ? 0 : (Int64(currentLength.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        let modStr = currentLastModified.trimmingCharacters(in: .whitespacesAndNewlines)
        let modified = HTTPStreamingHelper.parseHTTPDate(modStr)

        entries.append(FileEntry(
            name: name,
            path: normalizedPath,
            isDirectory: isDir,
            size: size,
            modified: modified,
            permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--"
        ))
    }
}
