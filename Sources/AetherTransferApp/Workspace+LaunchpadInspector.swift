import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import AetherTransferCore

// MARK: - Transmit 5 Bookmark Color Tags

enum ServerColorTag: String, CaseIterable, Identifiable, Sendable {
    case none = ""
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case blue = "blue"
    case purple = "purple"
    case gray = "gray"

    var id: String { rawValue }

    init(tagString: String) {
        let normalized = tagString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = ServerColorTag(rawValue: normalized) ?? .none
    }

    var localizedTitle: String {
        switch self {
        case .none: return L10n.tr("无标签", "None")
        case .red: return L10n.tr("红色", "Red")
        case .orange: return L10n.tr("橙色", "Orange")
        case .yellow: return L10n.tr("黄色", "Yellow")
        case .green: return L10n.tr("绿色", "Green")
        case .blue: return L10n.tr("蓝色", "Blue")
        case .purple: return L10n.tr("紫色", "Purple")
        case .gray: return L10n.tr("灰色", "Gray")
        }
    }

    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

// MARK: - Pure Helpers for Launchpad, Inspector, Checksums, Folder Size & URLs

struct FileChecksums: Equatable, Sendable {
    let sha256: String
    let md5: String
    let byteCount: Int64
}

struct FolderSizeSummary: Equatable, Sendable {
    let totalBytes: Int64
    let fileCount: Int
    let folderCount: Int
}

enum LaunchpadInspectorHelpers {
    /// Computes SHA-256 and MD5 checksums off the main thread in bounded 64 KiB chunks.
    static func computeChecksums(forFileAt url: URL) async throws -> FileChecksums {
        try Task.checkCancellation()
        let throttler = StreamingThrottler(speedLimitBytesPerSec: nil)
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var totalBytes: Int64 = 0

        for try await chunk in throttler.streamFileChunks(at: url) {
            try Task.checkCancellation()
            sha.update(data: chunk)
            md5.update(data: chunk)
            totalBytes += Int64(chunk.count)
        }

        let shaHex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        return FileChecksums(sha256: shaHex, md5: md5Hex, byteCount: totalBytes)
    }

    /// Generates a downsampled thumbnail off the main thread for local image files.
    static func loadImageThumbnail(forFileAt url: URL, maxPixelSize: Int = 180) async -> CGImage? {
        let ext = url.pathExtension.lowercased()
        let supported = ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "tif", "bmp", "icns"]
        guard supported.contains(ext) else { return nil }

        return await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize)
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        }.value
    }

    /// Recursively walks a local directory off the main thread and aggregates total bytes, files, and subfolders.
    static func calculateLocalFolderSize(at rootURL: URL, includeHidden: Bool) async throws -> FolderSizeSummary {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: options
            ) else {
                return FolderSizeSummary(totalBytes: 0, fileCount: 0, folderCount: 0)
            }

            var totalBytes: Int64 = 0
            var fileCount = 0
            var folderCount = 0

            while let item = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try item.resourceValues(forKeys: Set(keys))
                if values.isDirectory == true {
                    folderCount += 1
                } else {
                    fileCount += 1
                    totalBytes += Int64(values.fileSize ?? 0)
                }
            }

            return FolderSizeSummary(totalBytes: totalBytes, fileCount: fileCount, folderCount: folderCount)
        }.value
    }

    /// Aggregates recursive remote listing entries into byte and item counts.
    static func aggregateRemoteFolderSize(entries: [FileEntry], rootPath: String) -> FolderSizeSummary {
        let normalizedRoot = RemotePath.normalize(rootPath)
        var totalBytes: Int64 = 0
        var fileCount = 0
        var folderCount = 0
        for entry in entries {
            let entryNormalized = RemotePath.normalize(entry.path)
            if entryNormalized == normalizedRoot { continue }
            if entry.isDirectory {
                folderCount += 1
            } else {
                fileCount += 1
                totalBytes += max(0, entry.size)
            }
        }
        return FolderSizeSummary(totalBytes: totalBytes, fileCount: fileCount, folderCount: folderCount)
    }

    /// Maps a remote file/folder path to the profile's configured public `siteURL`.
    static func siteWebURL(for remotePath: String, isDirectory: Bool, profile: ServerProfile) -> URL? {
        FileClipboard.siteWebURL(for: remotePath, isDirectory: isDirectory, profile: profile)
    }

    /// Parses user-entered octal text (e.g. "0755" or "755") into `POSIXPermissions`.
    static func parseOctalPermissions(_ input: String) -> POSIXPermissions? {
        POSIXPermissions(fromOctalString: input)
    }

    /// Reads local file/folder POSIX permissions when `FileEntry.permissions` is unset.
    static func localPOSIXPermissions(at path: String) -> POSIXPermissions? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let raw = attrs[.posixPermissions] as? Int else {
            return nil
        }
        let octal = String(format: "%04o", raw & 0o777)
        return POSIXPermissions(fromOctalString: octal)
    }

    /// Human-readable subtitle summarizing host/bucket/container for Launchpad cards.
    static func endpointSummary(for profile: ServerProfile) -> String {
        switch profile.protocolKind {
        case .s3:
            let bucket = profile.s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = host.isEmpty ? "s3.\(profile.s3Region.isEmpty ? "us-east-1" : profile.s3Region).amazonaws.com" : host
            return bucket.isEmpty ? endpoint : "\(bucket) · \(endpoint)"
        case .b2:
            let bucket = profile.b2BucketName.isEmpty ? profile.b2BucketId : profile.b2BucketName
            let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint = host.isEmpty ? "api.backblazeb2.com" : host
            return bucket.isEmpty ? endpoint : "\(bucket) · \(endpoint)"
        case .azureBlob:
            let account = profile.azureAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let container = profile.azureContainer.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = profile.host.isEmpty ? (account.isEmpty ? "blob.core.windows.net" : "\(account).blob.core.windows.net") : profile.host
            return container.isEmpty ? host : "\(container) · \(host)"
        case .openstackSwift:
            let container = profile.swiftContainer.trimmingCharacters(in: .whitespacesAndNewlines)
            let authHost = URL(string: profile.swiftAuthURL)?.host ?? profile.host
            if container.isEmpty { return authHost }
            return authHost.isEmpty ? container : "\(container) · \(authHost)"
        case .sftp, .ftp, .ftps, .ftpsExplicit, .webdav, .webdavs:
            let userPrefix = profile.username.isEmpty ? "" : "\(profile.username)@"
            return "\(userPrefix)\(profile.host):\(profile.port)"
        }
    }

    static func matchesSearch(_ profile: ServerProfile, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystacks = [
            profile.name,
            profile.group,
            profile.host,
            profile.username,
            profile.protocolKind.title,
            profile.siteURL,
            profile.defaultLocalPath,
            profile.s3Bucket,
            profile.b2BucketName,
            profile.azureAccountName,
            profile.azureContainer,
            profile.swiftContainer
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Exports a standalone macOS `.app` Droplet bundle at `destinationAppURL`.
    static func exportDropletBundle(for profile: ServerProfile, remotePath: String, destinationAppURL: URL) throws {
        let appURL = destinationAppURL.pathExtension.lowercased() == "app"
            ? destinationAppURL
            : destinationAppURL.appendingPathExtension("app")
        try DropletExporter.exportDroplet(
            for: profile,
            remotePath: remotePath,
            destinationAppURL: appURL
        )
    }
}

// MARK: - Workspace Extension for Launchpad, Folder Linking, Inspector & Known Hosts

extension Workspace {
    /// Connects to a profile (Folder Linking is handled automatically inside `Workspace.connect(_:credentials:)`).
    func connectApplyingFolderLink(_ profile: ServerProfile, credentials: Credentials) {
        connect(profile, credentials: credentials)
    }

    func connectSavedApplyingFolderLink(_ profile: ServerProfile) {
        connectSaved(profile)
    }

    /// Exports a standalone macOS `.app` droplet for a saved bookmark.
    func saveBookmarkAsDroplet(_ profile: ServerProfile) {
        let baseName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? profile.host : profile.name
        let safeBase = baseName.replacingOccurrences(of: "/", with: "-")
        let panel = NSSavePanel()
        panel.title = L10n.tr("存储为 Droplet 小程序", "Save Bookmark as Droplet")
        panel.nameFieldStringValue = "\(safeBase.isEmpty ? "Server" : safeBase) Droplet.app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let destinationURL = selectedURL.pathExtension.lowercased() == "app"
            ? selectedURL
            : selectedURL.appendingPathExtension("app")
        let targetRemote = profile.initialPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : profile.initialPath

        Task { @MainActor [weak self] in
            do {
                let exportedURL = try await Task.detached(priority: .userInitiated) {
                    try DropletExporter.exportDroplet(
                        for: profile,
                        remotePath: targetRemote,
                        destinationAppURL: destinationURL
                    )
                }.value
                self?.rulesAndTranscriptStore.appendTranscript(
                    for: profile,
                    category: .command,
                    message: "Exported Droplet app '\(exportedURL.lastPathComponent)' -> \(targetRemote)"
                )
                self?.flashNotice(L10n.tr("已保存 Droplet：\(exportedURL.lastPathComponent)", "Saved Droplet: \(exportedURL.lastPathComponent)"))
            } catch {
                self?.error = L10n.tr("保存 Droplet 失败：\(error.localizedDescription)", "Failed to save Droplet: \(error.localizedDescription)")
            }
        }
    }

    /// Saved profiles with a pinned SSH host key fingerprint.
    var profilesWithTrustedHostKeys: [ServerProfile] {
        profiles.filter { ($0.trustedHostKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    /// Revokes / forgets the saved SSH host key fingerprint for the specified bookmark.
    func revokeTrustedHostKey(for profileId: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        let label = profiles[index].name.isEmpty ? profiles[index].host : profiles[index].name
        profiles[index].trustedHostKey = nil
        if connectedProfile?.id == profileId {
            connectedProfile?.trustedHostKey = nil
        }
        persist()
        flashNotice(L10n.tr("已撤销主机密钥信任：\(label)", "Revoked trusted host key for \(label)"))
    }

    /// Whether the entry belongs to the active remote pane.
    func isRemoteEntry(_ entry: FileEntry) -> Bool {
        remoteSelection.contains(entry.id) && remoteFiles.contains(where: { $0.id == entry.id })
    }

    /// Whether the active remote connection targets a cloud object store supporting extended metadata/presigned URLs.
    var isConnectedToCloudObjectStore: Bool {
        guard let kind = connectedProfile?.protocolKind else { return false }
        switch kind {
        case .s3, .b2, .azureBlob, .openstackSwift:
            return true
        case .sftp, .ftp, .ftps, .ftpsExplicit, .webdav, .webdavs:
            return false
        }
    }

    /// Calculates total folder size asynchronously off the main thread.
    func calculateFolderSize(for entry: FileEntry, remote: Bool) async throws -> FolderSizeSummary {
        if !remote {
            return try await LaunchpadInspectorHelpers.calculateLocalFolderSize(
                at: URL(fileURLWithPath: entry.path),
                includeHidden: showHidden
            )
        }
        guard let client else {
            throw TransferError.remote(L10n.tr("请先连接服务器。", "Connect to a server first."))
        }
        let entries = try await client.listRecursive(entry.path)
        return LaunchpadInspectorHelpers.aggregateRemoteFolderSize(entries: entries, rootPath: entry.path)
    }

    /// Maps a remote entry to its bookmark's configured public web URL (`siteURL`), if any.
    func siteWebURL(for entry: FileEntry, remote: Bool) -> URL? {
        guard remote, let profile = connectedProfile else { return nil }
        return LaunchpadInspectorHelpers.siteWebURL(for: entry.path, isDirectory: entry.isDirectory, profile: profile)
    }

    /// Formats the protocol/file URL string for Inspector copy actions.
    func inspectorServerURLString(for entry: FileEntry, remote: Bool) -> String {
        if !remote {
            return URL(fileURLWithPath: entry.path).absoluteString
        }
        guard let profile = connectedProfile else { return entry.path }
        return FileClipboard.remoteURLString(for: entry, profile: profile)
    }

    /// Recursively applies POSIX permissions to a folder and all enclosed items.
    func applyPermissionsRecursively(to entry: FileEntry, permissions: POSIXPermissions, remote: Bool) async throws -> Int {
        try Task.checkCancellation()
        if remote {
            guard let client else {
                throw TransferError.remote(L10n.tr("请先连接服务器。", "Connect to a server first."))
            }
            try await client.chmod(entry.path, permissions: permissions)
            var count = 1
            if entry.isDirectory {
                let enclosed = try await client.listRecursive(entry.path)
                let rootNormalized = RemotePath.normalize(entry.path)
                for child in enclosed {
                    try Task.checkCancellation()
                    if RemotePath.normalize(child.path) == rootNormalized { continue }
                    try await client.chmod(child.path, permissions: permissions)
                    count += 1
                }
            }
            refreshRemote()
            return count
        } else {
            let rootURL = URL(fileURLWithPath: entry.path)
            let octalMode = permissions.octalInt
            let includeHidden = showHidden
            let updatedCount = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let fm = FileManager.default
                try fm.setAttributes([.posixPermissions: octalMode], ofItemAtPath: rootURL.path)
                var count = 1
                if entry.isDirectory {
                    let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
                    if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: options) {
                        while let childURL = enumerator.nextObject() as? URL {
                            try Task.checkCancellation()
                            try fm.setAttributes([.posixPermissions: octalMode], ofItemAtPath: childURL.path)
                            count += 1
                        }
                    }
                }
                return count
            }.value
            refreshLocal()
            return updatedCount
        }
    }

    /// Loads cloud object extended metadata off the main thread.
    func loadRemoteMetadata(for remotePath: String) async throws -> RemoteObjectMetadata {
        guard let client else {
            throw TransferError.remote(L10n.tr("请先连接服务器。", "Connect to a server first."))
        }
        return try await client.statMetadata(remotePath)
    }

    /// Saves updated cloud object metadata off the main thread.
    func saveRemoteMetadata(_ metadata: RemoteObjectMetadata, for remotePath: String) async throws {
        guard let client else {
            throw TransferError.remote(L10n.tr("请先连接服务器。", "Connect to a server first."))
        }
        try await client.updateMetadata(remotePath, metadata: metadata)
    }

    /// Generates a presigned download URL for a remote cloud object.
    func generatePresignedURL(for remotePath: String, expiresIn seconds: Int) async throws -> URL {
        guard let client else {
            throw TransferError.remote(L10n.tr("请先连接服务器。", "Connect to a server first."))
        }
        return try await client.presignedURL(for: remotePath, expiresIn: seconds)
    }
}
