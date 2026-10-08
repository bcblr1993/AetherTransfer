import Foundation
import Darwin

/// Metadata snapshot only; payloads continue to use bounded native streams.
struct TreeManifest: Sendable {
    struct Item: Sendable {
        let relative: String
        let entry: FileEntry
        var parent: String { relative.split(separator: "/").dropLast().joined(separator: "/") }
    }
    private(set) var items: [Item] = []
    private(set) var bytes: Int64 = 0
    private var paths = Set<String>()
    private var metadataBytes = 0
    let entryLimit: Int
    let metadataLimit: Int
    let depthLimit: Int
    init(entryLimit: Int = 1_000_000, metadataLimit: Int = 32 * 1024 * 1024, depthLimit: Int = 64) {
        self.entryLimit = entryLimit; self.metadataLimit = metadataLimit; self.depthLimit = depthLimit
    }
    mutating func append(_ entry: FileEntry, relative: String, depth: Int) throws {
        let cost = entry.path.utf8.count + relative.utf8.count + entry.name.utf8.count + 256
        guard items.count < entryLimit, depth <= depthLimit, cost <= metadataLimit - metadataBytes else {
            throw TransferError.remote(L10n.text("目录扫描超过安全容量（32 MiB 元数据、64 层目录）；请分批选择子目录。"))
        }
        guard !entry.isSymbolicLink, entry.size >= 0 else { throw ResumeTransferError.unsupportedVersion }
        guard paths.insert(relative).inserted else { throw TransferError.invalidListing(L10n.text("目录包含重复路径。")) }
        let sum = bytes.addingReportingOverflow(entry.isDirectory ? 0 : entry.size)
        guard !sum.overflow else { throw TransferError.remote(L10n.text("目录总字节数超出支持范围。")) }
        bytes = sum.partialValue; metadataBytes += cost
        items.append(Item(relative: relative, entry: entry))
    }
    static func local(_ root: URL, control: TransferControl?,
                      progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TreeManifest {
        try await TreeIO.run {
            var manifest = TreeManifest(), last = ContinuousClock.now
            try TreeIO.boundarySync(control)
            let first = try TreeIO.localEntry(root)
            try manifest.append(first, relative: "", depth: 0)
            if first.isDirectory {
                let scanRoot = root.resolvingSymlinksInPath()
                var failure: (any Error)?
                guard let enumerator = FileManager.default.enumerator(at: scanRoot, includingPropertiesForKeys: nil,
                    errorHandler: { _, error in failure = error; return false }) else { throw ResumeTransferError.sourceChanged }
                let prefix = scanRoot.path.hasSuffix("/") ? scanRoot.path : scanRoot.path + "/"
                while let url = enumerator.nextObject() as? URL {
                    try TreeIO.boundarySync(control)
                    let entry = try TreeIO.localEntry(url)
                    let canonical = url.resolvingSymlinksInPath().path
                    guard canonical.hasPrefix(prefix) else { throw TransferError.invalidPath }
                    try manifest.append(entry, relative: String(canonical.dropFirst(prefix.count)), depth: enumerator.level)
                    let now = ContinuousClock.now
                    if last.duration(to: now) >= .milliseconds(100) {
                        progress(scanProgress(manifest.items.count)); last = now
                    }
                }
                if let failure { throw failure }
            }
            return manifest
        }
    }
    static func remote(_ root: FileEntry, client: RemoteClient,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TreeManifest {
        var manifest = TreeManifest(), last = ContinuousClock.now
        func visit(_ entry: FileEntry, relative: String, depth: Int) async throws {
            try await TreeIO.boundary(client.control)
            try manifest.append(entry, relative: relative, depth: depth)
            let now = ContinuousClock.now
            if last.duration(to: now) >= .milliseconds(100) {
                progress(scanProgress(manifest.items.count)); last = now
            }
            if entry.isDirectory {
                for child in try await client.list(entry.path) {
                    try RemotePath.validateName(child.name)
                    guard child.path == (try RemotePath.join(entry.path, child.name)) else { throw TransferError.invalidPath }
                    try await visit(child, relative: relative.isEmpty ? child.name : relative + "/" + child.name, depth: depth + 1)
                }
            }
        }
        try await visit(root, relative: "", depth: 0)
        return manifest
    }
    static func scanProgress(_ count: Int = 0) -> TransferProgress {
        TransferProgress(completed: 0, total: 0, phase: L10n.format("扫描目录 · %@ 个项目", String(describing: count)), scope: .directory)
    }
}

enum TreeIO {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func boundarySync(_ control: TransferControl?) throws {
        try Task.checkCancellation()
        while control?.isPaused == true && control?.isRetainingProgress != true { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.05) }
        if control?.isRetainingProgress == true { throw TransferError.remote(L10n.text("完整目录的进度保留尚未支持，请完成或取消目录任务。")) }
    }
    static func boundary(_ control: TransferControl?) async throws {
        try Task.checkCancellation()
        while control?.isPaused == true && control?.isRetainingProgress != true { try await Task.sleep(for: .milliseconds(50)) }
        if control?.isRetainingProgress == true { throw TransferError.remote(L10n.text("完整目录的进度保留尚未支持，请完成或取消目录任务。")) }
    }
    static func localEntry(_ url: URL) throws -> FileEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                     .fileSizeKey, .contentModificationDateKey])
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
            throw ResumeTransferError.unsupportedVersion
        }
        return FileEntry(name: url.lastPathComponent, path: url.path, isDirectory: values.isDirectory == true,
                         size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
    }
    static func localKind(_ url: URL) throws -> Bool? {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR: return true
        case S_IFREG: return false
        default: throw TransferError.conflict(url.lastPathComponent)
        }
    }
}

struct TreeProgress: Sendable {
    let total: Int64
    let totalItems: Int
    private(set) var completed: Int64 = 0
    private(set) var completedItems = 0
    private(set) var skippedItems = 0
    func event(currentBytes: Int64 = 0, phase: String? = nil) -> TransferProgress {
        TransferProgress(completed: completed + max(0, min(currentBytes, total - completed)), total: total,
                         phase: phase, scope: .directory, completedItems: completedItems, totalItems: totalItems,
                         skippedItems: skippedItems)
    }
    mutating func finish(_ item: TreeManifest.Item, skipped: Bool = false) {
        completed += item.entry.isDirectory ? 0 : item.entry.size; completedItems += 1
        if skipped { skippedItems += 1 }
    }
}

/// Authentication can reset a native request counter; a directory keeps logical progress.
final class TreeFileProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let base: TreeProgress
    private let size: Int64
    private let callback: @Sendable (TransferProgress) -> Void
    private var highWater: Int64 = 0
    init(base: TreeProgress, size: Int64, callback: @escaping @Sendable (TransferProgress) -> Void) {
        self.base = base; self.size = size; self.callback = callback
    }
    func receive(_ value: TransferProgress) {
        lock.lock(); defer { lock.unlock() }
        highWater = max(highWater, min(size, max(0, value.completed)))
        callback(base.event(currentBytes: highWater, phase: value.phase))
    }
}
