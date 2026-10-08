import Foundation
import Darwin

public struct FilePasteInput: Sendable, Identifiable {
    public let root: SyncRoot
    public let name: String
    public var id: String { root.id + ":" + Data(name.utf8).base64EncodedString() }
    public init(root: SyncRoot, name: String) { self.root = root; self.name = name }
}

public enum FilePasteIssue: Sendable, Equatable {
    case occupied, reserved, typeConflict, overlap
    public var description: String {
        switch self {
        case .occupied: L10n.text("目标名称已占用")
        case .reserved: L10n.text("多个源项目不能使用同一目标名称。")
        case .typeConflict: L10n.text("文件与目录类型冲突，请先处理。")
        case .overlap: FilePasteError.overlap.localizedDescription
        }
    }
}

public struct FilePasteItem: Sendable, Identifiable {
    public let input: FilePasteInput
    public let destinationName: String
    public let skipped: Bool
    public let issue: FilePasteIssue?
    public let count: Int
    public let bytes: Int64
    public let overwriteCount: Int
    public var id: String { input.id }
    let sourceRoot: SyncRoot
    let sourceRootVersion: PasteVersion
    let source: PasteTree
    let destination: PasteTree
}

/// Read-only preparation for the full file operation, not a completed transfer.
/// Secrets stay in captured clients in memory; this plan is never serialized.
public struct FilePastePlan: Sendable {
    public let id = UUID()
    public let destination: SyncRoot
    public let move: Bool
    public let policy: ConflictPolicy
    public let items: [FilePasteItem]
    public var canApply: Bool { items.contains { !$0.skipped } && !items.contains { !$0.skipped && $0.issue != nil } }
    public var count: Int { items.filter { !$0.skipped }.reduce(0) { $0 + $1.count } }
    public var bytes: Int64 { items.filter { !$0.skipped }.reduce(0) { $0 + $1.bytes } }
    public var overwriteCount: Int { items.filter { !$0.skipped }.reduce(0) { $0 + $1.overwriteCount } }
    let initialDestination: SyncRoot
    let destinationState: PasteRootState
    let limits: PasteLimits
}

public enum FilePasteError: Error, LocalizedError, Sendable {
    case invalid, changed, overlap, overlappingSelection, unsupported, limit
    public var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("粘贴计划无效，请重新生成预览。")
        case .changed: L10n.text("源或目标已变化，请重新生成粘贴预览。")
        case .overlap: L10n.text("不能将项目写回原位置，或将文件夹放入自身及其子目录。")
        case .overlappingSelection: L10n.text("所选源项目互相包含，请保留文件夹或其内部项目中的一种选择。")
        case .unsupported: L10n.text("粘贴预览只支持普通文件和文件夹，不跟随符号链接。")
        case .limit: L10n.text("粘贴预览超过 1,000 个选择、100,000 个项目、32 MiB 元数据或 64 层目录。")
        }
    }
}

struct PasteLimits: Sendable { var nodes = 100_000; var metadata = 32 * 1024 * 1024; var depth = 64 }
struct PasteBudget: Sendable {
    let limits: PasteLimits
    var nodes = 0, metadata = 0
    mutating func charge(_ bytes: Int, node: Bool = false) throws {
        try Task.checkCancellation()
        guard bytes >= 0, bytes <= limits.metadata - metadata,
              !node || nodes < limits.nodes else { throw FilePasteError.limit }
        metadata += bytes; if node { nodes += 1 }
    }
}
struct PasteLocalVersion: Sendable, Equatable {
    let device: Int32, inode: UInt64, mode: UInt16, owner: UInt32, group: UInt32
    let size: Int64, seconds: Int64, nanos: Int64, changedSeconds: Int64, changedNanos: Int64
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; mode = UInt16(info.st_mode)
        owner = info.st_uid; group = info.st_gid
        let directory = info.st_mode & S_IFMT == S_IFDIR
        size = directory ? 0 : info.st_size
        seconds = directory ? 0 : Int64(info.st_mtimespec.tv_sec)
        nanos = directory ? 0 : Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = directory ? 0 : Int64(info.st_ctimespec.tv_sec)
        changedNanos = directory ? 0 : Int64(info.st_ctimespec.tv_nsec)
    }
}
struct PasteVersion: Sendable, Equatable {
    let directory: Bool
    let size: Int64
    let permissions: String
    let local: PasteLocalVersion?
    let remote: RemoteFileVersion?
    static func local(_ info: stat) throws -> Self {
        guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { throw FilePasteError.unsupported }
        guard info.st_size >= 0 else { throw FilePasteError.unsupported }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        return Self(directory: directory, size: directory ? 0 : info.st_size, permissions: "", local: PasteLocalVersion(info), remote: nil)
    }
    static let root = Self(directory: true, size: 0, permissions: "", local: nil, remote: nil)
}
struct PasteNode: Sendable, Equatable {
    let relative: String
    let version: PasteVersion
    var key: Data { Data(relative.utf8) }
    static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.version == b.version }
}
struct PasteTree: Sendable, Equatable {
    var nodes: [PasteNode] = []
    var bytes: Int64 = 0
    mutating func append(_ path: String, version: PasteVersion, budget: inout PasteBudget) throws {
        try budget.charge(path.utf8.count * 2 + 256 + version.permissions.utf8.count + (version.remote?.etag?.utf8.count ?? 0), node: true)
        let sum = bytes.addingReportingOverflow(version.size)
        guard !sum.overflow else { throw FilePasteError.limit }
        bytes = sum.partialValue; nodes.append(PasteNode(relative: path, version: version))
    }
}
struct PasteListing: Sendable { let entry: FileEntry; let etag: String? }
struct PasteRootState: Sendable {
    let version: PasteVersion
    let names: [Data: String]
    let entries: [Data: PasteListing]
}

public enum FilePaste {
    public static func preview(_ inputs: [FilePasteInput], destination: SyncRoot, move: Bool = false,
                               policy: ConflictPolicy = .reject, excluded: Set<String> = []) async throws -> FilePastePlan {
        try await preview(inputs, destination: destination, move: move, policy: policy, excluded: excluded, limits: PasteLimits())
    }
    static func preview(_ inputs: [FilePasteInput], destination initialDestination: SyncRoot, move: Bool,
                        policy: ConflictPolicy, excluded: Set<String>, limits: PasteLimits) async throws -> FilePastePlan {
        guard !inputs.isEmpty, inputs.count <= 1000 else { throw inputs.isEmpty ? FilePasteError.invalid : .limit }
        var budget = PasteBudget(limits: limits)
        let destination = try await initialDestination.canonicalized()
        let (destinationState, afterDestination) = try await PasteScan.root(destination, budget: budget); budget = afterDestination
        let destinationAliases = Dictionary(grouping: destinationState.names.values, by: PasteScan.alias)
        let destinationAliasKeys = Set(destinationAliases.keys)
        var cache = [destination.id: destinationState], reserved = Set<Data>(), seen = Set<String>()
        var items: [FilePasteItem] = [], totalBytes: Int64 = 0, paths: [(SyncRoot, String)] = []
        for input in inputs {
            try Task.checkCancellation(); try RemotePath.validateName(input.name)
            guard seen.insert(input.id).inserted else { continue }
            let root = try await input.root.canonicalized()
            let state: PasteRootState
            if let cached = cache[root.id] { state = cached }
            else { let (value, next) = try await PasteScan.root(root, budget: budget); state = value; budget = next; cache[root.id] = value }
            guard state.names[Data(input.name.utf8)] != nil else { throw FilePasteError.changed }
            let key = PasteScan.alias(input.name)
            let aliases = destinationAliases[key] ?? []
            let exists = !aliases.isEmpty || reserved.contains(key)
            let skipped = excluded.contains(input.id) || (policy == .skip && exists)
            if skipped {
                items.append(FilePasteItem(input: input, destinationName: input.name, skipped: true, issue: nil, count: 0,
                    bytes: 0, overwriteCount: 0, sourceRoot: root, sourceRootVersion: state.version, source: PasteTree(), destination: PasteTree()))
                continue
            }
            let sourcePath = try root.fullPath(input.name)
            for (other, path) in paths where other.endpoint == root.endpoint {
                if PasteScan.contains(path, sourcePath, root: root) || PasteScan.contains(sourcePath, path, root: root) {
                    throw FilePasteError.overlappingSelection
                }
            }
            paths.append((root, sourcePath))
            let first = try await PasteScan.top(root, name: input.name, state: state)
            var name = input.name, issue: FilePasteIssue?
            if exists && policy == .keepBoth {
                name = try PasteScan.available(input.name, directory: first.directory, existing: destinationAliasKeys, reserved: reserved)
            } else if reserved.contains(key) { issue = .reserved }
            else if exists && (policy == .reject || aliases.count != 1 || Data(aliases[0].utf8) != Data(name.utf8)) { issue = .occupied }
            let targetPath = try destination.fullPath(name)
            if root.endpoint == destination.endpoint {
                if Data(sourcePath.utf8) == Data(targetPath.utf8) { issue = .overlap }
                else if first.directory {
                    if try await PasteScan.encloses(first, path: sourcePath, destination: destination) { issue = .overlap }
                }
            }
            // Resolve overlap before traversing either subtree.
            if issue == .overlap {
                items.append(FilePasteItem(input: input, destinationName: name, skipped: false, issue: issue, count: 0,
                    bytes: 0, overwriteCount: 0, sourceRoot: root, sourceRootVersion: state.version, source: PasteTree(), destination: PasteTree()))
                continue
            }
            let (source, afterSource) = try await PasteScan.tree(root, name: input.name, state: state, budget: budget); budget = afterSource
            guard source.nodes.first?.version == first else { throw FilePasteError.changed }
            var target = PasteTree()
            if destinationState.names[Data(name.utf8)] != nil {
                let (value, next) = try await PasteScan.tree(destination, name: name, state: destinationState, budget: budget)
                target = value; budget = next
                if let a = first.local, let b = target.nodes.first?.version.local,
                   a.device == b.device, a.inode == b.inode { issue = .overlap }
            }
            let targetByPath = Dictionary(uniqueKeysWithValues: target.nodes.map { ($0.key, $0.version) })
            var overwrites = 0, mapped = [Data: [Data: Data]]()
            for node in target.nodes { try PasteScan.reserve(node.relative, mapped: &mapped) }
            for node in source.nodes {
                _ = try destination.fullPath(node.relative.isEmpty ? name : name + "/" + node.relative)
                if destination.isS3 && node.version.directory { _ = try S3Endpoint.validateKey(targetPath + (node.relative.isEmpty ? "" : "/" + node.relative) + "/") }
                if !PasteScan.canReserve(node.relative, mapped: &mapped) { issue = .occupied }
                if let existing = targetByPath[node.key] {
                    if existing.directory != node.version.directory { issue = .typeConflict }
                    else if !existing.directory { overwrites += 1 }
                }
            }
            let sum = totalBytes.addingReportingOverflow(source.bytes); guard !sum.overflow else { throw FilePasteError.limit }
            totalBytes = sum.partialValue
            items.append(FilePasteItem(input: input, destinationName: name, skipped: false, issue: issue, count: source.nodes.count,
                bytes: source.bytes, overwriteCount: overwrites, sourceRoot: root, sourceRootVersion: state.version, source: source, destination: target))
            reserved.insert(PasteScan.alias(name))
        }
        return FilePastePlan(destination: destination, move: move, policy: policy, items: items,
                             initialDestination: initialDestination, destinationState: destinationState, limits: limits)
    }

    /// Full read-only revalidation before an executor may perform its first write.
    public static func validate(_ plan: FilePastePlan) async throws {
        guard plan.canApply else { throw FilePasteError.invalid }
        var budget = PasteBudget(limits: plan.limits)
        let destination = try await plan.initialDestination.canonicalized()
        guard destination.id == plan.destination.id else { throw FilePasteError.changed }
        let (state, next) = try await PasteScan.root(destination, budget: budget); budget = next
        guard state.version == plan.destinationState.version, state.names.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) ==
              plan.destinationState.names.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw FilePasteError.changed }
        var cache = [destination.id: state]
        for item in plan.items where !item.skipped {
            let root = try await item.input.root.canonicalized()
            guard root.id == item.sourceRoot.id else { throw FilePasteError.changed }
            let sourceState: PasteRootState
            if let value = cache[root.id] { sourceState = value }
            else { let (value, next) = try await PasteScan.root(root, budget: budget); sourceState = value; budget = next; cache[root.id] = value }
            guard sourceState.version == item.sourceRootVersion else { throw FilePasteError.changed }
            let (source, afterSource) = try await PasteScan.tree(root, name: item.input.name, state: sourceState, budget: budget); budget = afterSource
            let (target, afterTarget) = try await PasteScan.tree(destination, name: item.destinationName, state: state, budget: budget); budget = afterTarget
            guard source == item.source, target == item.destination else { throw FilePasteError.changed }
        }
    }
}

enum PasteScan {
    static func alias(_ name: String) -> Data { Data(name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).utf8) }
    static func contains(_ parent: String, _ child: String, root: SyncRoot) -> Bool {
        let a = Data(parent.utf8), b = Data(child.utf8)
        return a == b || b.starts(with: a + Data((parent.hasSuffix("/") ? "" : "/").utf8))
    }
    static func available(_ name: String, directory: Bool, existing: Set<Data>, reserved: Set<Data>) throws -> String {
        let ext = directory || name.hasPrefix(".") ? "" : URL(fileURLWithPath: name).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for number in 2...10_000 {
            try Task.checkCancellation()
            let value = stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
            try RemotePath.validateName(value)
            let key = alias(value)
            if !existing.contains(key) && !reserved.contains(key) { return value }
        }
        throw FilePasteError.limit
    }
    static func canReserve(_ path: String, mapped: inout [Data: [Data: Data]]) -> Bool {
        guard !path.isEmpty else { return true }
        let parts = path.split(separator: "/"), name = String(parts.last!), parent = Data(parts.dropLast().joined(separator: "/").utf8), key = alias(name), raw = Data(name.utf8)
        if let other = mapped[parent]?[key], other != raw { return false }
        mapped[parent, default: [:]][key] = raw; return true
    }
    static func reserve(_ path: String, mapped: inout [Data: [Data: Data]]) throws {
        guard canReserve(path, mapped: &mapped) else { throw FilePasteError.unsupported }
    }
    static func encloses(_ version: PasteVersion, path: String, destination: SyncRoot) async throws -> Bool {
        guard let identity = version.local, !destination.isRemote else { return contains(path, destination.path, root: destination) }
        return try await TreeIO.run {
            var descriptor = try openDirectory(destination.path)
            defer { close(descriptor) }
            while true {
                try Task.checkCancellation()
                let value = try descriptorVersion(descriptor)
                if value.local?.device == identity.device && value.local?.inode == identity.inode { return true }
                let parent = openat(descriptor, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard parent >= 0 else { throw FilePasteError.changed }
                let next: PasteVersion
                do { next = try descriptorVersion(parent) } catch { close(parent); throw error }
                if next.local?.device == value.local?.device && next.local?.inode == value.local?.inode {
                    close(parent); return false
                }
                close(descriptor); descriptor = parent
            }
        }
    }
    static func listing(_ root: SyncRoot, relative: String) async throws -> [PasteListing] {
        let path = relative.isEmpty ? root.path : try root.fullPath(relative)
        switch root {
        case .remote(let client, _): return try await client.list(path, includingHidden: true).map { PasteListing(entry: $0, etag: nil) }
        case .s3(let client, _):
            let objects = try await client.list(prefix: relative.isEmpty ? path : path + "/")
            try S3TreeSnapshot.validateChildren(objects)
            return objects.map { PasteListing(entry: $0.fileEntry, etag: $0.etag) }
        case .local: throw FilePasteError.invalid
        }
    }
    static func root(_ root: SyncRoot, budget initial: PasteBudget) async throws -> (PasteRootState, PasteBudget) {
        var initial = initial
        try initial.charge(root.path.utf8.count * 2 + 256)
        if !root.isRemote {
            return try await TreeIO.run { [initial] in
                var budget = initial; let fd = try openDirectory(root.path); defer { close(fd) }
                let version = try descriptorVersion(fd), names = try localNames(fd, budget: &budget)
                guard try localStat(root.path) == version else { throw FilePasteError.changed }
                return (PasteRootState(version: version, names: names, entries: [:]), budget)
            }
        }
        var budget = initial, version = PasteVersion.root
        if case .remote(let client, _) = root {
            try client.profile.validate()
            if root.path != "/" {
                guard let entry = try await client.list(RemotePath.parent(root.path), includingHidden: true).first(where: { Data($0.path.utf8) == Data(root.path.utf8) }),
                      entry.isDirectory, !entry.isSymbolicLink else { throw FilePasteError.invalid }
                version = PasteVersion(directory: true, size: 0, permissions: entry.permissions, local: nil, remote: nil)
            }
        } else if case .s3(let client, _) = root {
            try await S3Sync.validateRoot(client, prefix: root.path)
            version = PasteVersion(directory: true, size: 0, permissions: "", local: nil,
                                   remote: root.path.isEmpty ? nil : try await S3Sync.marker(client, prefix: root.path))
        }
        var names: [Data: String] = [:], entries: [Data: PasteListing] = [:]
        for value in try await listing(root, relative: "") {
            try RemotePath.validateName(value.entry.name)
            let key = Data(value.entry.name.utf8)
            guard names.count < budget.limits.nodes, names[key] == nil else { throw FilePasteError.limit }
            try budget.charge(value.entry.name.utf8.count * 2 + value.entry.path.utf8.count * 2 +
                              value.entry.permissions.utf8.count + (value.etag?.utf8.count ?? 0) + 256)
            names[key] = value.entry.name; entries[key] = value
        }
        if root.isS3 && !root.path.isEmpty && version.remote == nil && names.isEmpty { throw FilePasteError.changed }
        return (PasteRootState(version: version, names: names, entries: entries), budget)
    }
    static func top(_ root: SyncRoot, name: String, state: PasteRootState) async throws -> PasteVersion {
        if !root.isRemote { return try await TreeIO.run { try localStat(root.fullPath(name)) } }
        guard let value = state.entries[Data(name.utf8)] else { throw FilePasteError.changed }
        return try await version(root, relative: name, listed: value)
    }
    static func version(_ root: SyncRoot, relative: String, listed: PasteListing) async throws -> PasteVersion {
        let entry = listed.entry, path = try root.fullPath(relative)
        guard !entry.isSymbolicLink, entry.size >= 0, Data(entry.path.utf8) == Data((path + (root.isS3 && entry.isDirectory ? "/" : "")).utf8) else { throw FilePasteError.unsupported }
        switch root {
        case .remote(let client, _):
            let value = entry.isDirectory ? nil : try await client.fileVersion(path)
            guard value == nil || value?.size == entry.size else { throw FilePasteError.changed }
            return PasteVersion(directory: entry.isDirectory, size: value?.size ?? 0, permissions: entry.permissions, local: nil, remote: value)
        case .s3(let client, _):
            let value = entry.isDirectory ? try await S3Sync.marker(client, prefix: path + "/") : try await client.fileVersion(path)
            if !entry.isDirectory { guard value?.size == entry.size, value?.etag == listed.etag else { throw FilePasteError.changed } }
            return PasteVersion(directory: entry.isDirectory, size: entry.isDirectory ? 0 : value!.size, permissions: "", local: nil, remote: value)
        case .local: throw FilePasteError.invalid
        }
    }
    static func tree(_ root: SyncRoot, name: String, state: PasteRootState, budget initial: PasteBudget) async throws -> (PasteTree, PasteBudget) {
        guard state.names[Data(name.utf8)] != nil else { return (PasteTree(), initial) }
        if !root.isRemote {
            return try await TreeIO.run {
                var budget = initial, tree = PasteTree()
                let fd = try openDirectory(root.path); defer { close(fd) }
                guard try descriptorVersion(fd) == state.version else { throw FilePasteError.changed }
                func visit(_ parent: Int32, _ name: String, relative: String, depth: Int) throws {
                    try Task.checkCancellation(); guard depth <= budget.limits.depth else { throw FilePasteError.limit }
                    let value = try childVersion(parent, name: name); try tree.append(relative, version: value, budget: &budget)
                    if value.directory {
                        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard child >= 0 else { throw FilePasteError.changed }; defer { close(child) }
                        guard try descriptorVersion(child) == value else { throw FilePasteError.changed }
                        let children = try localNames(child, budget: &budget)
                        for name in children.values.sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }) {
                            try visit(child, name, relative: relative.isEmpty ? name : relative + "/" + name, depth: depth + 1)
                        }
                        var checkBudget = PasteBudget(limits: budget.limits)
                        guard try localNames(child, budget: &checkBudget).keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) ==
                              children.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) else { throw FilePasteError.changed }
                    }
                    guard try childVersion(parent, name: name) == value else { throw FilePasteError.changed }
                }
                try visit(fd, name, relative: "", depth: 0)
                guard try localStat(root.path) == state.version else { throw FilePasteError.changed }
                return (tree, budget)
            }
        }
        var budget = initial, tree = PasteTree()
        func visit(_ item: PasteListing, relative: String, depth: Int) async throws {
            try Task.checkCancellation(); guard depth <= budget.limits.depth else { throw FilePasteError.limit }
            let value = try await version(root, relative: relative, listed: item)
            let top = Data(relative.utf8) == Data(name.utf8) ? "" : String(relative.dropFirst(name.count + 1))
            try tree.append(top, version: value, budget: &budget)
            if value.directory {
                var seen = Set<Data>()
                let children = try await listing(root, relative: relative)
                if root.isS3 && children.isEmpty && value.remote == nil { throw FilePasteError.changed }
                for child in children.sorted(by: { Data($0.entry.name.utf8).lexicographicallyPrecedes(Data($1.entry.name.utf8)) }) {
                    try RemotePath.validateName(child.entry.name)
                    guard seen.insert(Data(child.entry.name.utf8)).inserted else { throw FilePasteError.limit }
                    try await visit(child, relative: relative + "/" + child.entry.name, depth: depth + 1)
                }
            }
        }
        try await visit(state.entries[Data(name.utf8)]!, relative: name, depth: 0)
        return (tree, budget)
    }
    static func localNames(_ fd: Int32, budget: inout PasteBudget) throws -> [Data: String] {
        let copy = dup(fd); guard copy >= 0 else { throw FilePasteError.changed }
        guard let stream = fdopendir(copy) else { close(copy); throw FilePasteError.changed }; defer { closedir(stream) }
        rewinddir(stream); var result = [Data: String]()
        while true {
            try Task.checkCancellation(); errno = 0
            guard let value = readdir(stream) else { if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; break }
            let name = withUnsafePointer(to: &value.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(value.pointee.d_namlen) + 1) { String(validatingCString: $0) } }
            guard let name else { throw FilePasteError.unsupported }
            if name == "." || name == ".." { continue }
            try RemotePath.validateName(name); let key = Data(name.utf8)
            guard result.count < budget.limits.nodes, result[key] == nil else { throw FilePasteError.limit }
            try budget.charge(name.utf8.count * 2 + 64); result[key] = name
        }
        return result
    }
    static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FilePasteError.changed }; return fd
    }
    static func descriptorVersion(_ fd: Int32) throws -> PasteVersion {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw FilePasteError.changed }; return try .local(info)
    }
    static func childVersion(_ fd: Int32, name: String) throws -> PasteVersion {
        var info = stat(); guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw FilePasteError.changed }; return try .local(info)
    }
    static func localStat(_ path: String) throws -> PasteVersion {
        var info = stat(); guard lstat(path, &info) == 0 else { throw FilePasteError.changed }; return try .local(info)
    }
}
