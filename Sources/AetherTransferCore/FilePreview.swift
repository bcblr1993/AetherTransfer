import Foundation
import Darwin

public enum FilePreviewError: Error, LocalizedError, Sendable {
    case unsupportedFile, tooLarge, changed
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: L10n.text("只能预览普通文件；目录和符号链接可在文件信息中查看。")
        case .tooLarge: L10n.text("远程预览最多下载 128 MiB；更大的文件请先下载，再从本地预览。")
        case .changed: L10n.text("文件在准备预览时发生变化，请刷新后重试。")
        }
    }
}

public enum FilePreviewSource: Sendable {
    case local(URL)
    case remote(RemoteClient, String)
    case s3(S3Client, String)
}

/// Local files stay in place; only verified remote snapshots own temporary storage.
public struct FilePreview: Sendable {
    public static let maximumRemoteBytes: Int64 = 128 * 1024 * 1024
    public let url: URL
    public let byteCount: Int64
    public let directory: URL?
    private let lease: PreviewCacheLease?
    public static var cacheDirectory: URL { PreviewCache.directory }
    private init(url: URL, byteCount: Int64, lease: PreviewCacheLease?) {
        self.url = url; self.byteCount = byteCount; self.lease = lease; directory = lease?.directory
    }
    public static func reclaimAbandoned(in parent: URL = cacheDirectory) async throws -> PreviewCacheCleanup {
        try await TreeIO.run { try PreviewCache.reclaim(parent) }
    }
    public static func open(_ source: FilePreviewSource,
                            maximumRemoteBytes: Int64 = maximumRemoteBytes,
                            temporaryParent: URL = cacheDirectory,
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
            return FilePreview(url: url, byteCount: size, lease: nil)
        case .remote(let client, let rawPath):
            try RemotePath.validate(rawPath)
            let path = RemotePath.normalize(rawPath)
            guard let entry = try await client.list(RemotePath.parent(path)).first(where: { $0.path == path }),
                  !entry.isDirectory, !entry.isSymbolicLink else { throw FilePreviewError.unsupportedFile }
            let version = try await client.fileVersion(path)
            guard maximumRemoteBytes > 0, version.size <= maximumRemoteBytes else { throw FilePreviewError.tooLarge }
            try Task.checkCancellation()
            let lease = try await TreeIO.run { try PreviewCacheLease(parentURL: temporaryParent) }
            let directory = lease.directory, destination = lease.payload.appendingPathComponent(entry.name)
            do {
                let store = ResumeTransferStore(directory: directory.appendingPathComponent("journal", isDirectory: true))
                guard let transfer = try await client.resumableDownload(entry, to: destination, store: store) else {
                    throw FilePreviewError.unsupportedFile
                }
                try await transfer.run(client: client, expectedSourceSize: version.size, progress: progress)
                guard try await client.fileVersion(path) == version else { throw FilePreviewError.changed }
                try Task.checkCancellation()
                return FilePreview(url: destination, byteCount: version.size, lease: lease)
            } catch {
                // This directory contains only this preview's verified file and its journal.
                // Cleanup cannot inherit the cancelled reader's cancellation.
                try await lease.close()
                throw error
            }
        case .s3(let client, let key):
            try S3Endpoint.validateKey(key)
            guard !key.isEmpty, !key.hasSuffix("/") else { throw FilePreviewError.unsupportedFile }
            let version = try await client.fileVersion(key)
            guard maximumRemoteBytes > 0, version.size <= maximumRemoteBytes else { throw FilePreviewError.tooLarge }
            try Task.checkCancellation()
            let lease = try await TreeIO.run { try PreviewCacheLease(parentURL: temporaryParent) }
            // Object keys stay byte-exact on the wire. Only the private snapshot's
            // filename is mapped; dot components and long names cannot escape its lease.
            let destination = lease.payload.appendingPathComponent(s3SnapshotName(key))
            do {
                try await client.download(key, to: destination, expectedVersion: version, progress: progress)
                guard try await client.fileVersion(key) == version else { throw FilePreviewError.changed }
                try Task.checkCancellation()
                return FilePreview(url: destination, byteCount: version.size, lease: lease)
            } catch {
                try await lease.close()
                throw error
            }
        }
    }
    static func s3SnapshotName(_ key: String) -> String {
        let name = String(key.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        if !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0), name.utf8.count <= 240 { return name }
        let suffix = (name as NSString).pathExtension
        if !suffix.isEmpty, suffix.utf8.count <= 32,
           suffix.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) {
            return "preview." + suffix
        }
        return "preview"
    }
    public func close() async throws {
        try await lease?.close()
    }
}
