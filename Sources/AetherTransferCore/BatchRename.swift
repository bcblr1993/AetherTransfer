import Foundation
import Darwin

public enum BatchRenameError: Error, LocalizedError, Sendable {
    case unavailable, changed, limit, invalidRule, unsupported, verification
    public var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("请选择同一目录中的文件或文件夹。")
        case .changed: L10n.text("目录或所选项目已变化，请重新读取重命名预览。")
        case .limit: L10n.text("重命名范围过大：最多选择 1,000 项，目录最多 10,000 项。")
        case .invalidRule: L10n.text("请填写有效的重命名规则和编号范围。")
        case .unsupported: L10n.text("此服务尚不支持批量重命名。")
        case .verification: L10n.text("无法核对重命名结果，请检查列出的实际名称。")
        }
    }
}

public struct RenameRule: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case replace, add, number }
    public var kind: Kind = .replace
    public var find = ""
    public var replacement = ""
    public var prefix = ""
    public var suffix = ""
    public var base = ""
    public var separator = "-"
    public var start = 1
    public var increment = 1
    public var digits = 3
    public var includeExtension = false
    public init() {}
    public func name(for entry: FileEntry, index: Int) throws -> String {
        guard (0..<1000).contains(index), [find, replacement, prefix, suffix, base, separator].allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw BatchRenameError.invalidRule
        }
        var stem = entry.name, ext = ""
        if !includeExtension, !entry.isDirectory, let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            ext = String(stem[dot...]); stem = String(stem[..<dot])
        }
        switch kind {
        case .replace:
            guard !find.isEmpty else { throw BatchRenameError.invalidRule }
            stem = stem.replacingOccurrences(of: find, with: replacement, options: .literal)
        case .add: stem = prefix + stem + suffix
        case .number:
            guard !base.isEmpty, (0...1_000_000_000).contains(start), (1...1_000_000).contains(increment), (1...12).contains(digits) else {
                throw BatchRenameError.invalidRule
            }
            let (offset, overflow) = index.multipliedReportingOverflow(by: increment)
            let (value, additionOverflow) = start.addingReportingOverflow(offset)
            guard !overflow, !additionOverflow else { throw BatchRenameError.invalidRule }
            let number = String(value)
            stem = base + separator + String(repeating: "0", count: max(0, digits - number.count)) + number
        }
        let result = stem + ext
        try RemotePath.validateName(result)
        guard result.utf8.count <= 255 else { throw TransferError.invalidPath }
        return result
    }
}

public struct BatchRenameItem: Identifiable, Sendable {
    public enum Issue: Sendable { case invalidName, duplicate, occupied }
    public let entry: FileEntry
    public let proposedName: String
    public let included: Bool
    public let issue: Issue?
    public var id: String { renameID(entry.name) }
    public var changes: Bool { included && Data(entry.name.utf8) != Data(proposedName.utf8) }
    public var explanation: String {
        if !included { return L10n.text("已排除") }
        switch issue {
        case .invalidName: return L10n.text("名称无效或超过 255 字节")
        case .duplicate: return L10n.text("新名称重复")
        case .occupied: return L10n.text("目标名称已占用")
        case nil: return changes ? L10n.text("待重命名") : L10n.text("名称不变")
        }
    }
}

public struct BatchRenameSnapshot: Sendable {
    public let entries: [FileEntry]
    public let parent: String
    fileprivate let siblings: Set<Data>
    fileprivate let local: [Data: LocalRenameVersion]
    fileprivate let parentIdentity: LocalRenameVersion?
    fileprivate let endpoint: [String]?
    public func plan(rule: RenameRule, excluded: Set<String> = []) throws -> BatchRenamePlan {
        try Task.checkCancellation()
        // Validate the rule even if every item is excluded.
        do { _ = try rule.name(for: entries[0], index: 0) } catch TransferError.invalidPath { }
        var items: [BatchRenameItem] = [], names: [Data: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let proposed: String, issue: BatchRenameItem.Issue?
            do { proposed = try rule.name(for: entry, index: index); issue = nil }
            catch TransferError.invalidPath { proposed = entry.name; issue = .invalidName }
            let included = !excluded.contains(renameID(entry.name))
            items.append(BatchRenameItem(entry: entry, proposedName: proposed, included: included, issue: included ? issue : nil))
            if included && issue == nil { names[collisionKey(proposed), default: []].append(index) }
        }
        let activeSources = Set(items.filter { $0.changes && $0.issue == nil }.map { collisionKey($0.entry.name) })
        var existing: [Data: [Data]] = [:]
        for name in siblings { existing[collisionKey(String(decoding: name, as: UTF8.self)), default: []].append(name) }
        for index in items.indices where items[index].included && items[index].issue == nil {
            let item = items[index], key = collisionKey(item.proposedName)
            let issue: BatchRenameItem.Issue?
            if names[key, default: []].count > 1 { issue = .duplicate }
            else if item.changes, let occupied = existing[key],
                    occupied.count > 1 || (!activeSources.contains(key) && occupied[0] != Data(item.entry.name.utf8)) { issue = .occupied }
            else { issue = nil }
            items[index] = BatchRenameItem(entry: item.entry, proposedName: item.proposedName, included: item.included, issue: issue)
        }
        var steps: [RenameStep] = []
        if !items.contains(where: { $0.included && $0.issue != nil }) {
            var pending = Set(items.indices.filter { items[$0].changes }), current = items.map { $0.entry.name }
            let destinations = items.map { collisionKey($0.proposedName) }
            var occupied = Set(existing.keys), reserved = occupied.union(destinations)
            while !pending.isEmpty {
                try Task.checkCancellation()
                if let index = items.indices.first(where: { pending.contains($0) && !occupied.contains(destinations[$0]) }) {
                    steps.append(RenameStep(index: index, source: current[index], destination: items[index].proposedName, final: true))
                    occupied.remove(collisionKey(current[index])); occupied.insert(destinations[index]); pending.remove(index)
                } else {
                    // Break swaps and case-only cycles without overwriting any original.
                    let index = pending.min()!
                    let temporary = ".aethertransfer-rename-\(UUID().uuidString)"
                    guard !reserved.contains(collisionKey(temporary)) else { throw BatchRenameError.changed }
                    reserved.insert(collisionKey(temporary))
                    steps.append(RenameStep(index: index, source: current[index], destination: temporary, final: false))
                    occupied.remove(collisionKey(current[index])); occupied.insert(collisionKey(temporary)); current[index] = temporary
                }
            }
        }
        return BatchRenamePlan(snapshot: self, items: items, steps: steps)
    }
}

public struct BatchRenamePlan: Sendable {
    public let snapshot: BatchRenameSnapshot
    public let items: [BatchRenameItem]
    fileprivate let steps: [RenameStep]
    public var count: Int { items.filter(\.changes).count }
    public var canApply: Bool { count > 0 && !items.contains { $0.included && $0.issue != nil } }
}

public struct BatchRenameOutcome: Identifiable, Sendable {
    public let original: FileEntry
    public fileprivate(set) var currentName: String
    public fileprivate(set) var completed = false
    /// A command may have reached the server before cancellation. Both names are shown, never reported as success.
    public fileprivate(set) var unconfirmedDestination: String?
    public var id: String { renameID(original.name) }
    public var staged: Bool { !completed && currentName != original.name }
}

public struct BatchRenameResult: Sendable {
    public let outcomes: [BatchRenameOutcome]
    public let total: Int
    public let cancelled: Bool
    public let error: String?
    public var completed: Int { outcomes.filter(\.completed).count }
}

public enum BatchRename {
    public static func preview(_ entries: [FileEntry], client: RemoteClient?) async throws -> BatchRenameSnapshot {
        guard !entries.isEmpty else { throw BatchRenameError.unavailable }
        guard entries.count <= 1000 else { throw BatchRenameError.limit }
        let parent = try selectedParent(entries)
        if let client {
            guard client.profile.protocolKind != .s3 else { throw BatchRenameError.unsupported }
            let listing = try await client.list(parent, includingHidden: true)
            let siblings = try boundedNames(listing.map(\.name)), byName = Dictionary(uniqueKeysWithValues: listing.map { (Data($0.name.utf8), $0) })
            let actual = try entries.map { entry -> FileEntry in
                guard let value = byName[Data(entry.name.utf8)], value.isDirectory == entry.isDirectory, value.isSymbolicLink == entry.isSymbolicLink else {
                    throw BatchRenameError.changed
                }
                return value
            }.sorted { Data($0.name.utf8).lexicographicallyPrecedes(Data($1.name.utf8)) }
            return BatchRenameSnapshot(entries: actual, parent: parent, siblings: siblings, local: [:], parentIdentity: nil, endpoint: endpointIdentity(client))
        }
        return try await worker {
            let fd = try openParent(parent); defer { close(fd) }
            let siblings = try localNames(fd), identity = try parentVersion(fd)
            var versions: [Data: LocalRenameVersion] = [:], actual: [FileEntry] = []
            for entry in entries {
                try Task.checkCancellation()
                let version = try localVersion(fd, name: entry.name)
                guard version.supported, version.isDirectory == entry.isDirectory, version.isLink == entry.isSymbolicLink else { throw BatchRenameError.changed }
                versions[Data(entry.name.utf8)] = version; actual.append(entry)
            }
            actual.sort { Data($0.name.utf8).lexicographicallyPrecedes(Data($1.name.utf8)) }
            return BatchRenameSnapshot(entries: actual, parent: parent, siblings: siblings, local: versions, parentIdentity: identity, endpoint: nil)
        }
    }
    public static func apply(_ plan: BatchRenamePlan, client: RemoteClient?,
                             progress: @escaping @Sendable (Int) -> Void = { _ in }) async -> BatchRenameResult {
        guard plan.canApply else { return result(plan, error: BatchRenameError.invalidRule) }
        if let client {
            guard endpointIdentity(client) == plan.snapshot.endpoint else { return result(plan, error: BatchRenameError.changed) }
            return await applyRemote(plan, client: client, progress: progress)
        }
        guard plan.snapshot.endpoint == nil else { return result(plan, error: BatchRenameError.changed) }
        do { return try await worker { applyLocal(plan, progress: progress) } }
        catch { return result(plan, error: error) }
    }
    private static func applyLocal(_ plan: BatchRenamePlan, progress: @escaping @Sendable (Int) -> Void) -> BatchRenameResult {
        var outcomes = initialOutcomes(plan), expectedNames = plan.snapshot.siblings
        do {
            let fd = try openParent(plan.snapshot.parent); defer { close(fd) }
            guard let expected = plan.snapshot.parentIdentity, expected.sameIdentity(try parentVersion(fd)), try localNames(fd) == expectedNames else { throw BatchRenameError.changed }
            for item in plan.items where item.changes {
                try Task.checkCancellation()
                guard let version = plan.snapshot.local[Data(item.entry.name.utf8)], version == (try localVersion(fd, name: item.entry.name)) else { throw BatchRenameError.changed }
            }
            for step in plan.steps {
                try Task.checkCancellation()
                let pathFD = try openParent(plan.snapshot.parent); defer { close(pathFD) }
                guard try parentVersion(fd).sameIdentity(parentVersion(pathFD)), try localNames(fd) == expectedNames,
                      let version = plan.snapshot.local[Data(plan.items[step.index].entry.name.utf8)], version == (try localVersion(fd, name: step.source)) else { throw BatchRenameError.changed }
                let code = step.source.withCString { source in step.destination.withCString { destination in
                    renameatx_np(fd, source, fd, destination, UInt32(RENAME_EXCL))
                }}
                if code != 0 {
                    if errno == EEXIST { throw TransferError.conflict(step.destination) }
                    throw posixError()
                }
                outcomes[step.index].unconfirmedDestination = step.destination
                guard version == (try localVersion(fd, name: step.destination)), !(try localNames(fd)).contains(Data(step.source.utf8)) else { throw BatchRenameError.verification }
                record(step, outcomes: &outcomes, names: &expectedNames)
                if step.final { progress(outcomes.filter(\.completed).count) }
            }
            return BatchRenameResult(outcomes: outcomes, total: plan.count, cancelled: false, error: nil)
        } catch { return BatchRenameResult(outcomes: outcomes, total: plan.count, cancelled: error is CancellationError, error: error is CancellationError ? nil : error.localizedDescription) }
    }
    private static func applyRemote(_ plan: BatchRenamePlan, client: RemoteClient, progress: @escaping @Sendable (Int) -> Void) async -> BatchRenameResult {
        var outcomes = initialOutcomes(plan), expectedNames = plan.snapshot.siblings
        do {
            try Task.checkCancellation()
            let initial = try await client.list(plan.snapshot.parent, includingHidden: true)
            guard try boundedNames(initial.map(\.name)) == expectedNames else { throw BatchRenameError.changed }
            let initialByName = Dictionary(uniqueKeysWithValues: initial.map { (Data($0.name.utf8), $0) })
            for item in plan.items where item.changes {
                guard let actual = initialByName[Data(item.entry.name.utf8)], sameRemote(item.entry, actual) else { throw BatchRenameError.changed }
            }
            for step in plan.steps {
                try Task.checkCancellation()
                let listing = try await client.list(plan.snapshot.parent, includingHidden: true)
                guard try boundedNames(listing.map(\.name)) == expectedNames,
                      let source = listing.first(where: { Data($0.name.utf8) == Data(step.source.utf8) }), sameRemote(plan.items[step.index].entry, source) else { throw BatchRenameError.changed }
                outcomes[step.index].unconfirmedDestination = step.destination
                try await client.rename(RemotePath.join(plan.snapshot.parent, step.source), to: RemotePath.join(plan.snapshot.parent, step.destination))
                let verified = try await client.list(plan.snapshot.parent, includingHidden: true)
                var afterNames = expectedNames; afterNames.remove(Data(step.source.utf8)); afterNames.insert(Data(step.destination.utf8))
                guard try boundedNames(verified.map(\.name)) == afterNames,
                      let destination = verified.first(where: { Data($0.name.utf8) == Data(step.destination.utf8) }), sameRemote(plan.items[step.index].entry, destination) else { throw BatchRenameError.verification }
                record(step, outcomes: &outcomes, names: &expectedNames)
                if step.final { progress(outcomes.filter(\.completed).count) }
            }
            return BatchRenameResult(outcomes: outcomes, total: plan.count, cancelled: false, error: nil)
        } catch { return BatchRenameResult(outcomes: outcomes, total: plan.count, cancelled: error is CancellationError, error: error is CancellationError ? nil : error.localizedDescription) }
    }
    private static func record(_ step: RenameStep, outcomes: inout [BatchRenameOutcome], names: inout Set<Data>) {
        names.remove(Data(step.source.utf8)); names.insert(Data(step.destination.utf8))
        outcomes[step.index].currentName = step.destination; outcomes[step.index].unconfirmedDestination = nil; outcomes[step.index].completed = step.final
    }
    private static func initialOutcomes(_ plan: BatchRenamePlan) -> [BatchRenameOutcome] { plan.items.map { BatchRenameOutcome(original: $0.entry, currentName: $0.entry.name) } }
    private static func result(_ plan: BatchRenamePlan, error: Error) -> BatchRenameResult {
        BatchRenameResult(outcomes: initialOutcomes(plan), total: plan.count, cancelled: error is CancellationError, error: error is CancellationError ? nil : error.localizedDescription)
    }
}

private struct RenameStep: Sendable { let index: Int; let source: String; let destination: String; let final: Bool }
private struct LocalRenameVersion: Equatable, Sendable {
    let device: Int32; let inode: UInt64; let type: UInt16; let mode: UInt16; let owner: UInt32; let group: UInt32
    let size: Int64; let modifiedSeconds: Int64; let modifiedNanoseconds: Int64
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; type = UInt16(info.st_mode & S_IFMT); mode = UInt16(info.st_mode & 0o7777)
        owner = info.st_uid; group = info.st_gid; size = info.st_size
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
    var isDirectory: Bool { type == S_IFDIR }
    var isLink: Bool { type == S_IFLNK }
    var supported: Bool { type == S_IFREG || isDirectory || isLink }
    func sameIdentity(_ other: Self) -> Bool { device == other.device && inode == other.inode && type == other.type }
}
private func sameRemote(_ a: FileEntry, _ b: FileEntry) -> Bool {
    a.isDirectory == b.isDirectory && a.isSymbolicLink == b.isSymbolicLink && a.size == b.size && a.modified == b.modified && a.permissions == b.permissions
}
private func endpointIdentity(_ client: RemoteClient) -> [String] { client.profile.credentialIdentity + [client.profile.trustedHostKey ?? ""] }
private func renameID(_ name: String) -> String { Data(name.utf8).base64EncodedString() }
// Conservative portability guard. Exact source paths and rename commands retain their bytes.
private func collisionKey(_ name: String) -> Data {
    Data(name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).utf8)
}
private func selectedParent(_ entries: [FileEntry]) throws -> String {
    let parent = RemotePath.parent(entries[0].path)
    var names: Set<Data> = []
    for entry in entries {
        try RemotePath.validateName(entry.name); try RemotePath.validate(entry.path)
        guard entry.s3Key == nil, Data(RemotePath.parent(entry.path).utf8) == Data(parent.utf8),
              Data(try RemotePath.join(parent, entry.name).utf8) == Data(entry.path.utf8), names.insert(Data(entry.name.utf8)).inserted else { throw BatchRenameError.unavailable }
    }
    return parent
}
private func boundedNames(_ names: [String]) throws -> Set<Data> {
    guard names.count <= 10_000 else { throw BatchRenameError.limit }
    var result: Set<Data> = [], bytes = 0
    for name in names {
        try Task.checkCancellation(); try RemotePath.validateName(name); bytes += name.utf8.count
        guard bytes <= 1_048_576, result.insert(Data(name.utf8)).inserted else { throw BatchRenameError.limit }
    }
    return result
}
private func openParent(_ path: String) throws -> Int32 {
    let fd = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
    guard fd >= 0 else { throw posixError() }; return fd
}
private func parentVersion(_ fd: Int32) throws -> LocalRenameVersion {
    var info = stat(); guard fstat(fd, &info) == 0 else { throw posixError() }; return LocalRenameVersion(info)
}
private func localVersion(_ fd: Int32, name: String) throws -> LocalRenameVersion {
    var info = stat()
    guard name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw posixError() }
    return LocalRenameVersion(info)
}
private func localNames(_ fd: Int32) throws -> Set<Data> {
    let copy = dup(fd); guard copy >= 0 else { throw posixError() }
    guard let directory = fdopendir(copy) else { close(copy); throw posixError() }
    defer { closedir(directory) }; rewinddir(directory)
    var names: [String] = []
    while true {
        try Task.checkCancellation(); errno = 0
        guard let entry = readdir(directory) else { if errno != 0 { throw posixError() }; break }
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
        }
        guard let name else { throw TransferError.invalidPath }
        if name == "." || name == ".." { continue }
        names.append(name); guard names.count <= 10_000 else { throw BatchRenameError.limit }
    }
    return try boundedNames(names)
}
private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
private func worker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached { try Task.checkCancellation(); return try operation() }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
