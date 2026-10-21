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
        host = profile.host.lowercased()
        port = profile.port
        username = profile.username
        protocolKind = profile.protocolKind
    }

    public init(host: String, port: Int, username: String, protocolKind: TransferProtocol) {
        self.host = host.lowercased()
        self.port = port
        self.username = username
        self.protocolKind = protocolKind
    }
}

public struct LocalTransferVersion: Codable, Hashable, Sendable {
    public let size: Int64
    public let modified: Int64
    public let changed: Int64
    public let device: Int64
    public let inode: UInt64
    public let digest: Data

    public init(size: Int64, modified: Int64, changed: Int64, device: Int64, inode: UInt64, digest: Data) {
        self.size = size
        self.modified = modified
        self.changed = changed
        self.device = device
        self.inode = inode
        self.digest = digest
    }
}

public struct RemoteFileVersion: Codable, Hashable, Sendable {
    public let size: Int64
    public let modified: Int64?
    public let etag: String?

    public init(size: Int64, modified: Int64? = nil, etag: String? = nil) {
        self.size = size
        self.modified = modified
        self.etag = etag
    }

    func validate() throws {
        guard size >= 0, modified == nil || modified! >= 0 else { throw ResumeTransferError.invalidCheckpoint }
        if let etag {
            guard etag.utf8.count < 1024, etag.count >= 2, etag.first == "\"", etag.last == "\"",
                  etag.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }), !etag.dropFirst().dropLast().contains("\"") else {
                throw ResumeTransferError.invalidCheckpoint
            }
        }
    }
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
    public var expectedSize: Int64 = 0
    public var retainedBytes: Int64 = 0
    public var discardPending: Bool = false
    public var sourceLocal: LocalTransferVersion?
    public var sourceRemote: RemoteFileVersion?
    public var targetLocal: LocalTransferVersion?
    public var targetRemote: RemoteFileVersion?
    public var partialDigest: Data?
    public var committingDigest: Data?
    public var version: Int = 1

    public var name: String { URL(fileURLWithPath: direction == .upload ? localPath : remotePath).lastPathComponent }

    public init(
        id: UUID,
        direction: Direction,
        endpoint: ResumeEndpoint,
        localPath: String,
        remotePath: String,
        overwrite: Bool,
        created: Date,
        expectedSize: Int64 = 0,
        retainedBytes: Int64 = 0,
        discardPending: Bool = false,
        sourceLocal: LocalTransferVersion? = nil,
        sourceRemote: RemoteFileVersion? = nil,
        targetLocal: LocalTransferVersion? = nil,
        targetRemote: RemoteFileVersion? = nil,
        partialDigest: Data? = nil,
        committingDigest: Data? = nil,
        version: Int = 1
    ) {
        self.id = id
        self.direction = direction
        self.endpoint = endpoint
        self.localPath = localPath
        self.remotePath = remotePath
        self.overwrite = overwrite
        self.created = created
        self.expectedSize = expectedSize
        self.retainedBytes = retainedBytes
        self.discardPending = discardPending
        self.sourceLocal = sourceLocal
        self.sourceRemote = sourceRemote
        self.targetLocal = targetLocal
        self.targetRemote = targetRemote
        self.partialDigest = partialDigest
        self.committingDigest = committingDigest
        self.version = version
    }

    public func validate() throws {
        guard version == 1, localPath.hasPrefix("/"), remotePath.hasPrefix("/"), expectedSize >= 0,
              retainedBytes >= 0, retainedBytes <= expectedSize, partialDigest == nil || partialDigest?.count == 32,
              committingDigest == nil || committingDigest?.count == 32 else { throw ResumeTransferError.invalidCheckpoint }
        try RemotePath.validate(localPath)
        try RemotePath.validate(remotePath)
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
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            var results: [ResumeTransferRecord] = []
            for file in files where file.pathExtension == "json" {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ResumeTransferError.invalidCheckpoint
                }
                let data = try ResumeIO.readSmall(file)
                let decoder = JSONDecoder()
                let record: ResumeTransferRecord
                do {
                    record = try decoder.decode(ResumeTransferRecord.self, from: data)
                } catch {
                    throw ResumeTransferError.invalidCheckpoint
                }
                try record.validate()
                results.append(record)
            }
            return results.sorted { $0.created < $1.created }
        }
    }

    public func save(_ record: ResumeTransferRecord) async throws {
        try record.validate()
        let data = try JSONEncoder().encode(record)
        try await ResumeIO.run {
            try ResumeIO.makePrivateDirectory(directory)
            let destination = directory.appendingPathComponent(record.id.uuidString + ".json")
            try ResumeIO.writePrivate(data, to: destination)
        }
    }

    public func remove(_ id: UUID) async throws {
        try await ResumeIO.run {
            let destination = directory.appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
        }
    }
}

public enum ResumeIO {
    public static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public static func checkDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ResumeTransferError.invalidCheckpoint }
    }

    public static func makePrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try checkDirectory(url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func readSmall(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ResumeTransferError.invalidCheckpoint }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= 64 * 1024 else { throw ResumeTransferError.invalidCheckpoint }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw ResumeTransferError.invalidCheckpoint }
        return data
    }

    public static func fingerprint(_ url: URL) async throws -> LocalTransferVersion {
        try await run { try fingerprintSync(url) }
    }

    public static func digest(_ url: URL, prefixBytes: Int64) async throws -> Data {
        try await run { try fingerprintSync(url, prefixBytes: prefixBytes).digest }
    }

    public static func fingerprintSync(_ url: URL, prefixBytes: Int64? = nil) throws -> LocalTransferVersion {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ResumeTransferError.sourceChanged }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ResumeTransferError.sourceChanged }
        let length = prefixBytes ?? before.st_size
        guard length >= 0, length <= before.st_size else { throw ResumeTransferError.sourceChanged }
        var remaining = length, hash = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
            guard !data.isEmpty else { throw ResumeTransferError.sourceChanged }
            hash.update(data: data)
            remaining -= Int64(data.count)
        }
        guard fstat(descriptor, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ResumeTransferError.sourceChanged
        }
        return LocalTransferVersion(
            size: before.st_size,
            modified: Int64(before.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(before.st_mtimespec.tv_nsec),
            changed: Int64(before.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(before.st_ctimespec.tv_nsec),
            device: Int64(before.st_dev),
            inode: UInt64(before.st_ino),
            digest: Data(hash.finalize())
        )
    }
}

public final class ResumableTransfer: @unchecked Sendable {
    public let store: ResumeTransferStore
    private let stateLock = NSLock()
    private var _record: ResumeTransferRecord

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public var record: ResumeTransferRecord {
        withLock { _record }
    }

    public init(
        direction: ResumeTransferRecord.Direction,
        local: URL,
        remote: String,
        profile: ServerProfile,
        overwrite: Bool = false,
        store: ResumeTransferStore? = nil
    ) throws {
        self.store = store ?? ResumeTransferStore()
        let id = UUID()
        let endpoint = ResumeEndpoint(profile)
        self._record = ResumeTransferRecord(
            id: id,
            direction: direction,
            endpoint: endpoint,
            localPath: local.path,
            remotePath: RemotePath.normalize(remote),
            overwrite: overwrite,
            created: Date()
        )
    }

    public init(restoring record: ResumeTransferRecord, store: ResumeTransferStore? = nil) {
        self.store = store ?? ResumeTransferStore()
        self._record = record
    }

    public func checkpoint() -> ResumeTransferRecord {
        record
    }

    public var stagingLocalURL: URL {
        URL(fileURLWithPath: record.localPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".aethertransfer-resume-\(record.id.uuidString).part")
    }

    public var stagingRemotePath: String {
        let parent = RemotePath.parent(record.remotePath)
        return RemotePath.normalize("\(parent)/.aethertransfer-resume-\(record.id.uuidString).part")
    }

    private func updateRetainedBytes(_ bytes: Int64) {
        withLock {
            _record.retainedBytes = bytes
        }
    }

    private func updateDownloadState(expectedSize: Int64, offset: Int64, remoteVersion: RemoteFileVersion) -> ResumeTransferRecord {
        withLock {
            _record.expectedSize = expectedSize
            _record.retainedBytes = offset
            _record.sourceRemote = remoteVersion
            return _record
        }
    }

    private func updateUploadState(expectedSize: Int64, offset: Int64, localVersion: LocalTransferVersion) -> ResumeTransferRecord {
        withLock {
            _record.expectedSize = expectedSize
            _record.retainedBytes = offset
            _record.sourceLocal = localVersion
            return _record
        }
    }

    public func run(
        client: RemoteClient,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()

        switch record.direction {
        case .download:
            try await runDownload(client: client, progress: progress)
        case .upload:
            try await runUpload(client: client, progress: progress)
        }
    }

    private func runDownload(
        client: RemoteClient,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let destination = URL(fileURLWithPath: record.localPath)
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) && !record.overwrite {
            throw TransferError.conflict(destination.lastPathComponent)
        }

        // Probe remote file
        let remoteDir = RemotePath.parent(record.remotePath)
        let entries = try await client.list(remoteDir)
        guard let entry = entries.first(where: { $0.path == record.remotePath || $0.name == record.name }) else {
            throw TransferError.remote("远端文件不存在: \(record.remotePath)")
        }

        let expectedSize = entry.size
        let currentRemoteVersion = RemoteFileVersion(
            size: expectedSize,
            modified: entry.modified.map { Int64($0.timeIntervalSince1970) }
        )

        // Safety verification: if source modified, refuse resume
        if let previous = record.sourceRemote {
            if previous.size != expectedSize {
                throw ResumeTransferError.sourceChanged
            }
            if let prevMod = previous.modified, let currMod = currentRemoteVersion.modified, prevMod != currMod {
                throw ResumeTransferError.sourceChanged
            }
        }

        // Check local staging
        let staging = stagingLocalURL
        var offset: Int64 = 0
        if fm.fileExists(atPath: staging.path) {
            let currentPartial = try await ResumeIO.fingerprint(staging)
            if currentPartial.size > expectedSize {
                try? fm.removeItem(at: staging)
                offset = 0
            } else {
                offset = currentPartial.size
            }
        }

        let currentRecord = updateDownloadState(expectedSize: expectedSize, offset: offset, remoteVersion: currentRemoteVersion)
        try await store.save(currentRecord)

        if offset < expectedSize {
            try await client.download(
                record.remotePath,
                to: destination,
                overwrite: record.overwrite,
                offset: offset > 0 ? offset : nil,
                stagingURL: staging,
                progress: { [weak self] p in
                    self?.updateRetainedBytes(p.completed)
                    progress(p)
                }
            )
        } else if offset == expectedSize && fm.fileExists(atPath: staging.path) {
            try await LocalFileCommit.commit(staging, to: destination, overwrite: record.overwrite)
        }

        // Verify destination exists and remove checkpoint
        if fm.fileExists(atPath: destination.path) {
            try await store.remove(record.id)
        }
    }

    private func runUpload(
        client: RemoteClient,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let sourceURL = URL(fileURLWithPath: record.localPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw TransferError.remote("本地文件不存在: \(record.localPath)")
        }

        let sourceFP = try await ResumeIO.fingerprint(sourceURL)
        if let prev = record.sourceLocal {
            if prev.size != sourceFP.size || prev.digest != sourceFP.digest {
                throw ResumeTransferError.sourceChanged
            }
        }

        // Check remote staging
        let remoteParent = RemotePath.parent(record.remotePath)
        let remoteListing = try await client.list(remoteParent)
        let stagingName = URL(fileURLWithPath: stagingRemotePath).lastPathComponent
        var offset: Int64 = 0
        if let stagingEntry = remoteListing.first(where: { $0.name == stagingName }) {
            if stagingEntry.size > sourceFP.size {
                try? await client.remove(stagingRemotePath, directory: false)
                offset = 0
            } else {
                offset = stagingEntry.size
            }
        }

        let currentRecord = updateUploadState(expectedSize: sourceFP.size, offset: offset, localVersion: sourceFP)
        try await store.save(currentRecord)

        if offset < sourceFP.size {
            try await client.upload(
                sourceURL,
                to: record.remotePath,
                overwrite: record.overwrite,
                offset: offset > 0 ? offset : nil,
                stagingRemotePath: stagingRemotePath,
                progress: { [weak self] p in
                    self?.updateRetainedBytes(p.completed)
                    progress(p)
                }
            )
        } else if offset == sourceFP.size {
            try await client.rename(stagingRemotePath, to: record.remotePath)
        }

        try await store.remove(record.id)
    }

    public func discard(client: RemoteClient? = nil) async throws {
        let fm = FileManager.default
        let staging = stagingLocalURL
        if fm.fileExists(atPath: staging.path) {
            try? fm.removeItem(at: staging)
        }
        if let client, record.direction == .upload {
            try? await client.remove(stagingRemotePath, directory: false)
        }
        try await store.remove(record.id)
    }
}
