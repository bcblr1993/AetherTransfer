import Foundation

struct S3XML {
    struct Node: Sendable {
        let name: String
        var text = ""
        var children: [Node] = []
        func value(_ name: String) throws -> String? {
            let matching = children.filter { $0.name == name }
            guard matching.count <= 1 else { throw TransferError.invalidListing(L10n.text("S3 返回重复字段。")) }
            return matching.first?.text
        }
    }
    static func parse(_ xml: String, root: String) throws -> Node {
        guard xml.utf8.count <= 4 * 1024 * 1024, !xml.uppercased().contains("<!DOCTYPE"),
              !xml.uppercased().contains("<!ENTITY") else { throw TransferError.invalidListing(L10n.text("S3 XML 超出限制或包含外部实体。")) }
        let delegate = Parser(); let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true; parser.delegate = delegate
        guard parser.parse(), let result = delegate.root, result.name == root else {
            throw TransferError.invalidListing(L10n.text("S3 返回了错误或不完整的结果。"))
        }
        return result
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var count = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            count += 1
            guard count <= 32_000, stack.count < 24, root == nil,
                  namespaceURI == nil || namespaceURI == "" || namespaceURI == "http://s3.amazonaws.com/doc/2006-03-01/" else {
                parser.abortParsing(); return
            }
            stack.append(Node(name: name))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
            if stack.last!.text.utf8.count > 16 * 1024 { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let node = stack.popLast() else { parser.abortParsing(); return }
            if stack.isEmpty { root = node } else { stack[stack.count - 1].children.append(node) }
        }
    }
}

struct S3ListingPage: Sendable {
    let objects: [S3Object]
    let next: String?
    // S3's encoding-type=url names use query escaping: '+' is space, '%2B' is plus.
    // Continuation tokens are opaque and must never pass through this decoder.
    private static func decode(_ value: String?) -> String? {
        value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
    static func parse(_ xml: String, prefix: String, bucket: String? = nil) throws -> S3ListingPage {
        let root = try S3XML.parse(xml, root: "ListBucketResult")
        if let bucket, try root.value("Name") != bucket { throw TransferError.invalidListing(L10n.text("S3 列表的存储桶与当前连接不一致。")) }
        guard try root.value("EncodingType") == "url", try decode(root.value("Delimiter")) == "/",
              try decode(root.value("Prefix"))?.utf8.elementsEqual(prefix.utf8) == true,
              let truncated = try root.value("IsTruncated"), ["true", "false"].contains(truncated) else {
            throw TransferError.invalidListing(L10n.text("S3 列表缺少分页或前缀信息。"))
        }
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeDate = ISO8601DateFormatter()
        var objects: [S3Object] = [], seen = Set<Data>()
        for child in root.children where child.name == "Contents" || child.name == "CommonPrefixes" {
            let directory = child.name == "CommonPrefixes"
            guard let key = try decode(child.value(directory ? "Prefix" : "Key")),
                  key.utf8.starts(with: prefix.utf8) else { throw TransferError.invalidListing(L10n.text("S3 返回了其他前缀的对象。")) }
            try S3Endpoint.validateKey(key)
            if key.utf8.elementsEqual(prefix.utf8) && key.hasSuffix("/") { continue } // The current directory's zero-byte marker.
            let suffix = String(decoding: key.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
            let rawName = directory ? String(suffix.dropLast()) : suffix
            guard (directory || !rawName.isEmpty), !rawName.contains("/"), !directory || key.hasSuffix("/"), seen.insert(Data(key.utf8)).inserted else {
                throw TransferError.invalidListing(L10n.text("S3 列表包含非直接子项或重复对象。"))
            }
            let name = rawName.isEmpty ? "/" : rawName // An empty path component is a distinct prefix.
            let size: Int64
            if directory { size = 0 }
            else {
                guard let rawSize = try child.value("Size"), let parsed = Int64(rawSize), parsed >= 0 else {
                    throw TransferError.invalidListing(L10n.text("S3 对象大小无效。"))
                }
                size = parsed
            }
            let modified = try child.value("LastModified").flatMap { date.date(from: $0) ?? wholeDate.date(from: $0) }
            let etag = try child.value("ETag")
            if !directory {
                guard etag != nil else { throw TransferError.invalidListing(L10n.text("S3 对象缺少版本标识。")) }
                try RemoteFileVersion(size: size, modified: nil, etag: etag).validate()
            }
            objects.append(S3Object(key: key, name: name, isPrefix: directory, size: size, modified: modified, etag: etag))
        }
        guard objects.count <= 1000 else { throw TransferError.invalidListing(L10n.text("S3 单页对象过多。")) }
        let next = try root.value("NextContinuationToken")
        guard truncated == "false" || (next?.isEmpty == false) else { throw TransferError.invalidListing(L10n.text("S3 分页令牌缺失。")) }
        return S3ListingPage(objects: objects, next: truncated == "true" ? next : nil)
    }
}
