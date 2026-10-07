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

/// Pause is forwarded to the worker through an atomic native flag, never a cross-thread curl call.
public final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var request: RequestBox?
    public init() {}
    public func pause() { setPaused(true) }
    public func resume() { setPaused(false) }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    private func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        if let request { at_pause(request.pointer, value ? 1 : 0) }
    }
    fileprivate func attach(_ request: RequestBox) {
        lock.lock(); defer { lock.unlock() }
        self.request = request; at_pause(request.pointer, paused ? 1 : 0)
    }
    fileprivate func detach() {
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
        self.profile = profile; self.credentials = credentials; self.control = control; self.rateLimit = max(0, rateLimit)
        self.certificateAuthority = certificateAuthority ?? Bundle.main.url(forResource: "cacert", withExtension: "pem")
    }

    public static func fingerprint(_ key: String) -> String {
        guard let data = Data(base64Encoded: key) else { return "Invalid key" }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private func perform(path: String, directory: Bool = false, mode: Int32, local: String = "", commands: String = "",
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws -> String {
        try Task.checkCancellation()
        let url = try profile.url(path: path, directory: directory)
        let request = url.withCString { url in profile.username.withCString { user in credentials.password.withCString { password in
            profile.privateKeyPath.withCString { key in credentials.passphrase.withCString { passphrase in
                (profile.trustedHostKey ?? "").withCString { fingerprint in at_create(url, user, password, key, passphrase, fingerprint) }
            }}
        }}}
        guard let request else { throw TransferError.remote("无法创建传输连接。") }
        let box = RequestBox(pointer: request, callback: progress)
        let tlsCode = (certificateAuthority?.path ?? "").withCString {
            at_tls(request, profile.protocolKind == .ftpes || profile.protocolKind == .ftps ? 1 : 0, $0)
        }
        guard tlsCode == 0 else { throw TransferError.remote("无法配置 TLS 证书验证。") }
        at_rate_limit(request, rateLimit)
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
                         progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) && !overwrite { throw TransferError.conflict(destination.lastPathComponent) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".aethertransfer-\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: temporary) }
        _ = try await perform(path: remote, mode: 1, local: temporary.path, progress: progress)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            guard overwrite else { throw TransferError.conflict(destination.lastPathComponent) }
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else { try fm.moveItem(at: temporary, to: destination) }
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
            try await rename(temporary, to: remote)
        } catch {
            // Cleanup is independent of the cancelled task. Never delete the user's final destination.
            let cleanup = RemoteClient(profile: profile, credentials: credentials, certificateAuthority: certificateAuthority)
            _ = try? await Task.detached { try await cleanup.remove(temporary, directory: false) }.value
            throw error
        }
    }
    public func mkdir(_ path: String) async throws {
        try await command(sftp: "mkdir \(RemotePath.quoted(path))", ftp: "MKD \(path)")
    }
    public func rename(_ source: String, to destination: String) async throws {
        try RemotePath.validate(source); try RemotePath.validate(destination)
        try await command(sftp: "rename \(RemotePath.quoted(source)) \(RemotePath.quoted(destination))", ftp: "RNFR \(source)\nRNTO \(destination)")
    }
    public func remove(_ path: String, directory: Bool) async throws {
        try await command(sftp: "\(directory ? "rmdir" : "rm") \(RemotePath.quoted(path))", ftp: "\(directory ? "RMD" : "DELE") \(path)")
    }
    private func command(sftp: String, ftp: String) async throws {
        _ = try await perform(path: "/", directory: true, mode: 3, commands: profile.protocolKind == .sftp ? sftp : ftp)
    }
}
