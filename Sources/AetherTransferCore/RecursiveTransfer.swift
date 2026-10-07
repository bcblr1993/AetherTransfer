import Foundation

public enum ConflictPolicy: String, CaseIterable, Sendable {
    case reject, overwrite, skip, keepBoth
}

extension RemoteClient {
    public func uploadTree(_ local: URL, to destination: String, policy: ConflictPolicy = .reject,
                           store: ResumeTransferStore = ResumeTransferStore(),
                           progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try await TreeIO.boundary(control)
        let root = try await TreeIO.run { try TreeIO.localEntry(local) }
        if !root.isDirectory {
            if let transfer = try await resumableUpload(local, to: destination, policy: policy, store: store) {
                try await runTreeFile(transfer, size: root.size, progress: progress)
            }
            return
        }
        var destination = RemotePath.normalize(destination), policy = policy
        if let existing = try await list(RemotePath.parent(destination)).first(where: { $0.path == destination }) {
            guard existing.isDirectory, !existing.isSymbolicLink else { throw TransferError.conflict(existing.name) }
            if policy == .reject { throw TransferError.conflict(existing.name) }
            if policy == .skip { progress(skippedTree()); return }
            if policy == .keepBoth { destination = try await availableRemoteName(destination); policy = .reject }
        }
        progress(TreeManifest.scanProgress())
        let manifest = try await TreeManifest.local(local, control: control, progress: progress)
        var counter = TreeProgress(total: manifest.bytes, totalItems: manifest.items.count)
        var directories: [String: String] = [:], skippedDirectories = Set<String>()
        progress(counter.event(phase: "目录扫描完成"))
        for item in manifest.items {
            try await TreeIO.boundary(control)
            if !item.relative.isEmpty && skippedDirectories.contains(item.parent) {
                if item.entry.isDirectory { skippedDirectories.insert(item.relative) }
                counter.finish(item, skipped: true); progress(counter.event(phase: "已跳过 · \(item.entry.name)")); continue
            }
            let source = URL(fileURLWithPath: item.entry.path)
            let current = try await TreeIO.run { try TreeIO.localEntry(source) }
            guard current.isDirectory == item.entry.isDirectory,
                  current.isDirectory || (current.size == item.entry.size && current.modified == item.entry.modified) else {
                throw ResumeTransferError.sourceChanged
            }
            var target = item.relative.isEmpty ? destination : try RemotePath.join(directories[item.parent]!, item.entry.name)
            if item.entry.isDirectory {
                if let existing = try await list(RemotePath.parent(target)).first(where: { $0.path == target }) {
                    guard existing.isDirectory, !existing.isSymbolicLink else { throw TransferError.conflict(existing.name) }
                    if policy == .skip {
                        skippedDirectories.insert(item.relative); counter.finish(item, skipped: true)
                        progress(counter.event(phase: "已跳过 · \(item.entry.name)")); continue
                    }
                    if policy == .reject { throw TransferError.conflict(existing.name) }
                    if policy == .keepBoth { target = try await availableRemoteName(target); try await mkdir(target) }
                } else { try await mkdir(target) }
                directories[item.relative] = target; counter.finish(item)
                progress(counter.event(phase: "已处理目录 · \(item.entry.name)"))
            } else {
                if let transfer = try await resumableUpload(source, to: target, policy: policy, store: store) {
                    let reporter = TreeFileProgress(base: counter, size: item.entry.size, callback: progress)
                    try await runTreeFile(transfer, size: item.entry.size) { reporter.receive($0) }
                    counter.finish(item); progress(counter.event(phase: "已提交 · \(item.entry.name)"))
                } else {
                    counter.finish(item, skipped: true); progress(counter.event(phase: "已跳过 · \(item.entry.name)"))
                }
            }
        }
        progress(counter.event(phase: "目录处理完成"))
    }

    public func downloadTree(_ entry: FileEntry, to destination: URL, policy: ConflictPolicy = .reject,
                             store: ResumeTransferStore = ResumeTransferStore(),
                             progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try await TreeIO.boundary(control)
        guard !entry.isSymbolicLink else { throw ResumeTransferError.unsupportedVersion }
        if !entry.isDirectory {
            if let transfer = try await resumableDownload(entry, to: destination, policy: policy, store: store) {
                try await runTreeFile(transfer, size: entry.size, progress: progress)
            }
            return
        }
        var destination = destination, policy = policy
        let initialDestination = destination
        if let isDirectory = try await TreeIO.run({ try TreeIO.localKind(initialDestination) }) {
            guard isDirectory else { throw TransferError.conflict(entry.name) }
            if policy == .reject { throw TransferError.conflict(entry.name) }
            if policy == .skip { progress(skippedTree()); return }
            if policy == .keepBoth {
                let original = destination
                destination = try await TreeIO.run { try availableLocalName(original) }; policy = .reject
            }
        }
        progress(TreeManifest.scanProgress())
        let manifest = try await TreeManifest.remote(entry, client: self, progress: progress)
        var counter = TreeProgress(total: manifest.bytes, totalItems: manifest.items.count)
        var directories: [String: URL] = [:], skippedDirectories = Set<String>()
        progress(counter.event(phase: "目录扫描完成"))
        for item in manifest.items {
            try await TreeIO.boundary(control)
            if !item.relative.isEmpty && skippedDirectories.contains(item.parent) {
                if item.entry.isDirectory { skippedDirectories.insert(item.relative) }
                counter.finish(item, skipped: true); progress(counter.event(phase: "已跳过 · \(item.entry.name)")); continue
            }
            var target = item.relative.isEmpty ? destination : directories[item.parent]!.appendingPathComponent(item.entry.name)
            if item.entry.isDirectory {
                // Recheck empty source directories too; the manifest is not a directory transaction.
                _ = try await list(item.entry.path)
                let original = target, conflict = policy
                let directoryResult: (URL, Bool) = try await TreeIO.run {
                    if let isDirectory = try TreeIO.localKind(original) {
                        guard isDirectory else { throw TransferError.conflict(original.lastPathComponent) }
                        if conflict == .skip { return (original, true) }
                        if conflict == .reject { throw TransferError.conflict(original.lastPathComponent) }
                        if conflict == .keepBoth {
                            let alternative = try availableLocalName(original)
                            try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: false)
                            return (alternative, false)
                        }
                    } else { try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false) }
                    return (original, false)
                }
                target = directoryResult.0
                if directoryResult.1 { skippedDirectories.insert(item.relative) }
                else { directories[item.relative] = target }
                counter.finish(item, skipped: directoryResult.1)
                progress(counter.event(phase: directoryResult.1 ? "已跳过 · \(item.entry.name)" : "已处理目录 · \(item.entry.name)"))
            } else {
                guard try await fileVersion(item.entry.path).size == item.entry.size else { throw ResumeTransferError.sourceChanged }
                if let transfer = try await resumableDownload(item.entry, to: target, policy: policy, store: store) {
                    let reporter = TreeFileProgress(base: counter, size: item.entry.size, callback: progress)
                    try await runTreeFile(transfer, size: item.entry.size) { reporter.receive($0) }
                    counter.finish(item); progress(counter.event(phase: "已提交 · \(item.entry.name)"))
                } else {
                    counter.finish(item, skipped: true); progress(counter.event(phase: "已跳过 · \(item.entry.name)"))
                }
            }
        }
        progress(counter.event(phase: "目录处理完成"))
    }

    private func runTreeFile(_ transfer: ResumableTransfer, size: Int64,
                             progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        do { try await transfer.run(client: self, expectedSourceSize: size, progress: progress) }
        catch {
            let original = error
            let quiet = RemoteClient(profile: profile, credentials: credentials, certificateAuthority: certificateAuthority)
            do { try await Task.detached { try await transfer.discard(client: quiet) }.value }
            catch { throw TransferError.remote("文件操作未完成，部分文件清理失败；可在保留的传输中重试清理。\(original.localizedDescription)") }
            throw original
        }
    }
    private func skippedTree() -> TransferProgress {
        TransferProgress(completed: 0, total: 0, phase: "已跳过目录", scope: .directory,
                         completedItems: 1, totalItems: 1, skippedItems: 1)
    }
    func availableRemoteName(_ path: String) async throws -> String {
        let parent = RemotePath.parent(path)
        let names = Set(try await list(parent).map(\.name))
        let name = URL(fileURLWithPath: path).lastPathComponent
        for index in 2...10000 {
            let candidate = "\(name) (\(index))"
            if !names.contains(candidate) { return try RemotePath.join(parent, candidate) }
        }
        throw TransferError.conflict(name)
    }
    func availableLocalName(_ url: URL) throws -> URL {
        for index in 2...10000 {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent) (\(index))")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw TransferError.conflict(url.lastPathComponent)
    }
}
