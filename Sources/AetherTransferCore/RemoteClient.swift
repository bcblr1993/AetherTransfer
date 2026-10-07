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
                         httpMethod: String? = nil, httpHeaders: [String] = [],
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
        let method = httpMethod ?? (mode == 0 ? "PROPFIND" : (mode == 2 ? "PUT" : "GET"))
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
            guard configuration == 0 else { throw TransferError.remote("无法配置 WebDAV 请求。") }
        }
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
                if profile.protocolKind.isWebDAV {
                    let status = at_response_code(box.pointer)
                    if status == 412 { throw TransferError.conflict(URL(fileURLWithPath: path).lastPathComponent) }
                    if status >= 300 {
                        let message: String
                        switch status {
                        case 301...399: message = "服务器重定向了请求。请直接填写最终 WebDAV 地址。"
                        case 401: message = "WebDAV 认证失败，请检查用户名和密码。"
                        case 403: message = "WebDAV 服务器拒绝了操作。"
                        case 404: message = "WebDAV 文件或目录不存在。"
                        case 409: message = "WebDAV 目标目录不存在或操作发生冲突。"
                        case 423: message = "WebDAV 文件被锁定，暂时无法修改。"
                        default: message = "WebDAV 请求失败（HTTP \(status)）。"
                        }
                        throw TransferError.remote(message)
                    }
                    if code == 0 {
                        let accepted: Set<Int> = switch method {
                        case "PROPFIND": [207]
                        case "GET": [200]
                        case "PUT", "MOVE", "COPY": [201, 204]
                        case "MKCOL": [201]
                        case "DELETE": [200, 204]
                        default: []
                        }
                        guard accepted.contains(status) else {
                            throw TransferError.remote("WebDAV 返回了不支持的结果（HTTP \(status)）；请刷新目录核对服务器状态。")
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
                return String(cString: at_result(box.pointer))
            }.value
        } onCancel: { box.cancel() }
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let response = try await perform(path: path, directory: true, mode: 0)
        if profile.protocolKind.isWebDAV {
            let origin = try profile.url(path: path, directory: true)
            return try await Task.detached { try WebDAVListing.parse(response, parent: path, origin: origin) }.value
        }
        return try DirectoryListing.parse(response, parent: RemotePath.normalize(path))
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
        try await command(sftp: "rename \(RemotePath.quoted(source)) \(RemotePath.quoted(destination))", ftp: "RNFR \(source)\nRNTO \(destination)")
    }
    public func remove(_ path: String, directory: Bool) async throws {
        if profile.protocolKind.isWebDAV {
            guard RemotePath.normalize(path) != "/" else { throw TransferError.invalidPath }
            if directory, !(try await list(path)).isEmpty {
                throw TransferError.remote("文件夹仍有内容，请先逐项确认删除。")
            }
            _ = try await perform(path: path, directory: directory, mode: 4, httpMethod: "DELETE")
            return
        }
        try await command(sftp: "\(directory ? "rmdir" : "rm") \(RemotePath.quoted(path))", ftp: "\(directory ? "RMD" : "DELE") \(path)")
    }
    private func command(sftp: String, ftp: String) async throws {
        _ = try await perform(path: "/", directory: true, mode: 3, commands: profile.protocolKind == .sftp ? sftp : ftp)
    }
}
