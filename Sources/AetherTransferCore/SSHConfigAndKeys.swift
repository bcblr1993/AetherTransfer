import Foundation
import CryptoKit

// MARK: - OpenSSH ~/.ssh/config Parser
public struct SSHConfigHostEntry: Identifiable, Hashable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?

    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        proxyJump: String? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }

    public func toServerProfile() -> ServerProfile {
        let resolvedHost = (hostName?.isEmpty == false) ? hostName! : alias
        let resolvedUser = (user?.isEmpty == false) ? user! : NSUserName()
        let resolvedPort = port ?? 22
        let resolvedKey = SSHConfigParser.expandTilde(identityFile ?? "")
        return ServerProfile(
            name: alias,
            group: "SSH Config",
            host: resolvedHost,
            port: resolvedPort,
            username: resolvedUser,
            protocolKind: .sftp,
            initialPath: "/",
            privateKeyPath: resolvedKey,
            useSSHAgent: resolvedKey.isEmpty
        )
    }
}

public enum SSHConfigParser {
    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }

    public static func expandTilde(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard trimmed.hasPrefix("~") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return home + String(trimmed.dropFirst(1))
        }
        return trimmed
    }

    public static func parseDefaultConfig() -> [SSHConfigHostEntry] {
        let url = defaultConfigURL()
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(content)
    }

    public static func parse(_ content: String) -> [SSHConfigHostEntry] {
        var entries: [SSHConfigHostEntry] = []
        var currentAliases: [String] = []
        var currentHostName: String?
        var currentUser: String?
        var currentPort: Int?
        var currentIdentityFile: String?
        var currentProxyJump: String?

        func flushCurrent() {
            for alias in currentAliases where !alias.contains("*") && !alias.contains("?") && !alias.isEmpty {
                entries.append(SSHConfigHostEntry(
                    alias: alias,
                    hostName: currentHostName,
                    user: currentUser,
                    port: currentPort,
                    identityFile: currentIdentityFile.map(expandTilde),
                    proxyJump: currentProxyJump
                ))
            }
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let lineWithoutComment = rawLine.split(separator: "#", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = lineWithoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            var rawValue = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue.hasPrefix("=") {
                rawValue = String(rawValue.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "host":
                flushCurrent()
                currentAliases = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                currentHostName = nil
                currentUser = nil
                currentPort = nil
                currentIdentityFile = nil
                currentProxyJump = nil
            case "hostname":
                currentHostName = value
            case "user":
                currentUser = value
            case "port":
                if let parsedPort = Int(value), (1...65535).contains(parsedPort) {
                    currentPort = parsedPort
                }
            case "identityfile":
                if currentIdentityFile == nil {
                    currentIdentityFile = value
                }
            case "proxyjump":
                if value.lowercased() == "none" || value.isEmpty {
                    currentProxyJump = nil
                } else {
                    currentProxyJump = value
                }
            default:
                break
            }
        }
        flushCurrent()
        return entries
    }
}

// MARK: - Built-in SSH Key Manager (Transmit Key Manager Parity)
public enum SSHKeyAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case ed25519 = "ed25519"
    case rsa4096 = "rsa"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ed25519: return "Ed25519 (推荐 · 高性能现代椭圆曲线)"
        case .rsa4096: return "RSA 4096-bit (传统兼容)"
        }
    }
    public var localizedDisplayName: String {
        switch self {
        case .ed25519: return L10n.tr("Ed25519 (推荐 · 现代安全密钥)", "Ed25519 (Recommended · Modern Curve)")
        case .rsa4096: return L10n.tr("RSA 4096 位 (广泛兼容)", "RSA 4096-bit (Legacy Compatible)")
        }
    }
}

public struct SSHKeyPairItem: Identifiable, Hashable, Sendable {
    public var id: String { privateKeyPath }
    public let name: String
    public let privateKeyPath: String
    public let publicKeyPath: String
    public let publicKeyContent: String
    public let keyType: String
    public let comment: String

    public init(name: String, privateKeyPath: String, publicKeyPath: String, publicKeyContent: String) {
        self.name = name
        self.privateKeyPath = privateKeyPath
        self.publicKeyPath = publicKeyPath
        let trimmed = publicKeyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicKeyContent = trimmed
        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        self.keyType = parts.first ?? "ssh"
        self.comment = parts.count >= 3 ? parts[2] : ""
    }
}

public enum SSHKeyManager {
    public static func defaultSSHDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    public static func listKeys(in directory: URL = defaultSSHDirectory()) -> [SSHKeyPairItem] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else {
            return []
        }
        let pubFiles = urls.filter { $0.pathExtension == "pub" }
        var items: [SSHKeyPairItem] = []
        for pubURL in pubFiles {
            let baseName = pubURL.deletingPathExtension().lastPathComponent
            let privURL = directory.appendingPathComponent(baseName)
            guard fm.fileExists(atPath: privURL.path),
                  let pubContent = try? String(contentsOf: pubURL, encoding: .utf8) else {
                continue
            }
            items.append(SSHKeyPairItem(
                name: baseName,
                privateKeyPath: privURL.path,
                publicKeyPath: pubURL.path,
                publicKeyContent: pubContent
            ))
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func generateKeyPair(
        name: String,
        algorithm: SSHKeyAlgorithm = .ed25519,
        comment: String = "",
        passphrase: String = "",
        in directory: URL = defaultSSHDirectory()
    ) throws -> SSHKeyPairItem {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.contains("/"), !cleanName.contains("..") else {
            throw TransferError.invalidPath
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let privURL = directory.appendingPathComponent(cleanName)
        let pubURL = directory.appendingPathComponent(cleanName + ".pub")
        if fm.fileExists(atPath: privURL.path) || fm.fileExists(atPath: pubURL.path) {
            throw TransferError.conflict(cleanName)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var args: [String] = []
        switch algorithm {
        case .ed25519:
            args += ["-t", "ed25519"]
        case .rsa4096:
            args += ["-t", "rsa", "-b", "4096"]
        }
        let effectiveComment = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(NSUserName())@AetherTransfer"
            : comment.trimmingCharacters(in: .whitespacesAndNewlines)
        args += ["-C", effectiveComment, "-f", privURL.path, "-N", passphrase, "-q"]
        proc.arguments = args

        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ssh-keygen error"
            throw TransferError.remote(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privURL.path)
        let pubContent = try String(contentsOf: pubURL, encoding: .utf8)
        return SSHKeyPairItem(
            name: cleanName,
            privateKeyPath: privURL.path,
            publicKeyPath: pubURL.path,
            publicKeyContent: pubContent
        )
    }
}

// MARK: - Trusted SSH Host Keys (Known Hosts Manager)

public struct TrustedHostKeyEntry: Identifiable, Hashable, Sendable {
    public var id: UUID { profileId }
    public let profileId: UUID
    public let profileName: String
    public let host: String
    public let port: Int
    public let protocolKind: TransferProtocol
    public let rawHostKey: String
    public let fingerprint: String

    public init(
        profileId: UUID,
        profileName: String,
        host: String,
        port: Int,
        protocolKind: TransferProtocol,
        rawHostKey: String,
        fingerprint: String
    ) {
        self.profileId = profileId
        self.profileName = profileName
        self.host = host
        self.port = port
        self.protocolKind = protocolKind
        self.rawHostKey = rawHostKey
        self.fingerprint = fingerprint
    }
}

public enum KnownHostsManager {
    public static func listTrustedHosts(from profiles: [ServerProfile]) -> [TrustedHostKeyEntry] {
        profiles.compactMap { profile in
            guard let rawKey = profile.trustedHostKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawKey.isEmpty else {
                return nil
            }
            let displayName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? profile.host
                : profile.name
            return TrustedHostKeyEntry(
                profileId: profile.id,
                profileName: displayName,
                host: profile.host,
                port: profile.port,
                protocolKind: profile.protocolKind,
                rawHostKey: rawKey,
                fingerprint: formattedFingerprint(rawKey)
            )
        }
        .sorted {
            let lhsName = $0.profileName
            let rhsName = $1.profileName
            let cmp = lhsName.localizedStandardCompare(rhsName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.host.localizedStandardCompare($1.host) == .orderedAscending
        }
    }

    @discardableResult
    public static func revokeHostKey(profileId: UUID, in profiles: inout [ServerProfile]) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }),
              profiles[index].trustedHostKey != nil else {
            return false
        }
        profiles[index].trustedHostKey = nil
        return true
    }

    public static func formattedFingerprint(_ rawKey: String) -> String {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Invalid key" }
        if trimmed.hasPrefix("SHA256:") {
            return trimmed
        }
        let base64Candidate: String
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        if tokens.count >= 2 && (tokens[0].hasPrefix("ssh-") || tokens[0].hasPrefix("ecdsa-")) {
            base64Candidate = String(tokens[1])
        } else {
            base64Candidate = trimmed
        }
        guard let data = Data(base64Encoded: base64Candidate), !data.isEmpty else {
            return "Invalid key"
        }
        let digest = Data(SHA256.hash(data: data)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }
}
