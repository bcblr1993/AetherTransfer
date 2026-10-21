import Foundation
import CryptoKit
import CTransfer

public struct TransferProgress: Sendable {
    public let completed: Int64
    public let total: Int64
}

private final class RequestBox: @unchecked Sendable {
    let pointer: OpaquePointer
    let callback: @Sendable (TransferProgress) -> Void
    init(pointer: OpaquePointer, callback: @escaping @Sendable (TransferProgress) -> Void) {
        self.pointer = pointer; self.callback = callback
    }
    deinit { at_destroy(pointer) }
    func cancel() { at_cancel(pointer) }
}

public struct RemoteClient: Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let speedLimitBytesPerSec: Int64?
    public init(profile: ServerProfile, credentials: Credentials, speedLimitBytesPerSec: Int64? = nil) {
        self.profile = profile
        self.credentials = credentials
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
    }

    public static func fingerprint(_ key: String) -> String {
        guard let data = Data(base64Encoded: key) else { return "Invalid key" }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private func perform(path: String, directory: Bool = false, mode: Int32, local: String = "", commands: String = "",
                         offset: Int64? = nil, rangeEnd: Int64 = -1, expectedTotal: Int64 = -1,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()
        let url = try profile.url(path: path, directory: directory)
        let request = url.withCString { url in profile.username.withCString { user in credentials.password.withCString { password in
            profile.privateKeyPath.withCString { key in credentials.passphrase.withCString { passphrase in
                (profile.trustedHostKey ?? "").withCString { fingerprint in at_create(url, user, password, key, passphrase, fingerprint) }
            }}
        }}}
        guard let request else { throw TransferError.remote(L10n.tr("无法创建传输连接。", "Unable to create transfer connection.")) }
        if let limit = speedLimitBytesPerSec, limit > 0, (mode == 1 || mode == 2) {
            _ = at_set_speed_limit(request, limit)
        }
        if let offset {
            let res = at_transfer_window(request, offset, rangeEnd, expectedTotal)
            guard res == 0 else {
                at_destroy(request)
                throw TransferError.remote("无法设置传输窗口。")
            }
        }
        let box = RequestBox(pointer: request, callback: progress)
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let context = Unmanaged.passUnretained(box).toOpaque()
                let code = local.withCString { local in commands.withCString { commands in
                    at_perform(box.pointer, mode, local, commands, { context, completed, total in
                        guard let context else { return }
                        Unmanaged<RequestBox>.fromOpaque(context).takeUnretainedValue().callback(
                            TransferProgress(completed: completed, total: total))
                    }, context)
                }}
                if code == 42 { throw CancellationError() }
                if code != 0 {
                    let key = String(cString: at_host_key(box.pointer))
                    if !key.isEmpty && key != profile.trustedHostKey {
                        throw TransferError.hostKeyRequired(key: key, changed: profile.trustedHostKey != nil)
                    }
                    throw TransferError.remote(String(cString: at_error(box.pointer)))
                }
                return String(cString: at_result(box.pointer))
            }.value
        } onCancel: { box.cancel() }
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try DirectoryListing.parse(await perform(path: path, directory: true, mode: 0), parent: RemotePath.normalize(path))
    }
    public func download(_ remote: String, to destination: URL, overwrite: Bool = false,
                         offset: Int64? = nil, stagingURL: URL? = nil,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) && !overwrite { throw TransferError.conflict(destination.lastPathComponent) }
        let temporary = stagingURL ?? destination.deletingLastPathComponent().appendingPathComponent(".aethertransfer-\(UUID().uuidString).part")
        defer {
            if stagingURL == nil { try? fm.removeItem(at: temporary) }
        }
        _ = try await perform(path: remote, mode: 1, local: temporary.path, offset: offset, progress: progress)
        try Task.checkCancellation()
        try await LocalFileCommit.commit(temporary, to: destination, overwrite: overwrite)
    }
    public func upload(_ local: URL, to remote: String, overwrite: Bool = false,
                       offset: Int64? = nil, stagingRemotePath: String? = nil,
                       progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        let parent = RemotePath.parent(remote)
        let name = URL(fileURLWithPath: remote).lastPathComponent
        if offset == nil && !overwrite {
            let listing = try await list(parent)
            if listing.contains(where: { $0.name == name }) {
                throw TransferError.conflict(name)
            }
        }
        let temporary: String
        if let stagingRemotePath {
            temporary = stagingRemotePath
        } else {
            temporary = try RemotePath.join(parent, ".aethertransfer-\(UUID().uuidString).part")
        }
        do {
            _ = try await perform(path: temporary, mode: 2, local: local.path, offset: offset, progress: progress)
            try Task.checkCancellation()
            if temporary != remote {
                try await rename(temporary, to: remote)
            }
        } catch {
            if stagingRemotePath == nil {
                // Cleanup is independent of the cancelled task. Never delete the user's final destination.
                _ = try? await Task.detached { try await self.remove(temporary, directory: false) }.value
            }
            throw error
        }
    }
    public func mkdir(_ path: String) async throws {
        try await command(sftp: "mkdir \(RemotePath.quoted(path))", ftp: "MKD \(path)")
    }
    public func mkdirRecursive(_ path: String) async throws {
        let parts = RemotePath.normalize(path).split(separator: "/").map(String.init)
        var current = ""
        for part in parts {
            current += "/" + part
            _ = try? await mkdir(current)
        }
    }
    public func listRecursive(_ remotePath: String) async throws -> [FileEntry] {
        var results: [FileEntry] = []
        var queue = [RemotePath.normalize(remotePath)]
        while !queue.isEmpty {
            try Task.checkCancellation()
            let current = queue.removeFirst()
            let entries = try await list(current)
            for entry in entries {
                results.append(entry)
                if entry.isDirectory {
                    queue.append(entry.path)
                }
            }
        }
        return results
    }
    public func rename(_ source: String, to destination: String) async throws {
        try RemotePath.validate(source); try RemotePath.validate(destination)
        try await command(sftp: "rename \(RemotePath.quoted(source)) \(RemotePath.quoted(destination))", ftp: "RNFR \(source)\nRNTO \(destination)")
    }
    public func remove(_ path: String, directory: Bool) async throws {
        try await command(sftp: "\(directory ? "rmdir" : "rm") \(RemotePath.quoted(path))", ftp: "\(directory ? "RMD" : "DELE") \(path)")
    }
    public func chmod(_ path: String, permissions: POSIXPermissions) async throws {
        try RemotePath.validate(path)
        let octal = permissions.octalString
        let octal3 = String(octal.suffix(3))
        try await command(sftp: "chmod \(octal) \(RemotePath.quoted(path))", ftp: "SITE CHMOD \(octal3) \(path)")
    }
    private func command(sftp: String, ftp: String) async throws {
        _ = try await perform(path: "/", directory: true, mode: 3, commands: profile.protocolKind == .sftp ? sftp : ftp)
    }
}
