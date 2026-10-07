import Foundation

public enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case sftp, ftp, ftps, ftpes, webdavs, webdav
    public var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftps: 990
        case .webdavs: 443
        case .webdav: 80
        default: 21
        }
    }
    public var isWebDAV: Bool { self == .webdav || self == .webdavs }
    public var usesTLS: Bool { self == .ftps || self == .ftpes || self == .webdavs }
    public var urlScheme: String {
        switch self {
        case .webdav: "http"
        case .webdavs: "https"
        case .ftpes: "ftp"
        default: rawValue
        }
    }
    public var title: String {
        switch self {
        case .ftps: "FTPS · 隐式 TLS"
        case .ftpes: "FTP · 显式 TLS"
        case .webdav: "WebDAV · HTTP"
        case .webdavs: "WebDAV · HTTPS"
        default: rawValue.uppercased()
        }
    }
}

public struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var group: String
    public var host: String
    public var port: Int
    public var username: String
    public var protocolKind: TransferProtocol
    public var initialPath: String
    public var privateKeyPath: String
    public var trustedHostKey: String?
    public init(id: UUID = UUID(), name: String = "", group: String = "", host: String = "", port: Int = 22,
                username: String = "", protocolKind: TransferProtocol = .sftp, initialPath: String = "/",
                privateKeyPath: String = "", trustedHostKey: String? = nil) {
        self.id = id; self.name = name; self.group = group; self.host = host; self.port = port
        self.username = username; self.protocolKind = protocolKind; self.initialPath = initialPath
        self.privateKeyPath = privateKeyPath; self.trustedHostKey = trustedHostKey
    }
    public func validate() throws {
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !host.contains("/"),
              !host.contains("@"), !host.contains("?"), !host.contains("#"), (1...65535).contains(port),
              !username.isEmpty else { throw TransferError.invalidConnection }
        try RemotePath.validate(initialPath)
    }
    public func url(path: String, directory: Bool = false) throws -> String {
        try validate(); try RemotePath.validate(path)
        var components = URLComponents()
        components.scheme = protocolKind.urlScheme
        components.host = host; components.port = port
        let absolute = RemotePath.normalize(path)
        // FTP URLs need a second slash to address an absolute server path.
        components.path = (protocolKind == .sftp || protocolKind.isWebDAV ? "" : "/") + absolute + (directory && absolute != "/" ? "/" : "")
        guard let url = components.url else { throw TransferError.invalidConnection }
        return url.absoluteString
    }
}

public struct Credentials: Sendable {
    public var password: String
    public var passphrase: String
    public init(password: String = "", passphrase: String = "") { self.password = password; self.passphrase = passphrase }
}

public enum TransferError: Error, LocalizedError, Sendable {
    case invalidConnection, invalidPath, invalidListing(String), remote(String), conflict(String)
    case hostKeyRequired(key: String, changed: Bool), keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidConnection: "请检查服务器地址、端口和用户名。"
        case .invalidPath: "文件名或路径不合法。"
        case .invalidListing(let line): "服务器目录格式暂不支持：\(line)"
        case .remote(let message): message
        case .conflict(let name): "目标已经存在：\(name)"
        case .hostKeyRequired(_, let changed): changed ? "服务器主机密钥已变化，连接被拒绝。" : "首次连接需要核对服务器指纹。"
        case .keychain(let status): "钥匙串操作失败（\(status)）。"
        }
    }
}

public enum RemotePath {
    public static func validate(_ path: String) throws {
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { throw TransferError.invalidPath }
    }
    public static func validateName(_ name: String) throws {
        try validate(name)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw TransferError.invalidPath }
    }
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
    public static func join(_ parent: String, _ name: String) throws -> String {
        try validateName(name)
        return normalize(parent + "/" + name)
    }
    public static func parent(_ path: String) -> String { normalize(path + "/..") }
    public static func quoted(_ path: String) throws -> String {
        try validate(path)
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var modifiedSortValue: Double { modified?.timeIntervalSince1970 ?? -.infinity }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
    public let permissions: String
    public init(name: String, path: String, isDirectory: Bool, isSymbolicLink: Bool = false,
                size: Int64 = 0, modified: Date? = nil, permissions: String = "") {
        self.name = name; self.path = path; self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink; self.size = size; self.modified = modified; self.permissions = permissions
    }
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
}
