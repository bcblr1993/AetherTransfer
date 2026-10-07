import Foundation
import CryptoKit
import Darwin

public enum ResumeTransferError: Error, LocalizedError, Sendable {
    case sourceChanged, targetChanged, invalidCheckpoint, busy, suspended, unsupportedVersion, uploadRestartRequired
    public var errorDescription: String? {
        switch self {
        case .sourceChanged: "源文件或已传部分内容已变化，拒绝续传；请核对后从头传输。"
        case .targetChanged: "目标文件已变化，未覆盖；请重新核对冲突选项。"
        case .invalidCheckpoint: "传输检查点不完整或不合法，未使用其中的部分文件。"
        case .busy: "此传输正在处理，请稍后再试。"
        case .suspended: "进度已保留，可以继续传输。"
        case .unsupportedVersion: "服务器没有返回可核对的大小与版本，无法安全续传。"
        case .uploadRestartRequired: "普通 WebDAV PUT 不支持按偏移续传；请明确选择从头重新上传。"
        }
    }
}

public struct ResumeEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let protocolKind: TransferProtocol
    public init(_ profile: ServerProfile) {
        host = profile.host.lowercased(); port = profile.port; username = profile.username; protocolKind = profile.protocolKind
    }
}

private struct LocalTransferVersion: Codable, Hashable, Sendable {
    let size: Int64
    let modified: Int64
    let changed: Int64
    let device: Int64
    let inode: UInt64
    let digest: Data
}

public struct ResumeTransferRecord: Codable, Identifiable, Sendable {
    public enum Direction: String, Codable, Sendable { case upload, download }
    public let id: UUID
    public let direction: Direction
    public let endpoint: ResumeEndpoint
    public let localPath: String
    public let remotePath: String
    public let overwrite: Bool
    public let created: Date
    public fileprivate(set) var expectedSize: Int64 = 0
    public fileprivate(set) var retainedBytes: Int64 = 0
    public fileprivate(set) var discardPending = false
    fileprivate var sourceLocal: LocalTransferVersion?
    fileprivate var sourceRemote: RemoteFileVersion?
    fileprivate var targetLocal: LocalTransferVersion?
    fileprivate var targetRemote: RemoteFileVersion?
    fileprivate var partialDigest: Data?
    fileprivate var committingDigest: Data?
    fileprivate var version = 1
    public var name: String { URL(fileURLWithPath: direction == .upload ? localPath : remotePath).lastPathComponent }
    fileprivate var staging: String { RemotePath.normalize(RemotePath.parent(remotePath) + "/.aethertransfer-resume-\(id.uuidString).part") }
    fileprivate var partialDirectory: URL {
        URL(fileURLWithPath: localPath).deletingLastPathComponent().appendingPathComponent(".aethertransfer-resume-\(id.uuidString)", isDirectory: true)
    }
    fileprivate var partial: URL { partialDirectory.appendingPathComponent("partial") }
    fileprivate func validate() throws {
        guard version == 1, localPath.hasPrefix("/"), remotePath.hasPrefix("/"), expectedSize >= 0,
              retainedBytes >= 0, retainedBytes <= expectedSize, partialDigest == nil || partialDigest?.count == 32,
              committingDigest == nil || committingDigest?.count == 32 else { throw ResumeTransferError.invalidCheckpoint }
        try RemotePath.validate(localPath); try RemotePath.validate(remotePath)
        try RemotePath.validateName(name)
        for local in [sourceLocal, targetLocal].compactMap({ $0 }) {
            guard local.size >= 0, local.digest.count == 32 else { throw ResumeTransferError.invalidCheckpoint }
        }
        for remote in [sourceRemote, targetRemote].compactMap({ $0 }) { try remote.validate() }
        if let sourceLocal { guard sourceLocal.size == expectedSize else { throw ResumeTransferError.invalidCheckpoint } }
        if let sourceRemote { guard sourceRemote.size == expectedSize else { throw ResumeTransferError.invalidCheckpoint } }
    }
}

public struct ResumeTransferStore: Sendable {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AetherTransfer/Transfers", isDirectory: true)
    }
    public func records() async throws -> [ResumeTransferRecord] {
        try await ResumeIO.run {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            try ResumeIO.checkDirectory(directory)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            guard files.count <= 1000 else { throw ResumeTransferError.invalidCheckpoint }
            return try files.map { file in
                let data = try ResumeIO.readSmall(file)
                let record = try JSONDecoder().decode(ResumeTransferRecord.self, from: data)
                try record.validate()
                guard file.deletingPathExtension().lastPathComponent == record.id.uuidString else { throw ResumeTransferError.invalidCheckpoint }
                return record
            }.sorted { $0.created > $1.created }
        }
    }
    fileprivate func lock(_ id: UUID) async throws -> Int32 {
        try await ResumeIO.run {
            try ResumeIO.makePrivateDirectory(directory)
            let path = directory.appendingPathComponent(id.uuidString + ".lock").path
            let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw ResumeTransferError.invalidCheckpoint }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(descriptor); throw ResumeTransferError.invalidCheckpoint
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw ResumeTransferError.busy }
            return descriptor
        }
    }
    fileprivate func save(_ record: ResumeTransferRecord) async throws {
        try await ResumeIO.run {
            try record.validate()
            let data = try JSONEncoder().encode(record)
            try ResumeIO.writePrivate(data, to: directory.appendingPathComponent(record.id.uuidString + ".json"))
        }
    }
    fileprivate func remove(_ id: UUID) throws {
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        let lock = directory.appendingPathComponent(id.uuidString + ".lock")
        if FileManager.default.fileExists(atPath: lock.path) { try FileManager.default.removeItem(at: lock) }
    }
    fileprivate func load(_ id: UUID) async throws -> ResumeTransferRecord {
        try await ResumeIO.run {
            let file = directory.appendingPathComponent(id.uuidString + ".json")
            let record = try JSONDecoder().decode(ResumeTransferRecord.self, from: ResumeIO.readSmall(file))
            guard record.id == id else { throw ResumeTransferError.invalidCheckpoint }
            try record.validate(); return record
        }
    }
}

/// A persisted file transfer. Credentials and host trust always come from the current, approved client.
public actor ResumableTransfer {
    private var record: ResumeTransferRecord
    private let store: ResumeTransferStore
    private var busy = false
    private var finished = false
    private var persisted = false
    public init(direction: ResumeTransferRecord.Direction, local: URL, remote: String, profile: ServerProfile,
                overwrite: Bool = false, store: ResumeTransferStore = ResumeTransferStore()) throws {
        try profile.validate()
        record = ResumeTransferRecord(id: UUID(), direction: direction, endpoint: ResumeEndpoint(profile), localPath: local.path,
                                      remotePath: RemotePath.normalize(remote), overwrite: overwrite, created: Date())
        self.store = store; try record.validate()
    }
    public init(restoring record: ResumeTransferRecord, store: ResumeTransferStore = ResumeTransferStore()) throws {
        try record.validate(); self.record = record; self.store = store; persisted = true
    }
    public func checkpoint() -> ResumeTransferRecord { record }
    public func run(client: RemoteClient, restartWebDAVUpload: Bool = false,
                    progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        guard !busy else { throw ResumeTransferError.busy }
        guard !finished, !record.discardPending, ResumeEndpoint(client.profile) == record.endpoint else { throw ResumeTransferError.invalidCheckpoint }
        busy = true; defer { busy = false }
        // Honor pause/retain requested during queued preparation; clear only after this attempt ends.
        defer { client.control?.resetRetainRequest() }
        let descriptor = try await store.lock(record.id)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        if persisted { record = try await store.load(record.id) }
        guard !record.discardPending, ResumeEndpoint(client.profile) == record.endpoint else { throw ResumeTransferError.invalidCheckpoint }
        let quiet = RemoteClient(profile: client.profile, credentials: client.credentials, certificateAuthority: client.certificateAuthority)
        do {
            if try await recognizeCommitted(client: client) {
                if record.direction == .upload,
                   try await client.list(RemotePath.parent(record.staging)).contains(where: { $0.path == record.staging }) {
                    try await client.remove(record.staging, directory: false)
                }
                try await cleanLocal(); finished = true; return
            }
            if record.sourceLocal == nil && record.sourceRemote == nil { try await prepare(client: client); try await store.save(record); persisted = true }
            try checkBoundary(client)
            switch record.direction {
            case .download: try await download(client: client, progress: progress)
            case .upload: try await upload(client: client, restart: restartWebDAVUpload, progress: progress)
            }
            try await cleanLocal(); finished = true
        } catch {
            if Task.isCancelled && client.control?.isRetainingProgress != true {
                finished = await Task.detached {
                    do { try await self.discardInternal(client: quiet); return true }
                    catch { return false }
                }.value
                throw CancellationError()
            }
            // Native workers have closed their files. Persist this exact partial before returning.
            try await Task.detached { try await self.persistPartial(client: quiet) }.value
            if client.control?.isRetainingProgress == true { throw ResumeTransferError.suspended }
            throw error
        }
    }
    public func discard(client: RemoteClient? = nil) async throws {
        guard !busy else { throw ResumeTransferError.busy }
        if finished { return }
        if record.direction == .upload {
            guard let client, ResumeEndpoint(client.profile) == record.endpoint else { throw ResumeTransferError.invalidCheckpoint }
        }
        busy = true; defer { busy = false }
        let descriptor = try await store.lock(record.id)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        if persisted { record = try await store.load(record.id) }
        try await discardInternal(client: client); finished = true
    }
    private func checkBoundary(_ client: RemoteClient) throws {
        try Task.checkCancellation()
        if client.control?.isRetainingProgress == true { throw ResumeTransferError.suspended }
    }
    private func prepare(client: RemoteClient) async throws {
        var prepared = record
        let entry = try await client.list(RemotePath.parent(record.remotePath)).first { $0.path == record.remotePath }
        if record.direction == .upload {
            prepared.sourceLocal = try await ResumeIO.fingerprint(URL(fileURLWithPath: record.localPath))
            prepared.expectedSize = prepared.sourceLocal!.size
            if let entry {
                guard !entry.isDirectory, !entry.isSymbolicLink, record.overwrite else { throw ResumeTransferError.targetChanged }
                prepared.targetRemote = try await client.fileVersion(record.remotePath)
            }
        } else {
            guard let entry, !entry.isDirectory, !entry.isSymbolicLink else { throw ResumeTransferError.unsupportedVersion }
            prepared.sourceRemote = try await client.fileVersion(record.remotePath); prepared.expectedSize = prepared.sourceRemote!.size
            let local = URL(fileURLWithPath: record.localPath)
            if FileManager.default.fileExists(atPath: local.path) {
                guard record.overwrite else { throw ResumeTransferError.targetChanged }
                prepared.targetLocal = try await ResumeIO.fingerprint(local)
            }
            let directory = record.partialDirectory, partial = record.partial
            try await ResumeIO.run {
                try ResumeIO.makePrivateDirectory(directory)
                if !FileManager.default.fileExists(atPath: partial.path) { try ResumeIO.writePrivate(Data(), to: partial) }
            }
        }
        record = prepared
    }
    private func download(client: RemoteClient, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        guard let source = record.sourceRemote, try await client.fileVersion(record.remotePath) == source else { throw ResumeTransferError.sourceChanged }
        let partial = try await ResumeIO.fingerprint(record.partial)
        guard partial.size <= source.size, partial.size >= record.retainedBytes else { throw ResumeTransferError.sourceChanged }
        if let expected = record.partialDigest {
            let savedPrefix = partial.size == record.retainedBytes ? partial.digest : try await ResumeIO.digest(record.partial, prefixBytes: record.retainedBytes)
            guard savedPrefix == expected else { throw ResumeTransferError.sourceChanged }
        }
        if partial.size > 0 {
            progress(TransferProgress(completed: partial.size, total: source.size, phase: "核对已下载部分"))
            guard try await client.contentDigest(record.remotePath, version: source, prefixBytes: partial.size) == partial.digest else { throw ResumeTransferError.sourceChanged }
        }
        try checkBoundary(client)
        if partial.size < source.size {
            try await client.downloadPartial(record.remotePath, to: record.partial, offset: partial.size, version: source, progress: progress)
        }
        progress(TransferProgress(completed: source.size, total: source.size, phase: "校验并提交"))
        let complete = try await ResumeIO.fingerprint(record.partial)
        guard complete.size == source.size, try await client.fileVersion(record.remotePath) == source else { throw ResumeTransferError.sourceChanged }
        if source.etag == nil {
            // FTP/SFTP timestamps can have only second precision. Verify the complete content too.
            progress(TransferProgress(completed: source.size, total: source.size, phase: "核对完整源文件"))
            guard try await client.contentDigest(record.remotePath, version: source) == complete.digest,
                  try await client.fileVersion(record.remotePath) == source else { throw ResumeTransferError.sourceChanged }
        }
        let destination = URL(fileURLWithPath: record.localPath)
        let current = try await ResumeIO.existingFingerprint(destination)
        guard current == record.targetLocal else { throw ResumeTransferError.targetChanged }
        try checkBoundary(client)
        record.committingDigest = complete.digest; try await store.save(record)
        let staging = record.partial
        try await ResumeIO.run {
            // Recheck the destination immediately before the same-filesystem rename.
            guard try ResumeIO.existingFingerprintSync(destination) == current else { throw ResumeTransferError.targetChanged }
            try Task.checkCancellation()
            try LocalFileCommit.commitSync(staging, to: destination, overwrite: current != nil)
        }
    }
    private func upload(client: RemoteClient, restart: Bool, progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        let source = URL(fileURLWithPath: record.localPath)
        guard let original = record.sourceLocal, try await ResumeIO.fingerprint(source) == original else { throw ResumeTransferError.sourceChanged }
        let staged = try await client.list(RemotePath.parent(record.staging)).first { $0.path == record.staging }
        var offset: Int64 = 0
        if let staged {
            guard !staged.isDirectory, !staged.isSymbolicLink, staged.size <= original.size else { throw ResumeTransferError.sourceChanged }
            offset = staged.size
            if offset > 0 {
                if record.endpoint.protocolKind.isWebDAV {
                    guard restart else { throw ResumeTransferError.uploadRestartRequired }
                    try await client.remove(record.staging, directory: false); offset = 0
                } else {
                    progress(TransferProgress(completed: offset, total: original.size, phase: "核对已上传部分"))
                    let stagedVersion = try await client.fileVersion(record.staging)
                    let digest = try await ResumeIO.digest(source, prefixBytes: offset)
                    guard try await client.contentDigest(record.staging, version: stagedVersion) == digest else { throw ResumeTransferError.sourceChanged }
                }
            }
        }
        try checkBoundary(client)
        if offset < original.size || staged == nil {
            try await client.uploadPartial(source, to: record.staging, offset: offset, progress: progress)
        }
        progress(TransferProgress(completed: original.size, total: original.size, phase: "校验并提交"))
        guard try await ResumeIO.fingerprint(source) == original else { throw ResumeTransferError.sourceChanged }
        let version = try await client.fileVersion(record.staging)
        guard version.size == original.size, try await client.contentDigest(record.staging, version: version) == original.digest else { throw ResumeTransferError.sourceChanged }
        let target = try await client.list(RemotePath.parent(record.remotePath)).first { $0.path == record.remotePath }
        if target != nil {
            guard let expected = record.targetRemote, try await client.fileVersion(record.remotePath) == expected else { throw ResumeTransferError.targetChanged }
        } else if record.targetRemote != nil { throw ResumeTransferError.targetChanged }
        try checkBoundary(client)
        record.committingDigest = original.digest; try await store.save(record)
        try await client.rename(record.staging, to: record.remotePath, overwrite: record.overwrite)
    }
    private func recognizeCommitted(client: RemoteClient) async throws -> Bool {
        guard let digest = record.committingDigest else { return false }
        switch record.direction {
        case .download:
            return try await ResumeIO.existingFingerprint(URL(fileURLWithPath: record.localPath))?.digest == digest
        case .upload:
            if let version = try? await client.fileVersion(record.remotePath), version.size == record.expectedSize {
                return try await client.contentDigest(record.remotePath, version: version) == digest
            }
            return false
        }
    }
    private func persistPartial(client: RemoteClient) async throws {
        if record.direction == .download, let file = try? await ResumeIO.fingerprint(record.partial) {
            record.retainedBytes = min(file.size, record.expectedSize); record.partialDigest = file.digest
        } else if record.direction == .upload {
            if let file = try? await client.list(RemotePath.parent(record.staging)).first(where: { $0.path == record.staging }) {
                record.retainedBytes = min(file.size, record.expectedSize)
            }
        }
        try await store.save(record)
    }
    private func discardInternal(client: RemoteClient?) async throws {
        record.discardPending = true
        try await store.save(record)
        if record.direction == .upload {
            guard let client else { throw ResumeTransferError.invalidCheckpoint }
            do {
                if try await client.list(RemotePath.parent(record.staging)).contains(where: { $0.path == record.staging }) {
                    try await client.remove(record.staging, directory: false)
                }
            } catch { try? await store.save(record); throw error }
        }
        try await cleanLocal()
    }
    private func cleanLocal() async throws {
        let record = record, store = store
        try await ResumeIO.run {
            if record.direction == .download, FileManager.default.fileExists(atPath: record.partialDirectory.path) {
                try ResumeIO.checkDirectory(record.partialDirectory)
                try FileManager.default.removeItem(at: record.partialDirectory)
            }
            try store.remove(record.id)
        }
    }
}

extension RemoteClient {
    public func resumableUpload(_ local: URL, to path: String, policy: ConflictPolicy = .reject,
                                store: ResumeTransferStore = ResumeTransferStore()) async throws -> ResumableTransfer? {
        let existing = try await list(RemotePath.parent(path)).first { $0.path == path }
        var target = path
        if let existing {
            guard !existing.isDirectory, !existing.isSymbolicLink else { throw TransferError.conflict(existing.name) }
            if policy == .skip { return nil }
            if policy == .keepBoth { target = try await availableRemoteName(path) }
            else if policy == .reject { throw TransferError.conflict(existing.name) }
        }
        return try ResumableTransfer(direction: .upload, local: local, remote: target, profile: profile,
                                     overwrite: policy == .overwrite, store: store)
    }
    public func resumableDownload(_ entry: FileEntry, to local: URL, policy: ConflictPolicy = .reject,
                                  store: ResumeTransferStore = ResumeTransferStore()) async throws -> ResumableTransfer? {
        guard !entry.isDirectory, !entry.isSymbolicLink else { throw ResumeTransferError.unsupportedVersion }
        let destination: URL? = try await ResumeIO.run {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory)
            if exists {
                guard !isDirectory.boolValue else { throw TransferError.conflict(entry.name) }
                if policy == .skip { return nil }
                if policy == .keepBoth { return try availableLocalName(local) }
                if policy == .reject { throw TransferError.conflict(entry.name) }
            }
            return local
        }
        guard let destination else { return nil }
        return try ResumableTransfer(direction: .download, local: destination, remote: entry.path, profile: profile,
                                     overwrite: policy == .overwrite, store: store)
    }
}

private enum ResumeIO {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ResumeTransferError.invalidCheckpoint }
    }
    static func makePrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try checkDirectory(url) }
        else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func readSmall(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ResumeTransferError.invalidCheckpoint }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 64 * 1024 else { throw ResumeTransferError.invalidCheckpoint }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw ResumeTransferError.invalidCheckpoint }; return data
    }
    static func existingFingerprint(_ url: URL) async throws -> LocalTransferVersion? { try await run { try existingFingerprintSync(url) } }
    static func existingFingerprintSync(_ url: URL) throws -> LocalTransferVersion? {
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        return try fingerprintSync(url)
    }
    static func fingerprint(_ url: URL) async throws -> LocalTransferVersion { try await run { try fingerprintSync(url) } }
    static func digest(_ url: URL, prefixBytes: Int64) async throws -> Data { try await run { try fingerprintSync(url, prefixBytes: prefixBytes).digest } }
    static func fingerprintSync(_ url: URL, prefixBytes: Int64? = nil) throws -> LocalTransferVersion {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ResumeTransferError.sourceChanged }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ResumeTransferError.sourceChanged }
        let length = prefixBytes ?? before.st_size
        guard length >= 0, length <= before.st_size else { throw ResumeTransferError.sourceChanged }
        var remaining = length, hash = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
            guard !data.isEmpty else { throw ResumeTransferError.sourceChanged }
            hash.update(data: data); remaining -= Int64(data.count)
        }
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ResumeTransferError.sourceChanged }
        return LocalTransferVersion(size: before.st_size, modified: Int64(before.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(before.st_mtimespec.tv_nsec),
            changed: Int64(before.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(before.st_ctimespec.tv_nsec), device: Int64(before.st_dev),
            inode: UInt64(before.st_ino), digest: Data(hash.finalize()))
    }
}
