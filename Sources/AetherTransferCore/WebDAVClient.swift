import Foundation

public struct WebDAVClient: Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let session: URLSession

    public init(profile: ServerProfile, credentials: Credentials, session: URLSession = .shared) {
        self.profile = profile
        self.credentials = credentials
        self.session = session
    }

    private func buildURL(for remotePath: String, directory: Bool = false) throws -> URL {
        let urlString = try profile.url(path: remotePath, directory: directory)
        guard let url = URL(string: urlString) else {
            throw TransferError.invalidConnection
        }
        return url
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 30)
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

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TransferError.remote(L10n.tr("WebDAV 响应无效。", "Invalid WebDAV response."))
        }
        guard (200...299).contains(http.statusCode) else {
            throw TransferError.remote("WebDAV HTTP \(http.statusCode)")
        }
        return try Self.parsePropfindXML(data, requestedPath: normalized)
    }

    public func download(_ remote: String, to destination: URL, overwrite: Bool = false,
                         offset: Int64? = nil, stagingURL: URL? = nil,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) && !overwrite {
            throw TransferError.conflict(destination.lastPathComponent)
        }
        let url = try buildURL(for: remote, directory: false)
        var req = authorizedRequest(url: url, method: "GET")
        if let offset, offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let temporary = stagingURL ?? destination.deletingLastPathComponent().appendingPathComponent(".aethertransfer-\(UUID().uuidString).part")
        defer {
            if stagingURL == nil { try? fm.removeItem(at: temporary) }
        }

        let (tempDownloadedURL, response) = try await session.download(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("WebDAV GET HTTP \(status)")
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
        let url = try buildURL(for: remote, directory: false)
        var req = authorizedRequest(url: url, method: "PUT")
        let fileData = try Data(contentsOf: local)
        let total = Int64(fileData.count)
        req.setValue("\(total)", forHTTPHeaderField: "Content-Length")
        progress(TransferProgress(completed: 0, total: total))
        let (_, response) = try await session.upload(for: req, from: fileData)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("WebDAV PUT HTTP \(status)")
        }
        progress(TransferProgress(completed: total, total: total))
    }

    public func mkdir(_ path: String) async throws {
        try Task.checkCancellation()
        let url = try buildURL(for: path, directory: true)
        let req = authorizedRequest(url: url, method: "MKCOL")
        let (_, response) = try await session.data(for: req)
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
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("WebDAV MOVE HTTP \(status)")
        }
    }

    public func remove(_ path: String, directory: Bool) async throws {
        try Task.checkCancellation()
        let url = try buildURL(for: path, directory: directory)
        let req = authorizedRequest(url: url, method: "DELETE")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TransferError.remote("WebDAV DELETE HTTP \(status)")
        }
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

    private static let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

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
        let modified: Date? = Self.rfc1123Formatter.date(from: modStr) ?? ISO8601DateFormatter().date(from: modStr)

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
