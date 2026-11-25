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
        self.pointer = pointer
        self.callback = callback
    }
    deinit { at_destroy(pointer) }
    func cancel() { at_cancel(pointer) }
}

public struct RemoteClient: RemoteTransport, Sendable {
    public let profile: ServerProfile
    public let credentials: Credentials
    public let speedLimitBytesPerSec: Int64?
    public let transferMode: TransferMode
    private let httpSession: URLSession

    public init(
        profile: ServerProfile,
        credentials: Credentials,
        speedLimitBytesPerSec: Int64? = nil,
        transferMode: TransferMode? = nil
    ) {
        self.profile = profile
        self.credentials = credentials
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.transferMode = transferMode ?? profile.defaultTransferMode
        self.httpSession = .shared
    }

    internal init(
        profile: ServerProfile,
        credentials: Credentials,
        speedLimitBytesPerSec: Int64? = nil,
        transferMode: TransferMode? = nil,
        httpSession: URLSession
    ) {
        self.profile = profile
        self.credentials = credentials
        self.speedLimitBytesPerSec = speedLimitBytesPerSec
        self.transferMode = transferMode ?? profile.defaultTransferMode
        self.httpSession = httpSession
    }

    public static func fingerprint(_ key: String) -> String {
        guard let data = Data(base64Encoded: key) else { return "Invalid key" }
        return "SHA256:" + Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public static func isFTPFamily(_ protocolKind: TransferProtocol) -> Bool {
        protocolKind == .ftp || protocolKind == .ftps || protocolKind == .ftpsExplicit
    }

    /// Resolves whether ASCII text transfer mode should be enabled for a given filename on FTP-family protocols.
    public func shouldUseAsciiTransfer(forFilename filename: String, transferModeOverride: TransferMode? = nil) -> Bool {
        guard Self.isFTPFamily(profile.protocolKind) else { return false }
        let effectiveMode = transferModeOverride ?? transferMode
        switch effectiveMode {
        case .automatic:
            return AsciiFileExtensions.isAsciiTransferFile(filename)
        case .ascii:
            return true
        case .binary:
            return false
        }
    }

    /// Validates a raw FTP/SFTP command before passing it to libcurl (`\0`, `\r`, `\n`, and blank commands are rejected).
    public static func validateRawCommand(_ command: String) throws -> String {
        let forbidden: Set<UnicodeScalar> = ["\0", "\r", "\n"]
        guard !command.unicodeScalars.contains(where: { forbidden.contains($0) }) else {
            throw TransferError.invalidPath
        }
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw TransferError.invalidPath
        }
        return trimmed
    }

    private func httpTransport() -> (any RemoteTransport)? {
        switch profile.protocolKind {
        case .webdav, .webdavs:
            return WebDAVClient(profile: profile, credentials: credentials, session: httpSession, speedLimitBytesPerSec: speedLimitBytesPerSec)
        case .s3:
            return S3Client(profile: profile, credentials: credentials, session: httpSession, speedLimitBytesPerSec: speedLimitBytesPerSec)
        case .b2:
            return B2Client(profile: profile, credentials: credentials, session: httpSession, speedLimitBytesPerSec: speedLimitBytesPerSec)
        case .azureBlob:
            return AzureBlobClient(profile: profile, credentials: credentials, session: httpSession, speedLimitBytesPerSec: speedLimitBytesPerSec)
        case .openstackSwift:
            return SwiftStorageClient(profile: profile, credentials: credentials, session: httpSession, speedLimitBytesPerSec: speedLimitBytesPerSec)
        case .sftp, .ftp, .ftps, .ftpsExplicit:
            return nil
        }
    }

    internal func createConfiguredRequest(
        path: String,
        directory: Bool = false,
        mode: Int32,
        transferFilename: String? = nil,
        offset: Int64? = nil,
        rangeEnd: Int64 = -1,
        expectedTotal: Int64 = -1
    ) throws -> OpaquePointer {
        let url = try profile.url(path: path, directory: directory)
        let request = url.withCString { url in profile.username.withCString { user in credentials.password.withCString { password in
            profile.privateKeyPath.withCString { key in credentials.passphrase.withCString { passphrase in
                (profile.trustedHostKey ?? "").withCString { fingerprint in at_create(url, user, password, key, passphrase, fingerprint) }
            }}
        }}}
        guard let request else { throw TransferError.remote(L10n.tr("无法创建传输连接。", "Unable to create transfer connection.")) }
        if profile.protocolKind == .sftp && profile.useSSHAgent {
            _ = at_set_ssh_agent(request, 1)
        }
        if profile.protocolKind == .ftpsExplicit {
            let result = at_set_ftps_explicit(request, 1)
            guard result == 0 else {
                at_destroy(request)
                throw TransferError.remote(L10n.tr("无法启用显式 FTPS TLS。", "Unable to enable Explicit FTPS TLS."))
            }
        }
        if let caBundle = Bundle.main.url(forResource: "cacert", withExtension: "pem") {
            let result = caBundle.path.withCString { at_set_ca_bundle(request, $0) }
            guard result == 0 else {
                at_destroy(request)
                throw TransferError.remote(L10n.tr("无法配置 TLS 证书根。", "Unable to configure TLS certificate roots."))
            }
        }
        let timeoutResult = at_set_connect_timeout(request, Int32(profile.connectTimeoutSeconds))
        guard timeoutResult == 0 else {
            at_destroy(request)
            throw TransferError.remote(L10n.tr("无法配置连接超时。", "Unable to configure connection timeout."))
        }
        if Self.isFTPFamily(profile.protocolKind) && !profile.ftpPassiveMode {
            let activeResult = at_set_ftp_active(request, 1)
            guard activeResult == 0 else {
                at_destroy(request)
                throw TransferError.remote(L10n.tr("无法启用主动 FTP 模式。", "Unable to enable Active FTP mode."))
            }
        }
        if Self.isFTPFamily(profile.protocolKind) && (mode == 1 || mode == 2), let transferFilename {
            // Byte-offset resumed transfers require binary mode so server and local byte offsets match.
            let useAscii = (offset == nil) && shouldUseAsciiTransfer(forFilename: transferFilename)
            let asciiResult = at_set_ascii_mode(request, useAscii ? 1 : 0)
            guard asciiResult == 0 else {
                at_destroy(request)
                throw TransferError.remote(L10n.tr("无法配置传输模式。", "Unable to configure transfer mode."))
            }
        }
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
        return request
    }

    private func perform(
        path: String,
        directory: Bool = false,
        mode: Int32,
        local: String = "",
        commands: String = "",
        transferFilename: String? = nil,
        offset: Int64? = nil,
        rangeEnd: Int64 = -1,
        expectedTotal: Int64 = -1,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> String {
        try await performWithMetadata(
            path: path,
            directory: directory,
            mode: mode,
            local: local,
            commands: commands,
            transferFilename: transferFilename,
            offset: offset,
            rangeEnd: rangeEnd,
            expectedTotal: expectedTotal,
            progress: progress
        ).output
    }

    private func performWithMetadata(
        path: String,
        directory: Bool = false,
        mode: Int32,
        local: String = "",
        commands: String = "",
        transferFilename: String? = nil,
        offset: Int64? = nil,
        rangeEnd: Int64 = -1,
        expectedTotal: Int64 = -1,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws -> (output: String, fileTime: Int64) {
        try Task.checkCancellation()
        let request = try createConfiguredRequest(
            path: path,
            directory: directory,
            mode: mode,
            transferFilename: transferFilename,
            offset: offset,
            rangeEnd: rangeEnd,
            expectedTotal: expectedTotal
        )
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
                let output = String(cString: at_result(box.pointer))
                let fileTime = at_file_time(box.pointer)
                return (output: output, fileTime: fileTime)
            }.value
        } onCancel: { box.cancel() }
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        if let transport = httpTransport() {
            return try await transport.list(path)
        }
        return try DirectoryListing.parse(await perform(path: path, directory: true, mode: 0), parent: RemotePath.normalize(path))
    }

    public func download(
        _ remote: String,
        to destination: URL,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingURL: URL? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        if let transport = httpTransport() {
            try await transport.download(
                remote,
                to: destination,
                overwrite: overwrite,
                offset: offset,
                stagingURL: stagingURL,
                progress: progress
            )
            return
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) && !overwrite {
            throw TransferError.conflict(destination.lastPathComponent)
        }
        let temporary = stagingURL ?? destination.deletingLastPathComponent()
            .appendingPathComponent(".aethertransfer-\(UUID().uuidString).part")
        defer {
            if stagingURL == nil { try? fm.removeItem(at: temporary) }
        }
        let (_, fileTime) = try await performWithMetadata(
            path: remote,
            mode: 1,
            local: temporary.path,
            transferFilename: (remote as NSString).lastPathComponent,
            offset: offset,
            progress: progress
        )
        try Task.checkCancellation()
        try await LocalFileCommit.commit(temporary, to: destination, overwrite: overwrite)

        if profile.preserveModificationDate {
            var mtime: Date?
            if fileTime > 0 {
                mtime = Date(timeIntervalSince1970: TimeInterval(fileTime))
            } else if !Task.isCancelled {
                let normalized = RemotePath.normalize(remote)
                let parent = RemotePath.parent(normalized)
                if let entries = try? await list(parent),
                   let match = entries.first(where: { $0.path == normalized }) {
                    mtime = match.modified
                }
            }
            if let mtime {
                try? await ResumeIO.run {
                    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: destination.path)
                }
            }
        }
    }

    public func upload(
        _ local: URL,
        to remote: String,
        overwrite: Bool = false,
        offset: Int64? = nil,
        stagingRemotePath: String? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void = { _ in }
    ) async throws {
        if let transport = httpTransport() {
            try await transport.upload(
                local,
                to: remote,
                overwrite: overwrite,
                offset: offset,
                stagingRemotePath: stagingRemotePath,
                progress: progress
            )
            return
        }

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
            let filename = name.isEmpty ? local.lastPathComponent : name
            _ = try await perform(
                path: temporary,
                mode: 2,
                local: local.path,
                transferFilename: filename,
                offset: offset,
                progress: progress
            )
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
        if let transport = httpTransport() {
            try await transport.mkdir(path)
            return
        }
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
        if profile.protocolKind == .s3 {
            return try await S3Client(
                profile: profile,
                credentials: credentials,
                session: httpSession,
                speedLimitBytesPerSec: speedLimitBytesPerSec
            ).listRecursive(remotePath)
        }
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
        try RemotePath.validate(source)
        try RemotePath.validate(destination)
        if let transport = httpTransport() {
            try await transport.rename(source, to: destination)
            return
        }
        try await command(
            sftp: "rename \(RemotePath.quoted(source)) \(RemotePath.quoted(destination))",
            ftp: "RNFR \(source)\nRNTO \(destination)"
        )
    }

    public func remove(_ path: String, directory: Bool) async throws {
        if let transport = httpTransport() {
            try await transport.remove(path, directory: directory)
            return
        }
        try await command(
            sftp: "\(directory ? "rmdir" : "rm") \(RemotePath.quoted(path))",
            ftp: "\(directory ? "RMD" : "DELE") \(path)"
        )
    }

    public func chmod(_ path: String, permissions: POSIXPermissions) async throws {
        try RemotePath.validate(path)
        guard profile.protocolKind == .sftp
                || profile.protocolKind == .ftp
                || profile.protocolKind == .ftps
                || profile.protocolKind == .ftpsExplicit else {
            return
        }
        let octal = permissions.octalString
        let octal3 = String(octal.suffix(3))
        try await command(sftp: "chmod \(octal) \(RemotePath.quoted(path))", ftp: "SITE CHMOD \(octal3) \(path)")
    }

    public func statMetadata(_ remotePath: String) async throws -> RemoteObjectMetadata {
        if let transport = httpTransport() {
            return try await transport.statMetadata(remotePath)
        }
        let normalized = RemotePath.normalize(remotePath)
        let parent = RemotePath.parent(normalized)
        let entries = try await list(parent)
        guard let entry = entries.first(where: { $0.path == normalized }) else {
            throw TransferError.remote(L10n.tr("未找到远程对象：\(normalized)", "Remote object not found: \(normalized)"))
        }
        return RemoteObjectMetadata(size: entry.size, modified: entry.modified)
    }

    public func updateMetadata(_ remotePath: String, metadata: RemoteObjectMetadata) async throws {
        if let transport = httpTransport() {
            try await transport.updateMetadata(remotePath, metadata: metadata)
            return
        }
        throw TransferError.remote(L10n.tr("协议 \(profile.protocolKind.title) 暂不支持修改对象元数据。", "Metadata updates are not yet supported for \(profile.protocolKind.title)."))
    }

    public func presignedURL(for remotePath: String, expiresIn seconds: Int = 3600) async throws -> URL {
        if profile.protocolKind == .b2 {
            return try await B2Client(
                profile: profile,
                credentials: credentials,
                session: httpSession,
                speedLimitBytesPerSec: speedLimitBytesPerSec
            ).presignedURL(for: remotePath, expiresIn: seconds)
        }
        return try presignedDownloadURL(for: remotePath, expiresIn: seconds)
    }

    public func presignedDownloadURL(for remotePath: String, expiresIn seconds: Int = 3600) throws -> URL {
        switch profile.protocolKind {
        case .s3:
            return try S3Client(profile: profile, credentials: credentials).presignedDownloadURL(for: remotePath, expiresIn: seconds)
        case .azureBlob:
            return try AzureBlobClient(profile: profile, credentials: credentials).presignedDownloadURL(for: remotePath, expiresIn: seconds)
        default:
            guard let url = URL(string: try profile.url(path: remotePath)) else {
                throw TransferError.invalidConnection
            }
            return url
        }
    }

    /// Sends a raw FTP/SFTP command off the main thread using `at_perform_raw`, keeping SFTP host-key and TLS checks enabled.
    public func sendRawCommand(_ command: String, path: String = "/") async throws -> RawCommandResult {
        try Task.checkCancellation()
        let validatedCommand = try Self.validateRawCommand(command)
        let sanitizedCommand = TranscriptRedactor.sanitize(validatedCommand)
        guard httpTransport() == nil else {
            throw TransferError.remote(L10n.tr(
                "协议 \(profile.protocolKind.title) 不支持发送原始命令。",
                "Raw commands are not supported for \(profile.protocolKind.title)."
            ))
        }
        let request = try createConfiguredRequest(path: path, directory: true, mode: 3)
        let box = RequestBox(pointer: request, callback: { _ in })
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try Task.checkCancellation()
                let code = validatedCommand.withCString { cmdPtr in
                    at_perform_raw(box.pointer, cmdPtr)
                }
                if code == 42 { throw CancellationError() }

                let rawOutput = String(cString: at_result(box.pointer))
                let rawError = String(cString: at_error(box.pointer))

                if code != 0 {
                    let key = String(cString: at_host_key(box.pointer))
                    if !key.isEmpty && key != profile.trustedHostKey {
                        throw TransferError.hostKeyRequired(key: key, changed: profile.trustedHostKey != nil)
                    }
                    // CURLE_QUOTE_ERROR (21): server responded with an error reply to the quote command.
                    if code == 21 {
                        let combined = rawOutput.isEmpty ? rawError : rawOutput
                        return RawCommandResult(
                            command: sanitizedCommand,
                            output: TranscriptRedactor.sanitize(combined),
                            succeeded: false
                        )
                    }
                    throw TransferError.remote(TranscriptRedactor.sanitize(rawError))
                }

                let outputText = rawOutput.isEmpty ? rawError : rawOutput
                return RawCommandResult(
                    command: sanitizedCommand,
                    output: TranscriptRedactor.sanitize(outputText),
                    succeeded: true
                )
            }.value
        } onCancel: {
            box.cancel()
        }
    }

    private func command(sftp: String, ftp: String) async throws {
        _ = try await perform(path: "/", directory: true, mode: 3, commands: profile.protocolKind == .sftp ? sftp : ftp)
    }
}
