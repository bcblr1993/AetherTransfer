import Foundation
import Darwin

extension S3Client {
    /// Conflict decisions are rechecked inside the queue operation; browsing is only a hint.
    public func uploadFile(_ source: URL, to key: String, policy: ConflictPolicy,
                           progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        var target = key
        let exists = try await objectExists(key)
        if exists {
            switch policy {
            case .skip: progress(TransferProgress(completed: 0, total: 0, completedItems: 1, totalItems: 1, skippedItems: 1)); return
            case .reject: throw TransferError.conflict(key)
            case .overwrite: break
            case .keepBoth: target = try await availableKey(key)
            }
        }
        try await upload(source, to: target, overwrite: policy == .overwrite, progress: progress)
    }
    public func downloadFile(_ entry: FileEntry, to destination: URL, policy: ConflictPolicy,
                             progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        guard let key = entry.s3Key, !entry.isDirectory else { throw TransferError.invalidPath }
        var target = destination
        let original = target
        let exists = try await localIO { try localExists(original) }
        if exists {
            switch policy {
            case .skip: progress(TransferProgress(completed: 0, total: 0, completedItems: 1, totalItems: 1, skippedItems: 1)); return
            case .reject: throw TransferError.conflict(destination.lastPathComponent)
            case .overwrite: break
            case .keepBoth: target = try await localIO { try availableLocalFile(original) }
            }
        }
        try await download(key, to: target, overwrite: policy == .overwrite, progress: progress)
    }
    private func objectExists(_ key: String) async throws -> Bool {
        do { _ = try await fileVersion(key); return true } catch S3Error.notFound { return false }
    }
    private func availableKey(_ key: String) async throws -> String {
        let prefix: String, name: String
        if let slash = key.lastIndex(of: "/") { prefix = String(key[...slash]); name = String(key[key.index(after: slash)...]) }
        else { prefix = ""; name = key }
        for number in 2...1000 {
            try Task.checkCancellation()
            let alternative = try S3BrowserPath.append(alternativeName(name, number: number), to: prefix)
            if try await !objectExists(alternative) { return alternative }
        }
        throw TransferError.conflict(name)
    }
}

private func alternativeName(_ name: String, number: Int) -> String {
    if let dot = name.lastIndex(of: "."), dot != name.startIndex {
        return String(name[..<dot]) + " \(number)" + String(name[dot...])
    }
    return name + " \(number)"
}
private func localIO<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(operation: body)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
private func localExists(_ url: URL) throws -> Bool {
    var metadata = stat()
    if url.path.withCString({ lstat($0, &metadata) }) == 0 { return true }
    guard errno == ENOENT else { throw TransferError.invalidPath }; return false
}
private func availableLocalFile(_ url: URL) throws -> URL {
    for number in 2...1000 {
        try Task.checkCancellation()
        let candidate = url.deletingLastPathComponent().appendingPathComponent(alternativeName(url.lastPathComponent, number: number))
        if try !localExists(candidate) { return candidate }
    }
    throw TransferError.conflict(url.lastPathComponent)
}
