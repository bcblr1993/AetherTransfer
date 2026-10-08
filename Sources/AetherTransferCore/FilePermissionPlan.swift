import Foundation
import Darwin

public struct PermissionScanLimits: Sendable {
    public let entries: Int
    public let metadataBytes: Int
    public let depth: Int
    public init(entries: Int = 1_000_000, metadataBytes: Int = 32 * 1024 * 1024, depth: Int = 64) {
        self.entries = entries; self.metadataBytes = metadataBytes; self.depth = depth
    }
}

public struct PermissionPlan: Sendable {
    public let targets: [PermissionTarget]
    public let recursive: Bool
    public let skippedSymbolicLinks: Int
    public let folderCount: Int
    public let fileCount: Int
    public let commonMode: UnixPermissions?
    let roots: [FileEntry]
    let contents: [String: Set<String>]
    let limits: PermissionScanLimits
    static func key(_ path: String) -> String { Data(path.utf8).base64EncodedString() }
    func matches(_ other: Self) -> Bool {
        guard targets.count == other.targets.count, contents == other.contents,
              skippedSymbolicLinks == other.skippedSymbolicLinks else { return false }
        let indexed = Dictionary(uniqueKeysWithValues: other.targets.map { (Self.key($0.path), $0) })
        return targets.allSatisfy { expected in
            guard let current = indexed[Self.key(expected.path)] else { return false }
            return expected.matches(current)
        }
    }
}

extension PermissionBatch {
    public static func preview(_ entries: [FileEntry], client: RemoteClient?, recursive: Bool,
                               limits: PermissionScanLimits = PermissionScanLimits(),
                               progress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> PermissionPlan {
        guard entries.count <= limits.entries, limits.entries > 0, limits.metadataBytes > 0,
              limits.depth >= 0 else { throw PermissionPlanError.capacity }
        var selectedBytes = 0
        for entry in entries {
            try Task.checkCancellation()
            let cost = PermissionDirectory.cost(entry.path)
            guard cost <= limits.metadataBytes - selectedBytes else { throw PermissionPlanError.capacity }
            selectedBytes += cost
        }
        let selected = try await prepare(entries, client: client)
        var unique = Set<String>()
        let roots = selected.filter { unique.insert(PermissionPlan.key($0.path)).inserted }
        // Index selected directories once; do not compare every selected pair.
        let directories = Set(roots.filter(\.isDirectory).map { PermissionPlan.key($0.path) })
        let topLevel = recursive ? roots.filter { target in
            let bytes = Array(target.path.utf8)
            if bytes.count > 1 && directories.contains(PermissionPlan.key("/")) { return false }
            for index in bytes.indices where bytes[index] == 47 && index > 0 {
                if directories.contains(Data(bytes[..<index]).base64EncodedString()) { return false }
            }
            return true
        } : roots
        let rootEntries = topLevel.map { FileEntry(name: URL(fileURLWithPath: $0.path).lastPathComponent,
                                                  path: $0.path, isDirectory: $0.isDirectory) }
        let updates = PermissionScanProgress(progress)
        let notify: @Sendable (Int) -> Void = { updates.send($0) }
        var state = PermissionScanState(limits: limits, progress: notify)
        for root in topLevel { try state.reserve(root.path, depth: 0) }
        if let client {
            func visit(_ target: PermissionTarget, depth: Int) async throws {
                try Task.checkCancellation()
                if recursive && target.isDirectory {
                    let children = try await PermissionDirectory.remote(target.path, client: client,
                        entries: limits.entries - state.count, bytes: limits.metadataBytes - state.bytes)
                    try state.accept(children, depth: depth + 1)
                    state.contents[PermissionPlan.key(target.path)] = children.members
                    for child in children.items {
                        switch child {
                        case .target(let target): try await visit(target, depth: depth + 1)
                        case .link: state.skipped += 1
                        }
                    }
                }
                state.targets.append(target)
            }
            for root in topLevel { try await visit(root, depth: 0) }
        } else {
            let initial = state
            state = try await TreeIO.run {
                var state = initial
                func visit(_ target: PermissionTarget, depth: Int) throws {
                    try Task.checkCancellation()
                    if recursive && target.isDirectory, case .local(let expected) = target {
                        let children = try PermissionDirectory.local(expected, entries: limits.entries - state.count,
                            bytes: limits.metadataBytes - state.bytes, scanned: state.count, progress: notify)
                        try state.accept(children, depth: depth + 1)
                        state.contents[PermissionPlan.key(target.path)] = children.members
                        for child in children.items {
                            switch child {
                            case .target(let target): try visit(target, depth: depth + 1)
                            case .link: state.skipped += 1
                            }
                        }
                        guard expected.matches(try LocalFilePermissions.read(expected.url)) else { throw FilePermissionError.changed }
                    }
                    state.targets.append(target)
                }
                for root in topLevel { try visit(root, depth: 0) }
                return state
            }
        }
        updates.send(state.count, final: true)
        let folders = state.targets.reduce(0) { $0 + ($1.isDirectory ? 1 : 0) }
        let common = state.targets.first?.mode
        let commonMode = state.targets.allSatisfy { $0.mode == common } ? common : nil
        return PermissionPlan(targets: state.targets, recursive: recursive, skippedSymbolicLinks: state.skipped,
                              folderCount: folders, fileCount: state.targets.count - folders,
                              commonMode: commonMode,
                              roots: rootEntries, contents: state.contents, limits: limits)
    }
    public static func apply(_ mode: UnixPermissions, plan: PermissionPlan, client: RemoteClient?,
                             progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> PermissionBatchResult {
        do {
            try Task.checkCancellation()
            let current = try await preview(plan.roots, client: client, recursive: plan.recursive, limits: plan.limits)
            guard plan.matches(current) else { throw FilePermissionError.changed }
            return await execute(mode, targets: plan.targets, client: client, progress: progress) { target in
                guard let expected = plan.contents[PermissionPlan.key(target.path)] else { return }
                let contents: PermissionDirectory
                switch target {
                case .local(let snapshot):
                    contents = try await TreeIO.run {
                        try PermissionDirectory.local(snapshot, entries: plan.limits.entries, bytes: plan.limits.metadataBytes)
                    }
                case .remote:
                    guard let client else { throw FilePermissionError.unsupported }
                    contents = try await PermissionDirectory.remote(target.path, client: client,
                        entries: plan.limits.entries, bytes: plan.limits.metadataBytes)
                }
                guard expected == contents.members else { throw FilePermissionError.changed }
            }
        } catch {
            return PermissionBatchResult(completed: 0, total: plan.targets.count, cancelled: error is CancellationError,
                                         error: error is CancellationError ? nil : error.localizedDescription)
        }
    }
}

enum PermissionPlanError: Error, LocalizedError {
    case capacity, duplicate
    var errorDescription: String? {
        switch self {
        case .capacity: L10n.text("权限扫描超过容量或目录深度限制，请分批选择子目录。")
        case .duplicate: L10n.text("权限范围包含重复路径，无法安全应用。")
        }
    }
}

private struct PermissionScanState: Sendable {
    let limits: PermissionScanLimits
    let progress: @Sendable (Int) -> Void
    var targets: [PermissionTarget] = []
    var contents: [String: Set<String>] = [:]
    var skipped = 0
    var count = 0
    var bytes = 0
    init(limits: PermissionScanLimits, progress: @escaping @Sendable (Int) -> Void) { self.limits = limits; self.progress = progress }
    mutating func reserve(_ path: String, depth: Int) throws {
        let cost = PermissionDirectory.cost(path)
        guard count < limits.entries, depth <= limits.depth, cost <= limits.metadataBytes - bytes else { throw PermissionPlanError.capacity }
        count += 1; bytes += cost; notify()
    }
    mutating func accept(_ contents: PermissionDirectory, depth: Int) throws {
        guard contents.items.isEmpty || depth <= limits.depth else { throw PermissionPlanError.capacity }
        count += contents.items.count; bytes += contents.bytes; notify()
    }
    private mutating func notify() {
        progress(count)
    }
}

private final class PermissionScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Int) -> Void
    private var last = ContinuousClock.now
    init(_ progress: @escaping @Sendable (Int) -> Void) { self.progress = progress }
    func send(_ count: Int, final: Bool = false) {
        lock.lock()
        guard final || ContinuousClock.now - last >= .milliseconds(150) else { lock.unlock(); return }
        last = .now; lock.unlock()
        progress(count)
    }
}

private struct PermissionDirectory: Sendable {
    enum Child: Sendable { case target(PermissionTarget), link(String) }
    var items: [Child] = []
    var members = Set<String>()
    var bytes = 0
    private var paths = Set<String>()
    static func cost(_ path: String) -> Int { path.utf8.count * 4 + 320 }
    mutating func add(_ child: Child, entries: Int, capacity: Int) throws {
        let path: String, kind: String
        switch child {
        case .target(let target): path = target.path; kind = target.isDirectory ? "d" : "f"
        case .link(let value): path = value; kind = "l"
        }
        guard items.count < entries, Self.cost(path) <= capacity - bytes else { throw PermissionPlanError.capacity }
        let key = PermissionPlan.key(path)
        guard paths.insert(key).inserted else { throw PermissionPlanError.duplicate }
        bytes += Self.cost(path); members.insert(kind + key); items.append(child)
    }
    static func local(_ expected: LocalPermissionSnapshot, entries: Int, bytes: Int, scanned: Int = 0,
                      progress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> Self {
        // Pin the directory while enumerating; never follow its final symlink.
        let fd = Darwin.open(expected.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var stream: UnsafeMutablePointer<DIR>?
        defer { if let stream { closedir(stream) } else { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard try expected.matches(LocalPermissionSnapshot(expected.url, info)) else { throw FilePermissionError.changed }
        stream = fdopendir(fd)
        guard let stream else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var result = Self(), last = ContinuousClock.now
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw FilePermissionError.unavailable }
            if name == "." || name == ".." { continue }
            var childInfo = stat()
            guard fstatat(fd, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let url = expected.url.appendingPathComponent(name), kind = childInfo.st_mode & S_IFMT
            let child: Child
            if kind == S_IFLNK { child = .link(url.path) }
            else {
                guard kind == S_IFREG || kind == S_IFDIR else { throw FilePermissionError.unavailable }
                child = .target(.local(try LocalPermissionSnapshot(url, childInfo)))
            }
            try result.add(child, entries: entries, capacity: bytes)
            if ContinuousClock.now - last >= .milliseconds(150) { progress(scanned + result.items.count); last = .now }
        }
        return result
    }
    static func remote(_ path: String, client: RemoteClient, entries: Int, bytes: Int) async throws -> Self {
        var result = Self()
        for child in try await client.list(path, includingHidden: true) {
            try Task.checkCancellation()
            guard Data(child.path.utf8) == Data(try RemotePath.join(path, child.name).utf8) else { throw TransferError.invalidPath }
            try result.add(child.isSymbolicLink ? .link(child.path) : .target(.remote(try RemotePermissionSnapshot(child))),
                           entries: entries, capacity: bytes)
        }
        return result
    }
}
