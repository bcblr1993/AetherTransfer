import Foundation

public enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case sftp, ftp, ftps
    public var defaultPort: Int { self == .sftp ? 22 : (self == .ftps ? 990 : 21) }
    public var title: String { rawValue.uppercased() }
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
        components.scheme = protocolKind.rawValue; components.host = host; components.port = port
        let absolute = RemotePath.normalize(path)
        // FTP URLs need a second slash to address an absolute server path.
        components.path = (protocolKind == .sftp ? "" : "/") + absolute + (directory && absolute != "/" ? "/" : "")
        guard let url = components.url else { throw TransferError.invalidConnection }
        return url.absoluteString
    }
    public static func grouped(_ profiles: [ServerProfile]) -> [ServerProfileGroup] {
        var dict: [String: [ServerProfile]] = [:]
        for profile in profiles {
            let key = profile.group.trimmingCharacters(in: .whitespaces).isEmpty ? "未分组" : profile.group.trimmingCharacters(in: .whitespaces)
            dict[key, default: []].append(profile)
        }
        let sortedKeys = dict.keys.sorted { k1, k2 in
            if k1 == "未分组" { return false }
            if k2 == "未分组" { return true }
            return k1.localizedStandardCompare(k2) == .orderedAscending
        }
        return sortedKeys.map { ServerProfileGroup(groupName: $0, profiles: dict[$0] ?? []) }
    }
    public static func exportJSON(_ profiles: [ServerProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profiles)
    }
    public static func importJSON(_ data: Data) throws -> [ServerProfile] {
        let decoder = JSONDecoder()
        return try decoder.decode([ServerProfile].self, from: data)
    }
}

public struct ServerProfileGroup: Identifiable, Sendable {
    public var id: String { groupName }
    public let groupName: String
    public let profiles: [ServerProfile]
    public init(groupName: String, profiles: [ServerProfile]) {
        self.groupName = groupName
        self.profiles = profiles
    }
}

public struct PlaceItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let systemImage: String
    public init(name: String, path: String, systemImage: String) {
        self.name = name
        self.path = path
        self.systemImage = systemImage
    }
    public static func defaultPlaces() -> [PlaceItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            PlaceItem(name: L10n.tr("个人文件夹", "Home"), path: home.path, systemImage: "house.fill"),
            PlaceItem(name: L10n.tr("桌面", "Desktop"), path: home.appendingPathComponent("Desktop").path, systemImage: "menubar.dock.rectangle"),
            PlaceItem(name: L10n.tr("文稿", "Documents"), path: home.appendingPathComponent("Documents").path, systemImage: "folder.fill"),
            PlaceItem(name: L10n.tr("下载", "Downloads"), path: home.appendingPathComponent("Downloads").path, systemImage: "arrow.down.circle.fill")
        ]
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
    public static func breadcrumbs(for path: String) -> [BreadcrumbItem] {
        let normalized = normalize(path)
        var result: [BreadcrumbItem] = [BreadcrumbItem(name: "/", path: "/")]
        if normalized == "/" { return result }
        let components = normalized.split(separator: "/").map(String.init)
        var current = ""
        for comp in components {
            current += "/" + comp
            result.append(BreadcrumbItem(name: comp, path: current))
        }
        return result
    }
    public static func uniqueName(for name: String, existingNames: [String]) -> String {
        guard existingNames.contains(name) else { return name }
        let set = Set(existingNames)
        let dotIndex = name.lastIndex(of: ".")
        let base: String
        let ext: String
        if let dot = dotIndex, dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            base = name
            ext = ""
        }
        var counter = 1
        while true {
            let candidate = "\(base) (\(counter))\(ext)"
            if !set.contains(candidate) {
                return candidate
            }
            counter += 1
        }
    }
}

public struct BreadcrumbItem: Identifiable, Hashable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum ConflictResolution: String, CaseIterable, Identifiable, Sendable {
    case overwrite = "覆盖"
    case skip = "跳过"
    case keepBoth = "保留两者"
    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .overwrite: return L10n.tr("覆盖", "Overwrite")
        case .skip: return L10n.tr("跳过", "Skip")
        case .keepBoth: return L10n.tr("保留两者", "Keep Both")
        }
    }
}

public struct NavigationHistory: Sendable {
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    public private(set) var currentPath: String

    public init(initialPath: String) {
        self.currentPath = RemotePath.normalize(initialPath)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public mutating func navigateTo(_ path: String) {
        let normalized = RemotePath.normalize(path)
        guard normalized != currentPath else { return }
        backStack.append(currentPath)
        currentPath = normalized
        forwardStack.removeAll()
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let prev = backStack.popLast() else { return false }
        forwardStack.append(currentPath)
        currentPath = prev
        return true
    }

    @discardableResult
    public mutating func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(currentPath)
        currentPath = next
        return true
    }
}

public enum FileSortField: String, CaseIterable, Identifiable, Sendable {
    case name = "名称"
    case size = "大小"
    case date = "修改日期"
    case kind = "种类"
    public var id: String { rawValue }
    public var localizedTitle: String {
        switch self {
        case .name: return L10n.tr("名称", "Name")
        case .size: return L10n.tr("大小", "Size")
        case .date: return L10n.tr("修改日期", "Date Modified")
        case .kind: return L10n.tr("种类", "Kind")
        }
    }
}

public struct PermissionTriad: Hashable, Equatable, Sendable {
    public var read: Bool
    public var write: Bool
    public var execute: Bool
    public init(read: Bool = false, write: Bool = false, execute: Bool = false) {
        self.read = read
        self.write = write
        self.execute = execute
    }
    public var octalDigit: Int {
        (read ? 4 : 0) + (write ? 2 : 0) + (execute ? 1 : 0)
    }
    public var triadString: String {
        "\(read ? "r" : "-")\(write ? "w" : "-")\(execute ? "x" : "-")"
    }
    public static func from(digit: Int) -> PermissionTriad {
        PermissionTriad(read: (digit & 4) != 0, write: (digit & 2) != 0, execute: (digit & 1) != 0)
    }
    public static func from(triad: Substring) -> PermissionTriad {
        let chars = Array(triad)
        let r = chars.indices.contains(0) && chars[0] == "r"
        let w = chars.indices.contains(1) && chars[1] == "w"
        let x = chars.indices.contains(2) && (chars[2] == "x" || chars[2] == "s" || chars[2] == "t")
        return PermissionTriad(read: r, write: w, execute: x)
    }
}

public struct POSIXPermissions: Hashable, Equatable, Sendable {
    public var owner: PermissionTriad
    public var group: PermissionTriad
    public var others: PermissionTriad

    public init(owner: PermissionTriad = PermissionTriad(), group: PermissionTriad = PermissionTriad(), others: PermissionTriad = PermissionTriad()) {
        self.owner = owner
        self.group = group
        self.others = others
    }

    public init(fromModeString str: String) {
        let clean = str.trimmingCharacters(in: .whitespaces)
        let modeChars: Substring
        if clean.count >= 10 {
            modeChars = clean.dropFirst(1)
        } else {
            modeChars = Substring(clean)
        }
        let oStr = modeChars.prefix(3)
        let gStr = modeChars.dropFirst(3).prefix(3)
        let otherStr = modeChars.dropFirst(6).prefix(3)

        self.owner = PermissionTriad.from(triad: oStr)
        self.group = PermissionTriad.from(triad: gStr)
        self.others = PermissionTriad.from(triad: otherStr)
    }

    public init?(fromOctalString str: String) {
        var clean = str.trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("0") && clean.count == 4 {
            clean.removeFirst()
        }
        guard clean.count == 3, let val = Int(clean, radix: 8) else { return nil }
        let d1 = (val >> 6) & 7
        let d2 = (val >> 3) & 7
        let d3 = val & 7
        self.owner = PermissionTriad.from(digit: d1)
        self.group = PermissionTriad.from(digit: d2)
        self.others = PermissionTriad.from(digit: d3)
    }

    public var octalInt: Int {
        (owner.octalDigit << 6) | (group.octalDigit << 3) | others.octalDigit
    }

    public var octalString: String {
        String(format: "0%o", octalInt)
    }

    public var modeString: String {
        owner.triadString + group.triadString + others.triadString
    }
}

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
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
    public var fileExtension: String {
        if isDirectory { return "" }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
    public var kindDescription: String {
        if isDirectory { return "文件夹" }
        switch fileExtension {
        case "pdf": return "PDF 文稿"
        case "txt", "text", "md", "markdown": return "纯文本文件"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "图像"
        case "mp4", "mov", "avi", "mkv": return "视频"
        case "mp3", "m4a", "flac", "wav": return "音频"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "dmg": return "压缩文件"
        case "swift", "c", "h", "cpp", "py", "sh", "js", "ts", "json", "xml", "html", "css": return "源代码"
        default: return fileExtension.isEmpty ? "文件" : "\(fileExtension.uppercased()) 文件"
        }
    }
    public var localizedKindDescription: String {
        if !L10n.isEnglish { return kindDescription }
        if isDirectory { return "Folder" }
        switch fileExtension {
        case "pdf": return "PDF Document"
        case "txt", "text", "md", "markdown": return "Plain Text"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "Image"
        case "mp4", "mov", "avi", "mkv": return "Video"
        case "mp3", "m4a", "flac", "wav": return "Audio"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "dmg": return "Archive"
        case "swift", "c", "h", "cpp", "py", "sh", "js", "ts", "json", "xml", "html", "css": return "Source Code"
        default: return fileExtension.isEmpty ? "Document" : "\(fileExtension.uppercased()) File"
        }
    }
    public static func sorted(_ entries: [FileEntry], by field: FileSortField = .name, ascending: Bool = true, foldersFirst: Bool = true) -> [FileEntry] {
        entries.sorted { a, b in
            if foldersFirst && a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            let comparison: ComparisonResult
            switch field {
            case .name:
                comparison = a.name.localizedStandardCompare(b.name)
            case .size:
                if a.size == b.size {
                    comparison = a.name.localizedStandardCompare(b.name)
                } else {
                    comparison = a.size < b.size ? .orderedAscending : .orderedDescending
                }
            case .date:
                let d1 = a.modified ?? .distantPast
                let d2 = b.modified ?? .distantPast
                if d1 == d2 {
                    comparison = a.name.localizedStandardCompare(b.name)
                } else {
                    comparison = d1 < d2 ? .orderedAscending : .orderedDescending
                }
            case .kind:
                let k1 = a.kindDescription
                let k2 = b.kindDescription
                if k1 == k2 {
                    comparison = a.name.localizedStandardCompare(b.name)
                } else {
                    comparison = k1.localizedStandardCompare(k2)
                }
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        sorted(entries, by: .name, ascending: true, foldersFirst: true)
    }
}
