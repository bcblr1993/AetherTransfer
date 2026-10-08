import Foundation
import Darwin
import CryptoKit
import CTransfer

public struct TransferProgress: Sendable {
    public enum Scope: Sendable { case file, directory, synchronization }
    public let completed: Int64
    public let total: Int64
    /// Localized display text. Use scope and counters for programmatic checks.
    public let phase: String?
    public let scope: Scope
    public let completedItems: Int?
    public let totalItems: Int?
    public let skippedItems: Int
    public var hasKnownTotal: Bool { total > 0 || totalItems != nil }
    public var fraction: Double {
        if total > 0 { return min(1, max(0, Double(completed) / Double(total))) }
        if let completedItems, let totalItems, totalItems > 0 {
            return min(1, max(0, Double(completedItems) / Double(totalItems)))
        }
        return 0
    }
    public init(completed: Int64, total: Int64, phase: String? = nil, scope: Scope = .file,
                completedItems: Int? = nil, totalItems: Int? = nil, skippedItems: Int = 0) {
        self.completed = completed; self.total = total; self.phase = phase
        self.scope = scope; self.completedItems = completedItems; self.totalItems = totalItems; self.skippedItems = skippedItems
    }
}

public struct RemoteFileVersion: Codable, Hashable, Sendable {
    public let size: Int64
    public let modified: Int64?
    public let etag: String?
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

final class NativeDigest: @unchecked Sendable {
    // Used exclusively by the owning native worker, including HTTP authentication resets.
    var hash = SHA256()
    func consume(_ pointer: UnsafeRawPointer?, _ count: Int) {
        guard let pointer else { hash = SHA256(); return }
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: pointer, count: count))
    }
}
private final class ResponseProbe: @unchecked Sendable {
    var version: RemoteFileVersion?
    var digest: Data?
    var bytes: Int64 = 0
}

final class RequestBox: @unchecked Sendable {
    let pointer: OpaquePointer
    let callback: @Sendable (TransferProgress) -> Void
    let digest: NativeDigest?
    init(pointer: OpaquePointer, callback: @escaping @Sendable (TransferProgress) -> Void) {
        self.pointer = pointer; self.callback = callback; digest = nil
    }
    init(pointer: OpaquePointer, callback: @escaping @Sendable (TransferProgress) -> Void, digest: NativeDigest?) {
        self.pointer = pointer; self.callback = callback; self.digest = digest
    }
    deinit { at_destroy(pointer) }
    func cancel() { at_cancel(pointer) }
}

/// Pause is forwarded to the worker through an atomic native flag, never a cross-thread curl call.
public final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var retaining = false
    private var request: RequestBox?
    public init() {}
    public func pause() { setPaused(true) }
    public func resume() { setPaused(false) }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    public var isRetainingProgress: Bool { lock.lock(); defer { lock.unlock() }; return retaining }
    public func retainProgress() {
        lock.lock(); defer { lock.unlock() }; retaining = true; request?.cancel()
    }
    func resetRetainRequest() { lock.lock(); defer { lock.unlock() }; retaining = false }
    private func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        if let request { at_pause(request.pointer, value ? 1 : 0) }
    }
    func attach(_ request: RequestBox) {
        lock.lock(); defer { lock.unlock() }
        self.request = request; at_pause(request.pointer, paused ? 1 : 0)
        if retaining { request.cancel() }
    }
    func detach() {
        lock.lock(); defer { lock.unlock() }
        request = nil
    }
}

public struct RemoteClient: Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let control: TransferControl?
    public let rateLimit: Int64
    public let certificateAuthority: URL?
    public init(profile: ServerProfile, credentials: Credentials, control: TransferControl? = nil, rateLimit: Int64 = 0,
                certificateAuthority: URL? = nil) {
        self.profile = profile; self.credentials = credentials.forProfile(profile); self.control = control; self.rateLimit = max(0, rateLimit)
        self.certificateAuthority = certificateAuthority ?? Bundle.main.url(forResource: "cacert", withExtension: "pem")
    }

    public static func fingerprint(_ key: String) -> String {
        guard let data = Data(base64Encoded: key) else { return "Invalid key" }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private func perform(path: String, directory: Bool = false, mode: Int32, local: String = "", commands: String = "",
                         httpMethod: String? = nil, httpHeaders: [String] = [], ftpListAll: Bool = false,
                         maximumDownloadBytes: Int64 = 0,
                         offset: Int64? = nil, rangeEnd: Int64 = -1, expectedTotal: Int64 = -1,
                         probe: ResponseProbe? = nil,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()
        let url = try profile.url(path: path, directory: directory)
        if profile.protocolKind == .sftp && profile.effectiveSSHAuthentication == .agent {
            guard let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !socket.isEmpty,
                  !socket.utf8.contains(0) else { throw SSHAuthenticationError.agentUnavailable }
        }
        let privateKey = profile.protocolKind == .sftp && profile.effectiveSSHAuthentication == .privateKey ? profile.privateKeyPath : ""
        let request = url.withCString { url in profile.username.withCString { user in credentials.password.withCString { password in
            privateKey.withCString { key in credentials.passphrase.withCString { passphrase in
                (profile.trustedHostKey ?? "").withCString { fingerprint in at_create(url, user, password, key, passphrase, fingerprint) }
            }}
        }}}
        guard let request else { throw TransferError.remote(L10n.text("无法创建传输连接。")) }
        let digest = mode == 5 ? NativeDigest() : nil
        let box = RequestBox(pointer: request, callback: progress, digest: digest)
        if profile.protocolKind == .sftp {
            guard at_ssh_auth(request, profile.effectiveSSHAuthentication.nativeValue) == 0 else { throw SSHAuthenticationError.configuration }
        }
        if let digest {
            at_body_sink(request, { context, bytes, count in
                guard let context else { return }
                Unmanaged<NativeDigest>.fromOpaque(context).takeUnretainedValue().consume(bytes, count)
            }, Unmanaged.passUnretained(digest).toOpaque())
        }
        let tlsCode = (certificateAuthority?.path ?? "").withCString {
            at_tls(request, profile.protocolKind == .ftpes || profile.protocolKind == .ftps ? 1 : 0, $0)
        }
        guard tlsCode == 0 else { throw TransferError.remote(L10n.text("无法配置 TLS 证书验证。")) }
        if ftpListAll {
            guard at_ftp_list_all(request) == 0 else { throw FilePermissionError.unavailable }
        }
        let method = httpMethod ?? (mode == 0 ? "PROPFIND" : (mode == 2 ? "PUT" : (mode == 6 ? "HEAD" : "GET")))
        if profile.protocolKind.isWebDAV {
            var headers = httpHeaders + ["Expect:"]
            let body: String?
            if method == "PROPFIND" {
                headers += ["Depth: 1", "Content-Type: application/xml; charset=utf-8"]
                body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"
            } else { body = nil }
            let configuration = method.withCString { method in headers.joined(separator: "\n").withCString { headers in
                if let body { return body.withCString { at_http(request, method, headers, $0) } }
                return at_http(request, method, headers, nil)
            }}
            guard configuration == 0 else { throw TransferError.remote(L10n.text("无法配置 WebDAV 请求。")) }
        }
        at_rate_limit(request, rateLimit)
        at_download_limit(request, maximumDownloadBytes)
        if let offset {
            guard at_transfer_window(request, offset, rangeEnd, expectedTotal) == 0 else { throw ResumeTransferError.invalidCheckpoint }
        }
        control?.attach(box)
        defer { control?.detach() }
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
                if profile.protocolKind.isWebDAV {
                    let status = at_response_code(box.pointer)
                    if status == 412 { throw TransferError.conflict(URL(fileURLWithPath: path).lastPathComponent) }
                    if status >= 300 {
                        let message: String
                        switch status {
                        case 301...399: message = L10n.text("服务器重定向了请求。请直接填写最终 WebDAV 地址。")
                        case 401: message = L10n.text("WebDAV 认证失败，请检查用户名和密码。")
                        case 403: message = L10n.text("WebDAV 服务器拒绝了操作。")
                        case 404: message = L10n.text("WebDAV 文件或目录不存在。")
                        case 409: message = L10n.text("WebDAV 目标目录不存在或操作发生冲突。")
                        case 423: message = L10n.text("WebDAV 文件被锁定，暂时无法修改。")
                        default: message = L10n.format("WebDAV 请求失败（HTTP %@）。", String(describing: status))
                        }
                        throw TransferError.remote(message)
                    }
                    if code == 0 {
                        let accepted: Set<Int> = switch method {
                        case "PROPFIND": [207]
                        case "GET": (offset ?? 0) > 0 || rangeEnd >= 0 ? [206] : [200]
                        case "HEAD": [200]
                        case "PUT", "MOVE", "COPY": [201, 204]
                        case "MKCOL": [201]
                        case "DELETE": [200, 204]
                        default: []
                        }
                        guard accepted.contains(status) else {
                            throw TransferError.remote(L10n.format("WebDAV 返回了不支持的结果（HTTP %@）；请刷新目录核对服务器状态。", String(describing: status)))
                        }
                    }
                }
                if code != 0 {
                    let key = String(cString: at_host_key(box.pointer))
                    if !key.isEmpty && key != profile.trustedHostKey {
                        throw TransferError.hostKeyRequired(key: key, changed: profile.trustedHostKey != nil)
                    }
                    throw TransferError.remote(String(cString: at_error(box.pointer)))
                }
                if let probe {
                    let raw = String(cString: at_etag(box.pointer))
                    let etag = raw.count >= 2 && raw.first == "\"" && raw.last == "\"" &&
                        raw.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e } && !raw.dropFirst().dropLast().contains("\"") ? raw : nil
                    let time = at_file_time(box.pointer)
                    probe.version = RemoteFileVersion(size: at_file_size(box.pointer), modified: time >= 0 ? time : nil, etag: etag)
                    probe.bytes = at_body_bytes(box.pointer)
                    if let digest { probe.digest = Data(digest.hash.finalize()) }
                }
                return String(cString: at_result(box.pointer))
            }.value
        } onCancel: { box.cancel() }
    }

    public func fileVersion(_ path: String) async throws -> RemoteFileVersion {
        let probe = ResponseProbe()
        _ = try await perform(path: path, mode: 6, probe: probe)
        guard let version = probe.version, version.size >= 0, version.modified != nil || version.etag != nil else {
            throw ResumeTransferError.unsupportedVersion
        }
        return version
    }
    public func contentDigest(_ path: String, version: RemoteFileVersion, prefixBytes: Int64? = nil) async throws -> Data {
        try version.validate()
        let bytes = prefixBytes ?? version.size
        guard bytes >= 0, bytes <= version.size else { throw ResumeTransferError.invalidCheckpoint }
        if bytes == 0 { return Data(SHA256.hash(data: Data())) }
        let probe = ResponseProbe()
        _ = try await perform(path: path, mode: 5, httpHeaders: version.etag.map { ["If-Match: \($0)"] } ?? [],
                              maximumDownloadBytes: bytes, offset: 0, rangeEnd: prefixBytes == nil ? -1 : bytes - 1,
                              expectedTotal: version.size, probe: probe)
        guard probe.bytes == bytes, let digest = probe.digest else { throw ResumeTransferError.sourceChanged }
        return digest
    }
    func downloadPartial(_ path: String, to partial: URL, offset: Int64, version: RemoteFileVersion,
                         progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        try version.validate()
        _ = try await perform(path: path, mode: 1, local: partial.path,
                              httpHeaders: version.etag.map { ["If-Match: \($0)"] } ?? [],
                              maximumDownloadBytes: version.size, offset: offset, expectedTotal: version.size, progress: progress)
    }
    func uploadPartial(_ local: URL, to staging: String, offset: Int64,
                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws {
        guard offset == 0 || !profile.protocolKind.isWebDAV else { throw ResumeTransferError.uploadRestartRequired }
        _ = try await perform(path: staging, mode: 2, local: local.path, offset: offset, progress: progress)
    }

    public func list(_ path: String, includingHidden: Bool = false) async throws -> [FileEntry] {
        let ftpListAll = includingHidden && [.ftp, .ftpes, .ftps].contains(profile.protocolKind)
        let response = try await perform(path: path, directory: true, mode: 0, ftpListAll: ftpListAll)
        if profile.protocolKind.isWebDAV {
            let origin = try profile.url(path: path, directory: true)
            return try await Task.detached { try WebDAVListing.parse(response, parent: path, origin: origin) }.value
        }
        return try DirectoryListing.parse(response, parent: RemotePath.normalize(path))
    }
    public func download(_ remote: String, to destination: URL, overwrite: Bool = false, maximumBytes: Int64 = 0,
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) && !overwrite { throw TransferError.conflict(destination.lastPathComponent) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".aethertransfer-\(UUID().uuidString).part")
        defer { temporary.path.withCString { _ = unlink($0) } }
        _ = try await perform(path: remote, mode: 1, local: temporary.path, maximumDownloadBytes: maximumBytes, progress: progress)
        try Task.checkCancellation()
        try await LocalFileCommit.commit(temporary, to: destination, overwrite: overwrite)
    }
    public func upload(_ local: URL, to remote: String, overwrite: Bool = false,
                       progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        let parent = RemotePath.parent(remote)
        let name = URL(fileURLWithPath: remote).lastPathComponent
        if try await list(parent).contains(where: { $0.name == name }) && !overwrite { throw TransferError.conflict(name) }
        let temporary = try RemotePath.join(parent, ".aethertransfer-\(UUID().uuidString).part")
        do {
            _ = try await perform(path: temporary, mode: 2, local: local.path, progress: progress)
            try Task.checkCancellation()
            try await rename(temporary, to: remote, overwrite: overwrite)
        } catch {
            // Cleanup is independent of the cancelled task. Never delete the user's final destination.
            let cleanup = RemoteClient(profile: profile, credentials: credentials, certificateAuthority: certificateAuthority)
            _ = try? await Task.detached { try await cleanup.remove(temporary, directory: false) }.value
            throw error
        }
    }
    public func mkdir(_ path: String) async throws {
        if profile.protocolKind.isWebDAV {
            _ = try await perform(path: path, directory: true, mode: 4, httpMethod: "MKCOL")
            return
        }
        try await command(sftp: "mkdir \(RemotePath.quoted(path))", ftp: "MKD \(path)")
    }
    public func rename(_ source: String, to destination: String, overwrite: Bool = false) async throws {
        try RemotePath.validate(source); try RemotePath.validate(destination)
        if profile.protocolKind.isWebDAV {
            do {
                _ = try await perform(path: source, mode: 4, httpMethod: "MOVE",
                                      httpHeaders: ["Destination: \(try profile.url(path: destination))", "Overwrite: \(overwrite ? "T" : "F")"])
            } catch TransferError.conflict {
                throw TransferError.conflict(URL(fileURLWithPath: destination).lastPathComponent)
            }
            return
        }
        if !overwrite {
            let name = URL(fileURLWithPath: destination).lastPathComponent
            if try await list(RemotePath.parent(destination), includingHidden: true).contains(where: { Data($0.name.utf8) == Data(name.utf8) }) {
                throw TransferError.conflict(name)
            }
        }
        try await command(sftp: "rename \(RemotePath.quoted(source)) \(RemotePath.quoted(destination))", ftp: "RNFR \(source)\nRNTO \(destination)")
    }
    public func remove(_ path: String, directory: Bool) async throws {
        if profile.protocolKind.isWebDAV {
            guard RemotePath.normalize(path) != "/" else { throw TransferError.invalidPath }
            if directory, !(try await list(path)).isEmpty {
                throw TransferError.remote(L10n.text("文件夹仍有内容，请先逐项确认删除。"))
            }
            _ = try await perform(path: path, directory: directory, mode: 4, httpMethod: "DELETE")
            return
        }
        try await command(sftp: "\(directory ? "rmdir" : "rm") \(RemotePath.quoted(path))", ftp: "\(directory ? "RMD" : "DELE") \(path)")
    }
    public func readPermissions(_ path: String) async throws -> RemotePermissionSnapshot {
        guard profile.protocolKind.supportsUnixPermissions else { throw FilePermissionError.unsupported }
        try RemotePath.validate(path)
        guard RemotePath.normalize(path) != "/",
              let entry = try await list(RemotePath.parent(path), includingHidden: true).first(where: { Data($0.path.utf8) == Data(path.utf8) }) else { throw FilePermissionError.changed }
        return try RemotePermissionSnapshot(entry)
    }
    public func setPermissions(_ mode: UnixPermissions, for expected: RemotePermissionSnapshot) async throws {
        guard profile.protocolKind.supportsUnixPermissions else { throw FilePermissionError.unsupported }
        let current = try await readPermissions(expected.entry.path)
        guard expected.matches(current) else { throw FilePermissionError.changed }
        try Task.checkCancellation()
        try await command(sftp: "chmod \(mode.octal) \(RemotePath.quoted(expected.entry.path))",
                          ftp: "SITE CHMOD \(mode.octal) \(expected.entry.path)")
        let verified = try await readPermissions(expected.entry.path)
        guard verified.entry.isDirectory == expected.entry.isDirectory, verified.entry.size == expected.entry.size,
              verified.entry.modified == expected.entry.modified, verified.mode == mode else { throw FilePermissionError.verification }
    }
    private func command(sftp: String, ftp: String) async throws {
        _ = try await perform(path: "/", directory: true, mode: 3, commands: profile.protocolKind == .sftp ? sftp : ftp)
    }
}
