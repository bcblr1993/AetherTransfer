import Foundation
import Darwin

public struct UnixPermissions: Hashable, Sendable {
    public let rawValue: UInt16
    public init(_ value: UInt16) throws {
        guard value <= 0o7777 else { throw FilePermissionError.invalidMode }
        rawValue = value
    }
    public init(octal: String) throws {
        let bytes = Array(octal.utf8)
        guard (3...4).contains(bytes.count), bytes.allSatisfy({ (48...55).contains($0) }),
              let value = UInt16(octal, radix: 8) else { throw FilePermissionError.invalidMode }
        try self.init(value)
    }
    public init(listing: String) throws {
        if (try? UnixPermissions(octal: listing)) != nil { try self.init(octal: listing); return }
        let bytes = Array(listing.utf8)
        guard (10...11).contains(bytes.count), [UInt8(45), 100, 108].contains(bytes[0]),
              bytes.count == 10 || [UInt8(43), 64, 46].contains(bytes[10]) else { throw FilePermissionError.unavailable }
        var mode: UInt16 = 0
        for group in 0..<3 {
            let index = 1 + group * 3, shift = (2 - group) * 3
            guard [UInt8(114), 45].contains(bytes[index]), [UInt8(119), 45].contains(bytes[index + 1]) else { throw FilePermissionError.unavailable }
            if bytes[index] == 114 { mode |= 4 << shift }
            if bytes[index + 1] == 119 { mode |= 2 << shift }
            let execute = bytes[index + 2]
            let special: [UInt8] = group == 2 ? [116, 84] : [115, 83]
            guard execute == 120 || execute == 45 || special.contains(execute) else { throw FilePermissionError.unavailable }
            if execute == 120 || execute == special[0] { mode |= 1 << shift }
            if special.contains(execute) { mode |= UInt16(group == 0 ? 0o4000 : (group == 1 ? 0o2000 : 0o1000)) }
        }
        try self.init(mode)
    }
    public var octal: String { String(format: "%04o", Int(rawValue)) }
    public var symbolic: String {
        var result = ""
        for group in 0..<3 {
            let bits = rawValue >> ((2 - group) * 3)
            result += bits & 4 != 0 ? "r" : "-"
            result += bits & 2 != 0 ? "w" : "-"
            let special = rawValue & UInt16(group == 0 ? 0o4000 : (group == 1 ? 0o2000 : 0o1000)) != 0
            result += special ? (group == 2 ? (bits & 1 != 0 ? "t" : "T") : (bits & 1 != 0 ? "s" : "S")) : (bits & 1 != 0 ? "x" : "-")
        }
        return result
    }
}

public enum FilePermissionError: Error, LocalizedError, Sendable, Equatable {
    case invalidMode, unavailable, unsupported, symbolicLink, changed, verification
    public var errorDescription: String? {
        switch self {
        case .invalidMode: L10n.text("请输入 3 或 4 位八进制权限，例如 0644。")
        case .unavailable: L10n.text("无法读取此项目的 Unix 权限。")
        case .unsupported: L10n.text("此连接不支持 Unix 权限编辑。")
        case .symbolicLink: L10n.text("权限编辑不跟随符号链接；请选择实际文件或文件夹。")
        case .changed: L10n.text("项目或权限已变化，请重新读取后再应用。")
        case .verification: L10n.text("权限写入后未能核对，请刷新检查实际结果。")
        }
    }
}

public struct LocalPermissionSnapshot: Sendable {
    public let url: URL
    public let mode: UnixPermissions
    let device: Int32
    let inode: UInt64
    let type: UInt16
    let owner: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    fileprivate init(_ url: URL, _ info: stat) throws {
        self.url = url
        mode = try UnixPermissions(UInt16(info.st_mode & 0o7777))
        device = info.st_dev; inode = info.st_ino; type = UInt16(info.st_mode & S_IFMT); owner = info.st_uid
        size = info.st_size; modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
    fileprivate func matches(_ other: LocalPermissionSnapshot) -> Bool {
        matchesIdentity(other) && mode == other.mode
    }
    fileprivate func matchesIdentity(_ other: LocalPermissionSnapshot) -> Bool {
        device == other.device && inode == other.inode && type == other.type && owner == other.owner && size == other.size &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}

public enum LocalFilePermissions {
    // Synchronous filesystem work. Call only from a worker; the batch facade does so.
    public static func read(_ url: URL) throws -> LocalPermissionSnapshot {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw TransferError.invalidPath }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { throw posixError() }
        if info.st_mode & S_IFMT == S_IFLNK { throw FilePermissionError.symbolicLink }
        try validateType(info)
        return try LocalPermissionSnapshot(url, info)
    }
    public static func apply(_ mode: UnixPermissions, to expected: LocalPermissionSnapshot) throws {
        let fd: Int32
        do { fd = try descriptor(expected.url) }
        catch let error as POSIXError where error.code == .EACCES && expected.owner == geteuid() {
            // An owner may chmod an unreadable file even though open is denied.
            // This path operation never follows the final symlink, but unlike the
            // descriptor path it cannot atomically guard concurrent replacement.
            guard try expected.matches(read(expected.url)) else { throw FilePermissionError.changed }
            try Task.checkCancellation()
            guard expected.url.path.withCString({ fchmodat(AT_FDCWD, $0, mode_t(mode.rawValue), AT_SYMLINK_NOFOLLOW) }) == 0 else { throw posixError() }
            try verify(mode, expected); return
        }
        defer { close(fd) }
        guard try expected.matches(snapshot(expected.url, fd)) else { throw FilePermissionError.changed }
        try Task.checkCancellation()
        guard fchmod(fd, mode_t(mode.rawValue)) == 0 else { throw posixError() }
        try verify(mode, expected)
    }
    private static func verify(_ mode: UnixPermissions, _ expected: LocalPermissionSnapshot) throws {
        let verified = try read(expected.url)
        guard expected.matchesIdentity(verified), verified.mode == mode else { throw FilePermissionError.verification }
    }
    private static func descriptor(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw TransferError.invalidPath }
        // Do not read file contents. NOFOLLOW protects the final component.
        let fd = url.path.withCString { Darwin.open($0, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else {
            if errno == ELOOP { throw FilePermissionError.symbolicLink }
            throw posixError()
        }
        return fd
    }
    private static func snapshot(_ url: URL, _ fd: Int32) throws -> LocalPermissionSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        try validateType(info)
        return try LocalPermissionSnapshot(url, info)
    }
    private static func validateType(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { throw FilePermissionError.unavailable }
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

public struct RemotePermissionSnapshot: Sendable {
    public let entry: FileEntry
    public let mode: UnixPermissions
    public init(_ entry: FileEntry) throws {
        guard !entry.isSymbolicLink else { throw FilePermissionError.symbolicLink }
        self.entry = entry; mode = try UnixPermissions(listing: entry.permissions)
    }
    func matches(_ other: RemotePermissionSnapshot) -> Bool {
        Data(entry.path.utf8) == Data(other.entry.path.utf8) && entry.isDirectory == other.entry.isDirectory &&
        entry.size == other.entry.size && entry.modified == other.entry.modified && mode == other.mode
    }
}

public enum PermissionTarget: Sendable {
    case local(LocalPermissionSnapshot), remote(RemotePermissionSnapshot)
    public var mode: UnixPermissions {
        switch self { case .local(let value): value.mode; case .remote(let value): value.mode }
    }
}

public struct PermissionBatchResult: Sendable {
    public let completed: Int
    public let total: Int
    public let cancelled: Bool
    public let error: String?
}

public enum PermissionBatch {
    public static func prepare(_ entries: [FileEntry], client: RemoteClient?) async throws -> [PermissionTarget] {
        guard !entries.isEmpty else { throw FilePermissionError.unavailable }
        guard !entries.contains(where: \.isSymbolicLink) else { throw FilePermissionError.symbolicLink }
        if let client {
            guard client.profile.protocolKind.supportsUnixPermissions else { throw FilePermissionError.unsupported }
            var parents: [String: [String: FileEntry]] = [:], result: [PermissionTarget] = []
            for entry in entries {
                try Task.checkCancellation(); try RemotePath.validate(entry.path)
                let parent = RemotePath.parent(entry.path), id = Data(parent.utf8).base64EncodedString()
                if parents[id] == nil { parents[id] = try await indexedListing(client, parent: parent) }
                guard let current = parents[id]?[pathKey(entry.path)] else { throw FilePermissionError.changed }
                result.append(.remote(try RemotePermissionSnapshot(current)))
            }
            return result
        }
        let work = Task.detached {
            try entries.map { entry in
                try Task.checkCancellation()
                return PermissionTarget.local(try LocalFilePermissions.read(URL(fileURLWithPath: entry.path)))
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    public static func apply(_ mode: UnixPermissions, targets: [PermissionTarget], client: RemoteClient?,
                             progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> PermissionBatchResult {
        var completed = 0
        let clock = ContinuousClock(); var last = clock.now
        do {
            guard !targets.isEmpty else { throw FilePermissionError.unavailable }
            var parents: [String: [String: FileEntry]] = [:]
            // Check the complete selection before the first mutation, then check again per item.
            for target in targets {
                try Task.checkCancellation()
                switch target {
                case .local(let expected):
                    let work = Task.detached { try LocalFilePermissions.read(expected.url) }
                    let current = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    guard expected.matches(current) else { throw FilePermissionError.changed }
                case .remote(let expected):
                    guard let client else { throw FilePermissionError.unsupported }
                    let parent = RemotePath.parent(expected.entry.path), id = pathKey(parent)
                    if parents[id] == nil { parents[id] = try await indexedListing(client, parent: parent) }
                    guard let entry = parents[id]?[pathKey(expected.entry.path)],
                          try expected.matches(RemotePermissionSnapshot(entry)) else { throw FilePermissionError.changed }
                }
            }
            for target in targets {
                try Task.checkCancellation()
                switch target {
                case .local(let expected):
                    let work = Task.detached { try LocalFilePermissions.apply(mode, to: expected) }
                    try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                case .remote(let expected):
                    guard let client else { throw FilePermissionError.unsupported }
                    try await client.setPermissions(mode, for: expected)
                }
                completed += 1
                if clock.now - last >= .milliseconds(150) || completed == targets.count { progress(completed); last = clock.now }
            }
            return PermissionBatchResult(completed: completed, total: targets.count, cancelled: false, error: nil)
        } catch {
            return PermissionBatchResult(completed: completed, total: targets.count, cancelled: error is CancellationError, error: error is CancellationError ? nil : error.localizedDescription)
        }
    }
    private static func pathKey(_ path: String) -> String { Data(path.utf8).base64EncodedString() }
    private static func indexedListing(_ client: RemoteClient, parent: String) async throws -> [String: FileEntry] {
        try await client.list(parent).reduce(into: [:]) { $0[pathKey($1.path)] = $1 }
    }
}
