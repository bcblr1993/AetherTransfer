import Foundation

public enum ConflictPolicy: String, CaseIterable, Sendable {
    case reject, overwrite, skip, keepBoth
}

extension RemoteClient {
    public func uploadTree(_ local: URL, to destination: String, policy: ConflictPolicy = .reject,
                           progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let values = try await Task.detached {
            let metadata = try local.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return (directory: metadata.isDirectory == true, symlink: metadata.isSymbolicLink == true)
        }.value
        guard !values.symlink else { throw TransferError.remote("符号链接传输暂不支持，请选择原文件。") }
        let existing = try await list(RemotePath.parent(destination)).first { $0.path == destination }
        if values.directory {
            if let existing {
                guard existing.isDirectory else { throw TransferError.conflict(existing.name) }
                if policy == .reject { throw TransferError.conflict(existing.name) }
                if policy == .skip { return }
                if policy == .keepBoth {
                    let alternative = try await availableRemoteName(destination)
                    try await uploadTree(local, to: alternative, policy: .reject, progress: progress)
                    return
                }
            } else { try await mkdir(destination) }
            let entries = try await Task.detached { try LocalFiles.list(local, showHidden: true) }.value
            for entry in entries {
                try Task.checkCancellation()
                try await uploadTree(URL(fileURLWithPath: entry.path), to: RemotePath.join(destination, entry.name), policy: policy, progress: progress)
            }
        } else {
            if let existing {
                guard !existing.isDirectory else { throw TransferError.conflict(existing.name) }
                if policy == .skip { return }
                if policy == .keepBoth {
                    try await upload(local, to: availableRemoteName(destination), progress: progress)
                    return
                }
            }
            try await upload(local, to: destination, overwrite: policy == .overwrite, progress: progress)
        }
    }
    public func downloadTree(_ entry: FileEntry, to destination: URL, policy: ConflictPolicy = .reject,
                             progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard !entry.isSymbolicLink else { throw TransferError.remote("符号链接传输暂不支持，请选择原文件。") }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists {
            if policy == .skip { return }
            if policy == .reject || isDirectory.boolValue != entry.isDirectory { throw TransferError.conflict(entry.name) }
            if policy == .keepBoth {
                try await downloadTree(entry, to: availableLocalName(destination), policy: .reject, progress: progress)
                return
            }
        }
        if entry.isDirectory {
            if !exists { try fm.createDirectory(at: destination, withIntermediateDirectories: false) }
            for child in try await list(entry.path) {
                try Task.checkCancellation()
                try await downloadTree(child, to: destination.appendingPathComponent(child.name), policy: policy, progress: progress)
            }
        } else { try await download(entry.path, to: destination, overwrite: policy == .overwrite, progress: progress) }
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
