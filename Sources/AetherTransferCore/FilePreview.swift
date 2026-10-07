import Foundation
import Darwin

public enum FilePreviewError: Error, LocalizedError, Sendable {
    case unsupportedFile, tooLarge, changed
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "只能预览普通文件；目录和符号链接可在文件信息中查看。"
        case .tooLarge: "远程预览最多下载 128 MiB；更大的文件请先下载，再从本地预览。"
        case .changed: "文件在准备预览时发生变化，请刷新后重试。"
        }
    }
}

public enum FilePreviewSource: Sendable {
    case local(URL)
    case remote(RemoteClient, String)
}

/// Local files stay in place; only verified remote snapshots own temporary storage.
public struct FilePreview: Sendable {
    public static let maximumRemoteBytes: Int64 = 128 * 1024 * 1024
    public let url: URL
    public let byteCount: Int64
    public let directory: URL?
    private init(url: URL, byteCount: Int64, directory: URL?) {
        self.url = url; self.byteCount = byteCount; self.directory = directory
    }
    public static func open(_ source: FilePreviewSource,
                            maximumRemoteBytes: Int64 = maximumRemoteBytes,
                            temporaryParent: URL = FileManager.default.temporaryDirectory,
                            progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> FilePreview {
        try Task.checkCancellation()
        switch source {
        case .local(let url):
            let size = try await TreeIO.run { () -> Int64 in
                guard url.isFileURL else { throw FilePreviewError.unsupportedFile }
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { throw FilePreviewError.unsupportedFile }
                defer { Darwin.close(descriptor) }
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                    throw FilePreviewError.unsupportedFile
                }
                return metadata.st_size
            }
            try Task.checkCancellation()
            return FilePreview(url: url, byteCount: size, directory: nil)
        case .remote(let client, let rawPath):
            try RemotePath.validate(rawPath)
            let path = RemotePath.normalize(rawPath)
            guard let entry = try await client.list(RemotePath.parent(path)).first(where: { $0.path == path }),
                  !entry.isDirectory, !entry.isSymbolicLink else { throw FilePreviewError.unsupportedFile }
            let version = try await client.fileVersion(path)
            guard maximumRemoteBytes > 0, version.size <= maximumRemoteBytes else { throw FilePreviewError.tooLarge }
            try Task.checkCancellation()
            let directory = temporaryParent.appendingPathComponent("aethertransfer-preview-\(UUID())", isDirectory: true)
            let destination = directory.appendingPathComponent(entry.name)
            do {
                try await TreeIO.run {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                }
                let store = ResumeTransferStore(directory: directory.appendingPathComponent("journal", isDirectory: true))
                guard let transfer = try await client.resumableDownload(entry, to: destination, store: store) else {
                    throw FilePreviewError.unsupportedFile
                }
                try await transfer.run(client: client, expectedSourceSize: version.size, progress: progress)
                guard try await client.fileVersion(path) == version else { throw FilePreviewError.changed }
                try Task.checkCancellation()
                return FilePreview(url: destination, byteCount: version.size, directory: directory)
            } catch {
                // This directory contains only this preview's verified file and its journal.
                // Cleanup cannot inherit the cancelled reader's cancellation.
                try await remove(directory)
                throw error
            }
        }
    }
    public func close() async throws {
        if let directory { try await Self.remove(directory) }
    }
    private static func remove(_ directory: URL) async throws {
        try await Task.detached {
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { if FileManager.default.fileExists(atPath: directory.path) { throw error } }
            }
        }.value
    }
}
