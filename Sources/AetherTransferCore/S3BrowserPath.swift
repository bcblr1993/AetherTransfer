import Foundation

/// Prefix navigation preserves raw UTF-8 bytes and empty path components.
public enum S3BrowserPath {
    public static func validatePrefix(_ prefix: String) throws {
        try S3Endpoint.validateKey(prefix)
        guard prefix.isEmpty || prefix.hasSuffix("/") else { throw TransferError.invalidPath }
    }
    public static func parent(_ prefix: String) -> String {
        guard !prefix.isEmpty else { return "" }
        let value = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        guard let slash = value.lastIndex(of: "/") else { return "" }
        return String(value[...slash])
    }
    public static func append(_ name: String, to prefix: String) throws -> String {
        try validatePrefix(prefix); try validateLocalName(name)
        let key = prefix + name; try S3Endpoint.validateKey(key); return key
    }
    public static func validateLocalName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw TransferError.remote("此对象键无法安全映射为本地文件名，请选择其他保存名称。")
        }
    }
}

extension S3Object {
    public var fileEntry: FileEntry {
        FileEntry(name: name, path: key, isDirectory: isPrefix, size: size, modified: modified, s3Key: key)
    }
}
