import Foundation

public enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case sftp, ftp, ftps, ftpes, webdavs, webdav, s3
    public static var fileServerCases: [Self] { allCases.filter { $0 != .s3 } }
    public var defaultPort: Int {
        switch self {
        case .sftp: 22
        case .ftps: 990
        case .webdavs, .s3: 443
        case .webdav: 80
        default: 21
        }
    }
    public var isWebDAV: Bool { self == .webdav || self == .webdavs }
    public var supportsUnixPermissions: Bool { self == .ftp || self == .ftpes || self == .ftps || self == .sftp }
    public var usesTLS: Bool { self == .ftps || self == .ftpes || self == .webdavs || self == .s3 }
    public var urlScheme: String {
        switch self {
        case .webdav: "http"
        case .webdavs, .s3: "https"
        case .ftpes: "ftp"
        default: rawValue
        }
    }
    public var title: String {
        switch self {
        case .ftps: L10n.text("FTPS · 隐式 TLS")
        case .ftpes: L10n.text("FTP · 显式 TLS")
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
    public var sshAuthentication: SSHAuthentication?
    public var trustedHostKey: String?
    public var s3Bucket: String?
    public var s3Region: String?
    public var s3CertificateAuthorityPath: String?
    public var credentialID: UUID?
    public var retiredCredentialIDs: [UUID]?
    public init(id: UUID = UUID(), name: String = "", group: String = "", host: String = "", port: Int = 22,
                username: String = "", protocolKind: TransferProtocol = .sftp, initialPath: String = "/",
                privateKeyPath: String = "", sshAuthentication: SSHAuthentication? = nil, trustedHostKey: String? = nil,
                s3Bucket: String? = nil, s3Region: String? = nil, s3CertificateAuthorityPath: String? = nil) {
        self.id = id; self.name = name; self.group = group; self.host = host; self.port = port
        self.username = username; self.protocolKind = protocolKind; self.initialPath = initialPath
        self.privateKeyPath = privateKeyPath; self.trustedHostKey = trustedHostKey
        self.sshAuthentication = sshAuthentication
        self.s3Bucket = s3Bucket; self.s3Region = s3Region; self.s3CertificateAuthorityPath = s3CertificateAuthorityPath
        self.credentialID = nil; self.retiredCredentialIDs = nil
    }
    public var s3Endpoint: S3Endpoint {
        S3Endpoint(host: host, port: port, bucket: s3Bucket ?? "", region: s3Region ?? "us-east-1")
    }
    public var effectiveSSHAuthentication: SSHAuthentication {
        sshAuthentication ?? (privateKeyPath.isEmpty ? .password : .privateKey)
    }
    public var connectionIdentity: [String] {
        [host, String(port), protocolKind.rawValue, username, s3Bucket ?? "", s3Region ?? "", s3CertificateAuthorityPath ?? ""]
    }
    public var credentialIdentity: [String] {
        connectionIdentity + (protocolKind == .sftp ? [effectiveSSHAuthentication.rawValue,
            effectiveSSHAuthentication == .privateKey ? privateKeyPath : ""] : [])
    }
    public func validate() throws {
        if protocolKind == .s3 {
            try s3Endpoint.validate(); try S3BrowserPath.validatePrefix(initialPath)
            return
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !host.contains("/"),
              !host.contains("@"), !host.contains("?"), !host.contains("#"), (1...65535).contains(port),
              !username.isEmpty else { throw TransferError.invalidConnection }
        if protocolKind == .sftp && effectiveSSHAuthentication == .privateKey {
            guard !privateKeyPath.isEmpty, !privateKeyPath.utf8.contains(0) else { throw SSHAuthenticationError.privateKeyRequired }
        }
        try RemotePath.validate(initialPath)
    }
    public func url(path: String, directory: Bool = false) throws -> String {
        // A file-server client must never normalize or authenticate an S3 object key.
        guard protocolKind != .s3 else { throw TransferError.invalidConnection }
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
    public var accessKey: String
    public var secretKey: String
    public var sessionToken: String
    public init(password: String = "", passphrase: String = "", accessKey: String = "", secretKey: String = "", sessionToken: String = "") {
        self.password = password; self.passphrase = passphrase
        self.accessKey = accessKey; self.secretKey = secretKey; self.sessionToken = sessionToken
    }
    public var s3: S3Credentials { S3Credentials(accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken) }
}

public enum TransferError: Error, LocalizedError, Sendable {
    case invalidConnection, invalidPath, invalidListing(String), remote(String), conflict(String)
    case hostKeyRequired(key: String, changed: Bool), keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidConnection: L10n.text("请检查服务器地址、端口与认证资料；S3 还需有效的存储桶和区域。")
        case .invalidPath: L10n.text("文件名或路径不合法。")
        case .invalidListing(let line): L10n.format("服务器目录格式暂不支持：%@", String(describing: line))
        case .remote(let message): message
        case .conflict(let name): L10n.format("目标已经存在：%@", String(describing: name))
        case .hostKeyRequired(_, let changed): changed ? L10n.text("服务器主机密钥已变化，连接被拒绝。") : L10n.text("首次连接需要核对服务器指纹。")
        case .keychain(let status): L10n.format("钥匙串操作失败（%@）。", String(describing: status))
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
    public var id: String { s3Identity ?? path }
    private let s3Identity: String?
    public var modifiedSortValue: Double { modified?.timeIntervalSince1970 ?? -.infinity }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
    public let permissions: String
    public let s3Key: String?
    public init(name: String, path: String, isDirectory: Bool, isSymbolicLink: Bool = false,
                size: Int64 = 0, modified: Date? = nil, permissions: String = "", s3Key: String? = nil) {
        self.name = name; self.path = path; self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink; self.size = size; self.modified = modified; self.permissions = permissions
        self.s3Key = s3Key
        self.s3Identity = s3Key.map { "s3:\(isDirectory ? "prefix" : "object"):\(S3Endpoint.encode($0))" }
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.name == b.name && a.isDirectory == b.isDirectory && a.isSymbolicLink == b.isSymbolicLink && a.size == b.size && a.modified == b.modified && a.permissions == b.permissions
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(name); hasher.combine(isDirectory); hasher.combine(isSymbolicLink)
        hasher.combine(size); hasher.combine(modified); hasher.combine(permissions)
    }
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
}
