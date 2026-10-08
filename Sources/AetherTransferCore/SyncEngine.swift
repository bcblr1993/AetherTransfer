import Foundation
import CryptoKit
import Darwin

public enum SyncRoot: Sendable {
    case local(URL)
    case remote(RemoteClient, String)
    case s3(S3Client, String)
    public var path: String {
        switch self {
        case .local(let url): url.standardizedFileURL.path
        case .remote(_, let path): RemotePath.normalize(path)
        case .s3(_, let prefix): prefix
        }
    }
    public var isRemote: Bool { if case .local = self { return false }; return true }
    public var isS3: Bool { if case .s3 = self { return true }; return false }
    private var endpoint: String {
        switch self {
        case .local: return "local"
        case .remote(let client, _):
            let p = client.profile
            return "\(p.protocolKind.rawValue)|\(p.host.lowercased())|\(p.port)|\(p.username)|\(p.trustedHostKey ?? "")"
        case .s3(let client, _):
            let p = client.endpoint
            return "s3|\(p.secure)|\(p.host.lowercased())|\(p.port)|\(p.bucket)"
        }
    }
    public var id: String { Data(SHA256.hash(data: Data((endpoint + "|" + path).utf8))).base64EncodedString() }
    fileprivate func canonicalized() async throws -> Self {
        switch self {
        case .local(let url): return .local(try await SyncIO.worker { url.standardizedFileURL.resolvingSymlinksInPath() })
        case .remote, .s3: return self
        }
    }
    func controlled(_ control: TransferControl?, rate: Int64) -> Self {
        switch self {
        case .local: return self
        case .remote(let client, let path):
            return .remote(RemoteClient(profile: client.profile, credentials: client.credentials, control: control,
                                        rateLimit: rate, certificateAuthority: client.certificateAuthority), path)
        case .s3(let client, let prefix):
            return .s3(S3Client(endpoint: client.endpoint, credentials: client.credentials, control: control,
                               rateLimit: rate, certificateAuthority: client.certificateAuthority), prefix)
        }
    }
    fileprivate func validate(with other: Self) async throws {
        if endpoint == other.endpoint {
            if isS3 {
                // S3 prefixes are byte-exact, include their delimiter, and are never file-path normalized.
                let a = Data(path.utf8), b = Data(other.path.utf8)
                guard !a.starts(with: b), !b.starts(with: a) else { throw SyncError.overlappingRoots }
            } else {
                let a = isRemote ? path : path.lowercased(), b = other.isRemote ? other.path : other.path.lowercased()
                if a == b || a.hasPrefix(b == "/" ? b : b + "/") || b.hasPrefix(a == "/" ? a : a + "/") {
                    throw SyncError.overlappingRoots
                }
            }
        }
        for root in [self, other] {
            if case .local = root {
                let url = URL(fileURLWithPath: root.path)
                let valid = try await SyncIO.worker {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    return values.isDirectory == true && values.isSymbolicLink != true
                }
                guard valid else { throw SyncError.invalidPlan }
            } else if case .s3(let client, let prefix) = root {
                try await S3Sync.validateRoot(client, prefix: prefix)
            } else if root.path != "/" {
                guard let entry = try await root.absoluteEntry(root.path), entry.isDirectory, !entry.isSymbolicLink else { throw SyncError.invalidPlan }
            }
        }
    }
    private func absoluteEntry(_ path: String) async throws -> FileEntry? {
        switch self {
        case .local:
            return try await SyncIO.worker { try LocalFiles.list(URL(fileURLWithPath: path).deletingLastPathComponent(), showHidden: true).first { $0.path == path } }
        case .remote(let client, _): return try await client.list(RemotePath.parent(path)).first { $0.path == path }
        case .s3: throw SyncError.invalidPlan
        }
    }
    fileprivate func fullPath(_ relative: String) throws -> String {
        try SyncPath.validate(relative)
        if isS3 { return try S3Sync.key(prefix: path, relative: relative) }
        return relative.split(separator: "/").reduce(path) { partial, component in partial == "/" ? "/" + component : partial + "/" + component }
    }
    fileprivate func list(_ relative: String) async throws -> [FileEntry] {
        let directory = relative.isEmpty ? path : try fullPath(relative)
        switch self {
        case .local: return try await SyncIO.worker { try LocalFiles.list(URL(fileURLWithPath: directory), showHidden: true) }
        case .remote(let client, _): return try await client.list(directory)
        case .s3(let client, _):
            let prefix = relative.isEmpty ? directory : directory + "/"
            let objects = try await client.list(prefix: prefix)
            try S3TreeSnapshot.validateChildren(objects)
            return objects.map(\.fileEntry)
        }
    }
    fileprivate func record(_ relative: String, contents: Bool = false, control: TransferControl? = nil) async throws -> SyncRecord? {
        let absolute = try fullPath(relative)
        if case .s3(let client, _) = self { return try await S3Sync.record(client, key: absolute, contents: contents) }
        let metadata: SyncRecord?
        if case .local = self {
            metadata = try await SyncIO.worker {
                do {
                    let values = try URL(fileURLWithPath: absolute).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    let kind: SyncRecordKind = values.isSymbolicLink == true ? .symbolicLink : (values.isDirectory == true ? .directory : .file)
                    return SyncRecord(kind: kind, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
            }
        } else if let entry = try await absoluteEntry(absolute) {
            metadata = SyncRecord(kind: entry.isSymbolicLink ? .symbolicLink : (entry.isDirectory ? .directory : .file), size: entry.size, modified: entry.modified)
        } else { metadata = nil }
        guard let metadata else { return nil }
        var digest: String?
        if contents && metadata.kind == .file { digest = try await hash(relative, size: metadata.size, control: control) }
        return SyncRecord(kind: metadata.kind, size: metadata.size, modified: metadata.modified, digest: digest)
    }
    fileprivate func hash(_ relative: String, size: Int64, control: TransferControl? = nil) async throws -> String {
        if case .local = self { return try await SyncIO.digest(URL(fileURLWithPath: fullPath(relative)), control: control) }
        if case .s3(let client, _) = self {
            let key = try fullPath(relative), version = try await client.fileVersion(key)
            return try await S3Sync.digest(client, key: key, version: version)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-sync-\(UUID().uuidString)")
        try await SyncIO.createTemporaryDirectory(directory, requiredBytes: size)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("content")
        try await materialize(relative, to: target, control: nil, progress: { _ in })
        return try await SyncIO.digest(target, control: control)
    }
    fileprivate func materialize(_ relative: String, to target: URL, control: TransferControl?,
                                 expected: SyncRecord? = nil,
                                 progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        switch self {
        case .local: try await SyncIO.copy(URL(fileURLWithPath: fullPath(relative)), to: target, control: control, progress: progress)
        case .remote(let client, _): try await client.download(fullPath(relative), to: target, progress: progress)
        case .s3(let client, _):
            guard let version = expected?.remoteVersion else { throw SyncError.invalidPlan }
            try await client.download(fullPath(relative), to: target, expectedVersion: version, progress: progress)
        }
    }
    fileprivate func mkdir(_ relative: String) async throws {
        let absolute = try fullPath(relative)
        switch self {
        case .local: try await SyncIO.worker { try FileManager.default.createDirectory(at: URL(fileURLWithPath: absolute), withIntermediateDirectories: false) }
        case .remote(let client, _): try await client.mkdir(absolute)
        case .s3(let client, _): try await client.createPrefix(absolute + "/")
        }
    }
    fileprivate func delete(_ relative: String, directory: Bool) async throws -> URL? {
        let absolute = try fullPath(relative)
        switch self {
        case .local:
            return try await SyncIO.worker {
                var result: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: absolute), resultingItemURL: &result)
                return result as URL?
            }
        case .remote(let client, _): try await client.remove(absolute, directory: directory); return nil
        case .s3: throw SyncError.invalidPlan // No unconditional mirror deletion of S3 objects.
        }
    }
    fileprivate func commit(_ staging: URL, to relative: String, overwrite: Bool, modified: Date?, expected: SyncRecord?,
                            progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let absolute = try fullPath(relative)
        switch self {
        case .local:
            try await SyncIO.worker {
                let destination = URL(fileURLWithPath: absolute), fm = FileManager.default
                if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: staging.path) }
                try Task.checkCancellation()
                if fm.fileExists(atPath: absolute) {
                    guard overwrite else { throw SyncError.changed(relative) }
                    _ = try fm.replaceItemAt(destination, withItemAt: staging)
                } else { try fm.moveItem(at: staging, to: destination) }
            }
        case .remote(let client, _): try await client.upload(staging, to: absolute, overwrite: overwrite, progress: progress)
        case .s3(let client, _):
            if overwrite && expected?.remoteVersion == nil { throw SyncError.invalidPlan }
            try await client.upload(staging, to: absolute, overwrite: overwrite, expectedVersion: expected?.remoteVersion, progress: progress)
        }
    }
}

private enum SyncIO {
    static func worker<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached {
            try Task.checkCancellation()
            return try await operation()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func checkSpace(at url: URL, requiredBytes: Int64) throws {
        let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        let available = (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard requiredBytes >= 0, available > requiredBytes, available - requiredBytes > 16 * 1024 * 1024 else {
            throw TransferError.remote(L10n.text("可用磁盘空间不足以安全生成同步临时文件。"))
        }
    }
    static func createTemporaryDirectory(_ url: URL, requiredBytes: Int64) async throws {
        try await worker {
            try checkSpace(at: url.deletingLastPathComponent(), requiredBytes: requiredBytes)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    static func digest(_ url: URL, control: TransferControl? = nil) async throws -> String {
        try await worker {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var digest = SHA256()
            while true {
                try await checkpoint(control)
                guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
                digest.update(data: data)
            }
            return Data(digest.finalize()).base64EncodedString()
        }
    }
    static func checkpoint(_ control: TransferControl?) async throws {
        try Task.checkCancellation()
        while control?.isPaused == true { try await Task.sleep(for: .milliseconds(100)) }
    }
    static func copy(_ source: URL, to target: URL, control: TransferControl?,
                     progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try await worker {
            let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            try checkSpace(at: target.deletingLastPathComponent(), requiredBytes: size)
            let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
            let descriptor = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw TransferError.remote(L10n.text("无法创建同步临时文件。"))
            }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? output.close() }
            var completed: Int64 = 0, last = Date.distantPast
            while true {
                try await checkpoint(control)
                guard let data = try input.read(upToCount: 64 * 1024), !data.isEmpty else { break }
                try output.write(contentsOf: data); completed += Int64(data.count)
                if Date().timeIntervalSince(last) >= 0.1 { progress(TransferProgress(completed: completed, total: size, scope: .synchronization)); last = Date() }
            }
            try output.synchronize(); progress(TransferProgress(completed: completed, total: size, scope: .synchronization))
        }
    }
}

public struct SyncExecutionResult: Sendable {
    public let completed: Int
    public let bytes: Int64
    public let trashedItems: [URL]
}
public enum SyncEngine {
    public static func preview(left: SyncRoot, right: SyncRoot, options: SyncOptions) async throws -> SyncPlan {
        let left = try await left.canonicalized(), right = try await right.canonicalized()
        try await left.validate(with: right)
        async let a = scan(left, options: options)
        async let b = scan(right, options: options)
        let plan = try await SyncPlanner.plan(left: a, right: b, options: options)
        let items = plan.items.map { item in
            if case .delete(let side) = item.operation, (side == .left ? left : right).isS3 {
                return SyncItem(path: item.path, operation: .blocked, left: item.left, right: item.right,
                                reason: .s3MirrorBlocked)
            }
            return item
        }
        return SyncPlan(left: plan.left, right: plan.right, options: plan.options, items: items, unchanged: plan.unchanged)
    }
    private static func scan(_ root: SyncRoot, options: SyncOptions, control: TransferControl? = nil) async throws -> SyncSnapshot {
        if case .s3(let client, let prefix) = root {
            return try await S3Sync.scan(client, prefix: prefix, rootID: root.id, options: options)
        }
        try options.validate()
        var pending = [(path: "", depth: 0)], records: [String: SyncRecord] = [:]
        while let directory = pending.popLast() {
            try await SyncIO.checkpoint(control)
            guard directory.depth < 128 else { throw SyncError.limitExceeded }
            let entries = try await root.list(directory.path)
            for entry in entries {
                try await SyncIO.checkpoint(control); try RemotePath.validateName(entry.name)
                let path = directory.path.isEmpty ? entry.name : directory.path + "/" + entry.name
                if options.excludes(path) { continue }
                guard records[path] == nil, records.count < 100_000 else { throw SyncError.limitExceeded }
                let kind: SyncRecordKind = entry.isSymbolicLink ? .symbolicLink : (entry.isDirectory ? .directory : .file)
                var record = SyncRecord(kind: kind, size: entry.size, modified: entry.modified)
                if kind == .file && options.comparison == .contents {
                    let digest = try await root.hash(path, size: entry.size, control: control)
                    if !root.isRemote, try await root.record(path) != record { throw SyncError.changed(path) }
                    record = SyncRecord(kind: kind, size: entry.size, modified: entry.modified, digest: digest)
                }
                records[path] = record
                if kind == .directory { pending.append((path, directory.depth + 1)) }
            }
            if root.isRemote && options.comparison == .contents {
                func metadata(_ entries: [FileEntry]) -> [String: SyncRecord] {
                    entries.reduce(into: [:]) { result, entry in
                        let path = directory.path.isEmpty ? entry.name : directory.path + "/" + entry.name
                        if !options.excludes(path) {
                            result[entry.name] = SyncRecord(kind: entry.isSymbolicLink ? .symbolicLink : (entry.isDirectory ? .directory : .file), size: entry.size, modified: entry.modified)
                        }
                    }
                }
                guard metadata(entries) == metadata(try await root.list(directory.path)) else { throw SyncError.changed(directory.path.isEmpty ? L10n.text("目录内容") : directory.path) }
            }
        }
        return SyncSnapshot(rootID: root.id, records: records)
    }
    public static func execute(_ plan: SyncPlan, left: SyncRoot, right: SyncRoot, selected: Set<String>,
                               resolutions: [String: SyncDirection] = [:], control: TransferControl? = nil, rateLimit: Int64 = 0,
                               progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> SyncExecutionResult {
        let left = try await left.canonicalized(), right = try await right.canonicalized()
        try await left.validate(with: right)
        guard plan.left.rootID == left.id, plan.right.rootID == right.id else { throw SyncError.invalidPlan }
        let roots: [SyncSide: SyncRoot] = [.left: left.controlled(control, rate: rateLimit), .right: right.controlled(control, rate: rateLimit)]
        let snapshots: [SyncSide: SyncSnapshot] = [.left: plan.left, .right: plan.right]
        var operations: [(SyncItem, SyncOperation)] = [], bytes: Int64 = 0
        guard selected.isSubset(of: Set(plan.items.map(\.id))) else { throw SyncError.invalidPlan }
        for item in plan.items where selected.contains(item.id) {
            var operation = item.operation
            if operation == .conflict {
                guard let direction = resolutions[item.id] else { throw SyncError.unresolved(item.path) }
                operation = .copy(direction)
            }
            guard operation != .blocked else { throw SyncError.invalidPlan }
            operations.append((item, operation))
            if case .copy(let direction) = operation {
                let size = snapshots[direction.source]!.records[item.path]!.size
                let total = bytes.addingReportingOverflow(size)
                guard !total.overflow else { throw SyncError.invalidPlan }; bytes = total.partialValue
            }
        }
        let operationByPath = Dictionary(uniqueKeysWithValues: operations.map { ($0.0.path, $0.1) })
        // Validate every S3 destination key and sibling alias before the first directory or object is written.
        for side in [SyncSide.left, .right] where roots[side]!.isS3 {
            let writes = operations.filter { $0.1.destination == side }
            guard !writes.contains(where: { if case .delete = $0.1 { return true }; return false }) else { throw SyncError.invalidPlan }
            try S3Sync.validateDestination(prefix: roots[side]!.path, snapshot: snapshots[side]!, writes: writes)
            if case .s3(let client, let prefix) = roots[side]! {
                try await S3Sync.validateExistingNames(client, prefix: prefix, writes: writes)
            }
        }
        let depthByPath = Dictionary(uniqueKeysWithValues: operations.map { ($0.0.path, $0.0.path.split(separator: "/").count) })
        for (item, operation) in operations {
            guard let side = operation.destination else { throw SyncError.invalidPlan }
            for parent in SyncPath.parents(item.path) where snapshots[side]!.records[parent] == nil {
                guard operationByPath[parent] == .createDirectory(side) else { throw SyncError.dependency(parent) }
            }
            if case .delete = operation, snapshots[side]!.records[item.path]?.kind == .directory {
                // A directory deletion never includes excluded, newly created, or unchecked descendants.
                for entry in try await roots[side]!.list(item.path) {
                    let child = item.path + "/" + entry.name
                    guard operationByPath[child] == .delete(side) else { throw SyncError.dependency(item.path) }
                }
            }
        }
        try await SyncIO.checkpoint(control)
        // One TransferControl owns one native request, so execution scans are sequential.
        let currentLeft = try await scan(roots[.left]!, options: plan.options, control: control)
        let currentRight = try await scan(roots[.right]!, options: plan.options, control: control)
        guard currentLeft == plan.left, currentRight == plan.right else { throw SyncError.changed(L10n.text("目录内容")) }
        func priority(_ operation: SyncOperation) -> Int { switch operation { case .createDirectory: 0; case .copy: 1; default: 2 } }
        operations.sort {
            let a = priority($0.1), b = priority($1.1)
            if a != b { return a < b }
            let x = depthByPath[$0.0.path]!, y = depthByPath[$1.0.path]!
            if x != y { return a == 2 ? x > y : x < y }
            return $0.0.path < $1.0.path
        }
        var created: [SyncSide: Set<String>] = [.left: [], .right: []], completed = 0, doneBytes: Int64 = 0, trashed: [URL] = []
        for (item, operation) in operations {
            try await SyncIO.checkpoint(control)
            let side = operation.destination!, destination = roots[side]!, expected = snapshots[side]!.records[item.path]
            for ancestor in SyncPath.parents(item.path) {
                guard try await destination.record(ancestor)?.kind == .directory else { throw SyncError.changed(ancestor) }
                guard snapshots[side]!.records[ancestor]?.kind == .directory || created[side]!.contains(ancestor) else { throw SyncError.changed(ancestor) }
            }
            try await verify(destination, path: item.path, expected: expected, contents: plan.options.comparison == .contents, control: control)
            switch operation {
            case .createDirectory:
                try await destination.mkdir(item.path); created[side]!.insert(item.path)
            case .delete:
                if expected?.kind == .directory, !(try await destination.list(item.path)).isEmpty { throw SyncError.changed(item.path) }
                if let trash = try await destination.delete(item.path, directory: expected?.kind == .directory) { trashed.append(trash) }
            case .copy(let direction):
                let source = roots[direction.source]!, sourceRecord = snapshots[direction.source]!.records[item.path]!
                try await verify(source, path: item.path, expected: sourceRecord, contents: false)
                for ancestor in SyncPath.parents(item.path) {
                    guard try await source.record(ancestor)?.kind == .directory else { throw SyncError.changed(ancestor) }
                }
                let stagingDirectory = destination.isRemote ? FileManager.default.temporaryDirectory : URL(fileURLWithPath: try destination.fullPath(item.path)).deletingLastPathComponent()
                let temporary = stagingDirectory.appendingPathComponent(".aethertransfer-sync-\(UUID().uuidString).part")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let base = doneBytes, total = bytes, size = sourceRecord.size
                let progressForSource: @Sendable (TransferProgress) -> Void = { value in
                    let count = min(size, value.completed) / (destination.isRemote ? 2 : 1)
                    progress(TransferProgress(completed: base + count, total: total, scope: .synchronization))
                }
                if source.isRemote { try await SyncIO.worker { try SyncIO.checkSpace(at: stagingDirectory, requiredBytes: size) } }
                try await source.materialize(item.path, to: temporary, control: control, expected: sourceRecord, progress: progressForSource)
                if let digest = sourceRecord.digest, try await SyncIO.digest(temporary, control: control) != digest { throw SyncError.changed(item.path) }
                try await verify(source, path: item.path, expected: sourceRecord, contents: false)
                try await verify(destination, path: item.path, expected: expected, contents: plan.options.comparison == .contents, control: control)
                try await SyncIO.checkpoint(control)
                try await destination.commit(temporary, to: item.path, overwrite: expected != nil, modified: sourceRecord.modified, expected: expected) { value in
                    progress(TransferProgress(completed: base + size / 2 + min(size, value.completed) / 2, total: total, scope: .synchronization))
                }
                doneBytes += size
            default: throw SyncError.invalidPlan
            }
            completed += 1; progress(TransferProgress(completed: doneBytes, total: bytes, scope: .synchronization))
        }
        return SyncExecutionResult(completed: completed, bytes: doneBytes, trashedItems: trashed)
    }
    private static func verify(_ root: SyncRoot, path: String, expected: SyncRecord?, contents: Bool, control: TransferControl? = nil) async throws {
        let actual = try await root.record(path, contents: contents && expected?.digest != nil, control: control)
        let comparison = contents ? expected : expected.map { SyncRecord(kind: $0.kind, size: $0.size, modified: $0.modified, remoteVersion: $0.remoteVersion) }
        guard actual == comparison else { throw SyncError.changed(path) }
    }
}
