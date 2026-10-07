import Foundation

/// Parses only direct children from successful DAV properties; never resolves external XML entities.
public enum WebDAVListing {
    public static func parse(_ xml: String, parent: String, origin: String) throws -> [FileEntry] {
        guard xml.utf8.count <= 32 * 1024 * 1024,
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY"),
              let base = URLComponents(string: origin), base.host != nil else {
            throw TransferError.invalidListing("WebDAV XML 不合法或超出限制。")
        }
        let delegate = ListingDelegate(parent: RemotePath.normalize(parent), origin: base)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed, delegate.foundRoot else {
            throw TransferError.invalidListing("WebDAV 目录结果不完整或包含不安全的路径。")
        }
        return FileEntry.sorted(delegate.entries)
    }
}

private final class ListingDelegate: NSObject, XMLParserDelegate {
    let parent: String
    let origin: URLComponents
    var entries: [FileEntry] = []
    var foundRoot = false
    var failed = false
    private var stack: [String] = []
    private var currentPath = ""
    private var text = ""
    private var href = ""
    private var responseStatus: Int?
    private var propStatus: Int?
    private var props: [String: String] = [:]
    private var successful: [String: String] = [:]
    private var collection = false
    private var seen = Set<String>()
    private var nodes = 0
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private static let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                                 "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
    private let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.isLenient = false
        return formatter
    }()
    init(parent: String, origin: URLComponents) { self.parent = parent; self.origin = origin }
    private func fail(_ parser: XMLParser) { failed = true; parser.abortParsing() }
    private func at(_ path: String) -> Bool { currentPath == path }
    private var capturesText: Bool {
        at("multistatus/response/href") || at("multistatus/response/status") ||
        at("multistatus/response/propstat/status") ||
        at("multistatus/response/propstat/prop/getcontentlength") ||
        at("multistatus/response/propstat/prop/getlastmodified")
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(namespaceURI == "DAV:" ? name : "?")
        currentPath = stack.joined(separator: "/")
        text = ""
        nodes += 1
        if stack.count > 48 || nodes > 1_600_000 || (stack.count == 1 && name != "multistatus") || stack.first != "multistatus" { fail(parser); return }
        if at("multistatus/response") { href = ""; responseStatus = nil; successful = [:] }
        if at("multistatus/response/propstat") { propStatus = nil; props = [:]; collection = false }
        if at("multistatus/response/propstat/prop/resourcetype") { props["type"] = "file" }
        if at("multistatus/response/propstat/prop/resourcetype/collection") { collection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturesText else { return }
        text += string
        if text.utf8.count > 16 * 1024 { fail(parser) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = capturesText ? text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if at("multistatus/response/href") {
            if !href.isEmpty { fail(parser); return }
            href = value
        } else if at("multistatus/response/status") {
            guard let status = status(value) else { fail(parser); return }
            responseStatus = status
        }
        else if at("multistatus/response/propstat/status") {
            guard let status = status(value) else { fail(parser); return }
            propStatus = status
        }
        else if at("multistatus/response/propstat/prop/getcontentlength") { props["size"] = value }
        else if at("multistatus/response/propstat/prop/getlastmodified") { props["modified"] = value }
        else if at("multistatus/response/propstat/prop/resourcetype") { props["type"] = collection ? "directory" : "file" }
        else if at("multistatus/response/propstat"), propStatus == 200 {
            for (key, value) in props {
                if let old = successful[key], old != value { fail(parser); return }
                successful[key] = value
            }
        } else if at("multistatus/response") {
            do { try finishResponse() } catch { fail(parser); return }
        }
        stack.removeLast()
        currentPath = stack.joined(separator: "/")
        text = ""
    }
    private func status(_ text: String) -> Int? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0].hasPrefix("HTTP/"), fields[1].count == 3 else { return nil }
        return Int(fields[1])
    }
    private func date(_ text: String) -> Date? {
        // Canonical HTTP dates have fixed English months and GMT. Avoid ICU for every row.
        let fields = text.split(separator: " ")
        if fields.count == 6, fields[5] == "GMT", fields[0].count == 4, fields[0].last == "," {
            let clock = fields[4].split(separator: ":")
            guard let day = Int(fields[1]), let month = Self.months[String(fields[2])], let year = Int(fields[3]),
                  (1...31).contains(day), (1601...9999).contains(year), clock.count == 3,
                  let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]),
                  (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
            let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
            guard let candidate = calendar.date(from: components), calendar.component(.day, from: candidate) == day,
                  calendar.component(.month, from: candidate) == month else { return nil }
            return candidate
        }
        return dates.date(from: text)
    }
    private func path(_ href: String) throws -> String {
        guard !href.isEmpty, let components = URLComponents(string: href), components.query == nil,
              components.fragment == nil, components.user == nil, components.password == nil else { throw TransferError.invalidPath }
        let encoded: String
        if components.scheme != nil || components.host != nil {
            guard components.scheme == origin.scheme, components.host?.lowercased() == origin.host?.lowercased(),
                  (components.port ?? (components.scheme == "https" ? 443 : 80)) == (origin.port ?? (origin.scheme == "https" ? 443 : 80)) else {
                throw TransferError.invalidPath
            }
            encoded = components.percentEncodedPath
        } else {
            encoded = href.hasPrefix("/") ? components.percentEncodedPath : origin.percentEncodedPath + components.percentEncodedPath
        }
        let parts = try encoded.split(separator: "/").map { part -> String in
            guard let decoded = String(part).removingPercentEncoding, !decoded.contains("\\") else { throw TransferError.invalidPath }
            try RemotePath.validateName(decoded)
            return decoded
        }
        return "/" + parts.joined(separator: "/")
    }
    private func finishResponse() throws {
        let path = try path(href)
        guard seen.insert(path).inserted, seen.count <= 100_001, responseStatus == nil || responseStatus == 200,
              let type = successful["type"] else { throw TransferError.invalidPath }
        if path == parent {
            guard type == "directory" else { throw TransferError.invalidPath }
            foundRoot = true
            return
        }
        guard RemotePath.parent(path) == parent else { throw TransferError.invalidPath }
        let size: Int64
        if type == "directory" { size = 0 }
        else if let raw = successful["size"] {
            guard let parsed = Int64(raw), parsed >= 0 else { throw TransferError.invalidPath }
            size = parsed
        } else { throw TransferError.invalidListing("WebDAV 未返回文件大小。") }
        entries.append(FileEntry(name: String(path.split(separator: "/").last!), path: path, isDirectory: type == "directory",
                                 size: size, modified: successful["modified"].flatMap { date($0) }))
    }
}
