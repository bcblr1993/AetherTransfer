import Foundation
import CryptoKit
import Darwin

public enum FileEditError: Error, LocalizedError, Sendable {
    case unsupportedText, tooLarge, changed, busy, closed, unstableDraft
    public var errorDescription: String? {
        switch self {
        case .unsupportedText: L10n.text("只支持 UTF-8 文本文件；二进制文件、目录和符号链接不能在此编辑。")
        case .tooLarge: L10n.text("文本编辑最多支持 5 MiB，请使用下载工作流处理更大的文件。")
        case .changed: L10n.text("原文件内容已变化，未回传覆盖。本机草稿已保留，请导出草稿或重新载入后合并。")
        case .busy: L10n.text("此文件仍在读取或保存，请稍后重试。")
        case .closed: L10n.text("编辑会话已关闭。")
        case .unstableDraft: L10n.text("编辑器仍在写入文件，请完成保存后重试。")
        }
    }
}

public enum FileEditSource: Sendable {
    case local(URL)
    case remote(RemoteClient, String)
    public var name: String {
        switch self {
        case .local(let url): url.lastPathComponent
        case .remote(_, let path): URL(fileURLWithPath: path).lastPathComponent
        }
    }
}

public struct FileEditSnapshot: Sendable {
    public let text: String
    public let byteCount: Int
    public let hasUTF8BOM: Bool
}

/// The source is captured for the session, independently of the current browser tab/connection.
public actor FileEditSession {
    public static let maximumBytes = 5 * 1024 * 1024
    public nonisolated let draftURL: URL
    public nonisolated let directory: URL
    private let source: FileEditSource
    private var baseline: Data
    private var bom: Bool
    private var busy = false
    private var closed = false

    private init(source: FileEditSource, directory: URL, data: Data) {
        self.source = source; self.directory = directory
        draftURL = directory.appendingPathComponent("draft", isDirectory: true).appendingPathComponent(source.name)
        baseline = Self.digest(data); bom = data.starts(with: [0xef, 0xbb, 0xbf])
    }
    public static func open(_ source: FileEditSource) async throws -> FileEditSession {
        try RemotePath.validateName(source.name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aethertransfer-edit-\(UUID().uuidString)")
        do {
            try await worker {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("work"), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("draft"), withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let data = try await read(source, directory: directory)
            _ = try decode(data)
            let session = FileEditSession(source: source, directory: directory, data: data)
            try await session.write(data)
            return session
        } catch {
            // Cleanup must still run when the caller cancelled the download/open operation.
            await Task.detached { try? FileManager.default.removeItem(at: directory) }.value
            throw error
        }
    }
    public func snapshot() async throws -> FileEditSnapshot {
        guard !closed else { throw FileEditError.closed }
        return try Self.decode(await Self.worker { try Self.readLocal(self.draftURL) })
    }
    public func persistDraft(_ text: String) async throws {
        guard !closed else { throw FileEditError.closed }
        guard !busy else { throw FileEditError.busy }
        busy = true; defer { busy = false }
        try await write(encode(text))
    }
    public func save(text: String? = nil) async throws -> FileEditSnapshot {
        guard !closed else { throw FileEditError.closed }
        guard !busy else { throw FileEditError.busy }
        busy = true; defer { busy = false }
        let data: Data
        if let text { data = try encode(text); try await write(data) }
        else { data = try await Self.worker { try Self.readLocal(self.draftURL) }; _ = try Self.decode(data) }
        if Self.digest(data) == baseline { return try Self.decode(data) }
        // A content digest catches same-size/same-time changes, including external editor saves.
        let current = try await Self.read(source, directory: directory)
        guard Self.digest(current) == baseline else { throw FileEditError.changed }
        try Task.checkCancellation()
        if Self.digest(data) != baseline {
            let upload = directory.appendingPathComponent("work/save-\(UUID().uuidString)")
            try await Self.worker { try Self.writePrivate(data, to: upload) }
            defer { try? FileManager.default.removeItem(at: upload) }
            switch source {
            case .local(let destination):
                let expected = baseline
                try await Self.worker {
                    // The rename stays on the destination filesystem, retaining its permissions.
                    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".aethertransfer-edit-\(UUID().uuidString).part")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    try Self.writePrivate(data, to: temporary)
                    if let permissions = attributes[.posixPermissions] {
                        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
                    }
                    guard Self.digest(try Self.readLocal(destination)) == expected else { throw FileEditError.changed }
                    try Task.checkCancellation()
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                }
            case .remote(let client, let path): try await client.upload(upload, to: path, overwrite: true)
            }
            let verified = try await Self.read(source, directory: directory)
            guard Self.digest(verified) == Self.digest(data) else { throw FileEditError.changed }
        }
        baseline = Self.digest(data); bom = data.starts(with: [0xef, 0xbb, 0xbf])
        return try Self.decode(data)
    }
    public func reload() async throws -> FileEditSnapshot {
        guard !closed else { throw FileEditError.closed }
        guard !busy else { throw FileEditError.busy }
        busy = true; defer { busy = false }
        let data = try await Self.read(source, directory: directory), snapshot = try Self.decode(data)
        try await write(data); baseline = Self.digest(data); bom = snapshot.hasUTF8BOM
        return snapshot
    }
    public func exportDraft(to destination: URL, text: String? = nil) async throws {
        guard !closed else { throw FileEditError.closed }
        let data: Data
        if let text { data = try encode(text) }
        else { data = try await Self.worker { try Self.readLocal(self.draftURL) } }
        try await Self.worker { try data.write(to: destination, options: .atomic) }
    }
    /// Called only after the UI confirms closing/discarding the session.
    public func close() async throws {
        guard !closed else { return }
        guard !busy else { throw FileEditError.busy }
        closed = true
        try await Self.worker { try FileManager.default.removeItem(at: self.directory) }
    }
    private func encode(_ text: String) throws -> Data {
        var data = Data(text.utf8)
        if bom { data.insert(contentsOf: [0xef, 0xbb, 0xbf], at: 0) }
        guard data.count <= Self.maximumBytes else { throw FileEditError.tooLarge }
        _ = try Self.decode(data)
        return data
    }
    private func write(_ data: Data) async throws {
        let draftURL = draftURL
        try await Self.worker { try Self.writePrivate(data, to: draftURL) }
    }
    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func decode(_ data: Data) throws -> FileEditSnapshot {
        guard data.count <= maximumBytes else { throw FileEditError.tooLarge }
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        let bytes = bom ? data.dropFirst(3) : data[...]
        guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { throw FileEditError.unsupportedText }
        return FileEditSnapshot(text: text, byteCount: data.count, hasUTF8BOM: bom)
    }
    private static func readLocal(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw FileEditError.unsupportedText }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw FileEditError.unsupportedText }
        guard before.st_size <= maximumBytes else { throw FileEditError.tooLarge }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw FileEditError.tooLarge }
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == before.st_size else { throw FileEditError.unstableDraft }
        return data
    }
    private static func read(_ source: FileEditSource, directory: URL) async throws -> Data {
        switch source {
        case .local(let url): return try await worker { try readLocal(url) }
        case .remote(let client, let path):
            guard let entry = try await client.list(RemotePath.parent(path)).first(where: { $0.path == RemotePath.normalize(path) }),
                  !entry.isDirectory, !entry.isSymbolicLink else { throw FileEditError.unsupportedText }
            guard entry.size <= maximumBytes else { throw FileEditError.tooLarge }
            let target = directory.appendingPathComponent("work/read-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: target) }
            try await client.download(path, to: target, maximumBytes: Int64(maximumBytes))
            return try await worker { try readLocal(target) }
        }
    }
    private static func worker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
